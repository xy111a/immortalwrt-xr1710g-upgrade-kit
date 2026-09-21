#!/bin/bash
# upgrade_router.sh — Gemtek XR1710G (naoki66 ImmortalWrt) 升级编排器, Mac 侧运行
#
# 安全模型(四层):
#   T0 预防: 路由器首启动经 uci-defaults 自举, 恢复到用户配置的 LAN 地址 + 原 SSID, 刷机窗口内 Mac 无需人工接手
#   T1 检测: 本脚本轮询重连 + 终验
#   T2 恢复: U-Boot 常住兜底 bootcmd=run boot_ubi || http_recovery (已实测在位) -> 刷坏自动进 Recovery, 免拆机
#   T3 回退: 刷前自动解析当前运行版本的本地 itb 作为回退镜像 (见 resolve_rollback); 无匹配时退回 FALLBACK_ITB(9/1, 仅最后兜底)
#
# 用法:
#   ./upgrade_router.sh            # 真正执行升级 (会触发路由器重启)
#   ./upgrade_router.sh --dry-run  # 只校验前置条件, 打印将执行的命令, 不刷机
#
# 前置(推荐, 非强制):
#   - 主路径可走 WiFi: 上传 kit+itb、触发 sysupgrade 均经当前 WiFi; 路由器重启后 uci-defaults 自举恢复
#     原 SSID 并 'wifi reload', Mac 自动重连, 全程无需插线。
#   - 但请把一根以太网线放在手边: 万一自举失败(路由回退出厂, 原 SSID 消失), WiFi 即不可达,
#     此时插有线是唯一入口; 插线后 Mac 有线网卡须设为 DHCP 自动获取(出厂态=192.168.1.x / 自举成功=192.168.88.x)。
#   - 恢复/诊断时若路由在出厂态, 你的路由器地址/别名连不上, 改用出厂默认: ssh root@192.168.1.1
#   - Mac 的 SSH 公钥已内置在 kit.tar.gz 的 etc/dropbear/authorized_keys (全清刷后仍可 key 登录)
#   - 升级后 root 密码由升级前从活路由器抓取的 shadow hash 自动恢复, 与升级前一致; 如需改密: ssh <路由器地址> 'passwd root'
#   - 在 ~/.ssh/config 配置你的路由器 SSH 地址 (如 Host <router> -> 192.168.x.1); 刷机后 host key 会变, 终验用 accept-new

set -u
# ---------- 参数解析 ----------
#   --dry-run  只校验前置条件 + 打印将执行步骤, 不刷机
#   --auto     强终验失败自动回退 (供 router_watch.sh 调用)
#   --force    忽略 EXPECT_SHA 不匹配强制刷 (仅紧急恢复用, 慎用)
DRY=0; AUTO=0; FORCE=0; ROUTER_OVERRIDE=""; ITB_OVERRIDE=""; EXPECT_SHA_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;;
    --auto)    AUTO=1;;
    --force)   FORCE=1;;
    --router)  ROUTER_OVERRIDE="${2:-}"; shift;;
    --router=*) ROUTER_OVERRIDE="${1#*=}";;
    --itb)     ITB_OVERRIDE="${2:-}"; shift;;
    --itb=*)   ITB_OVERRIDE="${1#*=}";;
    --expect-sha) EXPECT_SHA_OVERRIDE="${2:-}"; shift;;
    --expect-sha=*) EXPECT_SHA_OVERRIDE="${1#*=}";;
    *) ;;
  esac
  shift
done

# 退出即清理: 升级过程中在 /tmp 生成的注入 kit / 构建目录含 root shadow hash, 绝不落盘
trap 'rm -rf /tmp/kit_build /tmp/kit_injected.tar.gz 2>/dev/null' EXIT

REPO="naoki66/ImmortalWrt-for-Gemtek-XR1710G"
PREP_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$PREP_DIR/kit.tar.gz"
ROUTER="${ROUTER_OVERRIDE:-}"
EXPECT_SHA="${EXPECT_SHA_OVERRIDE:-}"
# 回退镜像: 默认自动解析为"当前路由器正在运行的版本"对应的本地 itb (刷前预飞时按 commit hash 匹配)。
# 旧 9/1 硬编码镜像仅作最后兜底 —— 升级到 9/8 后它已非当前版本, 不应再作为首选回退。
FALLBACK_ITB="$PREP_DIR/../router-backup-20260901/immortalwrt-xr1710g-20260901-131ef84fe9.itb"
# 升级前配置快照(sysupgrade -b)的本地路径, 供自动回退连带还原; 空=未备份
PREUPG_BACKUP=""

die(){ echo "❌ $1"; exit 1; }

# 解析待刷 itb: 优先级 --itb > 官方最新 release tag 本地匹配 > ls -t 最新(带警告)
# 不依赖 mtime 选 target, 避免回退 itb 比目标新时被误选为刷机目标
resolve_target_itb(){
  [ -n "$ITB_OVERRIDE" ] && { [ -f "$ITB_OVERRIDE" ] && { printf '%s' "$ITB_OVERRIDE"; return 0; } || { echo "❌ --itb 指定文件不存在: $ITB_OVERRIDE" >&2; return 1; }; }
  # 直接取官方最新 release 的 itb 资源名精确匹配(与 router_watch.sh 选源一致);
  # 注意: release tag 的哈希与 itb 文件名内的 commit 哈希不同, 不能靠 tag 哈希去 grep 文件名
  local name itb
  name=$(gh api "repos/$REPO/releases/latest" --jq '[.assets[] | select(.name|test("gemtek_xr1710g")) | .name][0]' 2>/dev/null)
  if [ -n "$name" ] && [ -f "$PREP_DIR/$name" ]; then
    printf '%s' "$PREP_DIR/$name"; return 0
  fi
  # 兜底: 取最新 mtime 的 itb, 但可能误选回退镜像, 仅警告(本地未下载最新版时)
  itb=$(ls -t "$PREP_DIR"/*.itb 2>/dev/null | head -1)
  [ -n "$itb" ] && { echo "⚠️ 未能从官方 release 解析目标 itb(本地可能未下载最新版), 退回按 mtime 选最新(可能误选回退镜像): $(basename "$itb")" >&2; printf '%s' "$itb"; return 0; }
  return 1
}

# macOS 桌面通知(仅本机提示, 远程无人值守时有反馈); 非 macOS 或无 osascript 时静默
notify(){
  local title="$1" msg="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null || true
  fi
}

# 解析路由器 SSH 目标 (不写死任何个人别名/IP)。优先级:
#   1. 环境变量 ROUTER         2. --router 参数
#   3. 本地 router-target.conf (git 忽略, 不入库)   4. 自动探测 ~/.ssh/config 中的 openwrt/immortalwrt/router 主机
#   5. 交互询问 (并把结果持久化到 router-target.conf, 下次免问)
# 全部失败时返回非 0, 由调用处 die。
resolve_router(){
  [ -n "$ROUTER" ] && { R_HOST="${ROUTER#*@}"; return 0; }
  if [ -f "$PREP_DIR/router-target.conf" ]; then
    ROUTER="$(cat "$PREP_DIR/router-target.conf" 2>/dev/null)"
    [ -n "$ROUTER" ] && { R_HOST="${ROUTER#*@}"; return 0; }
  fi
  if [ -f "$HOME/.ssh/config" ] && command -v awk >/dev/null 2>&1; then
    local cand
    cand=$(awk '/^[Hh]ost /{h=$2} {l=tolower($0)} (l ~ /openwrt/||l ~ /immortalwrt/||l ~ /router/) && h{print h; exit}' "$HOME/.ssh/config" 2>/dev/null)
    if [ -n "$cand" ]; then
      if [ -t 0 ]; then
        printf '检测到 ~/.ssh/config 中的主机 "%s", 用作路由器地址? [Y/n] ' "$cand" >&2
        local _ans=""
        read -r _ans </dev/tty 2>/dev/null
        case "$_ans" in n|N) ;; *) ROUTER="$cand";; esac
      else
        ROUTER="$cand"
      fi
    fi
  fi
  if [ -z "$ROUTER" ]; then
    if [ -t 0 ]; then
      printf '请输入路由器的 SSH 地址 (如 root@192.168.1.1, 或 ssh config 中的主机别名): ' >&2
      read -r ROUTER </dev/tty 2>/dev/null
    fi
  fi
  if [ -n "$ROUTER" ]; then
    printf '%s\n' "$ROUTER" > "$PREP_DIR/router-target.conf" 2>/dev/null
    R_HOST="${ROUTER#*@}"
    return 0
  fi
  return 1
}

ITB=$(resolve_target_itb) || die "找不到待刷 itb (期望 $PREP_DIR/*.itb, 应为最新下载的那个; 或用 --itb 显式指定)"
[ -f "$KIT" ]    || die "找不到 kit.tar.gz"

# 自动解析回退镜像: 取路由器当前运行的 commit hash, 在本地 firmware-prep 匹配同名 itb。
# 这样每次升级都会把"刚跑的版本"作为回退目标 —— 即自动备份当前版本。
resolve_rollback(){
  local rev hash itb
  rev=$(ssh -o ConnectTimeout=8 "$ROUTER" 'grep DISTRIB_REVISION /etc/openwrt_release' 2>/dev/null) || return 1
  hash=$(printf '%s' "$rev" | grep -oE '[0-9a-f]{7,40}' | tail -1)  # 取末尾 hex 串; 避开 DISTRIB_REVISION 行尾单引号对 $ 锚点的干扰
  [ -n "$hash" ] || return 1
  itb=$(ls "$PREP_DIR"/*.itb 2>/dev/null | grep -i "$hash" | head -1)
  [ -n "$itb" ] && { printf '%s' "$itb"; return 0; }
  return 1
}

# 升级前对当前运行配置做快照(sysupgrade -b), 落本地 backups/ 作为"配置级回退点"。
# 与 resolve_rollback 的固件级回退互补: 固件刷成功但配置被搞坏时, 可手动 scp 此备份回路由 sysupgrade -f 还原。
backup_config(){
  local rev hash ts dest
  rev=$(ssh -o ConnectTimeout=8 "$ROUTER" 'grep DISTRIB_REVISION /etc/openwrt_release' 2>/dev/null) || return 0
  hash=$(printf '%s' "$rev" | grep -oE '[0-9a-f]{7,40}' | tail -1)  # 取末尾 hex 串; 避开 DISTRIB_REVISION 行尾单引号对 $ 锚点的干扰
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$PREP_DIR/backups"
  dest="$PREP_DIR/backups/pre-upg-${hash:-unknown}-$ts.tar.gz"
  if ssh -o ConnectTimeout=15 "$ROUTER" 'sysupgrade -b /tmp/pre-upg.tar.gz' 2>/dev/null \
     && scp -o ConnectTimeout=15 "$ROUTER:/tmp/pre-upg.tar.gz" "$dest" 2>/dev/null; then
    echo "✅ 升级前配置已备份: $(basename "$dest")"
    PREUPG_BACKUP="$dest"
  else
    echo "⚠️ 配置备份失败(不影响升级, 仅失去配置级回退点)"
  fi
}

# 升级前从活路由器抓取"当前运行态"配置注入 kit (无明文存储, kit 不进 Git):
#   - root 密码 shadow hash
#   - WiFi key + 三频 SSID (避免源码硬编码个人信息)
#   - OpenClash 配置/订阅 (订阅会过期, 必须取活路由当前的, 不能烘焙旧文件)
# 注入后的 kit 仅存在于 /tmp, 脚本退出即被 trap 清理。
collect_runtime(){
  local s w ss0 ss1 ss2
  s=$(ssh -o ConnectTimeout=8 "$ROUTER" "grep '^root:' /etc/shadow" 2>/dev/null) || s=""
  # 取 radio0/radio1 的 WiFi key (两频应一致); 任一非空即可
  w=$(ssh -o ConnectTimeout=8 "$ROUTER" "uci get wireless.@wifi-iface[0].key 2>/dev/null; uci get wireless.@wifi-iface[1].key 2>/dev/null" 2>/dev/null) || w=""
  w=$(printf '%s\n' "$w" | grep -v '^$' | head -1)
  [ -n "$w" ] || { echo "❌ 无法抓取 WiFi key, 中止升级(避免生成无密码开放 WiFi)"; exit 1; }
  ss0=$(ssh -o ConnectTimeout=8 "$ROUTER" "uci get wireless.@wifi-iface[0].ssid 2>/dev/null") || ss0=""
  ss1=$(ssh -o ConnectTimeout=8 "$ROUTER" "uci get wireless.@wifi-iface[1].ssid 2>/dev/null") || ss1=""
  ss2=$(ssh -o ConnectTimeout=8 "$ROUTER" "uci get wireless.@wifi-iface[2].ssid 2>/dev/null") || ss2=""
  lanip=$(ssh -o ConnectTimeout=8 "$ROUTER" "uci get network.lan.ipaddr 2>/dev/null") || lanip=""

  local build=/tmp/kit_build newkit=/tmp/kit_injected.tar.gz
  rm -rf "$build"; mkdir -p "$build/etc"
  tar -xzf "$KIT" -C "$build" 2>/dev/null || { echo "❌ 解包 kit 失败"; exit 1; }
  # 用活路由当前 OpenClash 配置覆盖 kit 内烘焙的旧订阅/规则 (保持订阅有效, 避免升级后连不上)
  if ssh -o ConnectTimeout=10 "$ROUTER" "tar -czf - -C / etc/config/openclash etc/openclash" 2>/dev/null \
       | tar -xzf - -C "$build" 2>/dev/null; then
    echo "✅ 已抓取活路由 OpenClash 配置(订阅/规则)覆盖 kit 内旧文件"
  else
    echo "⚠️ OpenClash 配置抓取失败, 沿用 kit 内烘焙版本"
  fi
  # 抓取活路由当前 DHCP 静态租约(host 段) -> 写入 kit 的 etc/dhcp-hosts.uci
  # 格式: 每行 "host <name> <mac> <ip> <leasetime>"; 首启动自举据此重建, 不写死 MAC
  if ssh -o ConnectTimeout=8 "$ROUTER" 'for sec in $(uci show dhcp 2>/dev/null | grep -oE "dhcp.@host\[[0-9]+\]" | sort -u); do n=$(uci -q get "${sec}.name"); m=$(uci -q get "${sec}.mac"); ip=$(uci -q get "${sec}.ip"); lt=$(uci -q get "${sec}.leasetime"); [ -n "$m" ] && [ -n "$ip" ] && echo "host ${n:-unknown} $m $ip ${lt:-infinite}"; done' 2>/dev/null > "$build/etc/dhcp-hosts.uci"; then
    if [ -s "$build/etc/dhcp-hosts.uci" ]; then
      echo "✅ 已抓取活路由 DHCP 静态租约 ($(wc -l < "$build/etc/dhcp-hosts.uci") 条) 注入 kit"
    else
      echo "ℹ️ 活路由无 DHCP 静态租约, 跳过"
    fi
  else
    echo "⚠️ DHCP 静态租约抓取失败(不影响升级, 升级后无静态租约)"
  fi
  {
    [ -n "$s" ]  && echo "ROOT_SHADOW=$s"
    echo "WIFI_KEY=$w"
    [ -n "$ss0" ] && echo "SSID0=$ss0"
    [ -n "$ss1" ] && echo "SSID1=$ss1"
    [ -n "$ss2" ] && echo "SSID2=$ss2"
    [ -n "$lanip" ] && echo "LAN_IP=$lanip"
  } > "$build/etc/router-secrets"
  chmod 600 "$build/etc/router-secrets"
  tar -czf "$newkit" -C "$build" . || { echo "❌ 重打 kit 失败"; exit 1; }
  KIT="$newkit"
  if [ -n "$s" ]; then echo "✅ 已注入 root hash + WiFi key + 三频 SSID + LAN IP + OpenClash 配置到 kit (无明文存储)"; else echo "⚠️ 已注入 WiFi key/SSID/LAN IP/OpenClash, 但 root shadow 抓取失败(升级后仅 key 登录)"; fi
}

resolve_router || die "未配置路由器 SSH 地址 — 请用 --router root@192.168.1.1 或 ROUTER 环境变量指定, 或在首次运行时按提示输入"

echo "=== 预检 ==="
echo "ITB : $(basename "$ITB")"
echo "KIT : $(basename "$KIT")"
ssh -o ConnectTimeout=8 "$ROUTER" 'echo "路由器可达: $(grep DISTRIB_REVISION /etc/openwrt_release)"' \
  || die "无法 SSH 到路由器 (确认本机已连路由器: WiFi 或有线均可, 且 SSH 地址解析有效; 可用 --router 显式指定或配置 router-target.conf)"

# 解析回退镜像(当前运行版本对应的本地 itb = 自动备份点)
ROLLBACK=$(resolve_rollback 2>/dev/null)
if [ -z "$ROLLBACK" ]; then
  if [ -n "$FALLBACK_ITB" ] && [ -f "$FALLBACK_ITB" ]; then
    ROLLBACK="$FALLBACK_ITB"
    echo "⚠️ 未匹配到当前运行版本的本地 itb, 退回旧回退镜像: $(basename "$ROLLBACK")"
  else
    echo "⚠️ 未找到任何回退镜像 —— 升级前请准备当前版本 itb 以防需回退"
  fi
else
  echo "回退: $(basename "$ROLLBACK") (已自动匹配当前运行版本)"
fi

if [ "$DRY" = "1" ]; then
  echo "=== DRY-RUN: 不执行升级 ==="
  echo "将执行的步骤:"
  echo "  0. 升级前配置快照 sysupgrade -b -> backups/ ; 并从活路由抓取 root/WiFi key/三频 SSID/OpenClash/DHCP 静态租约 注入 kit"
  echo "  1. scp $(basename "$ITB") $(basename "$KIT") -> $ROUTER:/tmp/"
  echo "  1b. 路由器侧复核 itb sha256 (防止 WiFi 上传损坏)"
  echo "  2. ssh $ROUTER 'sysupgrade -n -f /tmp/kit.tar.gz /tmp/$(basename "$ITB")' (n=不保留当前配置, 严格全清)"
  echo "     (nohup 后台执行, 路由器重启, SSH 断开, 本脚本随后轮询重连)"
  echo "  3. 轮询重连 (每 5s, 最多 40 次) 于路由器地址 / 常见出厂 IP (192.168.1.1 等)"
  echo "  4. 终验: 版本 / flow offload / 三频 / OpenClash / DNS / U-Boot (accept-new 接受新 host key)"
  echo "=== DRY-RUN 结束 ==="
  exit 0
fi

# 升级前: 配置快照(配置级回退点) + 抓取当前运行态注入 kit (dry-run 不执行)
backup_config
collect_runtime

echo "=== 上传固件与 kit ==="
scp "$ITB" "$KIT" "$ROUTER:/tmp/" || die "上传失败"

# 刷机前在路由器侧复核 itb 完整性: WiFi 上传若抖动传坏会直接刷入损坏镜像(变砖), 先拦截
ACT_SHA=$(ssh -o ConnectTimeout=10 "$ROUTER" "sha256sum /tmp/$(basename "$ITB")" 2>/dev/null | awk '{print $1}')
[ -n "$ACT_SHA" ] || die "无法在路由器侧计算 itb sha256 (上传可能不完整)"

# EXPECT_SHA 优先级: --expect-sha 显式 > 官方 sha256sums 运行时派生 > 退出(防刷错)
derive_expect_sha(){
  command -v gh >/dev/null 2>&1 || { echo "  (无 gh CLI, 跳过官方校验, 需 --expect-sha 或 --force)"; return 1; }
  local sums_url
  sums_url=$(gh api "repos/$REPO/releases/latest" --jq '[.assets[] | select(.name=="sha256sums") | .browser_download_url][0]' 2>/dev/null)
  [ -n "$sums_url" ] || { echo "  (未找到官方 sha256sums)"; return 1; }
  curl -fsSL "$sums_url" 2>/dev/null | grep "$(basename "$ITB")" | awk '{print $1}'; return 0
}
if [ -z "$EXPECT_SHA" ]; then
  EXPECT_SHA=$(derive_expect_sha)
fi
if [ -n "$EXPECT_SHA" ] && [ "$ACT_SHA" = "$EXPECT_SHA" ]; then
  echo "✅ itb 完整性校验通过 (sha256 匹配官方, 可安全刷入)"
elif [ "$FORCE" = "1" ]; then
  echo "⚠️ itb sha256 未校验(期望 ${EXPECT_SHA:-未知}, 实得 $ACT_SHA), --force 已忽略, 继续刷入"
else
  die "itb sha256 校验未通过 (期望 ${EXPECT_SHA:-未能获取官方校验值}, 实得 $ACT_SHA) — 上传可能损坏或无法获取官方校验值; 重试上传, 或用 --force / --expect-sha 跳过"
fi

echo "=== 触发干净刷 (严格全清 -n + uci-defaults 自举) ==="
echo "⚠️ 路由器即将重启, SSH 会断开, 本脚本自动轮询重连, 无需人工介入"
# nohup + & 让 sysupgrade 在路由后台跑, ssh 立即返回, 避免连接在 reboot 时被重置误判
ssh "$ROUTER" "nohup sysupgrade -n -f /tmp/kit.tar.gz /tmp/$(basename "$ITB") >/tmp/upg.log 2>&1 &" || true

# 干净刷后路由器生成全新 SSH host key; 先清掉本地旧 key, 否则 accept-new 会把"密钥变更"误判为拒绝 → 误报重连失败
ssh-keygen -R "$R_HOST" 2>/dev/null; ssh-keygen -R "$ROUTER" 2>/dev/null
echo "=== 轮询重连 (每 5s, 最多 40 次 = 200s) ==="
OK=0
for i in $(seq 1 40); do
  # 先试用户配置的地址(别名或 IP), 再退到常见出厂默认 IP (首启动自举可能重置为出厂态)
  tried="$ROUTER"
  for ip in 192.168.1.1 192.168.0.1 10.0.0.1; do tried="$tried root@$ip"; done
  for target in $tried; do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "$target" 'true' 2>/dev/null; then
      echo "✅ 第 $i 轮经 $target 重连成功"; ROUTER="$target"; OK=1; break 2
    fi
  done
  sleep 5
done
[ "$OK" = "1" ] || die "重连失败 — 可能进入 Recovery 或需手动介入 (U-Boot 兜底已就位, 可访问 HTTP Recovery 重刷)"

echo "=== 终验 (在路由器上, accept-new 接受全清后的新 host key) ==="
ssh -o StrictHostKeyChecking=accept-new "$ROUTER" '
set -x
echo "--- 版本 ---"; grep DISTRIB_REVISION /etc/openwrt_release
echo "--- flow offload 计数 ---"; nft list counters 2>/dev/null | grep -iE "OFFLOAD|HW_OFFLOAD" | head
echo "--- 三频 disabled 状态 ---"; uci show wireless | grep -E "radio[0-9]\.disabled"
echo "--- OpenClash 进程 ---"; pgrep -f clash >/dev/null && echo "clash 运行中" || echo "clash 未运行"
echo "--- OpenClash 安装日志尾部 ---"; tail -5 /tmp/zzz-postinstall.log 2>/dev/null
echo "--- OpenClash DNS 解析 (foreign) ---"; nslookup github.com 127.0.0.1 2>/dev/null | awk "/Address: /{print \$2}" | grep -v "#53" | tail -1
echo "--- dnsmasq 是否指向 OpenClash ---"; uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null; uci get dhcp.@dnsmasq[0].server 2>/dev/null
echo "--- U-Boot 兜底 (直接读活跃 UBI 卷 ubootenv2/ubootenv, 绕开 fw_env.config stale mtd0) ---"; ( cat /dev/ubi0_2 2>/dev/null; cat /dev/ubi0_1 2>/dev/null; fw_printenv bootcmd recovery_mtd boot_ubi 2>/dev/null ) | strings | grep -E "^bootcmd=|^recovery_mtd=|^boot_ubi=" | sort -u
echo "--- 首启动自举日志尾部 ---"; tail -5 /tmp/zzz-restore.log 2>/dev/null
'
echo "=== 升级流程结束 ==="
echo "若终验全部通过, 升级成功。若 OpenClash 仍未起(rc.local 未跑完), 在 Mac 侧执行:"
echo "  ssh \"$ROUTER\" 'apk add luci-app-openclash && /etc/init.d/openclash restart'"
echo "升级后请改 root 密码: ssh \"$ROUTER\" 'passwd root'"

# ---------- 强终验 (仅 --auto 模式: 判定成败并触发回退) ----------
# 判定: 外网通 + 代理DNS通(clash@7874) + radio0/1 启用 + clash 进程在 → 成功
verify_router(){
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$ROUTER" '
    curl -fsS --max-time 6 https://www.google.com >/dev/null 2>&1 || ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 || { echo "FAIL: 外网不通"; exit 1; }
    nslookup github.com 127.0.0.1 >/dev/null 2>&1 || { echo "FAIL: 代理DNS不通"; exit 1; }
    for r in radio0 radio1; do
      [ "$(uci get wireless.$r.disabled 2>/dev/null)" = "1" ] && { echo "FAIL: $r 被禁用"; exit 1; }
    done
    pgrep -f clash >/dev/null 2>&1 || { echo "FAIL: clash 未运行"; exit 1; }
    exit 0
  ' 2>/dev/null
}

auto_rollback(){
  echo "⚠️ 强终验失败, 自动回退到 $(basename "$ROLLBACK")"
  if [ ! -f "$ROLLBACK" ]; then
    echo "❌ 无回退镜像, 依赖 U-Boot http_recovery 硬件兜底, 需手动进 Recovery 重刷"
    notify "路由器升级回退失败" "无回退镜像, 需手动进 U-Boot Recovery"
    return 1
  fi
  scp "$ROLLBACK" "$ROUTER":/tmp/rb.itb || { notify "路由器升级回退失败" "回退镜像上传失败"; return 1; }
  # 连带还原升级前的配置快照(配置级回退): 旧固件 + 旧配置 = 完全一致的可工作状态
  local rbcmd="sysupgrade -F /tmp/rb.itb"
  if [ -n "$PREUPG_BACKUP" ] && [ -f "$PREUPG_BACKUP" ]; then
    scp "$PREUPG_BACKUP" "$ROUTER":/tmp/rb-config.tar.gz || return 1
    rbcmd="sysupgrade -F -f /tmp/rb-config.tar.gz /tmp/rb.itb"
    echo "   同时还原升级前配置快照(配置级回退): $(basename "$PREUPG_BACKUP")"
  fi
  ssh -o StrictHostKeyChecking=accept-new "$ROUTER" "nohup $rbcmd >/tmp/rb.log 2>&1 &" || true
  ssh-keygen -R "$R_HOST" 2>/dev/null; ssh-keygen -R "$ROUTER" 2>/dev/null
  for i in $(seq 1 40); do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "$ROUTER" 'true' 2>/dev/null; then break; fi
    sleep 5
  done
  if verify_router; then
    echo "✅ 回退后强终验通过"; notify "路由器已自动回退" "旧固件+旧配置已恢复, 强终验通过"
  else
    echo "❌ 回退后仍失败, 需手动进 U-Boot Recovery"
    notify "路由器升级回退失败" "回退后仍终验失败, 需手动进 U-Boot Recovery"
  fi
}

# 保守清理旧 itb: 保留最新 3 个, 且永不删除回退镜像(上一版本)与兜底镜像
prune_old_itbs(){
  local n f
  n=0
  for f in $(ls -t "$PREP_DIR"/*.itb 2>/dev/null); do
    n=$((n+1))
    if [ "$n" -gt 3 ]; then
      case "$f" in
        "$FALLBACK_ITB"|"$ROLLBACK") continue;;
      esac
      echo "🧹 清理旧 itb: $(basename "$f")"
      rm -f "$f"
    fi
  done
}

if [ "$AUTO" = "1" ]; then
  echo "=== 强终验 (--auto) ==="
  if verify_router; then
    echo "✅ 强终验通过: 外网/代理DNS/三频/clash 均正常, 升级成功"
    prune_old_itbs
    notify "路由器升级成功" "固件已更新, 强终验通过"
  else
    echo "❌ 强终验未通过"
    auto_rollback
  fi
fi
