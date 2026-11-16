#!/bin/bash
# upgrade_router.sh — Gemtek XR1710G (naoki66 ImmortalWrt) 升级编排器, Mac 侧运行
#
# 安全模型(四层):
#   T0 预防: 路由器首启动经 uci-defaults 自举, 恢复到用户配置的 LAN 地址 + 原 SSID, 刷机窗口内 Mac 无需人工接手
#   T1 检测: 本脚本轮询重连 + 终验
#            刷前另有 verify_t2_fallback() 实测核验 T2 是否在位(T2 是命门, 不能只写在文档里)
#   T2 恢复: U-Boot 常住兜底 bootcmd=run boot_ubi || http_recovery (已实测在位) -> 刷坏自动进 Recovery, 免拆机
#            ⚠️ 恢复页地址随 U-Boot 实现变化: 当前 chainloader(2026.07 血脉)=192.168.255.1,
#               刷入 2026-11-11 新版 chainloader 后变为 192.168.0.1; 触发均为"上电后按 reset, LED 变色松手"。
#               刷 U-Boot 后必须重学兜底入口, 否则真出事时连不上恢复页(见 SKILL.md「U-Boot/chainloader 评估基线」)。
#   T3 回退: 刷前自动解析当前运行版本的本地 itb 作为回退镜像 (见 resolve_rollback); 无匹配时退回 FALLBACK_ITB(10/16, 仅最后兜底)
#
# 用法:
#   ./upgrade_router.sh            # 真正执行升级 (会触发路由器重启)
#   ./upgrade_router.sh --dry-run  # 只校验前置条件, 打印将执行的命令, 不刷机
#
# 前置(推荐, 非强制):
#   - 主路径可走 WiFi: 上传 kit+itb、触发 sysupgrade 均经当前 WiFi; 路由器重启后 uci-defaults 自举恢复
#     原 SSID 并 'wifi reload', Mac 自动重连, 全程无需插线。
#   - 但请把一根以太网线放在手边: 万一自举失败(路由回退出厂, 原 SSID 消失), WiFi 即不可达,
#     此时插有线是唯一入口; 插线后 Mac 有线网卡须设为 DHCP 自动获取(XR1710G 出厂态=192.168.50.x / 自举成功=升级前 LAN 网段)。
#   - 恢复/诊断时若路由在出厂态, 你的路由器地址/别名连不上, 改用 XR1710G 出厂默认: ssh root@192.168.50.1
#     ⚠️ 192.168.1.1 是 XG2010G / Nokia 机型的默认地址, 不是本机型的(2026-11-13 纠正了重连候选与自举 fallback)。
#   - Mac 的 SSH 公钥已内置在 kit.tar.gz 的 etc/dropbear/authorized_keys (全清刷后仍可 key 登录)
#   - 升级后 root 密码由升级前从活路由器抓取的 shadow hash 自动恢复, 与升级前一致; 如需改密: ssh <路由器地址> 'passwd root'
#   - 在 ~/.ssh/config 配置你的路由器 SSH 地址 (如 Host <router> -> 192.168.x.1); 本工具会在刷前抓取活路由 host key 随 kit 还原, 故其他终端无需更新 known_hosts

set -u
# macOS tar(bsdtar) 归档时会为每个文件附加 AppleDouble ._* 伴随文件 —— 曾随 kit 刷进路由器,
# 在 /etc 留下 ._zzz-restore-router / ._authorized_keys 等垃圾。COPYFILE_DISABLE=1 让 bsdtar
# 跳过伴随文件(2026-10-21 卫生整治; GNU tar 无此行为, 设为无害)。
export COPYFILE_DISABLE=1
# ---------- 参数解析 ----------
#   --dry-run  只校验前置条件 + 打印将执行步骤, 不刷机
#   --auto     强终验失败自动回退 (供 router_watch.sh 调用)
#   --force    仅跳过"发布满 72h"沉淀闸 (2026-11-04 窄化: 不再关闭 sha256 完整性校验)
#   --allow-same-version    允许重刷"当前正在运行的版本"(默认拒绝, 防白刷)
#   --allow-recent-crash    允许在近期异常硬复位(UBIFS recovery)后刷机 (默认拒绝, 语义模糊)
#   --ack-manual-reboot     显式确认"近期硬复位是本人主动重启"(默认拒绝); 与上一个等价放行,
#                           但会强制打印实测 recovery/uptime 并留审计痕, 不把人工操作误记为故障
#   --allow-unverified-sha  仅在"完全拿不到任何官方基准"时允许无校验刷入 (有基准但不匹配永远拒绝)
#   --allow-test-build      允许刷入被识别为"测试版 / 预发布"的官方最新 release (默认拒绝)
#   --allow-unverified-t2   允许在"刷前读不到 U-Boot/T2 兜底"时仍刷机 (默认拒绝, 自担风险)
#   --allow-stale-kit       允许使用"自举脚本与仓库源码不一致 / 缺 manifest"的陈旧 kit (默认拒绝)
#   --ack-config-reset      确认"wipe-config 版本不恢复旧 /etc/config, 需人工重配"(默认拒绝)
#   --config-policy        覆盖配置策略: full(全量保真) | selective(版本感知选择性重建)
DRY=0; AUTO=0; FORCE=0; ROUTER_OVERRIDE=""; ITB_OVERRIDE=""; EXPECT_SHA_OVERRIDE=""
ALLOW_SAME_VERSION=0; ALLOW_RECENT_CRASH=0; ALLOW_UNVERIFIED_SHA=0; ALLOW_TEST_BUILD=0; ALLOW_UNVERIFIED_T2=0; ALLOW_STALE_KIT=0
ACK_CONFIG_RESET=0; CONFIG_POLICY_OVERRIDE=""; ACK_MANUAL_REBOOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;;
    --auto)    AUTO=1;;
    --force)   FORCE=1;;
    --allow-same-version)   ALLOW_SAME_VERSION=1;;
    --allow-recent-crash)   ALLOW_RECENT_CRASH=1;;
    --ack-manual-reboot)    ACK_MANUAL_REBOOT=1;;
    --allow-unverified-sha) ALLOW_UNVERIFIED_SHA=1;;
    --allow-test-build)     ALLOW_TEST_BUILD=1;;
    --allow-unverified-t2)  ALLOW_UNVERIFIED_T2=1;;
    --allow-stale-kit)      ALLOW_STALE_KIT=1;;
    --ack-config-reset)     ACK_CONFIG_RESET=1;;
    --config-policy)        CONFIG_POLICY_OVERRIDE="${2:-}"; shift;;
    --config-policy=*)      CONFIG_POLICY_OVERRIDE="${1#*=}";;
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

REPO="naoki66/ImmortalWrt-for-Gemtek-brightspeed"
PREP_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$PREP_DIR/kit.tar.gz"
# ---------- 全清还原范围(2026-10-21 活机审计后扩充, 见 SKILL.md「备份机制」节) ----------
# 出厂之上有实质差异、须随 kit 全清还原的 /etc/config 文件。
# 不含 network/wireless(已有专门的真实配置通道) 与 firewall(openclash/zerotier 的 include 段
# 由各自 init 自动增删, 见 zzz-restore 3.5 说明) 与 openclash(已有专门抓取通道)。
EXTRA_CONFIGS="dhcp rpcd luci watchcat dawn system"
# ---------- 跨版本不兼容配置(2026-11-15 解包 1115 出厂镜像真实 diff 校准) ----------
# 依据 /tmp 中的 1115 rootfs: 出厂 /etc/config 仅 40 个, 本机 50 个;
#   ONLY-LIVE(新版已移除): airoha_npu / npu-monitor / cpufreq / network / wireless / system
#                          / fstab / ubootenv / ubihealthd  -> 导入即悬空或阻断首启动生成
#   DIFF(新版主动改写):    firewall 3261B->4159B / uhttpd 742B->4569B / dhcp 2280B->1325B
#                          / zerotier 617B->1918B / luci / rpcd / smartdns / watchcat / openssl
#   SAME 但新版重写控制程序: fan(配置逐字节相同, 排除仅为让新版出厂默认值生效)
# 命中此表即拒绝随 kit 注入(verify_kit final)。
INCOMPATIBLE_CONFIGS="airoha_npu fan npu-monitor cpufreq network wireless firewall system fstab ubootenv ubihealthd dhcp luci rpcd smartdns uhttpd watchcat zerotier openssl"
# selective 策略下允许整文件导入的 /etc/config (2026-11-15 二, 逐文件实证):
#   解包 1115 出厂镜像: 本机 50 个 /etc/config, 出厂仅 40 个; 下列 10 项在出厂里
#   **根本不存在**, 整文件导入不会覆盖任何新版出厂配置, 也不阻断 board.d / uci-defaults
#   生成。程序侧由 etc/zzz-oc-app.tar.gz + etc/zzz-extra-app.tar.gz 离线恢复
#   (openclash / dawn / pushbot / wifihistory / tailscale); 其余若程序未装回则是无害的
#   悬空配置 —— 配置原文得以保真, 且刷后可从 ~/router-upgrade-logs/ 取回。
#   另 9 个 DIFF 文件(dhcp/firewall/luci/rpcd/uhttpd/smartdns/watchcat/zerotier/openssl)
#   绝不能整文件导入(新版出厂已主动改写), 走「参考快照 + 键级迁移表」。
SAFE_CONFIGS="openclash dawn pushbot glass meshconf msd_lite rtp2httpd socat udpxy usteer"
# selective 下需离线恢复程序的第三方服务: 1115 出厂 init.d 全无, 且官方源 / vsean
# 镜像的 packages.adb 均无这些包(tailscale / wifihistory 更是手工部署, 不属任何 apk 包)。
# ⚠️ airoha-npu / cpufreq 是 1115 明确移除的, 绝不在本清单内。
OFFLINE_SERVICES="dawn pushbot tailscale wifihistory"
# 出厂之上新增/改写的非 /etc/config 路径(定制脚本/补丁/令牌/启用态, 全清刷即丢):
#   etc/crontabs             root 计划任务(lan_report.sh 上报 + 关灯计划模板)
#   etc/lan_report.token     lan_report.sh 的上报令牌(无它 crontab 静默失败)
#   etc/apk/repositories.d   自定义 apk 镜像源(rc.local 的 apk add 依赖; 出厂走官方源, 国内可能不可达)
#   usr/sbin/lan_report.sh   LAN 设备快照上报脚本(crontab 引用)
#   usr/lib/lua/luci/http.lua + usr/share/ucode/luci/http.uc  用户手工补丁(上传上限 100kB->10MB)
#   root/.ssh/known_hosts    root 侧 known_hosts
# 均排除 macOS AppleDouble ._* 与 *.bak 垃圾。
# 注意: etc/rc.d(服务启用态)不走整包 —— openclash 开机链须排除, 见下方专门拉取。
# 2026-11-15: apk 源只抓 customfeeds.list。整目录 repositories.d 含 distfeeds.list,
#   该文件注释明写"auto-generated and build-specific, changes lost in sysupgrade"; 本机是
#   mirrors.vsean.net 镜像, 1115 出厂是 downloads.immortalwrt.org 官方源(发布说明「修复默认 APK
#   安装源」正是此事)。导入旧源会覆盖修复, 且 rc.local 靠 apk add 装回 OpenClash, 源错则全清刷后代理起不来。
EXTRA_PATHS="etc/crontabs etc/lan_report.token etc/apk/repositories.d/customfeeds.list usr/sbin/lan_report.sh usr/lib/lua/luci/http.lua usr/share/ucode/luci/http.uc root/.ssh/known_hosts"
# selective 策略进一步排除 LuCI 补丁(http.lua/http.uc 是 1016 版文件, 覆盖新版 LuCI 会破坏界面)
SAFE_EXTRA_PATHS="etc/crontabs etc/lan_report.token etc/apk/repositories.d/customfeeds.list usr/sbin/lan_report.sh root/.ssh/known_hosts"
ROUTER="${ROUTER_OVERRIDE:-}"
EXPECT_SHA="${EXPECT_SHA_OVERRIDE:-}"
# host key 是否已在升级前抓取并随 kit 还原(成功=1): 决定升级后是否需清本地 known_hosts / 提示其他终端
HOSTKEY_PRESERVED=0
# 回退镜像: 默认自动解析为"当前路由器正在运行的版本"对应的本地 itb (刷前预飞时按 commit hash 匹配)。
# 注意: 路由器 DISTRIB_REVISION 末尾 commit(a2535c4f2c, 10 位) 与 GitHub itb 文件名中的 commit(a2535c4f, 8 位) 长度不同,
#   resolve_rollback 的 grep 因此匹配不到 —— 故显式将 FALLBACK_ITB 指向"当前运行版本(20261016)的回退镜像"作为最后兜底(正常 resolve_rollback 已按日期匹配本机当前 itb)
FALLBACK_ITB="$PREP_DIR/immortalwrt-naoki66-xr1710g-20261016-1a34e17c-airoha-an7581-gemtek_xr1710g-squashfs-sysupgrade.itb"
# 升级前配置快照(sysupgrade -b)的本地路径, 供自动回退连带还原; 空=未备份
PREUPG_BACKUP=""

die(){ echo "❌ $1"; exit 1; }

# 执行机拓扑自检(P0): 升级"担任网关/隧道路由器"时, 执行机绝不能依赖该设备通信。
# 方法: 在路由侧读 SSH_CONNECTION 取执行机源 IP; 落在路由器 LAN 网段 -> 直连(安全); 否则 -> 经隧道(危险)。
executor_online(){ curl -s --max-time 6 -o /dev/null https://www.baidu.com 2>/dev/null || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; }
precheck_executor_location(){
  local rip lanip srcip lan_net src_net
  rip="${ROUTER#*@}"; rip="${rip%:*}"
  lanip=$(ssh -o ConnectTimeout=8 "$ROUTER" 'uci get network.lan.ipaddr' 2>/dev/null | cut -d/ -f1)
  srcip=$(ssh -o ConnectTimeout=8 "$ROUTER" 'echo $SSH_CONNECTION' 2>/dev/null | awk '{print $1}')
  echo "---- 执行机拓扑自检 ----"
  echo "路由器 LAN IP: ${lanip:-?}; 路由侧看到的执行机源 IP: ${srcip:-?}"
  if [ -n "$srcip" ] && [ -n "$lanip" ]; then
    lan_net=$(printf '%s' "$lanip" | awk -F. '{print $1"."$2"."$3}')
    src_net=$(printf '%s' "$srcip" | awk -F. '{print $1"."$2"."$3}')
    if [ "$lan_net" = "$src_net" ]; then
      echo "✅ 执行机经 LAN 直连路由器(${lan_net}.0/24), 重启后 WiFi/有线可重连, 风险可控"
      return 0
    fi
    echo "🔴 执行机源 IP($srcip) 不在路由器 LAN 网段(${lan_net}.0/24) —— 极可能经隧道/VPN 回家"
    echo "   升级会重启路由器, 隧道将断, 执行机将永久失联, 无法终验/回退!"
    echo "   请改用: 执行机用独立上网路径(手机热点/另一网卡), 并用有线直连路由器 LAN 口后再升级。"
    if [ -t 0 ]; then
      printf '仍要继续(自担风险)? [y/N] ' >&2; read -r _a </dev/tty 2>/dev/null
      case "$_a" in y|Y) echo "已确认继续(自担风险)";; *) die "已中止: 请有线直连路由器 LAN 口后重试";; esac
    else
      die "非交互环境检测到执行机疑似经隧道回家, 为安全中止。请有线直连路由器 LAN 口后重试"
    fi
  else
    echo "⚠️ 无法判定执行机拓扑, 按高风险处理"
    if [ -t 0 ]; then
      printf '确认执行机已用有线直连路由器 LAN 口(非隧道)? [y/N] ' >&2; read -r _a </dev/tty 2>/dev/null
      case "$_a" in y|Y) echo "已确认";; *) die "已中止";; esac
    else
      die "非交互环境无法判定拓扑, 为安全中止"
    fi
  fi
}

# 近期异常硬复位预检(2026-11-04 新增, 对应 11-03 卡死事件):
# 刷机 = 往 UBI 分区写数据的数分钟窗口。若设备刚发生过原因未明的卡死/异常复位, 此刻刷机
# 一旦复发(断电/网口锁死)就是半写变砖; 且 T2 兜底(HTTP Recovery 由 chainloader 提供)在
# 供电/硬件级故障时也可能一起失效。故本次启动若带 UBIFS recovery(上次非正常关机)且
# uptime < 48h, 默认拒绝刷机, 需显式 --allow-recent-crash 才放行。
precheck_recent_crash(){
  echo "---- 近期异常复位预检 ----"
  # 2026-11-15 二: 机械判据(UBIFS recovery + uptime<48h)区分不了"人工硬重启"与"故障复位"。
  # 用户已明确说明 11-15 那次重启是自己做的, 日志亦无 Oops/panic(3 条匹配全是 procd watchdog
  # 正常启动信息)。故新增语义明确的 --ack-manual-reboot: 默认闸不变, 只是给人工操作一条
  # 可审计的显式放行路径, 且**仍然实测并打印** recovery/uptime, 不掩盖事实。
  local info rec up_h up_int bypass=0
  if [ "$ACK_MANUAL_REBOOT" = "1" ]; then
    echo "✅ 已由 --ack-manual-reboot 显式确认: 本次近期硬复位为人工操作(非故障)"
    bypass=1
  elif [ "$ALLOW_RECENT_CRASH" = "1" ]; then
    echo "⚠️ 已由 --allow-recent-crash 显式放行(自担风险)"
    bypass=1
  fi
  info=$(ssh -o ConnectTimeout=8 "$ROUTER" 'r=$(dmesg 2>/dev/null | grep -ci "UBIFS.*recovery needed"); u=$(cut -d" " -f1 /proc/uptime); printf "%s %s\n" "${r:-0}" "${u:-0}"' 2>/dev/null)
  rec=$(printf '%s' "$info" | awk '{print $1}')
  up_h=$(printf '%s' "$info" | awk '{printf "%.1f", $2/3600}')
  up_int=$(printf '%s' "${up_h:-0}" | cut -d. -f1)
  echo "本次启动 UBIFS recovery 标志: ${rec:-?}; uptime: ${up_h:-?}h"
  if [ "${rec:-0}" -gt 0 ] && [ "${up_int:-999}" -lt 48 ]; then
    if [ "$bypass" = "1" ]; then
      echo "⚠️ 实测 UBIFS recovery=${rec} / uptime=${up_h}h —— 按上述显式确认放行, 不视为故障(审计留痕)"
      return 0
    fi
    if [ "$DRY" = "1" ]; then
      echo "⚠️ [dry-run] 检测到近期异常硬复位(uptime ${up_h}h <48h), 真实执行时本脚本会拒绝刷机"
      return 0
    fi
    die "🛑 设备近期发生过异常硬复位(UBIFS recovery 为证, uptime 仅 ${up_h}h), 根因未查明。为避免刷写窗口内复发导致半写变砖, 已中止。建议: 先稳定观察 48h / 补远程 syslog 抓根因, 或显式加 --allow-recent-crash 自担风险。"
  fi
  echo "✅ 无近期异常复位痕迹(或已超过 48h 观察窗)"
}

# ---------- U-Boot 兜底状态档案(2026-11-16 新增) ----------
# 问题: 恢复页地址不是常量 —— 旧 chainloader 血脉是 192.168.255.1, 11-11 新版是
#   192.168.0.1, 且新版是**按 MAC 的 DHCP 租约表**下发(不同 MAC 可能拿到不同 IP)。
#   原实现靠 grep mtd3 里的 IP 字符串 + 硬编码兜底, 刷完 U-Boot 后必然失真。
# 方案: 维护一份持久化状态档案 uboot-state.env, 记录当前已知的 U-Boot 血脉 /
#   恢复页地址 / 触发方式 / 最近实测时间, 刷 U-Boot 后由用户或流程更新, 之后所有
#   提示、重连候选、失败指引一律读它, 不再散落硬编码。
UBOOT_STATE_FILE="${UBOOT_STATE_FILE:-$HOME/router-upgrade-logs/uboot-state.env}"
PROBE_RECOVERY_OK=0; PROBE_RECOVERY_IP=""
UBOOT_STATE_VERSION=1

uboot_state_load(){
  # 只接受 KEY=VALUE 的白名单键, 避免被任意内容注入
  if [ -f "$UBOOT_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$UBOOT_STATE_FILE" 2>/dev/null || true
  fi
  UBOOT_STATE_RECOVERY_IP="${UBOOT_STATE_RECOVERY_IP:-}"
  UBOOT_STATE_TRIGGER="${UBOOT_STATE_TRIGGER:-}"
  UBOOT_STATE_VERSION_STR="${UBOOT_STATE_VERSION_STR:-}"
  UBOOT_STATE_ENV_HEALTH="${UBOOT_STATE_ENV_HEALTH:-}"
  UBOOT_STATE_LAST_VERIFIED="${UBOOT_STATE_LAST_VERIFIED:-}"
}

uboot_state_set(){
  # 用法: uboot_state_set KEY VALUE
  local k="$1" v="$2"
  mkdir -p "$(dirname "$UBOOT_STATE_FILE")" 2>/dev/null || return 1
  local tmp="$UBOOT_STATE_FILE.tmp.$$"
  {
    echo "# U-Boot 兜底状态档案 —— 由 router-immortalwrt-upgrade skill 维护"
    echo "# 刷 U-Boot 后请更新 RECOVERY_IP / VERSION_STR / TRIGGER 并写回本文件"
    echo "UBOOT_STATE_VERSION=$UBOOT_STATE_VERSION"
    grep -E '^(UBOOT_STATE_RECOVERY_IP|UBOOT_STATE_TRIGGER|UBOOT_STATE_VERSION_STR|UBOOT_STATE_ENV_HEALTH|UBOOT_STATE_LAST_VERIFIED)=' "$UBOOT_STATE_FILE" 2>/dev/null       | grep -v "^$k=" || true
    echo "$k=$v"
  } > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$UBOOT_STATE_FILE" 2>/dev/null || return 1
  return 0
}

uboot_state_save(){
  uboot_state_set UBOOT_STATE_RECOVERY_IP    "${UBOOT_STATE_RECOVERY_IP:-}"
  uboot_state_set UBOOT_STATE_TRIGGER       "${UBOOT_STATE_TRIGGER:-}"
  uboot_state_set UBOOT_STATE_VERSION_STR   "${UBOOT_STATE_VERSION_STR:-}"
  uboot_state_set UBOOT_STATE_ENV_HEALTH    "${UBOOT_STATE_ENV_HEALTH:-}"
  uboot_state_set UBOOT_STATE_LAST_VERIFIED "${UBOOT_STATE_LAST_VERIFIED:-}"
}

# 恢复页 HTTP 探测: 真去戳一下候选地址, 判断 T2 兜底入口是否真的在位。
# 刷 U-Boot 后 / 救砖时, 唯一能进系统的路就是 Recovery 页 —— 它必须在**事前**被证实可达,
# 而不是靠文档里写着一个 IP 就相信。
probe_recovery_page(){
  # 用法: probe_recovery_page [候选IP...]
  local cands=("$@") ip code
  [ ${#cands[@]} -eq 0 ] && cands=(192.168.255.1 192.168.0.1)
  for ip in "${cands[@]}"; do
    [ -z "$ip" ] && continue
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 --noproxy '*' "http://$ip/" 2>/dev/null)
    if [ "$code" = "000" ]; then
      echo "   ✗ http://$ip/ 无响应"
    else
      echo "   ✓ http://$ip/ 有响应 (HTTP $code)"
      PROBE_RECOVERY_OK=1; PROBE_RECOVERY_IP="$ip"
    fi
  done
  return 0
}

# ---------- 刷前 T2 兜底核验(2026-11-13 新增, 把"执行顺序第 1 步"从文档变成代码) ----------
# 安全模型最底层是 U-Boot 常住 bootcmd=run boot_ubi || http_recovery。此前脚本只在"终验"里
# echo 打印一次, 刷前从不判定 —— 万一刷 U-Boot / 改 env 把兜底改没了, 脚本仍会照常刷机,
# 真出事时才发现进不去 Recovery。现改为刷前 fail-closed 校验, 并把刷前基线存进全局,
# 供 post_upgrade_report 输出"刷前 vs 刷后"对比(刷过 chainloader 后恢复页会变, 必须能看出来)。
T2_PRE_BOOTCMD=""; T2_PRE_UBOOT=""; T2_PRE_RECOVERY_IP=""; T2_PRE_OK=0
T2_ENV_HEALTH="unknown"; T2_ENV_LIVE=""
# 2026-11-16: 实机复核推翻了一个假设并暴露新风险, 故重写本函数。
#   实测 A: /etc/fw_env.config 指向的是**活跃 UBI 卷**(ubootenv=/dev/ubi0_1,
#           ubootenv2=/dev/ubi0_2), 不是 mtd0 的厂商陈旧副本 —— fw_printenv 本身是可信来源。
#   实测 B: ubi0_1(ubootenv) 内容已**全 0xFF(空)**, 真实 env 只存在于 ubi0_2(ubootenv2)
#           单点 —— 即 env 冗余对已失效, 一旦该卷被写坏, bootcmd/http_recovery 兜底即失效。
#   故 T2 判据改为: 只认活跃 UBI 卷里的 bootcmd(不含 fw_printenv 兜底), 并额外报告
#   env 冗余健康度(单点=高风险, 刷 U-Boot 前必须先修)。
verify_t2_fallback(){
  echo "---- T2 兜底(U-Boot) 刷前核验 ----"
  uboot_state_load
  if [ -n "$UBOOT_STATE_RECOVERY_IP" ]; then
    echo "   已加载状态档案: 恢复页=$UBOOT_STATE_RECOVERY_IP / U-Boot=${UBOOT_STATE_VERSION_STR:-?} / 触发=${UBOOT_STATE_TRIGGER:-?}"
  else
    echo "   ⚠️ 无 U-Boot 状态档案($UBOOT_STATE_FILE) —— 恢复页地址将退化为推定值"
  fi
  local raw
  raw=$(ssh -o ConnectTimeout=10 "$ROUTER" 'sh -s' 2>/dev/null <<'REMOTE'
# 只读活跃 UBI 卷(ubootenv / ubootenv2), 不用 fw_printenv 兜底 ——
# 旧实现把三路来源并联进同一管道, 任一路含 http_recovery 就判在位, 掩盖了"哪一路真的在位"。
# 现在逐卷分开读, 由 Mac 侧按卷判定, 哪一路失效一目了然。
for v in /dev/ubi0_1 /dev/ubi0_2; do
  echo "---ENV:$v---"
  if [ -r "$v" ]; then
    cat "$v" 2>/dev/null | strings 2>/dev/null | grep -E '^bootcmd=|^recovery_mtd=|^boot_ubi=' | sort -u
  fi
done
echo '---UBOOT---'
M=$(awk -F: '/"chainloader"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
[ -z "$M" ] && M=mtd3
grep -a -o -E 'U-Boot 20[0-9]{2}[^ ]{0,50}' /dev/$M 2>/dev/null | sort -u | head -1
echo '---IP---'
grep -a -o -E '192\.168\.(255|0)\.(1|2|255)' /dev/$M 2>/dev/null | sort -u | tr '\n' ' '
echo
REMOTE
)
  local env1 env2
  env1=$(printf '%s\n' "$raw" | sed -n '/^---ENV:\/dev\/ubi0_1---$/,/^---ENV:\/dev\/ubi0_2---$/p' | grep '^bootcmd=' | head -1)
  env2=$(printf '%s\n' "$raw" | sed -n '/^---ENV:\/dev\/ubi0_2---$/,/^---UBOOT---$/p' | grep '^bootcmd=' | head -1)
  T2_PRE_UBOOT=$(printf '%s\n' "$raw" | sed -n '/^---UBOOT---$/,/^---IP---$/p' | grep '^U-Boot' | head -1)
  # 恢复页地址: mtd3 里 grep 出来的可能是多个 IP 拼在一行(如 "192.168.255.1 192.168.255.2 ..."),
  #   原实现直接整行塞进 T2_PRE_RECOVERY_IP, 后续用它拼 URL/提示都会得到垃圾串。
  #   现在: 取第一个合法单 IP; 若 mtd3 未读出则用状态档案的值; 都没有才退化为推定。
  T2_PRE_RECOVERY_IP=$(printf '%s\n' "$raw" | sed -n '/^---IP---$/,$p' | grep -v '^---IP---$' | tr ' ' '\n' | grep -oE '^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$' | head -1)

  # env 冗余健康度: 两卷都有 = 健康; 只有一卷 = 单点(高风险)
  local env_health="unknown" env_live=""
  if [ -n "$env1" ] && [ -n "$env2" ]; then
    env_health="redundant"; env_live="ubootenv+ubootenv2"
  elif [ -n "$env1" ]; then
    env_health="single"; env_live="ubootenv(ubi0_1)"
  elif [ -n "$env2" ]; then
    env_health="single"; env_live="ubootenv2(ubi0_2)"
  fi
  T2_ENV_HEALTH="$env_health"; T2_ENV_LIVE="$env_live"

  if [ -n "$env1" ] && [ -n "$env2" ] && [ "$env1" != "$env2" ]; then
    echo "⚠️ 两个 env 卷的 bootcmd 不一致(冗余对已不同步):"
    echo "     ubootenv : $env1"
    echo "     ubootenv2: $env2"
    echo "     -> 以 fw_printenv 实际读到的为准, 但建议刷机前用 mkenvimage 重建冗余对"
  fi

  # 判据: 任意**活跃 UBI 卷**读到含 http_recovery/boot_ubi 的 bootcmd 即算 T2 在位
  local picked=""
  for c in "$env1" "$env2"; do
    if printf '%s' "$c" | grep -qE 'http_recovery|boot_ubi'; then picked="$c"; break; fi
  done
  if [ -n "$picked" ]; then
    T2_PRE_OK=1
    T2_PRE_BOOTCMD="$picked"
    echo "✅ T2 兜底在位: $picked  (来源: $env_live)"
  else
    T2_PRE_BOOTCMD="${env1:-$env2}"
    echo "🛑 刷前未读到 U-Boot 常住兜底 bootcmd(http_recovery / boot_ubi) —— T2 命门可能已失效"
  fi
  case "$env_health" in
    redundant) echo "   env 冗余: ✅ 健康(ubootenv + ubootenv2 两卷均在位)";;
    single)    echo "   env 冗余: 🔴 单点失效(仅 $env_live 有 env, 另一卷为空) —— 兜底无备份, 刷 U-Boot 前建议先修复冗余对";;
    *)         echo "   env 冗余: ⚠️ 两个 env 卷都读不到 bootcmd";;
  esac
  [ -n "$T2_PRE_UBOOT" ] && echo "   U-Boot 版本串(mtd3): $T2_PRE_UBOOT"
  if [ -n "$T2_PRE_RECOVERY_IP" ]; then
    echo "   恢复页(mtd3 实测): $T2_PRE_RECOVERY_IP"
  elif [ -n "$UBOOT_STATE_RECOVERY_IP" ]; then
    T2_PRE_RECOVERY_IP="$UBOOT_STATE_RECOVERY_IP"
    echo "   恢复页(取自状态档案): $UBOOT_STATE_RECOVERY_IP"
  else
    T2_PRE_RECOVERY_IP="192.168.255.1(推定, mtd3 未读出)"
    echo "   ⚠️ mtd3 未读出恢复页 IP 且无状态档案, 按当前 U-Boot 血脉推定 192.168.255.1 (刷过 11-11 chainloader 则为 192.168.0.1)"
  fi
  # 恢复页可达性实测(事前证明 T2 入口真的在位, 而不是文档里写着一个 IP 就相信)
  echo "   恢复页可达性探测(事后救砖的唯一入口, 必须事前证实):"
  _pc=()
  [ -n "$UBOOT_STATE_RECOVERY_IP" ] && _pc+=("$UBOOT_STATE_RECOVERY_IP")
  _pc+=(192.168.255.1 192.168.0.1)
  probe_recovery_page "${_pc[@]}"
  if [ "$PROBE_RECOVERY_OK" = "1" ]; then
    echo "   ✅ Recovery 页可达: http://$PROBE_RECOVERY_IP/ —— T2 入口已实证"
    UBOOT_STATE_RECOVERY_IP="$PROBE_RECOVERY_IP"
  else
    echo "   ⚠️ Recovery 页当前无响应(路由器正常运行中时本就无响应, 需进 Recovery 才起)—— 属正常, 但刷机前请确保你知道如何进 Recovery"
  fi
  # 把本次实测写回状态档案。
  #   恢复页地址优先用 mtd3 实测值(T2_PRE_RECOVERY_IP, 权威), 其次用探测命中的地址,
  #   再次是档案原值 —— 探测在路由器正常运行时必然无响应(Recovery 只有进 Recovery 才起),
  #   所以不能拿探测结果去覆盖实测值, 否则会把档案写成空。
  if printf '%s' "$T2_PRE_RECOVERY_IP" | grep -qE '^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    UBOOT_STATE_RECOVERY_IP="$T2_PRE_RECOVERY_IP"
  elif [ "$PROBE_RECOVERY_OK" = "1" ]; then
    UBOOT_STATE_RECOVERY_IP="$PROBE_RECOVERY_IP"
  fi
  UBOOT_STATE_VERSION_STR="$T2_PRE_UBOOT"
  UBOOT_STATE_ENV_HEALTH="$T2_ENV_HEALTH"
  UBOOT_STATE_LAST_VERIFIED="$(date '+%Y-%m-%d %H:%M:%S')"
  [ -n "$UBOOT_STATE_TRIGGER" ] || UBOOT_STATE_TRIGGER="上电后按住 reset 键, LED 变色松手"
  uboot_state_save
  echo "   状态档案已更新: $UBOOT_STATE_FILE"
  if [ "$T2_PRE_OK" = "1" ]; then return 0; fi
  if [ "$DRY" = "1" ]; then echo "⚠️ [dry-run] 真实执行时本脚本会拒绝刷机"; return 0; fi
  if [ "$ALLOW_UNVERIFIED_T2" = "1" ]; then echo "⚠️ 已由 --allow-unverified-t2 显式放行(自担风险)"; return 0; fi
  die "🛑 T2 兜底未验证, 拒绝刷机。请先确认 U-Boot env(/dev/ubi0_1|ubi0_2), 或显式加 --allow-unverified-t2 自担风险。"
}

# ---------- kit 有效性核验(2026-11-13 新增, 把"kit 是否重建"从人工提醒变成代码强制) ----------
# 2026-11-13 实证: 仓库根的 kit.tar.gz 停留在 2026-10-08, 内嵌 zzz-restore-router 仅 339 行
# (仓库源码 445 行), 缺 zzz-disabled-services 禁用态还原等后续修复, sha256 不一致 —— 用这种
# kit 全清刷会静默丢配置。故刷前校验: 必需文件在位 + 自举脚本与源码一致 + manifest 绑定目标固件。
# ⚠️ 只按需 tar -xOf 提取 2 个非敏感成员, 绝不整包解包注入后的 kit(那含 root shadow/WiFi key/订阅)。
verify_kit(){
  local mode="${1:-pre}" tmp m_restore m_keys m_manifest kit_sha repo_sha m_commit m_khash warn=0
  echo "---- kit 有效性核验 ($mode) ----"
  tmp=/tmp/kit_build/verify
  rm -rf "$tmp"; mkdir -p "$tmp" 2>/dev/null || { echo "⚠️ 无法创建临时校验目录, 跳过 kit 核验"; return 0; }
  m_restore=$(tar -tzf "$KIT" 2>/dev/null | grep -E '(^|/)etc/uci-defaults/zzz-restore-router$' | head -1)
  m_keys=$(tar -tzf "$KIT" 2>/dev/null | grep -E '(^|/)etc/dropbear/authorized_keys$' | head -1)
  m_manifest=$(tar -tzf "$KIT" 2>/dev/null | grep -E '(^|/)etc/kit-manifest$' | head -1)
  if [ -z "$m_restore" ] || [ -z "$m_keys" ]; then
    echo "❌ kit 缺少必需文件: etc/uci-defaults/zzz-restore-router 或 etc/dropbear/authorized_keys"
    rm -rf "$tmp"; return 1
  fi
  tar -xOf "$KIT" "$m_restore" > "$tmp/restore" 2>/dev/null
  [ -s "$tmp/restore" ] || { echo "❌ 无法提取 kit 内自举脚本"; rm -rf "$tmp"; return 1; }
  kit_sha=$(shasum -a 256 "$tmp/restore" 2>/dev/null | awk '{print $1}')
  repo_sha=$(shasum -a 256 "$PREP_DIR/zzz-restore-router" 2>/dev/null | awk '{print $1}')
  if [ -n "$kit_sha" ] && [ -n "$repo_sha" ] && [ "$kit_sha" != "$repo_sha" ]; then
    echo "🛑 kit 内自举脚本不是当前仓库源码 (kit ${kit_sha:0:12}… vs repo ${repo_sha:0:12}…) —— kit 已陈旧"
    echo "   影响: 全清刷后首启动用的是旧自举逻辑, 可能缺真实配置还原 / 订阅还原 / 禁用态还原等后续修复。"
    echo "   修法: 见 README「真刷前必须先重建 kit」(从旧 kit 自提取 authorized_keys + clash_meta 后重建)"
    warn=1
  else
    echo "✅ kit 内自举脚本与仓库源码一致 (${kit_sha:0:12}…)"
  fi
  if [ -n "$m_manifest" ]; then
    tar -xOf "$KIT" "$m_manifest" > "$tmp/manifest" 2>/dev/null
    m_commit=$(grep '^target_commit=' "$tmp/manifest" 2>/dev/null | cut -d= -f2- | head -1)
    m_khash=$(grep '^source_kernel=' "$tmp/manifest" 2>/dev/null | cut -d= -f2- | head -1)
    echo "   manifest: target_commit=${m_commit:-?} / source_kernel=${m_khash:-?}"
    if [ "$mode" = "final" ] && [ -n "${TARGET_COMMIT:-}" ]; then
      _m8=$(printf '%s' "$m_commit" | cut -c1-8)
      _t8=$(printf '%s' "$TARGET_COMMIT" | cut -c1-8)
      if [ "${m_commit:-unspecified}" = "unspecified" ] || [ "$_m8" != "$_t8" ]; then
        echo "🛑 kit manifest 未绑定本次目标固件 ($TARGET_COMMIT) —— collect_runtime 应已覆写, 不一致说明流程异常"
        warn=1
      else
        echo "✅ kit manifest 已绑定目标固件 commit $_t8"
      fi
    fi
  else
    if [ "$mode" = "final" ]; then
      echo "🛑 最终 kit 缺少 etc/kit-manifest —— 无法证明它针对本次目标固件重建"
      warn=1
    else
      echo "ℹ️ 源 kit 无 manifest(旧版 build_kit.sh 产物); collect_runtime 会在注入时补写并绑定目标固件"
    fi
  fi
  if [ -n "$m_khash" ] && [ "$m_khash" != "unspecified" ]; then
    echo "   ⚠️ kit 源内核 $m_khash; 目标固件若跨内核版本, 切勿恢复旧 kmod-*, 且必须按新固件重建 kit"
  fi
  # ---------- 2026-11-15: final 阶段扫描注入 kit 的 /etc/config ----------
  # verify_kit(pre) 只看静态 kit(本来不含任何 config), 检测不到 collect_runtime 注入的旧配置。
  # 只列文件名(tar -tzf), 绝不读取内容 —— 注入 kit 含 root shadow / WiFi key / 订阅。
  if [ "$mode" = "final" ]; then
    local _present="" _c _bad="" _extra="" m_pol
    _present=$(tar -tzf "$KIT" 2>/dev/null | grep -E '(^|/)etc/config/[^/]+$' | sed 's#.*/##' | sort -u | tr '\n' ' ')
    for _c in $INCOMPATIBLE_CONFIGS; do
      case " $_present " in *" $_c "*) _bad="${_bad}${_bad:+, }$_c" ;; esac
    done
    if [ -n "$_bad" ]; then
      echo "🛑 注入 kit 含跨版本不兼容的 /etc/config: $_bad"
      echo "   这些文件在本版本被移除或主动改写, 导入会覆盖出厂默认 / 留下悬空段。"
      warn=1
    elif [ "${CONFIG_POLICY:-full}" = "selective" ]; then
      for _c in $_present; do
        case " $SAFE_CONFIGS " in *" $_c "*) ;; *) _extra="${_extra}${_extra:+, }$_c" ;; esac
      done
      if [ -n "$_extra" ]; then
        echo "🛑 selective 策略下注入 kit 仍含白名单外的 /etc/config: $_extra"
        warn=1
      else
        echo "✅ 注入 kit 的 /etc/config 仅含白名单项 (${_present:-无})"
      fi
    else
      echo "✅ 注入 kit 的 /etc/config 未命中不兼容黑名单 (${#_present} 字符的文件清单)"
    fi
    if [ -n "$m_manifest" ]; then
      m_pol=$(grep '^config_policy=' "$tmp/manifest" 2>/dev/null | cut -d= -f2- | head -1)
      if [ -n "$m_pol" ] && [ "$m_pol" != "${CONFIG_POLICY:-full}" ]; then
        echo "🛑 kit manifest 的 config_policy=$m_pol 与本次策略 ${CONFIG_POLICY:-full} 不一致"
        warn=1
      else
        echo "✅ kit manifest 配置策略一致: ${m_pol:-${CONFIG_POLICY:-full}}"
      fi
    fi
    # ---------- 2026-11-15: selective 必须携带离线 OpenClash 程序包 ----------
    if [ "${CONFIG_POLICY:-full}" = "selective" ]; then
      local _ocapp _ocinner
      _ocapp=$(tar -tzf "$KIT" 2>/dev/null | grep -E '(^|/)etc/zzz-oc-app\.tar\.gz$' | head -1)
      if [ -z "$_ocapp" ]; then
        echo "🛑 selective kit 缺少离线 OpenClash 程序包 etc/zzz-oc-app.tar.gz"
        echo "   1115 出厂不含 luci-app-openclash, 官方/vsean feed 均无此包, 联网 apk add 必失败"
        warn=1
      else
        _ocinner=$(tar -xOf "$KIT" "$_ocapp" 2>/dev/null | tar -tzf - 2>/dev/null)
        if ! printf '%s\n' "$_ocinner" | grep -qE '(^|/)etc/init\.d/openclash$'; then
          echo "🛑 离线程序包内缺 etc/init.d/openclash"; warn=1
        elif ! printf '%s\n' "$_ocinner" | grep -q 'usr/share/openclash/'; then
          echo "🛑 离线程序包内缺 usr/share/openclash 运行时脚本"; warn=1
        else
          echo "✅ 离线 OpenClash 程序包就位 (init.d + 运行时脚本), 首启动零联网"
        fi
      fi
      # ---------- 2026-11-15 (二): 其余第三方程序 + 语义级迁移表数据源 ----------
      # 只列文件名(tar -tzf), 绝不读取归档内容 —— 内含 zerotier secret / shadow hash /
      # tailscaled.state 节点私钥。
      local _ea _eain _cr _crin
      _ea=$(tar -tzf "$KIT" 2>/dev/null | grep -E '(^|/)etc/zzz-extra-app\.tar\.gz$' | head -1)
      if [ -z "$_ea" ]; then
        echo "🛑 selective kit 缺少离线第三方程序包 etc/zzz-extra-app.tar.gz ($OFFLINE_SERVICES)"; warn=1
      else
        _eain=$(tar -xOf "$KIT" "$_ea" 2>/dev/null | tar -tzf - 2>/dev/null)
        if ! printf '%s\n' "$_eain" | grep -qE '(^|/)usr/sbin/tailscaled$'; then
          echo "🛑 离线第三方程序包内缺 usr/sbin/tailscaled"; warn=1
        elif ! printf '%s\n' "$_eain" | grep -qE '(^|/)etc/init\.d/dawn$'; then
          echo "🛑 离线第三方程序包内缺 etc/init.d/dawn"; warn=1
        else
          echo "✅ 离线第三方程序包就位: $OFFLINE_SERVICES (tailscaled + dawn + pushbot + wifihistory)"
        fi
      fi
      _cr=$(tar -tzf "$KIT" 2>/dev/null | grep -E '(^|/)etc/zzz-config-ref\.tar\.gz$' | head -1)
      if [ -z "$_cr" ]; then
        echo "🛑 selective kit 缺少配置参考快照 etc/zzz-config-ref.tar.gz (键级迁移表数据源)"; warn=1
      else
        _crin=$(tar -xOf "$KIT" "$_cr" 2>/dev/null | tar -tzf - 2>/dev/null)
        if ! printf '%s\n' "$_crin" | grep -qE '(^|/)etc/config/dhcp$'; then
          echo "🛑 配置参考快照内缺 etc/config/dhcp"; warn=1
        else
          echo "✅ 配置参考快照就位(9 个 DIFF 文件的用户定制按键迁移, 出厂默认不被覆盖)"
        fi
      fi
    fi
  fi
  rm -rf "$tmp"
  if [ "$warn" = "1" ]; then
    if [ "$ALLOW_STALE_KIT" = "1" ]; then echo "⚠️ 已由 --allow-stale-kit 显式放行(自担风险)"; return 0; fi
    if [ "$DRY" = "1" ]; then echo "⚠️ [dry-run] 真实执行时本脚本会拒绝刷机, 直到 kit 重建"; return 0; fi
    die "🛑 kit 有效性核验未通过。请按上面提示重建 kit, 或显式加 --allow-stale-kit 自担风险。"
  fi
  return 0
}

# 升级日志持久化(P3): 归档到固定目录而非易失的 /tmp, 升级当次及日后复盘均可追溯
LOG_DIR="$HOME/router-upgrade-logs"
archive_logs(){
  local d="$LOG_DIR/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$d"
  local f got=0
  for f in /tmp/upg.log /tmp/zzz-restore.log /tmp/zzz-postinstall.log /tmp/rb.log; do
    if scp -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER:$f" "$d/" 2>/dev/null; then got=1; fi
  done
  if [ "$got" = "1" ]; then echo "📦 已归档路由日志到 $d"; else echo "⚠️ 日志归档失败(可能已失联, 路由重启后重连再试)"; fi
}

# 升级后结构化报告(P3, SRE 视角): 一眼看清"到底恢复全了没", 落持久化目录
# 配置保真度独立校验(2026-11-02 修复 #1): 用升级前 sysupgrade -b 快照比对升级后运行态 /etc/config,
# 暴露"抓进 kit 但首启动未还原"的配置漂移(此前 verify 只查连通性+节点数+信道+DHCP条数+uci changes,
# 不比对还原前后一致性)。非 fail-closed, 仅告警, 不触发回退。
config_fidelity_check(){
  [ -n "$PREUPG_BACKUP" ] && [ -f "$PREUPG_BACKUP" ] || { echo "ℹ️ 无升级前配置快照, 跳过保真度校验"; return 0; }
  local algo
  algo=$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'command -v sha256sum >/dev/null 2>&1 && echo sha256 || echo none' 2>/dev/null)
  if [ "$algo" != "sha256" ]; then
    echo "ℹ️ 路由器不支持 sha256sum, 跳过配置保真度校验(仍可手工比对 $PREUPG_BACKUP)"
    return 0
  fi
  local tmp; tmp=/tmp/cfg_pre_$$; rm -rf "$tmp"; mkdir -p "$tmp"
  tar -xzf "$PREUPG_BACKUP" -C "$tmp" 2>/dev/null || { echo "⚠️ 升级前快照解包失败, 跳过保真度校验"; rm -rf "$tmp"; return 0; }
  local pre_dir="$tmp/etc/config"
  [ -d "$pre_dir" ] || { echo "⚠️ 升级前快照无 /etc/config, 跳过保真度校验"; rm -rf "$tmp"; return 0; }
  echo "=== 配置保真度校验 (策略: ${CONFIG_POLICY:-full}) ==="
  # 2026-11-16 P0 修复: post.txt(升级后 /etc/config 指纹)必须在**策略分支之前**采集。
  #   原实现只在 full 分支末尾生成 post.txt, 而 selective 分支在分支内就去读它 ——
  #   selective 下读到的是不存在的空文件 -> awk 无匹配 -> 所有白名单项被误报
  #   「升级后缺失」, 且 wc -l 报错。1115 恰好走 selective, 升级报告必然失真。
  #   现在两个策略共用同一次采集, 并对"采集为空"显式告警(不再静默误判)。
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'cd /etc/config && for f in *; do [ -f "$f" ] || continue; printf "%s %s\n" "$(sha256sum "$f" 2>/dev/null | cut -d" " -f1)" "$f"; done' 2>/dev/null > "$tmp/post.txt" || { echo "⚠️ 无法读取升级后 /etc/config, 跳过保真度校验"; rm -rf "$tmp"; return 0; }
  if [ ! -s "$tmp/post.txt" ]; then echo "⚠️ 升级后 /etc/config 指纹采集为空, 跳过保真度校验(无法判定, 非配置漂移)"; rm -rf "$tmp"; return 0; fi
  # 2026-11-15: selective 策略下"逐字节一致"是错误判据 —— 新版主动改写配置, 一致反而说明
  # 旧配置被误导入。改为分层: 白名单项必须还原, 其余期望变化(只列清单, 不计漂移)。
  if [ "${CONFIG_POLICY:-full}" = "selective" ]; then
    echo "  策略 selective: 白名单项须保真; 其余配置由新版出厂 + uci-defaults 重建(变化=预期)"
    local _ok=0 _bad=0 _c _h1 _h2 _lan _ssid
    for _c in $SAFE_CONFIGS; do
      [ -f "$pre_dir/$_c" ] || continue
      _h2=$(awk -v f="$_c" '$2==f{print $1}' "$tmp/post.txt")
      _h1=$(shasum -a 256 "$pre_dir/$_c" 2>/dev/null | awk '{print $1}')
      if [ -z "$_h2" ]; then echo "  ❌ 白名单项升级后缺失: $_c"; _bad=$((_bad+1));
      elif [ -n "$_h1" ] && [ "$_h1" != "$_h2" ]; then echo "  ⚠️ 白名单项升级后内容变化: $_c"; _bad=$((_bad+1));
      else echo "  ✅ $_c 已还原"; _ok=$((_ok+1)); fi
    done
    # 身份项由补丁式 uci set 恢复, 独立核验(不比对整文件)
    _lan=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'uci -q get network.lan.ipaddr' 2>/dev/null)
    _ssid=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'uci -q get wireless.@wifi-iface[0].ssid' 2>/dev/null)
    [ -n "$_lan" ]  && echo "  ✅ LAN IP 已由补丁恢复: $_lan"  || { echo "  ⚠️ 未能读取 LAN IP"; _bad=$((_bad+1)); }
    [ -n "$_ssid" ] && echo "  ✅ SSID 已由补丁恢复: $_ssid"  || { echo "  ⚠️ 未能读取 SSID"; _bad=$((_bad+1)); }
    _post_total=$(wc -l < "$tmp/post.txt" | tr -d ' ')
    _post_rest=$(( _post_total - _ok ))
    [ "$_post_rest" -lt 0 ] && _post_rest=0
    echo "✅ 分层校验完成: 白名单 $_ok 项通过 / $_bad 项异常; 升级后 /etc/config 共 $_post_total 个文件, 其中非白名单 $_post_rest 个属新版出厂+uci-defaults 生成, 不计漂移"
    rm -rf "$tmp"
    return 0
  fi
  local diffs=0 nf=0 bf pre_h post_h
  for pre in "$pre_dir"/*; do
    [ -f "$pre" ] || continue
    bf=$(basename "$pre")
    post_h=$(awk -v f="$bf" '$2==f{print $1}' "$tmp/post.txt")
    if [ -z "$post_h" ]; then echo "  ⚠️ 升级后缺失: /etc/config/$bf"; nf=$((nf+1)); diffs=$((diffs+1)); continue; fi
    pre_h=$(shasum -a 256 "$pre" 2>/dev/null | awk '{print $1}')
    if [ "$pre_h" != "$post_h" ]; then echo "  ⚠️ 配置漂移: /etc/config/$bf (升级前/后不一致)"; diffs=$((diffs+1)); fi
  done
  while read -r _h bf; do
    [ -f "$pre_dir/$bf" ] || echo "  ℹ️ 升级后新增 config(一般无害): $bf"
  done < "$tmp/post.txt"
  if [ "$diffs" -eq 0 ]; then echo "✅ 配置保真度校验通过: 升级前快照的全部 /etc/config 均已还原且内容一致"; else echo "⚠️ 配置保真度校验发现 $diffs 处差异(缺失 $nf), 请核查上面列出的文件(差异可能来自首启动自举的正常生成项)"; fi
  rm -rf "$tmp"
}

post_upgrade_report(){
  mkdir -p "$LOG_DIR"
  local d rep
  d="$LOG_DIR/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$d"
  rep="$d/report.md"
  {
    echo "# 路由器升级后结构化报告"
    echo ""
    echo "- 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- 目标版本 commit: ${TARGET_COMMIT:-?}"
    echo "- 回退镜像: $(basename "${ROLLBACK:-}")"
    echo "- 刷前 T2 基线: bootcmd=${T2_PRE_BOOTCMD:-?} / ${T2_PRE_UBOOT:-?} / 恢复页 ${T2_PRE_RECOVERY_IP:-?} / 核验通过=${T2_PRE_OK}"
    echo ""
  } > "$rep"
  if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'true' 2>/dev/null; then
    echo "⚠️ 连不上路由器, 无法生成结构化报告(可待重连后手动跑本函数)" >> "$rep"
    echo "⚠️ 连不上路由器, 无法生成结构化报告"
    return 0
  fi
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" '
    rev=$(grep DISTRIB_REVISION /etc/openwrt_release 2>/dev/null)
    r=$(printf "%s" "$rev" | grep -oE "[0-9a-f]{7,40}" | tail -1)
    echo "## 1. 版本"
    echo "- 当前固件: $rev"
    echo "- 目标版本: '"$TARGET_COMMIT"'"
    echo "- 版本匹配: $(printf "%s" "$r" | grep -q "'"$TARGET_COMMIT"'" && echo "✅ 是" || echo "❌ 否")"
    echo ""
    echo "## 2. 外网直连 DNS(不依赖 OpenClash)"
    if curl -fsS --max-time 6 https://www.baidu.com >/dev/null 2>&1; then echo "- ✅ baidu 直连可达 (HTTP 2xx/3xx)"; else echo "- ❌ 外网直连不通"; fi
    echo ""
    echo "## 3. 三频状态"
    for rad in radio0 radio1 radio2; do
      st=$(uci get wireless.$rad.disabled 2>/dev/null)
      echo "- $rad: $([ "$st" = "1" ] && echo "disabled(关闭)" || echo "enabled(开启)")"
    done
    echo ""
    echo "## 4. OpenClash"
    if pgrep -f clash >/dev/null 2>&1; then echo "- ✅ clash 进程运行中"; else echo "- ⚠️ clash 未运行"; fi
    if [ -x /etc/openclash/core/clash_meta ]; then echo "- ✅ 内核 clash_meta 存在且可执行"; else echo "- ❌ 内核 clash_meta 缺失/不可执行"; fi
    OC_CFG=$(ps w | grep "[c]lash" | grep -oE "\-f [^ ]+" | awk "{print \$2}")
    [ -z "$OC_CFG" ] && OC_CFG=/etc/openclash/config.yaml
    SEC=$(grep -m1 "secret:" "$OC_CFG" 2>/dev/null | sed -E "s/.*secret:[ ]*[\"]?([A-Za-z0-9_]+)[\"]?.*/\1/")
    # 2026-11-16 P0 修复: 合并 /proxies 与 /providers/proxies 两个来源取大值。
    #   机场订阅多为 provider 模式, 节点不在 /proxies 顶层而在 /providers/proxies;
    #   只查顶层会把"有节点"误判成 0 节点 -> DNS 由 OpenClash(7874)接管时判 FAIL
    #   -> --auto 误触发整机回退。
    REAL_NODES=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/proxies" 2>/dev/null | grep -oE "\"type\":\"(Vless|Vmess|Trojan|Hysteria2|Hysteria|Shadowsocks|ShadowsocksR|Tuic|WireGuard|Snell)\"" | wc -l | tr -d " ")
    PROV_NODES=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/providers/proxies" 2>/dev/null | grep -oE "\"type\":\"(Vless|Vmess|Trojan|Hysteria2|Hysteria|Shadowsocks|ShadowsocksR|Tuic|WireGuard|Snell)\"" | wc -l | tr -d " ")
    [ "${PROV_NODES:-0}" -gt "${REAL_NODES:-0}" ] 2>/dev/null && REAL_NODES="$PROV_NODES"
    ACTIVE_CONN=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/connections" 2>/dev/null | grep -oE "\"id\":\"[^\"]+\"" | wc -l)
    echo "- 真实节点数(经控制器, 顶层+provider 合并): $REAL_NODES 个"
    echo "- 当前活跃外部连接: $ACTIVE_CONN 条 (证明代理正在承载上网)"
    echo ""
    echo "## 5. DHCP 静态租约数"
    echo "- $(uci show dhcp 2>/dev/null | grep -c "dhcp.@host") 条"
    echo ""
    echo "## 6. 防火墙 fw4 check"
    fw4 check 2>&1 | tail -1
    echo ""
    echo "## 7. 配置持久化(uci changes 应为空)"
    ch=$(uci changes 2>/dev/null)
    if [ -z "$ch" ]; then echo "- ✅ uci changes 为空(已全部 commit)"; else echo "- ⚠️ 存在未提交改动:"; echo "$ch"; fi
  ' 2>/dev/null >> "$rep"
  config_fidelity_check >> "$rep"
  {
    echo ""
    echo "## 8. U-Boot / T2 兜底 (刷前基线 vs 刷后实测)"
    echo "- 刷前: bootcmd=\`${T2_PRE_BOOTCMD:-?}\` / ${T2_PRE_UBOOT:-?} / 恢复页 ${T2_PRE_RECOVERY_IP:-?} / 核验通过=${T2_PRE_OK}"
    echo "- 刷前 env 冗余健康度: ${T2_ENV_HEALTH:-?} (在位卷: ${T2_ENV_LIVE:-?})"
    echo "- 刷后实测:"
  } >> "$rep"
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'sh -s' 2>/dev/null <<'REMOTE' >> "$rep"
echo '  - bootcmd / recovery_mtd (逐卷, 不并联):'
for v in /dev/ubi0_1 /dev/ubi0_2; do
  echo "    [$v]"
  cat "$v" 2>/dev/null | strings 2>/dev/null | grep -E '^bootcmd=|^recovery_mtd=|^boot_ubi=' | sort -u | sed 's/^/      /'
done
echo '  - fw_printenv (参考, 不作为判据):'
fw_printenv bootcmd recovery_mtd boot_ubi 2>/dev/null | sed 's/^/      /'
M=$(awk -F: '/"chainloader"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
[ -z "$M" ] && M=mtd3
echo '  - U-Boot 版本串(mtd3):'
grep -a -o -E 'U-Boot 20[0-9]{2}[^ ]{0,50}' /dev/$M 2>/dev/null | sort -u | head -3 | sed 's/^/    /'
echo '  - 恢复页 IP(mtd3):'
grep -a -o -E '192\.168\.(255|0)\.(1|2|255)' /dev/$M 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/^/    /'
echo ""
REMOTE
  echo "📄 已生成升级后结构化报告: $rep"
}

# ---------- 官方 release 统一元数据(2026-11-13 合并为单次 gh 调用) ----------
# 原 official_asset_meta() 与 official_release_flags() 各调一次 gh 取 .[0]: 两次调用之间上游
# 一旦发版就可能指向不同 release(闸校验 A、实际刷 B), 且 /releases 默认按 created_at 排序,
# 编辑过发布时间的 release 会排错。现合并为一次调用 + sort_by(.published_at)|reverse|.[0],
# 目标选片 / 沉淀闸 / digest 基准 / 测试版识别全部绑定到同一份数据。
# digest 是 GitHub 官方外部基准, 可替代缺失的 sha256sums(1029 / 1112 均无 sums)。
OFFICIAL_ITB_PUB=""; OFFICIAL_ITB_NAME=""; OFFICIAL_ITB_URL=""; OFFICIAL_ITB_SHA=""
OFFICIAL_REL_TAG=""; OFFICIAL_REL_PRERELEASE=""; OFFICIAL_REL_BODY=""; OFFICIAL_REL_FLAGS="UNKNOWN"
# 2026-11-15: 环境里被注入无效 GITHUB_TOKEN 时会覆盖 gh keyring 的有效凭据, 使 gh api
#   报 401 Bad credentials -> 官方元数据/asset.digest/发布闸全线失效, 静默降级成"仅 --itb 可用"。
#   先探活, 失败则在本进程内丢弃该变量改用 keyring; 不修改用户 shell 配置。
gh_auth_guard(){
  [ -n "${GITHUB_TOKEN:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  if ! gh api user >/dev/null 2>&1; then
    echo "⚠️ 环境变量 GITHUB_TOKEN 无效(gh api 401), 本进程内忽略它, 改用 gh keyring 凭据"
    unset GITHUB_TOKEN
  fi
}

official_release_meta(){
  command -v gh >/dev/null 2>&1 || return 1
  gh_auth_guard
  local tsv try
  for try in 1 2 3; do
    tsv=$(gh api "repos/$REPO/releases?per_page=100" --jq '[.[] | select(any(.assets[]; .name|test("gemtek_xr1710g")))] | sort_by(.published_at) | reverse | .[0] | [.published_at, (.assets | map(select(.name|test("gemtek_xr1710g"))) | .[0].name), (.assets | map(select(.name|test("gemtek_xr1710g"))) | .[0].browser_download_url), (.assets | map(select(.name|test("gemtek_xr1710g"))) | .[0].digest // "NONE"), (.tag_name // ""), ((.prerelease // false)|tostring), ((.body // "")|gsub("[\r\n\t]+";" "))] | @tsv' 2>/dev/null | head -1)
    [ -n "$tsv" ] && break
    sleep 2
  done
  [ -n "$tsv" ] || return 1
  # NONE 占位防 IFS=tab 折叠空字段(同 router_watch.sh)
  IFS=$'\t' read -r OFFICIAL_ITB_PUB OFFICIAL_ITB_NAME OFFICIAL_ITB_URL OFFICIAL_ITB_SHA OFFICIAL_REL_TAG OFFICIAL_REL_PRERELEASE OFFICIAL_REL_BODY <<< "$tsv"
  [ "$OFFICIAL_ITB_SHA" = "NONE" ] && OFFICIAL_ITB_SHA=""
  OFFICIAL_ITB_SHA="${OFFICIAL_ITB_SHA#sha256:}"
  [ -n "$OFFICIAL_ITB_NAME" ] || return 1
  return 0
}

# release 性质识别: 纯 bash 判定, 不再独立调 gh(与元数据同源)。
# 20261112 是 OTA 测试版, 正文写"本次为测试固件""不保留配置""OTA: wipe-config", 但
# prerelease=false, 光看元数据看不出来。关键字之外再加一条不依赖措辞的客观信号。
official_release_flags(){
  local flags="" tag_date img_date
  [ -n "$OFFICIAL_REL_TAG" ] || { OFFICIAL_REL_FLAGS="UNKNOWN"; return 0; }
  [ "$OFFICIAL_REL_PRERELEASE" = "true" ] && flags="PRERELEASE"
  # 2026-11-15 拆分: TEST(版本性质) 与 WIPE-CONFIG(配置兼容性) 是正交的两类信号。
  #   20261112 = 测试版 + wipe-config -> 两者都命中; 20261115 = prerelease=false 正式版 + wipe-config
  #   -> 只应命中 WIPE-CONFIG。旧逻辑把 wipe-config 也算 TEST, 导致正式版被误判"等正式版"永远等不到。
  if [ "$OFFICIAL_REL_PRERELEASE" != "true" ] && printf '%s' "$OFFICIAL_REL_BODY" | grep -qE '本次为测试固件|测试固件|测试版|测试不保留配置'; then
    flags="${flags:+$flags+}TEST"
  fi
  if printf '%s' "$OFFICIAL_REL_BODY" | grep -qE 'wipe-config|不保留配置|默认打开测试'; then
    flags="${flags:+$flags+}WIPE-CONFIG"
  fi
  # 客观信号(2026-11-13): tag 日期与镜像名日期不符 —— 20261112 标签挂的是 20261111 镜像。
  # 正式版历史上两者同日; 错配通常意味着临时打包 / 测试发布 / 产物与说明不一致。
  # 上游若换措辞写英文 beta 而关键字漏判, 这一条仍可能兜住。
  tag_date=$(printf '%s' "$OFFICIAL_REL_TAG" | grep -oE '20[0-9]{6}' | head -1)
  img_date=$(printf '%s' "$OFFICIAL_ITB_NAME" | grep -oE '20[0-9]{6}' | head -1)
  if [ -n "$tag_date" ] && [ -n "$img_date" ] && [ "$tag_date" != "$img_date" ]; then
    flags="${flags:+$flags+}TAG-DATE-MISMATCH"
  fi
  OFFICIAL_REL_FLAGS="${flags:-OK}"
}
if official_release_meta; then
  official_release_flags
else
  echo "⚠️ 无法读取官方 release 元数据(gh 未登录/限流/网络抖动); 自动选片、官方基准与测试版识别均不可用, 仅 --itb 显式指定可用"
fi

# ---------- 配置策略(2026-11-15: 版本感知选择性重建) ----------
#   full      = 同代小版本升级, 全量保真导入旧 /etc/config(既有行为)
#   selective = wipe-config / 配置不兼容版本, 只恢复身份数据 + OpenClash, 其余交给新版出厂默认
# 自动切换: release 标记含 WIPE-CONFIG -> selective; --config-policy 显式覆盖(需自担风险)
CONFIG_POLICY="${CONFIG_POLICY_OVERRIDE:-full}"
if [ -z "${CONFIG_POLICY_OVERRIDE:-}" ] && printf '%s' "${OFFICIAL_REL_FLAGS:-}" | grep -q 'WIPE-CONFIG'; then
  CONFIG_POLICY=selective
fi
case "$CONFIG_POLICY" in
  full)      echo "配置策略: full (全量配置保真)" ;;
  selective) echo "配置策略: selective (版本感知选择性重建 —— 不导入旧 /etc/config)"
             echo "  依据: 2026-11-15 解包 1115 出厂镜像真实 diff, 见 README「wipe-config 版本适配」" ;;
  *) die "未知 --config-policy: $CONFIG_POLICY (仅支持 full|selective)" ;;
esac

# ---- 大镜像下载/校验公共函数(2026-11-17 修复) ----
# 原缺陷(本次实战真踩到):
#   1) 主路径 `curl -fL --max-time 300` 对 85MB itb 不够 -> 真超时失败; 单次、无重试、无续传。
#   2) `2>/dev/null` 把 curl 错误全吞掉, 失败只剩一句"下载失败", 无法判因。
#   3) 回退路径 `curl -fL` **连 --max-time 都没有** -> 可能无限挂住。
#   4) 回退镜像下载后**完全不校验 sha256** 就被 scp 上去刷机 —— 缺口恰在"出事时才走"的安全路径上。
# 现改为: stall 检测(限速判停滞, 不再用总时长硬帽卡死大文件) + 重试 + 断点续传 + stderr 落日志 + digest 校验。
ITB_DL_MAXTIME="${ITB_DL_MAXTIME:-1800}"           # 总时长兜底上限(可用环境变量覆盖)
ITB_DL_STALL_SPEED="${ITB_DL_STALL_SPEED:-10240}"  # 低于 10KB/s ...
ITB_DL_STALL_TIME="${ITB_DL_STALL_TIME:-60}"       # ... 持续 60s 即判停滞并重试
fetch_itb(){  # $1=url $2=dest; 成功返回 0
  local url="$1" dest="$2" log rc
  log="${dest}.curl.log"
  curl -fL --no-progress-meter --retry 3 --retry-delay 5 --retry-all-errors -C - \
       --speed-limit "$ITB_DL_STALL_SPEED" --speed-time "$ITB_DL_STALL_TIME" \
       --max-time "$ITB_DL_MAXTIME" \
       "$url" -o "$dest" 2>"$log"
  rc=$?
  if [ $rc -ne 0 ] || [ ! -s "$dest" ]; then
    echo "❌ 下载失败(curl rc=$rc, 日志 $log): $(tail -2 "$log" 2>/dev/null | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}
# 返回: 0=校验通过 1=不符 2=无官方基准(无法校验)
verify_itb_sha(){  # $1=file $2=期望 sha256(可空/NONE)
  local f="$1" want="${2:-}" act
  want="${want#sha256:}"
  if [ -z "$want" ] || [ "$want" = "NONE" ]; then
    echo "⚠️ 无官方 digest 基准, 无法校验 $(basename "$f")" >&2
    return 2
  fi
  act=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
  if [ "$act" = "$want" ]; then return 0; fi
  echo "❌ $(basename "$f") sha256 不符(实际 ${act:-空} vs 官方 $want)" >&2
  return 1
}
# 按 asset 名取官方 digest(回退镜像用; 与主路径同一权威来源 GitHub asset.digest)
asset_digest_by_name(){  # $1=asset name; 取不到或格式非法一律返回 NONE
  local jqf out
  jqf=$(printf '[.[] | .assets[] | select(.name=="%s")] | .[0].digest // "NONE"' "$1")
  out=$(gh api "repos/$REPO/releases?per_page=100" --jq "$jqf" 2>/dev/null | head -1)
  out="${out#sha256:}"
  # gh 出错时可能把 JSON 错误体打到 stdout(如 404/401), 那不是 digest。
  # 外部 API 边界必须校验格式: 只接受 64 位 hex, 否则视为无基准, 避免把错误体当期望值。
  case "$out" in
    ''|*[!0-9a-fA-F]*) echo "NONE" ;;
    *) if [ "${#out}" -eq 64 ]; then echo "$out"; else echo "NONE"; fi ;;
  esac
}

# 官方目标 itb 本地缺失时自动下载并用官方 digest 校验(仅真实执行; dry-run 不下载)。
download_official_itb(){
  local dest="$PREP_DIR/$OFFICIAL_ITB_NAME" act
  [ -f "$dest" ] && { printf '%s' "$dest"; return 0; }
  [ -n "$OFFICIAL_ITB_URL" ] || { echo "❌ 无官方 itb 下载地址" >&2; return 1; }
  [ -n "$OFFICIAL_ITB_SHA" ] || { echo "❌ 无官方 digest 基准, 拒绝下载无校验镜像" >&2; return 1; }
  echo "⬇️ 官方目标 itb 本地缺失, 自动下载: $OFFICIAL_ITB_NAME"
  if ! fetch_itb "$OFFICIAL_ITB_URL" "$dest"; then
    rm -f "$dest"; return 1
  fi
  act=$(shasum -a 256 "$dest" 2>/dev/null | awk '{print $1}')
  if [ "$act" != "$OFFICIAL_ITB_SHA" ]; then
    rm -f "$dest"; echo "❌ 下载镜像与 GitHub 官方 digest 不符(可能被篡改/截断), 已删除" >&2; return 1
  fi
  echo "✅ 已下载并通过 GitHub 官方 digest 校验: $act"
  printf '%s' "$dest"; return 0
}

# 解析待刷 itb: 优先级 --itb > 官方最新 release 的 xr1710g itb(本地缺失则真实执行自动下载)
# 2026-11-04 P0 修复: 删除 mtime 兜底。原因: 上游 20261102 把 XG2010G 设为 Latest 后,
#   本地未下载 1029 时旧的 ls -t 兜底会静默选中 1016(当前正在跑的版本), 导致完整全清刷
#   一遍却毫无收益, 且回退镜像也是同一个 => 空转 + 全担风险。现改为 fail-closed / 自动下载。
resolve_target_itb(){
  if [ -n "$ITB_OVERRIDE" ]; then
    [ -f "$ITB_OVERRIDE" ] && { printf '%s' "$ITB_OVERRIDE"; return 0; }
    echo "❌ --itb 指定文件不存在: $ITB_OVERRIDE" >&2; return 1
  fi
  [ -n "$OFFICIAL_ITB_NAME" ] || { echo "❌ 无法解析官方目标 itb; 请显式 --itb <已下载并校验的镜像>, 或检查 gh/网络" >&2; return 1; }
  printf '%s' "$PREP_DIR/$OFFICIAL_ITB_NAME"
  return 0
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
      printf '请输入路由器的 SSH 地址 (如 root@192.168.50.1 [XR1710G 出厂默认], 或 ssh config 中的主机别名): ' >&2
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

ITB=$(resolve_target_itb) || die "找不到待刷 itb (官方目标镜像无法解析; 请用 --itb 显式指定已下载并校验的镜像)"
[ -f "$KIT" ]    || die "找不到 kit.tar.gz"
# P0: 官方目标镜像本地缺失时, 真实执行自动下载(官方 digest 校验); dry-run 仅提示。
#     绝不再"任取一个本地 itb" —— 那会静默刷回当前正在运行的版本(白刷)。
if [ ! -f "$ITB" ]; then
  if [ "$DRY" = "1" ]; then
    echo "⚠️ [dry-run] 官方目标 itb 本地缺失: $(basename "$ITB"); 真实执行将自动下载并用 GitHub 官方 digest 校验"
  else
    ITB=$(download_official_itb) || die "官方目标 itb 下载/校验失败, 已中止(绝不退回本地任意 itb, 避免刷回当前版本)"
  fi
fi

# ---------- 发布沉淀闸(2026-11-02 加固 #2; 2026-11-04 绑定实际 ITB) ----------
# 背景: 手动跑本脚本(不带 --itb)会绕过 router_watch.sh 的 72h 闸。
#   2026-11-04 补掉的隐蔽缝隙: 旧代码校验的是"官方最新 release 的发布时间", 而实际刷入的
#   可能是 mtime 兜底选出的旧镜像 —— 闸和镜像根本不是同一个对象。现仅当
#   "实际待刷 ITB == 官方目标镜像"时, 用该镜像所属 release 的 published_at 校验。
#   --force 只跳过本闸, 不再影响 sha256 完整性校验(2026-11-04 窄化)。
#   dry-run 下仅告警不拦截(便于预演); 真实执行则 fail-closed。
if [ -z "$ITB_OVERRIDE" ] && [ "$FORCE" = "0" ] && [ "$(basename "$ITB")" = "$OFFICIAL_ITB_NAME" ]; then
  _pub="$OFFICIAL_ITB_PUB"
  if [ -n "$_pub" ]; then
    _pub_utc="${_pub/Z/+0000}"
    _pub_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$_pub_utc" +%s 2>/dev/null)
    _now_epoch=$(date +%s)
    if [ -n "$_pub_epoch" ]; then
      _age=$(( ( _now_epoch - _pub_epoch ) / 3600 ))
      if [ "$_age" -lt 72 ]; then
        if [ "$DRY" = "1" ]; then
          echo "⚠️ [dry-run] 沉淀闸: 目标镜像所属 release($_pub) 发布仅 ${_age}h (<72h), 真实执行时本脚本会拒绝自动升最新版"
        else
          die "🛑 沉淀闸: 目标镜像所属 release($_pub) 发布仅 ${_age}h (<72h)。请二选一: (a) 显式 --itb <指定版本 itb 文件> 升级到已确认版本; (b) 加 --force 跳过此闸(自担风险; 不影响 sha256 完整性校验)。"
        fi
      else
        echo "✅ 沉淀闸通过: 目标镜像所属 release 已发布 ${_age}h (>=72h)"
      fi
    fi
  fi
fi

# ---------- 版本闸(2026-11-12 新增, 2026-11-15 拆分) ----------
#   TEST / PRERELEASE : 版本性质, 默认 fail-closed, 需 --allow-test-build
#   WIPE-CONFIG       : 配置兼容性, 不拒绝刷, 但强制 selective 策略 + --ack-config-reset 确认
#   TAG-DATE-MISMATCH : 独立客观信号, 仅告警
#   --itb 显式指定历史版本时全部不适用(目标 release 已不是"最新"那个, 标记不该张冠李戴)。
release_risk_gate(){
  [ -z "$ITB_OVERRIDE" ] || return 0
  [ "$(basename "$ITB")" = "$OFFICIAL_ITB_NAME" ] || return 0
  local fl="${OFFICIAL_REL_FLAGS:-UNKNOWN}"
  case "$fl" in
    OK|"") return 0 ;;
    UNKNOWN)
      echo "⚠️ 无法读取目标 release 的发布说明(gh 限流/网络抖动), 测试版 / 不保留配置标记未知; 请人工核对 ${OFFICIAL_REL_TAG:-最新 release} 的正文后再刷"
      return 0 ;;
  esac
  echo "ℹ️ 官方目标 release [${OFFICIAL_REL_TAG:-?}] 标记: $fl"
  # A) 版本性质闸: 测试版 / 预发布默认拒绝, 与配置策略无关
  case "$fl" in
    *TEST*|*PRERELEASE*)
      echo "🛑 该 release 是测试版/预发布, 默认拒绝刷入"
      echo "   发布说明摘录: ${OFFICIAL_REL_BODY:0:200}"
      if [ "$DRY" = "1" ]; then echo "⚠️ [dry-run] 真实执行会拒绝刷入该测试版; 需 --allow-test-build, 或等正式版"; return 0; fi
      if [ "$ALLOW_TEST_BUILD" = "1" ]; then
        echo "⚠️ 已由 --allow-test-build 显式放行(自担风险)"
      else
        die "🛑 目标为测试版/预发布, 默认拒绝刷入。请等正式版 / 用 --itb 指定已确认版本, 或加 --allow-test-build 自担风险。"
      fi
      ;;
  esac
  # B) 配置兼容性闸: 不拒绝刷, 但强制 selective + 显式确认"配置不保真"
  case "$fl" in
    *WIPE-CONFIG*)
      echo "⚠️ 该 release 明确要求「不保留配置 / wipe-config」。注意: 这**不代表它是测试版** ——"
      echo "   20261115 就是 prerelease=false 的正式版, 只是后端大改动导致旧配置不兼容。"
      echo "   本工具已自动切换配置策略: $CONFIG_POLICY"
      echo "   自动恢复: 身份数据 + 10 个 ONLY-LIVE 第三方配置(整文件) + 9 个 DIFF 文件(键级迁移表) + OpenClash/4 个第三方程序(离线注入, 零联网)"
      echo "   不导入: 旧 network/wireless/system 及新版移除的 NPU/风扇等; 这些由出厂默认 + uci-defaults 重建(见 README「语义级配置迁移表」)"
      echo "   ⚠️ 升级后仍建议按 $LOG_DIR/config-restore-todo-*.md 核对 glass 主题 / openssl 等少数人工项"
      if [ "$DRY" = "1" ]; then echo "⚠️ [dry-run] 真实执行还需 --ack-config-reset 显式确认配置重建"; return 0; fi
      if [ "$ALLOW_TEST_BUILD" != "1" ] && [ "$ACK_CONFIG_RESET" != "1" ]; then
        die "🛑 wipe-config 版本会丢弃大量自定义配置, 请加 --ack-config-reset 显式确认后再刷。"
      fi
      ;;
  esac
  case "$fl" in
    *TAG-DATE-MISMATCH*) echo "⚠️ TAG-DATE-MISMATCH: tag 日期 != 镜像名日期, 产物/说明可能不一致, 请人工核对" ;;
  esac
}
release_risk_gate

# 自动解析回退镜像: 取路由器当前运行的 commit hash, 在本地 firmware-prep 匹配同名 itb。
# 这样每次升级都会把"刚跑的版本"作为回退目标 —— 即自动备份当前版本。
resolve_rollback(){
  local rev date hash itb
  rev=$(ssh -o ConnectTimeout=8 "$ROUTER" 'grep DISTRIB_REVISION /etc/openwrt_release' 2>/dev/null) || return 1
  # 优先按日期(YYYYMMDD, 补零)匹配: 路由器 DISTRIB_REVISION 形如 2026-9-16-...-<commit>, itb 文件名含 20260916-<commit>
  # 避坑: 文件名 commit 为 8 位, 运行固件 commit 为 10 位, 子串 grep 易失配; 用日期更稳
  #       且 DISTRIB_REVISION 月/日可能是单数字(9/16), 需补零成 8 位才能匹配文件名 20260916
  ymd=$(printf '%s' "$rev" | grep -oE '[0-9]{4}-[0-9]+-[0-9]+' | head -1)
  y=$(printf '%s' "$ymd" | cut -d- -f1); m=$(printf '%s' "$ymd" | cut -d- -f2); d=$(printf '%s' "$ymd" | cut -d- -f3)
  date=$(printf '%s%02d%02d' "$y" "$m" "$d")
  hash=$(printf '%s' "$rev" | grep -oE '[0-9a-f]{7,40}' | tail -1)  # 取末尾 hex 串; 避开行尾单引号对 $ 锚点的干扰
  [ -n "$date" ] && itb=$(ls "$PREP_DIR"/*.itb 2>/dev/null | grep -i "$date" | head -1)
  [ -z "$itb" ] && [ -n "$hash" ] && itb=$(ls "$PREP_DIR"/*.itb 2>/dev/null | grep -i "$hash" | head -1)
  [ -n "$itb" ] && { printf '%s' "$itb"; return 0; }
  return 1
}

# 固件级回退点自动化(P2): 确保"当前路由器正在运行的版本"的 itb 本地存在;
# 不存在则 best-effort 从官方 release 下载(按日期/commit 匹配), 与 backup_config 的
# 配置级备份形成"固件+配置"双保险。失败不阻断升级, 回落到 FALLBACK_ITB。
ensure_rollback_itb(){
  if [ -n "$ROLLBACK" ] && [ -f "$ROLLBACK" ]; then
    local _rsha _vrc
    _rsha=$(asset_digest_by_name "$(basename "$ROLLBACK")")
    verify_itb_sha "$ROLLBACK" "$_rsha"; _vrc=$?
    if [ "$_vrc" = "1" ]; then
      echo "⚠️ 已选定的回退镜像与官方 digest 不符, 弃用(依赖 FALLBACK_ITB): $(basename "$ROLLBACK")"
      ROLLBACK=""
    else
      [ "$_vrc" = "2" ] && echo "ℹ️ 回退镜像未经校验(无 digest 基准), 仅作 best-effort 回退点"
      echo "✅ 回退镜像已本地就位: $(basename "$ROLLBACK")"
      return 0
    fi
  fi
  [ "$DRY" = "1" ] && { echo "ℹ️ dry-run 不下载回退镜像(仅本地检查)"; return 0; }
  command -v gh >/dev/null 2>&1 || { echo "⚠️ 无 gh CLI, 跳过回退镜像下载(依赖 FALLBACK_ITB)"; return 0; }
  local rev ymd y m d date hash jqf url name
  rev=$(ssh -o ConnectTimeout=8 "$ROUTER" 'grep DISTRIB_REVISION /etc/openwrt_release' 2>/dev/null) || { echo "⚠️ 读不到当前版本, 跳过回退镜像下载"; return 0; }
  ymd=$(printf '%s' "$rev" | grep -oE '[0-9]{4}-[0-9]+-[0-9]+' | head -1)
  y=$(printf '%s' "$ymd" | cut -d- -f1); m=$(printf '%s' "$ymd" | cut -d- -f2); d=$(printf '%s' "$ymd" | cut -d- -f3)
  date=$(printf '%s%02d%02d' "$y" "$m" "$d")
  hash=$(printf '%s' "$rev" | grep -oE '[0-9a-f]{7,40}' | tail -1)
  # 在含 XR1710G 的 releases 中找含当前版本 date 或 hash 的 itb 资产
  jqf=$(printf '[.[] | select(any(.assets[]; .name|test("gemtek_xr1710g")))] | .[] | .assets[] | select(.name|test("gemtek_xr1710g") and (.name|test("%s"))) | .browser_download_url' "$date")
  url=$(gh api "repos/$REPO/releases?per_page=100" --jq "$jqf" 2>/dev/null | head -1)
  if [ -z "$url" ] && [ -n "$hash" ]; then
    jqf=$(printf '[.[] | select(any(.assets[]; .name|test("gemtek_xr1710g")))] | .[] | .assets[] | select(.name|test("gemtek_xr1710g") and (.name|test("%s"))) | .browser_download_url' "$hash")
    url=$(gh api "repos/$REPO/releases?per_page=100" --jq "$jqf" 2>/dev/null | head -1)
  fi
  [ -z "$url" ] && { echo "⚠️ 未找到当前版本($date/$hash)的回退 itb 下载源, 依赖 FALLBACK_ITB"; return 0; }
  name=$(basename "$url")
  local rsha vrc
  rsha=$(asset_digest_by_name "$name")
  if [ -f "$PREP_DIR/$name" ]; then
    verify_itb_sha "$PREP_DIR/$name" "$rsha"; vrc=$?
    if [ "$vrc" = "1" ]; then
      echo "⚠️ 本地回退镜像与官方 digest 不符, 拒绝用作回退点(依赖 FALLBACK_ITB): $name"
      return 0
    fi
    [ "$vrc" = "2" ] && echo "ℹ️ 回退镜像未经校验(无 digest 基准), 仅作 best-effort 回退点: $name"
    echo "✅ 回退镜像已本地就位: $name"
    ROLLBACK="$PREP_DIR/$name"; return 0
  fi
  # 与主路径同一纪律: 无官方 digest 基准就不下载无校验镜像。
  # 回退是"出事时才走"的安全路径, 绝不能把未校验/被截断的镜像刷进去。
  if [ -z "$rsha" ] || [ "$rsha" = "NONE" ]; then
    echo "⚠️ 取不到回退镜像官方 digest, 拒绝下载无校验镜像(依赖 FALLBACK_ITB): $name"
    return 0
  fi
  echo "⬇️ 下载当前版本回退镜像: $name"
  if ! fetch_itb "$url" "$PREP_DIR/$name"; then
    rm -f "$PREP_DIR/$name"; echo "⚠️ 回退镜像下载失败, 依赖 FALLBACK_ITB"; return 0
  fi
  if ! verify_itb_sha "$PREP_DIR/$name" "$rsha"; then
    rm -f "$PREP_DIR/$name"; echo "⚠️ 回退镜像校验未通过, 已删除, 依赖 FALLBACK_ITB"; return 0
  fi
  echo "✅ 已下载并通过官方 digest 校验的回退镜像: $PREP_DIR/$name"
  ROLLBACK="$PREP_DIR/$name"
}
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
    echo "⚠️ 配置备份失败(不影响升级, 但将失去本机唯一配置级回退点; 固件级回退仍由 ROLLBACK itb 提供)"
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
  rm -rf "$build"; mkdir -p "$build/etc/config" "$build/etc/apk/repositories.d"
  tar -xzf "$KIT" -C "$build" 2>/dev/null || { echo "❌ 解包 kit 失败"; exit 1; }
  # 清理从旧 kit 继承的 AppleDouble 垃圾(._*), 避免再次刷进路由器 /etc
  find "$build" -name '._*' -type f -delete 2>/dev/null
  # 用活路由当前 OpenClash 配置覆盖 kit 内烘焙的旧订阅/规则 (保持订阅有效, 避免升级后连不上)
  # 注意: 排除 etc/openclash/core —— 内核二进制(57MB)由 kit 烘焙(见 build_kit.sh --openclash-core),
  #       随 kit 整包 scp + sysupgrade -f 还原, 不再走"大文件经 SSH tar 管道"的脆弱链路(P1 根治)。
  # ⚠️ BusyBox tar 不支持 GNU 的 --exclude(会 unrecognized option 静默失败, 曾导致本抓取长期
  #    走 fallback 而无人察觉); 必须用 -X <模式文件>。模式文件写在路由 /tmp, 用完即删。
  #    排除 core(57MB, kit 已烘焙)与 ._*(路由器 /etc/openclash 里存量 AppleDouble 垃圾;
  #    bsdtar 解包 busybox 流时对 ._ 条目会报 Truncated 并使退出码非零, 故必须在源头排除)。
  #    注意: bsdtar 对 busybox tar 流偶发非零退出(内容已抽全), 故成功判定以落盘内容为准, 不信退出码。
  ssh -o ConnectTimeout=10 "$ROUTER" 'printf "%s\n" "etc/openclash/core" "._*" "*/._*" > /tmp/kit_tar.ex; tar -czX /tmp/kit_tar.ex -f - -C / etc/config/openclash etc/openclash; rm -f /tmp/kit_tar.ex' 2>/dev/null \
       | tar -xzf - -C "$build" 2>/dev/null || true
  if [ -s "$build/etc/config/openclash" ]; then
    echo "✅ 已抓取活路由 OpenClash 配置(订阅/规则)覆盖 kit 内旧文件"
  else
    echo "⚠️ OpenClash 配置抓取失败, 沿用 kit 内烘焙版本"
  fi
  # 订阅数据兜底(P1 之后发现: clean 刷机后 rc.local 的 apk add 重装 OpenClash 会清空 /etc/openclash/config,
  #  仅靠 sysupgrade -f 还原不够可靠 —— 本次实机就因此丢了订阅, 只能从升级前备份回拷)。
  # 把活路由 openclash 数据(除 57MB 内核)另存到 kit 的 etc/zzz-oc-data/(apk add 不会触碰此路径),
  # 由 zzz-restore 的 rc.local 在 apk add 之后、启动 openclash 之前据此还原。
  mkdir -p "$build/etc/zzz-oc-data"
  ssh -o ConnectTimeout=10 "$ROUTER" 'printf "%s\n" "etc/openclash/core" "._*" "*/._*" > /tmp/kit_tar.ex; tar -czX /tmp/kit_tar.ex -f - -C / etc/openclash; rm -f /tmp/kit_tar.ex' 2>/dev/null \
       | tar -xzf - --strip-components=2 -C "$build/etc/zzz-oc-data" 2>/dev/null || true
  if [ -n "$(ls -A "$build/etc/zzz-oc-data" 2>/dev/null)" ]; then
    echo "✅ 已另存 OpenClash 订阅数据(除内核)到 kit 的 etc/zzz-oc-data/ (防 apk 重装清空)"
  else
    echo "⚠️ OpenClash 订阅数据另存失败(依赖上方 sysupgrade -f 还原路径)"
  fi
  # ---------- 2026-11-15: 离线注入 OpenClash 程序文件(wipe-config 决定性) ----------
  # 1115 出厂不含 luci-app-openclash, 且官方源 / vsean 镜像的 packages.adb 均无此包,
  # 首启动联网 apk add 必失败。这里从活路由导出"程序文件"(apk 包全量 + 运行时脚本),
  # 打成 etc/zzz-oc-app.tar.gz 注入 kit; 首启动 uci-defaults 阶段解到 /, 零联网。
  # 排除 core(57MB 内核已由 kit 烘焙)与 etc/config/openclash(上面已单独抓取覆盖)。
  if [ "${CONFIG_POLICY:-full}" = "selective" ]; then
    _ocapp="$build/etc/zzz-oc-app.tar.gz"
    ssh -o ConnectTimeout=25 "$ROUTER" '
      # ⚠️ apk info -L 输出的是不带前导 / 的相对路径(第 2 行起), 早期版本用 grep "^/"
      #   过滤会把 221 行全部清空, 实测打出 16B 空 tar —— 必须按路径前缀白名单匹配。
      apk info -L luci-app-openclash 2>/dev/null | tail -n +2 \
        | grep -E "^(etc|usr|lib|www|sbin|bin)/" \
        | grep -vE "(^|/)\._|/etc/openclash/core|^etc/config/openclash$|^etc/openclash/" > /tmp/oc_app.list
      # 运行时脚本目录不在 apk 文件清单里(运行时生成/第三方), 单独补; find 必须走绝对路径
      find /usr/share/openclash /usr/lib/lua/luci/model/cbi/openclash \
           /usr/lib/lua/luci/view/openclash -type f 2>/dev/null \
        | sed "s|^/||" | grep -v "/\._" >> /tmp/oc_app.list
      cd / && tar -czf - -T /tmp/oc_app.list 2>/dev/null
      rm -f /tmp/oc_app.list
    ' > "$_ocapp" 2>/dev/null
    _oclist=$(tar -tzf "$_ocapp" 2>/dev/null)
    if [ -s "$_ocapp" ] \
       && printf '%s\n' "$_oclist" | grep -qE '(^|/)etc/init\.d/openclash$' \
       && printf '%s\n' "$_oclist" | grep -q 'usr/share/openclash/'; then
      echo "✅ 已抓取活路由 OpenClash 程序文件 ($(printf '%s\n' "$_oclist" | grep -c . ) 项) -> kit 的 etc/zzz-oc-app.tar.gz (离线, 无需 apk add)"
    else
      rm -f "$_ocapp"
      die "🛑 离线 OpenClash 程序包抓取/校验失败。1115 出厂不含该包且所有 feed 均无, 继续刷机必然导致代理网关断; 请检查活路由 apk info -L luci-app-openclash 是否可用。"
    fi
  fi
  # ---------- 2026-11-15 (二): selective 整文件导入白名单内的第三方配置 ----------
  # 实证: 这些文件在 1115 出厂 /etc/config 里根本不存在(ONLY-LIVE), 导入不覆盖任何出厂默认。
  # openclash 已由上方专通道抓取覆盖; 这里抓其余白名单项。
  if [ "${CONFIG_POLICY:-full}" = "selective" ]; then
    local _nsc=0
    for cfg in $SAFE_CONFIGS; do
      [ "$cfg" = "openclash" ] && continue
      if ssh -o ConnectTimeout=8 "$ROUTER" "cat /etc/config/$cfg" 2>/dev/null > "$build/etc/config/$cfg" \
         && [ -s "$build/etc/config/$cfg" ] && grep -q '^config' "$build/etc/config/$cfg"; then
        _nsc=$((_nsc+1))
      else
        rm -f "$build/etc/config/$cfg"
      fi
    done
    echo "✅ 已注入白名单第三方配置 $_nsc 个(1115 出厂无同名文件, 不覆盖出厂默认): $SAFE_CONFIGS"
  fi
  # ---------- 2026-11-15 (二): 配置参考快照(语义级迁移表的数据源) ----------
  # 9 个 DIFF 文件不能整文件导入, 但用户定制必须保真: dhcp 的 noresolv/127.0.0.1#7874/
  # cachesize、rpcd 的 homepage 只读用户(含系统用户)、watchcat 223.5.5.5、zerotier
  # secret+network、uhttpd 性能项、firewall 的 include 段…
  # 这里把活路由全量 /etc/config + homepage 系统用户行打成**不生效**的嵌套归档注入 kit;
  # zzz-restore 首启动按硬编码键表逐键读取回写(值只在运行时 kit, 绝不进源码 / GitHub)。
  # 归档同时也是刷后可人工取回的原文备份(zzz 会移到 ~/router-upgrade-logs/ 并 chmod 600)。
  if [ "${CONFIG_POLICY:-full}" = "selective" ]; then
    _ref="$build/etc/zzz-config-ref.tar.gz"
    ssh -o ConnectTimeout=30 "$ROUTER" '
      rm -rf /tmp/zzzref; mkdir -p /tmp/zzzref/etc
      printf "%s\n" "._*" "*/._*" "*.bak*" "*.apk-new" > /tmp/zzzref.ex
      cd / && tar -cX /tmp/zzzref.ex -f - etc/config 2>/dev/null | tar -xf - -C /tmp/zzzref
      grep -E "^homepage:" /etc/passwd > /tmp/zzzref/etc/passwd.homepage 2>/dev/null || :
      grep -E "^homepage:" /etc/shadow > /tmp/zzzref/etc/shadow.homepage 2>/dev/null || :
      cd /tmp/zzzref && tar -czf - etc
      rm -rf /tmp/zzzref /tmp/zzzref.ex
    ' > "$_ref" 2>/dev/null
    if [ -s "$_ref" ] && tar -tzf "$_ref" 2>/dev/null | grep -qE '(^|/)etc/config/dhcp$'; then
      echo "✅ 已抓取配置参考快照 -> kit 的 etc/zzz-config-ref.tar.gz (键级迁移 + 刷后人工取回)"
    else
      rm -f "$_ref"
      die "🛑 配置参考快照抓取/校验失败。9 个 DIFF 文件的用户定制无法迁移, 继续刷机会静默丢配置。"
    fi
  fi
  # ---------- 2026-11-15 (二): 离线恢复其余 4 个第三方服务 ----------
  # 1115 出厂 init.d 与本机差 8 个服务: airoha-npu / cpufreq(新版移除, 绝不恢复)、
  # openclash(上面已处理)、dawn / luci-app-pushbot(apk 包)、tailscale / wifihistory
  # (手工部署, 不属任何 apk 包, 含 30MB tailscale + 39MB tailscaled 二进制)。
  # 打成 etc/zzz-extra-app.tar.gz 注入 kit; 首启动直接解到 /, 零联网。
  if [ "${CONFIG_POLICY:-full}" = "selective" ]; then
    _extraapp="$build/etc/zzz-extra-app.tar.gz"
    ssh -o ConnectTimeout=60 "$ROUTER" '
      : > /tmp/extra_app.list
      for p in dawn luci-app-pushbot; do
        apk info -L "$p" 2>/dev/null | tail -n +2 \
          | grep -E "^(etc|usr|lib|www|sbin|bin)/" \
          | grep -vE "(^|/)\._|^etc/config/|^etc/uci-defaults/|^lib/apk/" >> /tmp/extra_app.list
      done
      for f in /usr/sbin/tailscale /usr/sbin/tailscaled \
               /etc/init.d/tailscale /etc/init.d/tailscale-derp-home \
               /etc/init.d/wifihistory /usr/sbin/wifihistory \
               /usr/lib/lua/luci/controller/tailscale.lua \
               /usr/lib/lua/luci/i18n/wifihistory.zh-cn.lmo; do
        [ -f "$f" ] && printf "%s\n" "${f#/}" >> /tmp/extra_app.list
      done
      find /usr/lib/lua/luci/view/tailscale /etc/tailscale -type f 2>/dev/null \
        | sed "s|^/||" | grep -v "/\._" >> /tmp/extra_app.list
      # ⚠️ BusyBox sort 的 -o 不写目标文件, 反而把排序结果输出到 stdout(实测), 会污染
      #   SSH 返回的 tar 流, 造成"文件 36MB 但 tar -tzf 读出 0 条目"。必须用重定向+mv。
      sort -u /tmp/extra_app.list > /tmp/extra_app.sorted && mv -f /tmp/extra_app.sorted /tmp/extra_app.list
      cd / && tar -czf - -T /tmp/extra_app.list 2>/dev/null
      rm -f /tmp/extra_app.list
    ' > "$_extraapp" 2>/dev/null
    _ealist=$(tar -tzf "$_extraapp" 2>/dev/null)
    if [ -s "$_extraapp" ] \
       && printf '%s\n' "$_ealist" | grep -qE '(^|/)usr/sbin/tailscaled$' \
       && printf '%s\n' "$_ealist" | grep -qE '(^|/)etc/init\.d/dawn$'; then
      echo "✅ 已抓取离线第三方程序 ($(printf '%s\n' "$_ealist" | grep -c .) 项, $(du -h "$_extraapp" | awk '{print $1}')) -> kit 的 etc/zzz-extra-app.tar.gz"
    else
      rm -f "$_extraapp"
      die "🛑 离线第三方程序包抓取/校验失败($OFFLINE_SERVICES)。若活路由本就不含这些服务, 请从 OFFLINE_SERVICES 中移除后再刷。"
    fi
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
  # 抓取活路由当前 SSH host key (dropbear), 注入 kit 的 etc/dropbear/
  # 升级后由 sysupgrade -f 原样还原 -> host key 不变 -> 其他终端的 known_hosts 依然有效, 无需 ssh-keygen -R
  HOSTKEY_PRESERVED=0
  mkdir -p "$build/etc/dropbear"
  if ssh -o ConnectTimeout=10 "$ROUTER" 'cd / && tar -czf - etc/dropbear/dropbear_*_host_key 2>/dev/null' 2>/dev/null \
       | tar -xzf - -C "$build" 2>/dev/null; then
    hk_n=$(ls "$build"/etc/dropbear/dropbear_*_host_key 2>/dev/null | wc -l | tr -d ' ')
    if [ "${hk_n:-0}" -gt 0 ]; then
      HOSTKEY_PRESERVED=1
      echo "✅ 已抓取活路由 SSH host key ($hk_n 个) 注入 kit (升级后其他终端无需更新 known_hosts)"
    else
      echo "⚠️ 活路由无 dropbear host key, 升级后 host key 会变(各终端需 ssh-keygen -R)"
    fi
  else
    echo "⚠️ host key 抓取失败, 升级后 host key 会变(各终端需 ssh-keygen -R)"
  fi
  # 2026-11-15 selective: 严禁导入旧 network/wireless。解包 1115 出厂镜像实证, 新版
  # /etc/config 里根本没有 network/wireless/system —— 由 board.d + 03_wireless +
  # 22_airoha-network-migrate-v4 首启动生成; 导入旧文件会阻断生成并造成混合状态。
  if [ "${CONFIG_POLICY:-full}" = "full" ]; then
  # 抓取真实 network/wireless 配置(P2): 还原用户自定义信道/功率/桥接/额外SSID, 不再写死成作者默认。
  # 仅当两者都抓取成功才写标记文件 etc/zzz-realconfig.flag, zzz-restore 据此跳过 heredoc 改用真实配置;
  # 任一失败则删除, 首启动降级回写死 heredoc。注入的是运行时临时 kit(/tmp, 不进Git), 与源码零明文泄露。
  if ssh -o ConnectTimeout=10 "$ROUTER" 'cat /etc/config/network' 2>/dev/null > "$build/etc/config/network" && [ -s "$build/etc/config/network" ]; then
    echo "✅ 已抓取活路由 network 配置(还原自定义网络设置)"
  else
    rm -f "$build/etc/config/network"
  fi
  if ssh -o ConnectTimeout=10 "$ROUTER" 'cat /etc/config/wireless' 2>/dev/null > "$build/etc/config/wireless" && [ -s "$build/etc/config/wireless" ]; then
    echo "✅ 已抓取活路由 wireless 配置(还原自定义信道/功率/SSID)"
  else
    rm -f "$build/etc/config/wireless"
  fi
  if [ -f "$build/etc/config/network" ] && [ -f "$build/etc/config/wireless" ]; then
    : > "$build/etc/zzz-realconfig.flag"
    echo "✅ 真实 network/wireless 配置已就位, 首启动将还原用户自定义设置(而非写死默认)"
  else
    echo "⚠️ 真实配置抓取不完整, 首启动将降级为已知良好 heredoc 默认"
  fi
  else
    rm -f "$build/etc/config/network" "$build/etc/config/wireless" "$build/etc/zzz-realconfig.flag"
    echo "ℹ️ [selective] 不导入旧 network/wireless; 首启动由新版生成后仅补丁恢复 LAN IP / SSID / key"
  fi
  # ---------- 抓取额外配置(2026-10-21 审计扩充) ----------
  # 背景: 全清刷(sysupgrade -n)只保留 kit 内文件, 此前 dhcp 的 dnsmasq 定制(7874/noresolv)、
  # rpcd 的 homepage 只读用户、luci 主题、cpufreq governor、crontab、lan_report.sh+token、
  # apk 镜像源、http.lua 上传上限补丁、rc.d 启用态均不在抓取范围, 升级后丢失。
  # 单项失败不阻断(该配置全清后回出厂默认), 仅告警。
  if [ "${CONFIG_POLICY:-full}" = "full" ]; then
  local cfg n_ok=0 n_all=0
  for cfg in $EXTRA_CONFIGS; do
    n_all=$((n_all+1))
    if ssh -o ConnectTimeout=10 "$ROUTER" "cat /etc/config/$cfg" 2>/dev/null > "$build/etc/config/$cfg" \
       && [ -s "$build/etc/config/$cfg" ] && grep -q '^config' "$build/etc/config/$cfg"; then
      n_ok=$((n_ok+1))
    else
      rm -f "$build/etc/config/$cfg"
      echo "⚠️ /etc/config/$cfg 抓取失败或为空, 跳过(全清后将回出厂默认)"
    fi
  done
  [ "$n_ok" -gt 0 ] && echo "✅ 已抓取额外配置 $n_ok/$n_all 个: $EXTRA_CONFIGS"
  else
    echo "ℹ️ [selective] 跳过 EXTRA_CONFIGS 整文件导入(新版出厂配置由本版本自己生成)"
  fi
  # ⚠️ 2026-11-15: 这段"黑名单式全量兜底"等价于官方明令禁止的「导入旧版本配置」。
  #   wipe-config 版本必须整段跳过, 改由 SAFE_CONFIGS 白名单 + 补丁式身份恢复。
  if [ "${CONFIG_POLICY:-full}" = "full" ]; then
  # ---------- 全量 /etc/config 兜底(2026-10-27 修复 R5: 全清刷后配置漂移丢失) ----------
  # 背景: 此前仅白名单式抓取 EXTRA_CONFIGS + openclash/network/wireless, 全清刷(sysupgrade -n -f)
  #   后其余所有 /etc/config(如 firewall/ddns-go/lucky/wechatpush/zerotier/smartdns/upnpd/usteer/...)
  #   会回退包默认, 需升级后手动重建(实测 firewall 有 129 行自定义规则, ddns-go/lucky 等均含实质配置)。
  #   改为黑名单式: 抓取活机全部 /etc/config 作兜底, 覆盖所有未被上面单独处理的包配置; 未来新增包自动覆盖。
  #   排除 ._*(AppleDouble 垃圾) 与 *.bak(如 dawn.bak-<日期>, 非有效配置)。
  #   ⚠️ firewall 的 openclash/zerotier 等指向 /var 运行时文件的 config include 段, 由 zzz-restore 在首启动
  #      还原后、fw4 reload 前剥离(见 zzz-restore 第 3 节), 避免首启动 fw4 加载失败; 这些 include 由
  #      OpenClash/zerotier 自身启动时重新添加。etc/config/openclash 已被上面单独通道处理, 此处重复抓取同一
  #      UCI 文件, 内容一致无害。
  mkdir -p "$build/etc/config"
  ssh -o ConnectTimeout=15 "$ROUTER" 'printf "%s\n" "._*" "*/._*" "*.bak*" "*.apk-new" > /tmp/kit_tar.ex; cd / && tar -czX /tmp/kit_tar.ex -f - etc/config; rm -f /tmp/kit_tar.ex' 2>/dev/null \
       | tar -xzf - -C "$build" 2>/dev/null || true
  if [ -n "$(ls -A "$build/etc/config" 2>/dev/null)" ]; then
    cfg_all=$(find "$build/etc/config" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "✅ 已全量兜底抓取活机 /etc/config ($cfg_all 个文件), 覆盖 EXTRA_CONFIGS 之外的所有包配置(R5 修复)"
  else
    echo "⚠️ 全量 /etc/config 兜底抓取失败(仅 EXTRA_CONFIGS 等显式配置会被还原)"
  fi
  else
    echo "ℹ️ [selective] 已跳过全量 /etc/config 兜底 —— 官方明确要求不得导入旧版本配置"
  fi
  # ---------- 抓取定制路径(目录/文件混合, tar 一次拉取; 排除 ._* 与 *.bak) ----------
  if [ "${CONFIG_POLICY:-full}" = "selective" ]; then RUN_EXTRA_PATHS="$SAFE_EXTRA_PATHS"; else RUN_EXTRA_PATHS="$EXTRA_PATHS"; fi
  # rc.d 单独拉: 排除 openclash 开机链(首启动时 init.d/openclash 尚未安装, 悬空符号链接无意义,
  # 由 zzz-restore 的 rc.local 在 apk add 后 /etc/init.d/openclash enable 重建)。
  # ⚠️ BusyBox tar 无 --exclude, 一律用 -X <模式文件>(见上方说明)。
  #    bsdtar 解 busybox 流退出码不可靠, 成功判定以落盘内容为准(crontabs/root 为探针)。
  ssh -o ConnectTimeout=15 "$ROUTER" 'printf "%s\n" "._*" "*/._*" "*.bak" "*.apk-new" > /tmp/kit_tar.ex; tar -czX /tmp/kit_tar.ex -f - -C / '"$RUN_EXTRA_PATHS"'; rm -f /tmp/kit_tar.ex' 2>/dev/null \
       | tar -xzf - -C "$build" 2>/dev/null || true
  if [ -f "$build/etc/crontabs/root" ]; then
    echo "✅ 已抓取定制路径(排除 ._*/bak): $RUN_EXTRA_PATHS"
  else
    echo "⚠️ 定制路径整包抓取失败, 逐个降级重试"
    local p
    for p in $RUN_EXTRA_PATHS; do
      if ssh -o ConnectTimeout=10 "$ROUTER" "cat /$p" 2>/dev/null > "$build/$p" 2>/dev/null && [ -s "$build/$p" ]; then
        echo "  ✅ $p"
      else
        rm -f "$build/$p"
        echo "  ⚠️ $p 抓取失败, 跳过"
      fi
    done
  fi
  # 2026-11-15: selective 下不导入旧 /etc/rc.d 启用态 —— 新版服务集合已变
  #   (1115 新增 bridger/pbr/sing-box/naoki66-ota 等 9 个配置), 旧链会悬空。
  if [ "${CONFIG_POLICY:-full}" = "full" ]; then
  ssh -o ConnectTimeout=10 "$ROUTER" 'printf "%s\n" "etc/rc.d/*openclash*" > /tmp/kit_tar.ex; tar -czX /tmp/kit_tar.ex -f - -C / etc/rc.d; rm -f /tmp/kit_tar.ex' 2>/dev/null \
       | tar -xzf - -C "$build" 2>/dev/null || true
  if [ -d "$build/etc/rc.d" ] && [ -n "$(ls -A "$build/etc/rc.d" 2>/dev/null)" ]; then
    echo "✅ 已抓取 /etc/rc.d 服务启用态(排除 openclash 链, 由 rc.local enable 重建)"
  else
    echo "⚠️ /etc/rc.d 抓取失败(启用态将回出厂默认)"
  fi
  else
    echo "ℹ️ [selective] 不导入旧 /etc/rc.d 启用态(沿用新版出厂启用状态)"
  fi
  # ---------- 抓取"用户禁用"的服务清单(overlay 白名单不在 tar 可见文件里!) ----------
  # 背景: 禁用服务 = 删 /etc/rc.d 的开机链, 在 overlay upper 留下 whiteout(字符设备 0/0)。
  #   whiteout 不是普通文件, tar 抓不到; 全清刷后 upper 被清空, /rom 下层的出厂链重新可见
  #   -> watchcat/igmpproxy 等会被默默重启(2026-10-08 升级后就复发过, 用户手动补禁用)。
  # 修法: 刷前算出"出厂有链、现网无链、且 init.d 仍在(包未卸=用户主动禁用)"的清单, 写入 kit;
  #   zzz-restore 首启动对每个链 rm -f(重建 whiteout)恢复禁用态。
  # 区分"包被卸"($init.d 不存在): 那种链缺失是包的默认状态, 不能禁(新固件自带该包时应保持出厂启用)。
  # 2026-11-15: 旧清单按 1016 的 /rom/etc/rc.d 链接名(S19firewall 等)生成, 新版编号会变;
  #   selective 改抓"服务名", 首启动用 /etc/init.d/<svc> disable, 与编号解耦。
  if [ "${CONFIG_POLICY:-full}" = "selective" ]; then
    if ssh -o ConnectTimeout=10 "$ROUTER" 'for l in $(ls /rom/etc/rc.d 2>/dev/null); do [ -e "/etc/rc.d/$l" ] && continue; svc=$(printf "%s" "$l" | sed "s/^[SK][0-9][0-9]//"); [ -x "/etc/init.d/$svc" ] && printf "%s\n" "$svc"; done' 2>/dev/null \
         | sort -u > "$build/etc/zzz-disabled-services"; then
      if [ -s "$build/etc/zzz-disabled-services" ]; then
        echo "✅ 已抓取用户禁用服务(服务名, 跨版本安全): $(tr '\n' ' ' < "$build/etc/zzz-disabled-services")"
      else
        rm -f "$build/etc/zzz-disabled-services"
        echo "ℹ️ 无用户禁用服务"
      fi
    else
      rm -f "$build/etc/zzz-disabled-services"
      echo "⚠️ 禁用服务清单抓取失败(不影响升级)"
    fi
  else
  if ssh -o ConnectTimeout=10 "$ROUTER" 'for l in $(ls /rom/etc/rc.d 2>/dev/null); do [ -e "/etc/rc.d/$l" ] && continue; svc=$(printf "%s" "$l" | sed "s/^[SK][0-9][0-9]//"); [ -x "/etc/init.d/$svc" ] && printf "%s\n" "$l"; done' 2>/dev/null > "$build/etc/zzz-disabled-services"; then
    if [ -s "$build/etc/zzz-disabled-services" ]; then
      echo "✅ 已抓取用户禁用服务清单: $(tr '\n' ' ' < "$build/etc/zzz-disabled-services")"
    else
      rm -f "$build/etc/zzz-disabled-services"
      echo "ℹ️ 无用户禁用服务(出厂链与现网一致)"
    fi
  else
    rm -f "$build/etc/zzz-disabled-services"
    echo "⚠️ 禁用服务清单抓取失败(全清后禁用态可能回退)"
  fi
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
  # ---------- 2026-11-15: 把配置策略写进 kit, 供首启动自举读取 ----------
  printf '%s\n' "${CONFIG_POLICY:-full}" > "$build/etc/zzz-config-policy"
  if [ "${CONFIG_POLICY:-full}" = "selective" ]; then
    # 生成"升级后需人工重配清单": 只记文件名 + 字节数, 绝不写配置内容/密钥/订阅。
    mkdir -p "$LOG_DIR"
    local todo="$LOG_DIR/config-restore-todo-$(date +%Y%m%d-%H%M%S).md"
    {
      echo "# wipe-config 升级: 配置恢复与人工重配清单"
      echo ""
      echo "- 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "- 目标固件: ${TARGET_COMMIT:-unspecified}"
      echo "- 配置策略: selective (版本感知选择性重建)"
      echo "- 自动恢复(整文件白名单): $SAFE_CONFIGS —— 1115 出厂无同名文件, 不覆盖出厂默认"
      echo "- 自动恢复(键级迁移表): dhcp(dnsmasq/odhcpd/静态租约) / firewall(include 段) / luci(仅语言, 主题降级) / rpcd(homepage 只读用户+系统用户) / watchcat / zerotier / uhttpd / smartdns"
      echo "- 自动恢复(程序离线, 零联网): OpenClash + $OFFLINE_SERVICES"
      echo "- 自动恢复(身份): root 密码 / SSH 公钥+host key / WiFi SSID+key / LAN IP / DHCP 静态租约 / crontab+自定义脚本 / customfeeds.list"
      echo "- 人工核对: 下表标「人工重配/核对」的项; 升级前配置原文快照在刷后 ~/router-upgrade-logs/config-reference-*.tar.gz(权限 600)"
      echo ""
      echo "| /etc/config 文件 | 升级前大小(B) | 处理 |"
      echo "|---|---|---|"
      ssh -o ConnectTimeout=10 "$ROUTER" 'cd /etc/config && for f in *; do [ -f "$f" ] || continue; printf "%s|%s\n" "$f" "$(wc -c < "$f" | tr -d " ")"; done' 2>/dev/null \
        | while IFS='|' read -r _c _sz; do
            case " $SAFE_CONFIGS " in *" $_c "*) _act="自动恢复(白名单)" ;; *) _act="人工重配/核对" ;; esac
            printf '| %s | %s | %s |\n' "$_c" "$_sz" "$_act"
          done
      echo ""
      echo "> 依据: 2026-11-15 解包 1115 出厂镜像, 与本机 50 个 /etc/config 逐文件比对(26 相同 / 9 改写 / 19 仅本机有 / 9 仅出厂有)。"
      echo "> 刷前配置快照: $PREUPG_BACKUP (仅在需要查旧值时解包, 勿整包导入新系统)。"
    } > "$todo" 2>/dev/null || true
    echo "📋 已生成人工重配清单: $todo"
  fi
  # 打包前最后一道 AppleDouble 防线: 清掉抓取/烘焙路径可能残留的 ._*(源头排除 + 本地清理双保险)
  # 2026-11-13: 写入无敏感信息的 kit manifest, 供 verify_kit(final) 绑定目标固件、核验重建状态。
  # 只记 commit / 内核 / 文件 sha256, 绝不写 root shadow / WiFi key / 订阅 / SSID / MAC。
  {
    echo "kit_schema=3"
    echo "built_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "config_policy=${CONFIG_POLICY:-full}"
    echo "config_scope=${CONFIG_POLICY:+$(if [ "${CONFIG_POLICY:-full}" = selective ]; then printf '%s' "identity+openclash+offline-apps+key-migration+crontab+customfeeds"; else printf '%s' "full-/etc/config"; fi)}"
    echo "safe_configs=$SAFE_CONFIGS"
    echo "offline_services=$OFFLINE_SERVICES"
    echo "config_ref=required_for_selective"
    echo "incompatible_configs=$INCOMPATIBLE_CONFIGS"
    echo "target_commit=${TARGET_COMMIT:-unspecified}"
    echo "source_router_commit=${CURRENT_COMMIT:-unspecified}"
    echo "source_kernel=$(ssh -o ConnectTimeout=8 "$ROUTER" 'uname -r' 2>/dev/null | head -1)"
    echo "restore_script_sha256=$(shasum -a 256 "$build/etc/uci-defaults/zzz-restore-router" 2>/dev/null | awk '{print $1}')"
    if [ -f "$build/etc/openclash/core/clash_meta" ]; then
      echo "clash_core_sha256=$(shasum -a 256 "$build/etc/openclash/core/clash_meta" 2>/dev/null | awk '{print $1}')"
    else
      echo "clash_core_sha256=absent"
    fi
    # 目标内核只能从发布说明启发式取, 不作判据, 仅用于跨内核告警
    echo "target_kernel_hint=$(printf '%s' "${OFFICIAL_REL_BODY:-}" | grep -oE '6\.[0-9]+\.[0-9]+' | head -1)"
  } > "$build/etc/kit-manifest"
  find "$build" -name '._*' -type f -delete 2>/dev/null
  tar -czf "$newkit" -C "$build" . || { echo "❌ 重打 kit 失败"; exit 1; }
  KIT="$newkit"
  if [ -n "$s" ]; then echo "✅ 已注入 root hash + WiFi key + 三频 SSID + LAN IP + OpenClash 配置 + 额外配置/定制路径到 kit (无明文存储)"; else echo "⚠️ 已注入 WiFi key/SSID/LAN IP/OpenClash/额外配置, 但 root shadow 抓取失败(升级后仅 key 登录)"; fi
}

resolve_router || die "未配置路由器 SSH 地址 — 请用 --router root@192.168.50.1 (XR1710G 出厂默认) 或 ROUTER 环境变量指定, 或在首次运行时按提示输入"

precheck_executor_location

echo "=== 预检 ==="
echo "ITB : $(basename "$ITB")"
echo "KIT : $(basename "$KIT")"
TARGET_COMMIT=$(basename "$ITB" | grep -oE '[0-9]{6,8}-[0-9a-f]{7,40}' | head -1 | cut -d- -f2)
[ -n "$TARGET_COMMIT" ] && echo "目标版本 commit : $TARGET_COMMIT"
ssh -o ConnectTimeout=8 "$ROUTER" 'echo "路由器可达: $(grep DISTRIB_REVISION /etc/openwrt_release)"' \
  || die "无法 SSH 到路由器 (确认本机已连路由器: WiFi 或有线均可, 且 SSH 地址解析有效; 可用 --router 显式指定或配置 router-target.conf)"

# ---------- 同版本白刷保护(2026-11-04 P0) ----------
# 路由器 DISTRIB_REVISION 的 commit 是 10 位, itb 文件名里是 8 位, 取前 8 位前缀比对。
# 即便自动选片/下载逻辑将来再出岔子, 这一层也能独立挡住"完整全清刷一遍却刷回当前版本"。
CURRENT_COMMIT=$(ssh -o ConnectTimeout=8 "$ROUTER" 'grep DISTRIB_REVISION /etc/openwrt_release 2>/dev/null | grep -oE "[0-9a-f]{7,40}" | tail -1' 2>/dev/null)
if [ -n "$CURRENT_COMMIT" ] && [ -n "$TARGET_COMMIT" ]; then
  _cur8=$(printf '%s' "$CURRENT_COMMIT" | cut -c1-8)
  _tgt8=$(printf '%s' "$TARGET_COMMIT" | cut -c1-8)
  if [ "$_cur8" = "$_tgt8" ]; then
    if [ "$ALLOW_SAME_VERSION" = "1" ]; then
      echo "⚠️ 目标版本($_tgt8) == 当前运行版本, 已由 --allow-same-version 显式放行(仅重刷配置/修复时用)"
    elif [ "$DRY" = "1" ]; then
      echo "🛑 [dry-run] 目标版本($_tgt8) == 当前运行版本 —— 真实执行时本脚本会拒绝(白刷: 断网+还原+重装, 收益为零, 风险全担)"
    else
      die "🛑 目标版本($_tgt8) 与路由器当前运行版本相同, 拒绝全清刷(收益为零却要承担断网/还原/变砖风险)。若确需重刷同版本, 显式加 --allow-same-version。"
    fi
  else
    echo "✅ 版本递增校验: 当前 $_cur8 → 目标 $_tgt8 (不同, 非白刷)"
  fi
fi

# 载入 U-Boot 兜底状态档案(恢复页地址/触发方式/最近实测), 供重连候选与提示使用
uboot_state_load

# 11-03 卡死事件的流程化缓解: 近期异常硬复位未过 48h 观察窗时拒绝刷机
precheck_recent_crash

# 2026-11-13 新增两道刷前闸: T2 兜底实测核验 + kit 有效性(陈旧 kit 会静默丢配置)
verify_t2_fallback
verify_kit pre

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

# 固件级回退点: 确保当前运行版本 itb 本地存在(缺失则 best-effort 下载), 与配置级备份互补(P2)
ensure_rollback_itb

if [ "$DRY" = "1" ]; then
  echo "=== DRY-RUN: 不执行升级 ==="
  echo "将执行的步骤:"
  echo "  0. 升级前配置快照 sysupgrade -b -> backups/ ; 配置策略=${CONFIG_POLICY:-full}"
  echo "     full: 全量 /etc/config 保真 + 额外配置 + 定制路径; selective: 身份数据 + 10 个白名单第三方配置 + 9 个 DIFF 键级迁移 + 离线程序包(OpenClash/dawn/pushbot/tailscale/wifihistory) + crontab/脚本/customfeeds.list"
  echo "  1. scp $(basename "$ITB") $(basename "$KIT") -> $ROUTER:/tmp/"
  echo "  1b. 路由器侧复核 itb sha256 (防止 WiFi 上传损坏)"
  echo "  2. ssh $ROUTER 'sysupgrade -F -n -f /tmp/$(basename "$KIT") /tmp/$(basename "$ITB")' (F=跳过设备名校验[见下], n=不保留当前配置, 严格全清)"
  echo "     (nohup 后台执行, 路由器重启, SSH 断开, 本脚本随后轮询重连)"
  echo "  3. 轮询重连 (每 5s, 最多 80 次) 于路由器地址 / 出厂默认 192.168.50.1 等候选 IP"
  echo "  4. 终验: 版本 / flow offload / 三频 / OpenClash / DNS / U-Boot; 报告含 T2 刷前基线 vs 刷后实测"
  echo "     (host key 将在刷前从活路由抓取并随 kit 还原, 成功则其他终端无需更新 known_hosts; 失败则降级为 accept-new)"
  echo "=== DRY-RUN 结束 ==="
  exit 0
fi

# 升级前: 配置快照(配置级回退点) + 抓取当前运行态注入 kit (dry-run 不执行)
backup_config
collect_runtime

# 注入后的临时 kit 才是真正要刷进去的东西 —— 再核验一次(含 manifest 是否绑定本次目标固件)
verify_kit final || die "kit 最终核验失败"

echo "=== 上传固件与 kit ==="
# ---------- 2026-11-15 (二): 刷前 overlay 可用空间预检 ----------
# 离线注入 tailscale(30MB)+tailscaled(39MB)+clash_meta(55MB) 后, sysupgrade -f 的
# CONF_IMAGE 归档解压到 /overlay 约需 130MB+; 该设备 overlay 仅 335MB(实测可用 256MB)。
# 空间不足会在写 UBI 中途失败 = 半写变砖, 必须在上传前 fail-closed 拦住。
_avail_kb=$(ssh -o ConnectTimeout=10 "$ROUTER" 'df -k /overlay 2>/dev/null | tail -1 | awk "{print \$4}"' 2>/dev/null | tr -d ' \n')
_kit_kb=$(( $(stat -f%z "$KIT" 2>/dev/null || echo 0) / 1024 ))
_est_kb=$(( _kit_kb * 3 + 20480 ))
echo "刷前空间预检: /overlay 可用 ${_avail_kb:-?}KB, kit ${_kit_kb}KB, 估算解压需求 ${_est_kb}KB"
if [ -n "$_avail_kb" ] && [ "$_avail_kb" -lt "$_est_kb" ]; then
  die "🛑 /overlay 可用空间不足(需约 ${_est_kb}KB, 实得 ${_avail_kb}KB)。离线程序包无法完整还原, 请清理 overlay 或改用不含离线 tailscale 的精简 kit。"
fi
echo "✅ /overlay 空间充足"
scp "$ITB" "$KIT" "$ROUTER:/tmp/" || die "上传失败"

# 刷机前在路由器侧复核 itb 完整性: WiFi 上传若抖动传坏会直接刷入损坏镜像(变砖), 先拦截
ACT_SHA=$(ssh -o ConnectTimeout=10 "$ROUTER" "sha256sum /tmp/$(basename "$ITB")" 2>/dev/null | awk '{print $1}')
[ -n "$ACT_SHA" ] || die "无法在路由器侧计算 itb sha256 (上传可能不完整)"

# EXPECT_SHA 优先级: --expect-sha 显式 > 官方最新 asset digest > 按文件名查历史 asset digest > 官方 sha256sums > 空
# 2026-11-04 P1 修复: 1029 release 未附 sha256sums 文件(实测只有 1 个 itb 资产), 但 GitHub API
#   的 asset.digest 就是同一种官方 sha256 基准(sha256:a5a2...)。用它补齐, 不再迫使人工
#   --expect-sha 或顺手加 --force(旧版 --force 会连带关掉完整性校验, 极危险)。
#   显式 --itb 指定历史版本时, 按文件名遍历所有 release 找该 asset 的 digest, 保证校验路径不断裂。
derive_expect_sha(){
  local bn jqf d sums_url h
  bn=$(basename "$ITB")
  if [ -n "$OFFICIAL_ITB_NAME" ] && [ "$bn" = "$OFFICIAL_ITB_NAME" ] && [ -n "$OFFICIAL_ITB_SHA" ]; then
    printf '%s' "$OFFICIAL_ITB_SHA"; return 0
  fi
  command -v gh >/dev/null 2>&1 || { echo "  (无 gh CLI, 无官方基准)" >&2; return 1; }
  # 文件名仅含 [A-Za-z0-9._-], 可直接嵌入 jq 字符串
  jqf=$(printf '[.[] | .assets[] | select(.name == "%s") | (.digest // "NONE")] | .[0] // "NONE"' "$bn")
  d=$(gh api "repos/$REPO/releases?per_page=100" --jq "$jqf" 2>/dev/null | head -1)
  if [ -n "$d" ] && [ "$d" != "NONE" ]; then
    printf '%s' "${d#sha256:}"; return 0
  fi
  sums_url=$(gh api "repos/$REPO/releases?per_page=100" --jq '[.[] | select(any(.assets[]; .name|test("gemtek_xr1710g")))] | sort_by(.published_at) | reverse | .[0].assets[] | select(.name=="sha256sums") | .browser_download_url' 2>/dev/null | head -1)
  [ -n "$sums_url" ] || { echo "  (未找到官方 sha256sums, 且该 ITB 无 asset digest)" >&2; return 1; }
  h=$(curl -fsSL "$sums_url" 2>/dev/null | grep -F "$bn" | awk '{print $1}' | head -1)
  [ -n "$h" ] && { printf '%s' "$h"; return 0; }
  return 1
}
if [ -z "$EXPECT_SHA" ]; then
  EXPECT_SHA=$(derive_expect_sha)
fi
# 2026-11-04 P1 修复: --force 不再能关闭完整性校验。
#   (a) 有官方基准但不匹配 => 任何参数都不放行(传坏了就是传坏了, 没有理由刷进去);
#   (b) 完全拿不到基准     => 仅 --allow-unverified-sha 显式放行;
#   (c) 匹配              => 通过。
if [ -n "$EXPECT_SHA" ] && [ "$ACT_SHA" = "$EXPECT_SHA" ]; then
  echo "✅ itb 完整性校验通过 (sha256 匹配官方基准: $EXPECT_SHA)"
elif [ -n "$EXPECT_SHA" ]; then
  die "itb sha256 校验未通过 (官方基准 $EXPECT_SHA, 实得 $ACT_SHA) — 上传/下载可能损坏或被篡改, 已中止。此错误不可被 --force 跳过, 请重新上传镜像。"
elif [ "$ALLOW_UNVERIFIED_SHA" = "1" ]; then
  echo "⚠️ 无任何官方 sha256 基准, 已由 --allow-unverified-sha 显式放行(自担风险); 路由器侧实得 $ACT_SHA"
else
  die "无法获取 itb 的官方 sha256 基准(该 release 无 sha256sums 且 GitHub asset digest 不可用)。请用 --expect-sha <官方哈希> 提供基准, 或 --allow-unverified-sha 显式自担风险。"
fi

# ---------- 设备名兼容性预检(防 -F 误用于异构镜像) ----------
# 背景: 本家族 naoki66 构建在 1016 把板名 gemtek,xr1710g-ubi 改名为 gemtek,xr1710g(仅元数据改名,
#   实际 UBI 布局/硬件/启动机制与现网完全一致, 已比对两 itb 的 ubi-volume 结构确认)。故用 -F 跳过
#   设备名校验。但 -F 是双刃剑: 若误指向真正异构镜像(如 XG2010G)会直接变砖。
#   此处用归一化(去 -ubi 后缀)比对运行板名与 itb 支持设备, 仅当差异仅为 -ubi 后缀时才允许 -F;
#   否则中止, 把"异构镜像"风险挡在刷写之前。提取失败(字符串解析未命中)则放行(信任上方 sha256 完整性)。
RUNNING_BOARD=$(ssh -o ConnectTimeout=10 "$ROUTER" 'cat /tmp/sysinfo/board_name 2>/dev/null' 2>/dev/null)
NB_RUNNING=${RUNNING_BOARD%-ubi}
ITB_DEV=$(ssh -o ConnectTimeout=10 "$ROUTER" "strings /tmp/$(basename "$ITB") 2>/dev/null | grep -oE '${NB_RUNNING}[-a-z]*' | head -1" 2>/dev/null)
if [ -n "$ITB_DEV" ]; then
  NB_ITB=${ITB_DEV%-ubi}
  if [ "$NB_RUNNING" = "$NB_ITB" ]; then
    echo "✅ 设备名兼容 ($RUNNING_BOARD ↔ $ITB_DEV, 仅 -ubi 后缀差异, -F 安全)"
  else
    die "设备名不兼容: 运行板 $RUNNING_BOARD, itb 支持 $ITB_DEV —— 拒绝 -F 强刷(疑似异构镜像, 强刷会变砖)"
  fi
else
  echo "⚠️ 无法从 itb 提取设备名(字符串解析未命中), 信任 sha256 完整性, 继续 -F"
fi

echo "=== 触发干净刷 (严格全清 -n + uci-defaults 自举) ==="
echo "⚠️ 路由器即将重启, SSH 会断开, 本脚本自动轮询重连, 无需人工介入"
# nohup + & 让 sysupgrade 在路由后台跑, ssh 立即返回, 避免连接在 reboot 时被重置误判
# ⚠️ -F (force): 跳过设备名兼容性校验。背景(2026-10-28 实战): naoki66 的 1016 构建把板名从
#   gemtek,xr1710g-ubi 改名为 gemtek,xr1710g(仅元数据改名, 实际 UBI 布局/硬件/启动机制与现网
#   完全一致 —— 已比对两 itb 的 ubi-volume 结构确认), 导致 sysupgrade 默认设备校验失败、拒绝刷入。
#   加 -F 是此设备家族跨版本升级的标准解法; 完整性已由上方 sha256 校验把关, 风险可控。
#   (注意: 仅在已确认镜像确为本设备 UBI 布局时方可 -F, 勿用于真正异构镜像)
ssh "$ROUTER" "nohup sysupgrade -F -n -f /tmp/$(basename "$KIT") /tmp/$(basename "$ITB") >/tmp/upg.log 2>&1 &" || true

# host key 若已随 kit 保留(升级前从活路由抓取并 sysupgrade -f 还原), 则密钥不变 -> 不清除本机 known_hosts, 其他终端零感知;
# 仅当未成功保留时才清本地旧 key 并提示各终端更新(降级路径)
if [ "$HOSTKEY_PRESERVED" = "1" ]; then
  echo "✅ SSH host key 已随 kit 保留, 本机 known_hosts 无需清理, 其他终端亦可照常连接"
else
  ssh-keygen -R "$R_HOST" 2>/dev/null; ssh-keygen -R "$ROUTER" 2>/dev/null
  echo "⚠️ host key 未保留(已变更), 其他终端需执行: ssh-keygen -R $R_HOST ; ssh-keygen -R $ROUTER"
fi
echo "=== 等待路由器重启(先确认断开, 再等重连, 避免刷写 race 误判) ==="
DOWN=0
for i in $(seq 1 12); do
  if ! ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'true' 2>/dev/null; then
    echo "✅ 第 $i 次探测: 路由器已断开(正在重启)"; DOWN=1; break
  fi
  sleep 5
done
[ "$DOWN" = "1" ] || echo "⚠️ 12 次探测内未检测到断开 — 可能 sysupgrade 未触发重启, 继续尝试重连并终验"
echo "=== 轮询重连 (每 5s, 最多 80 次 = 400s) ==="
OK=0
for i in $(seq 1 80); do
  # 先判断执行机自身链路是否健康: 若执行机自己都上不了网, "连不上路由"可能是执行机问题, 不应急于判定路由故障(P0)
  if ! executor_online; then
    echo "⚠️ 第 $i 轮: 执行机自身外网不可达(可能经路由上网, 重启导致断网), 继续等待链路恢复..."
    sleep 5; continue
  fi
  # 试用户配置的地址(别名或 IP), 再退到常见出厂默认 IP (首启动自举可能重置为出厂态)
  tried="$ROUTER"
  # XR1710G 出厂默认 192.168.50.1(官方 README 首次启动表); 192.168.1.1 属 XG2010G/Nokia。
  # 恢复页候选: 旧 chainloader 血脉 = 192.168.255.1, 11-11 新版 = 192.168.0.1;
  #   2026-11-16 补 192.168.255.1 —— 原候选表漏了当前血脉的恢复页, 一旦刷完变砖
  #   (或首启动自举失败落到 Recovery), 重连循环里根本没有当前恢复页地址, 只能干等超时。
  #   另从状态档案读入实测的恢复页地址(刷过 U-Boot 后地址会变, 只能靠档案)。
  _recov_cands=""
  [ -n "$UBOOT_STATE_RECOVERY_IP" ] && _recov_cands="$UBOOT_STATE_RECOVERY_IP "
  for ip in 192.168.50.1 192.168.1.1 192.168.255.1 192.168.0.1 10.0.0.1; do tried="$tried root@$ip"; done
  for ip in $_recov_cands; do tried="$tried root@$ip"; done
  for target in $tried; do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$target" 'true' 2>/dev/null; then
      echo "✅ 第 $i 轮经 $target 重连成功"; ROUTER="$target"; OK=1; break 2
    fi
  done
  sleep 5
done
if [ "$OK" != "1" ]; then
  echo "❌ 重连失败 — 可能进入 Recovery 或执行机链路仍异常"
  echo "   诊断: 执行机出口 IP=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null || echo '?'); 路由器=$ROUTER"
  echo "   若执行机本就不经此路由上网, 请确认有线已直连路由器 LAN 口; U-Boot 兜底已就位, 可访问 HTTP Recovery 重刷"
  uboot_state_load
  _recov="${UBOOT_STATE_RECOVERY_IP:-192.168.255.1}"
  echo "   HTTP Recovery 入口: ${UBOOT_STATE_TRIGGER:-上电后按住 reset 键, LED 变色松手}"
  echo "   恢复页地址: http://$_recov/  (来源: $([ -n "$UBOOT_STATE_RECOVERY_IP" ] && echo 状态档案 || echo 推定默认))"
  echo "   当前 U-Boot 血脉: ${UBOOT_STATE_VERSION_STR:-?}"
  echo "   提示: 恢复页仅在路由器进入 Recovery 时才响应; 若路由器已正常启动, 请走人工排查"
  die "重连失败, 需人工介入"
fi

echo "=== 终验 (在路由器上, accept-new 接受全清后的新 host key) ==="
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" '
set -x
echo "--- 版本(期望 '"$TARGET_COMMIT"') ---"; rev=$(grep DISTRIB_REVISION /etc/openwrt_release); echo "$rev"; echo "$rev" | grep -q "'"$TARGET_COMMIT"'" && echo "✅ 版本已更新为新固件" || echo "❌ 版本未变(仍运行旧固件!)"
echo "--- flow offload 计数 ---"; nft list counters 2>/dev/null | grep -iE "OFFLOAD|HW_OFFLOAD" | head
echo "--- 三频 disabled 状态 ---"; uci show wireless | grep -E "radio[0-9]\.disabled"
echo "--- OpenClash 进程 ---"; pgrep -f clash >/dev/null && echo "clash 运行中" || echo "clash 未运行"
echo "--- OpenClash 安装日志尾部 ---"; tail -5 /tmp/zzz-postinstall.log 2>/dev/null
echo "--- OpenClash DNS 解析 (foreign) ---"; nslookup github.com 127.0.0.1 2>/dev/null | awk "/Address: /{print \$2}" | grep -v "#53" | tail -1
echo "--- dnsmasq 是否指向 OpenClash ---"; uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null; uci get dhcp.@dnsmasq[0].server 2>/dev/null
echo "--- U-Boot 兜底 (逐卷读活跃 UBI 卷 ubootenv/ubootenv2, fw_printenv 仅作参考) ---"; for v in /dev/ubi0_1 /dev/ubi0_2; do echo "  [$v]"; cat "$v" 2>/dev/null | strings | grep -E "^bootcmd=|^recovery_mtd=|^boot_ubi=" | sort -u; done; echo "  [fw_printenv 参考]"; fw_printenv bootcmd recovery_mtd boot_ubi 2>/dev/null
echo "--- 首启动自举日志尾部 ---"; tail -5 /tmp/zzz-restore.log 2>/dev/null
'
echo "=== 升级流程结束 ==="
archive_logs
post_upgrade_report
echo "若终验全部通过, 升级成功。若 OpenClash 仍未起(rc.local 未跑完), 在 Mac 侧执行:"
echo "  ssh \"$ROUTER\" 'apk add luci-app-openclash && /etc/init.d/openclash restart'"
echo "升级后请改 root 密码: ssh \"$ROUTER\" 'passwd root'"
if [ "$HOSTKEY_PRESERVED" = "1" ]; then
  echo "✅ SSH host key 已随 kit 还原, host key 不变 —— 所有终端(含其他设备)的 known_hosts 仍有效, 无需 ssh-keygen -R"
else
  echo "⚠️ SSH host key 未保留(已变更), 各终端需执行: ssh-keygen -R <路由器IP/别名> 后重新连接"
fi

# ---------- 强终验 (仅 --auto 模式: 判定成败并触发回退) ----------
# 判定: 外网通 + 代理DNS通(clash@7874) + radio0/1 启用 + clash 进程在 → 成功
# 返回: 0=成功; 1=连上但终验不通过(真失败, 可回退); 2=连不上路由器(执行机/路由不可达, 不触发回退)
verify_router(){
  if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'true' 2>/dev/null; then
    echo "WARN: 连不上路由器, 跳过终验(不触发回退以免误改状态)"; return 2
  fi
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" '
    rev=$(grep DISTRIB_REVISION /etc/openwrt_release 2>/dev/null | grep -oE "[0-9a-f]{7,40}" | tail -1)
    # 关键防御: 版本读不到(早启动/连接抖动/文件瞬时不可读)一律归为"无法判定", 返回2 不回退;
    # 只有"读到了但确实不是目标"才判 FAIL(返回1). 杜绝检测失败触发破坏性回退.
    if [ -z "$rev" ]; then echo "WARN: 无法读取当前固件版本(可能为早启动/连接抖动), 不判定失败以免误回退"; exit 2; fi
    echo "$rev" | grep -q "'"$TARGET_COMMIT"'" || { echo "FAIL: 固件版本未变更 (期望 '"$TARGET_COMMIT"', 实得 $rev)"; exit 1; }
    # 硬终验: 外网直连(不依赖 OpenClash 7874) — 用国内可直连站点验证
    curl -fsS --max-time 6 https://www.baidu.com >/dev/null 2>&1 || ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 || { echo "FAIL: 外网不通"; exit 1; }
    for r in radio0 radio1; do
      [ "$(uci get wireless.$r.disabled 2>/dev/null)" = "1" ] && { echo "FAIL: $r 被禁用"; exit 1; }
    done
    # 2026-11-15: wipe-config 版本专属硬终验 —— 防"配置在/程序不在"与"补丁谎报成功"
    if [ -f /etc/config/openclash ] && [ ! -x /etc/init.d/openclash ]; then
      echo "FAIL: OpenClash 配置已恢复但程序文件缺失(离线程序包未生效)"
      exit 1
    fi
    if [ -f /etc/zzz-wifi-pending ]; then
      echo "FAIL: 无线身份补丁(SSID/key)未在首启动或 rc.local 完成"
      exit 1
    fi
    # 软终验(可选): 仅当用户真正启用 OpenClash 时才查(P1). 注意: 本路由 OpenClash 实为上网网关(fake-ip+TCP重定向+DNS 7874),
    # 一旦"启用但 0 真实节点"用户会静默断网(进程在/7874在/DNS通, 但出不去) —— 必须暴露, 不能误判成功.
    if pgrep -f clash >/dev/null 2>&1 || [ "$(uci get openclash.config.enabled 2>/dev/null)" = "1" ]; then
      # P1: 内核二进制必须存在且可执行, 否则"内核丢了却误判成功" —— 直接判 FAIL 暴露问题
      if [ ! -x /etc/openclash/core/clash_meta ]; then
        echo "FAIL: OpenClash 已启用但内核 clash_meta 缺失/不可执行 (全清刷内核丢失?)"
        exit 1
      fi
      nslookup github.com 127.0.0.1 >/dev/null 2>&1 || { echo "FAIL: 代理DNS不通(已启用OpenClash)"; exit 1; }
      # ★ 真实节点健康检查: 控制器 secret 在 clash 实际加载的配置文件(-f 参数所指), 而非生成的 /etc/openclash/config.yaml
      REAL_NODES=0
      for _i in 1 2 3 4; do
        OC_CFG=$(ps w | grep "[c]lash" | grep -oE "\-f [^ ]+" | awk "{print \$2}")
        [ -z "$OC_CFG" ] && OC_CFG=/etc/openclash/config.yaml
        SEC=$(grep -m1 "secret:" "$OC_CFG" 2>/dev/null | sed -E "s/.*secret:[ ]*[\"]?([A-Za-z0-9_]+)[\"]?.*/\1/")
        # 2026-11-16 P0 修复: 合并 /proxies 与 /providers/proxies 两个来源。
        #   机场订阅多为 provider 模式, 节点全在 /providers/proxies; 只查顶层会误判
        #   0 节点, 而本路由 OpenClash 正是 DNS 网关(fake-ip + 7874) -> 误判 FAIL
        #   -> --auto 误触发整机回退(最坏情况: 好端端的路由器被回退成旧版)。
        REAL_NODES=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/proxies" 2>/dev/null | grep -oE "\"type\":\"(Vless|Vmess|Trojan|Hysteria2|Hysteria|Shadowsocks|ShadowsocksR|Tuic|WireGuard|Snell)\"" | wc -l | tr -d " ")
        PROV_NODES=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/providers/proxies" 2>/dev/null | grep -oE "\"type\":\"(Vless|Vmess|Trojan|Hysteria2|Hysteria|Shadowsocks|ShadowsocksR|Tuic|WireGuard|Snell)\"" | wc -l | tr -d " ")
        [ "${PROV_NODES:-0}" -gt "${REAL_NODES:-0}" ] 2>/dev/null && REAL_NODES="$PROV_NODES"
        [ "$REAL_NODES" -gt 0 ] && break
        sleep 5
      done
      if [ "$REAL_NODES" -eq 0 ]; then
        # 仅当 OpenClash 真正接管 DNS(网关)时, 0 节点 = 用户无可用外网 = 升级失败; 否则仅告警
        DNS_VIA_OC=$(uci get dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "7874" && echo 1 || echo 0)
        if [ "$DNS_VIA_OC" = "1" ]; then
          echo "FAIL: OpenClash 是 DNS 网关但控制器查到 0 个真实节点(订阅未加载/节点全失效?) -> 用户实际无可用外网"
          exit 1
        else
          echo "WARN: OpenClash 启用但 0 真实节点(非 DNS 网关, 仅告警不判失败)"
        fi
      else
        echo "  OpenClash 真实节点: $REAL_NODES 个 (正在承载上网)"
      fi
    fi
    exit 0
  ' 2>/dev/null
}

# 回退后终验(2026-11-02 修复 #3): 回退是把固件刷回旧版, 再用 verify_router(拿新 commit 比对)必然判 FAIL 误报。
# 故独立判据: 已回到"非目标新版本"(即确实回退了) + 外网直连通 + 三频启用。不再与新 commit 比对。
verify_rollback(){
  if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'true' 2>/dev/null; then
    echo "WARN: 回退后连不上路由器"; return 2
  fi
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" '
    rev=$(grep DISTRIB_REVISION /etc/openwrt_release 2>/dev/null | grep -oE "[0-9a-f]{7,40}" | tail -1)
    [ -z "$rev" ] && { echo "WARN: 回退后无法读取版本(可能早启动/抖动)"; exit 2; }
    echo "回退后版本: $rev"
    if echo "$rev" | grep -q "'"$TARGET_COMMIT"'"; then echo "FAIL: 仍运行目标新版本, 回退可能未生效"; exit 1; fi
    curl -fsS --max-time 6 https://www.baidu.com >/dev/null 2>&1 || ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 || { echo "FAIL: 回退后外网不通"; exit 1; }
    for r in radio0 radio1; do
      [ "$(uci get wireless.$r.disabled 2>/dev/null)" = "1" ] && { echo "FAIL: 回退后 $r 被禁用"; exit 1; }
    done
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
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" "nohup $rbcmd >/tmp/rb.log 2>&1 &" || true
  # 回退保留当前 config(sysupgrade -F 不带 -n), host key 不变 -> 仅当本次升级未保留 key 时才清本地 known_hosts
  if [ "$HOSTKEY_PRESERVED" != "1" ]; then
    ssh-keygen -R "$R_HOST" 2>/dev/null; ssh-keygen -R "$ROUTER" 2>/dev/null
  fi
  for i in $(seq 1 80); do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" 'true' 2>/dev/null; then break; fi
    sleep 5
  done
  # DNS 兜底(P1): 回退还原旧配置可能含 7874 死端口, 若 OpenClash 未监听则回退公共DNS
  # 2026-11-16 P0 修复(两处真 bug, 均已实机复现):
  #   (a) 原代码 `! nc -z -w2 ...` —— BusyBox 的 nc 不支持 -z 选项(实机实测:
  #       `nc -z -w2 127.0.0.1 22` 打印用法并返回 rc=1), 取反后条件**恒为真**,
  #       于是每次回退都无条件把 dnsmasq 改成公共 DNS, 把 OpenClash 的网关配置破坏掉。
  #       改为用 netstat/ss 真实判断该端口是否处于 LISTEN。
  #   (b) 原端口提取 `grep -oE "[0-9]+" | head -1` 从 "127.0.0.1#7874" 里取到的是
  #       "127"(IP 的第一段)而不是 7874, 即探测了一个完全无关的端口。改为按 #PORT 取。
  ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER" '
    up=$(uci get dhcp.@dnsmasq[0].server 2>/dev/null)
    if echo "$up" | grep -q "127.0.0.1"; then
      p=$(echo "$up" | grep -oE "127\.0\.0\.1#([0-9]+)" | head -1 | cut -d"#" -f2)
      [ -z "$p" ] && p=53
      listening=0
      if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -qE "[:.]${p}$" && listening=1
      fi
      if [ "$listening" = "0" ] && command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -qE "[:.]${p}([[:space:]]|$)" && listening=1
      fi
      if [ "$listening" = "0" ]; then
        uci del dhcp.@dnsmasq[0].noresolv 2>/dev/null
        uci del dhcp.@dnsmasq[0].server 2>/dev/null
        uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
        uci add_list dhcp.@dnsmasq[0].server="8.8.8.8"
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        echo "DNS 兜底: 127.0.0.1:${p} 未监听, 已回退公共 DNS"
      else
        echo "DNS 兜底: 127.0.0.1:${p} 正在监听, 保留 OpenClash 网关配置(不改 DNS)"
      fi
    fi
  ' 2>/dev/null || true
  if verify_rollback; then
    echo "✅ 回退后终验通过(已恢复到非目标旧版本, 外网+三频正常)"; notify "路由器已自动回退" "旧固件+旧配置已恢复, 终验通过"
  else
    echo "❌ 回退后仍终验失败, 需手动进 U-Boot Recovery"
    notify "路由器升级回退失败" "回退后仍终验失败, 需手动进 U-Boot Recovery"
  fi
  archive_logs
  post_upgrade_report
}

# 清理过期的升级前配置快照(2026-11-02 修复 #5): backups/ 仅本机配置级回退点, 保留最近 10 份即可, 避免无限堆积
prune_old_backups(){
  local n f d
  d="$PREP_DIR/backups"; [ -d "$d" ] || return 0
  n=0
  for f in $(ls -t "$d"/pre-upg-*.tar.gz 2>/dev/null); do
    n=$((n+1))
    if [ "$n" -gt 10 ]; then echo "🧹 清理旧配置快照: $(basename "$f")"; rm -f "$f"; fi
  done
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
  # 2026-11-02 修复 #4: 原逻辑在首次 verify 返回 RC=1(连上但终验失败)即 break 并触发回退,
  #   但首启动 rc.local(apk 装 OpenClash + 还原订阅)可能尚未跑完 -> 0 节点误判 -> 不必要回退。
  #   现改为: RC=0 立即成功; RC=2(连不上)持续重试; RC=1(终验失败)也重试(10s 间隔, 给首启动留足时间),
  #   连续 12 次仍失败才回退, 避免慢首启动被误判炸机。
  RC=2
  for _att in $(seq 1 12); do
    verify_router; RC=$?
    if [ "$RC" = "0" ]; then break; fi
    if [ "$RC" = "2" ]; then
      echo "⚠️ 第 $_att/12 次强终验连不上路由器(RC=2), 10s 后重试..."
    else
      echo "⚠️ 第 $_att/12 次强终验未通过(RC=1), 首启动可能未就绪, 10s 后重试..."
    fi
    sleep 10
  done
  if [ "$RC" = "0" ]; then
    echo "✅ 强终验通过: 固件版本/外网直连/三频 均正常, 升级成功"
    prune_old_itbs
    prune_old_backups
    notify "路由器升级成功" "固件已更新, 强终验通过"
  elif [ "$RC" = "2" ]; then
    echo "⚠️ 12 次重试后仍连不上路由器, 不触发自动回退(避免误改状态), 需人工确认后手动处理"
    notify "路由器升级终验中断" "连不上路由器, 未自动回退, 需人工确认"
  else
    echo "❌ 强终验持续未通过(连上但终验失败), 执行自动回退"
    auto_rollback
  fi
fi
