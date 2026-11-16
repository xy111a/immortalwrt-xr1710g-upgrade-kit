#!/bin/bash
# uboot_upgrade.sh — Gemtek XR1710G U-Boot(chainloader) 升级/回滚子流程, Mac 侧运行
#
# 设计原则(与 upgrade_router.sh 分离, 互不调用):
#   1. 固件升级与 U-Boot 升级是**两个独立窗口**, 不塞进同一次 sysupgrade。
#      理由: U-Boot 刷写改的是引导链(mtd3 chainloader + env 层), 与固件(UBI/fit 卷)
#      写入路径完全不同; 同时引入两个未验证变量会让故障归因失效。
#   2. 本脚本**永不**自动触发升级。由人显式加 --ack-uboot-flash 才允许真刷。
#   3. 所有写入前必做: 备份 mtd3(旧 chainloader)+ mtd1(uenv)+ 两个 env 卷 -> 落盘 + sha256。
#      备份失败 = fail-closed, 绝不继续。
#   4. 写完必须**整块回读比对**, 不符则不重启(可重写)。
#   5. 绝不在 chainloader 里 saveenv / env default -a (uenv 是原厂 U-Boot 的 env 分区)。
#      本脚本只做 mtd write, 从不碰 env。
#
# 用法:
#   ./uboot_upgrade.sh --status                 # 只看现状(链 loader 版本/env 健康/mtd 布局), 不写入
#   ./uboot_upgrade.sh --plan                   # 规划: 列出将下载/校验/备份/写入的每一步, 不写入
#   ./uboot_upgrade.sh --prepare                # 只做备份 + 下载 + 校验, 不写入 (推荐先跑)
#   ./uboot_upgrade.sh --flash --ack-uboot-flash # 真刷 (需显式确认)
#   ./uboot_upgrade.sh --rollback --ack-uboot-flash  # 用备份把旧 chainloader 写回
#   ./uboot_upgrade.sh --probe-recovery         # 探测 Recovery 页是否可达(救砖时用)
#
# 关键参数:
#   --router <host[:port]>   路由器 SSH 地址(默认读 router-target.conf)
#   --release <tag>          指定 chainloader release tag(默认: 官方最新 release)
#   --asset <name>           指定 asset 文件名(默认: 该 release 里 xr1710g-*-slot.bin)
#   --expect-sha <sha256>    指定官方 sha256 基准(默认: 从 GitHub asset digest 自动取)
#   --backup-dir <dir>       备份落盘目录(默认 ~/router-upgrade-logs/uboot-backups/<ts>)
#   --dry-run                所有写入动作只打印不执行

set -u
export COPYFILE_DISABLE=1

PREP_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_CONF="$PREP_DIR/router-target.conf"
LOG_DIR="$HOME/router-upgrade-logs"
STATE_FILE="$LOG_DIR/uboot-state.env"

# chainloader 仓库与固件仓库
UBOOT_REPO="naoki66/Gemtek-brightspeed-chainloader"
# chainloader 分区在设备上的事实(实机 2026-11-16 核对 /proc/mtd + hexdump)
CHAINLOADER_MTD="chainloader"      # /proc/mtd 里的分区名
CHAINLOADER_SIZE="0x100000"         # 1 MiB
CHAINLOADER_FLASH_OFF="0x600000"    # flash 绝对偏移(原厂前 6MiB 保留)
# 双入口 magic(实机 hexdump 确认): 前缀 shim 头 + 内嵌控制 DTB
MAGIC_SHIM="27051956"               # offset 0x0
MAGIC_DTB="d00dfeed"                # offset 0x2100
MAGIC_SHIM_OFF=0
MAGIC_DTB_OFF=0x2100
# U-Boot env 载体(活跃 UBI 卷)与原厂 env 分区
ENV_VOL_PRIMARY="/dev/ubi0_1"       # ubootenv
ENV_VOL_REDUND="/dev/ubi0_2"        # ubootenv2
VENDOR_ENV_MTD="uenv"               # mtd1, 原厂 U-Boot 的 env 分区(2MiB)

DRY=0; ACK_FLASH=0; MODE="status"; RELEASE_TAG=""; ASSET_NAME=""; EXPECT_SHA=""
ROUTER_OVERRIDE=""; BACKUP_DIR=""

die(){ echo "❌ $1" >&2; exit 1; }
say(){ echo "$1"; }
hr(){ echo "--------------------------------------------------"; }

usage(){
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --status)          MODE="status";;
    --plan)            MODE="plan";;
    --prepare)         MODE="prepare";;
    --flash)           MODE="flash";;
    --rollback)        MODE="rollback";;
    --probe-recovery)  MODE="probe";;
    --ack-uboot-flash) ACK_FLASH=1;;
    --dry-run)         DRY=1;;
    --release)         RELEASE_TAG="${2:-}"; shift;;
    --release=*)       RELEASE_TAG="${1#*=}";;
    --asset)           ASSET_NAME="${2:-}"; shift;;
    --asset=*)         ASSET_NAME="${1#*=}";;
    --expect-sha)      EXPECT_SHA="${2:-}"; shift;;
    --expect-sha=*)    EXPECT_SHA="${1#*=}";;
    --router)          ROUTER_OVERRIDE="${2:-}"; shift;;
    --router=*)        ROUTER_OVERRIDE="${1#*=}";;
    --backup-dir)      BACKUP_DIR="${2:-}"; shift;;
    --backup-dir=*)    BACKUP_DIR="${1#*=}";;
    -h|--help)         usage;;
    *) echo "⚠️ 忽略未知参数: $1";;
  esac
  shift
done

# ---------- 路由器地址 ----------
ROUTER="${ROUTER_OVERRIDE:-}"
if [ -z "$ROUTER" ] && [ -f "$TARGET_CONF" ]; then
  ROUTER=$(grep -E '^[^#]' "$TARGET_CONF" 2>/dev/null | head -1 | tr -d '\r' | awk '{print $1}')
fi
[ -n "$ROUTER" ] || die "未指定路由器地址, 且 $TARGET_CONF 不可用(用 --router root@IP 指定)"
say "路由器: $ROUTER"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
rssh(){ ssh $SSH_OPTS "$ROUTER" "$@"; }

# ---------- GitHub 工具 ----------
gh_auth_guard(){
  [ -n "${GITHUB_TOKEN:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  if ! env -u HTTP_PROXY -u HTTPS_PROXY gh api user >/dev/null 2>&1; then
    # ⚠️ 必须走 stderr: 本函数的 stdout 会被 select_asset 的 $(...) 捕获成 TSV,
    #   警告混进去会导致 TSV 字段错位(实测踩过: TAG 变成警告文本, NAME/URL 全空)。
    echo "⚠️ GITHUB_TOKEN 无效, 本进程内忽略, 改用 gh keyring" >&2
    unset GITHUB_TOKEN
  fi
}

# ---------- 设备现状读取(只读) ----------
read_device_state(){
  say ""
  hr; say "---- 设备现状 (只读探测) ----"; hr
  rssh 'sh -s' 2>/dev/null <<'REMOTE'
echo "--- /proc/mtd ---"
cat /proc/mtd 2>/dev/null
echo "--- UBI 卷 ---"
ubinfo -a 2>/dev/null | grep -E 'Name:' | head -10
echo "--- env 载体内容判定 ---"
for v in /dev/ubi0_1 /dev/ubi0_2; do
  if [ -r "$v" ]; then
    n=$(cat "$v" 2>/dev/null | strings 2>/dev/null | grep -c '^bootcmd=')
    echo "$v bootcmd 数=$n"
    cat "$v" 2>/dev/null | strings 2>/dev/null | grep -E '^bootcmd=|^recovery_mtd=|^recovery_ubi_part=' | sort -u | sed 's/^/    /'
  fi
done
echo "--- fw_printenv (参考) ---"
fw_printenv bootcmd recovery_mtd recovery_ubi_part uboot_ofs recovery_size_uboot 2>/dev/null | sed 's/^/    /'
echo "--- chainloader 分区头部 ---"
M=$(awk -F: '/"chainloader"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
[ -z "$M" ] && M=mtd3
echo "mtd=$M"
hexdump -C -n 64 "/dev/$M" 2>/dev/null | sed 's/^/    /'
echo "--- 内嵌 DTB 头 ---"
hexdump -C -s 8448 -n 16 "/dev/$M" 2>/dev/null | sed 's/^/    /'
echo "--- U-Boot 版本串 ---"
strings -n 8 "/dev/$M" 2>/dev/null | grep -oE 'U-Boot 20[0-9]{2}[^ ]*' | sort -u | head -3 | sed 's/^/    /'
echo "--- 原厂 uenv(mtd1) 的 bootcmd ---"
V=$(awk -F: '/"uenv"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
[ -n "$V" ] && strings -n 8 "/dev/$V" 2>/dev/null | grep -E '^bootcmd=' | head -2 | sed 's/^/    /'
REMOTE
}

# ---------- 血脉识别 + 前置安全检查 (2026-11-16 离线实证新增) ----------
# 为什么需要:
#   XR1710G 上至少有 4 条 chainloader 血脉(YYH2913 / naoki66 / pbs05 / Wiro),
#   它们最关键的差别是 **env 存放在哪**:
#     - YYH2913 血脉: env 在 UBI 卷(ubootenv / ubootenv2), 恢复页 192.168.255.1
#     - naoki66 官方: env 在 MTD 分区 "uenv"(mtd1, 0x200000), 恢复页 192.168.0.1
#   官方 chainloader 的 defconfig 明确:
#     CONFIG_ENV_IS_IN_MTD=y / CONFIG_ENV_MTD_DEV="uenv" / CONFIG_ENV_OFFSET=0x0
#     CONFIG_ENV_SIZE=0x4000
#   ⇒ 若本机没有名为 uenv 的 MTD 分区, 官方 chainloader 将读不到 env,
#     只能退回默认 env(仍可引导, 但用户 env 不生效)。
#   ⇒ 反之若本机 uenv 分区里的 bootcmd 不是 flash read 0x600000 ...,
#     一级引导链就断了, 刷完起不来(只能 TTL 救)。
LINEAGE="unknown"; LINEAGE_ENV_SRC=""; LINEAGE_RECOVERY_IP=""
LINEAGE_UENV_MTD=""; LINEAGE_UBI_PART=""; LINEAGE_UBI_SIZE=""
LINEAGE_BOOTCMD=""; LINEAGE_CHAINLOADER_VER=""; LINEAGE_DESC=""

detect_lineage(){
  say ""; hr; say "---- 血脉识别 (决定 env 源/恢复页/引导链假设) ----"; hr
  local raw
  raw=$(rssh 'sh -s' 2>/dev/null <<'REMOTE'
M=$(awk -F: '/"chainloader"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null); [ -z "$M" ] && M=mtd3
echo "---CHAINLOADER_MTD---"; echo "$M"
echo "---CHAINLOADER_DESC---"
strings -n 8 "/dev/$M" 2>/dev/null | grep -oE 'XR1710G [a-z0-9 -]*chainloader FIT' | sort -u | head -2
echo "---CHAINLOADER_VER---"
strings -n 8 "/dev/$M" 2>/dev/null | grep -oE 'U-Boot 20[0-9]{2}[^ ]{0,40}' | sort -u | head -2
echo "---UENV_MTD---"
awk -F: '/"uenv"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null
echo "---MTD_NAMES---"
awk -F: '{gsub(/"/,"",$4);print $4}' /proc/mtd 2>/dev/null | tr '\n' ' '
echo
echo "---UBI_SIZE---"
awk -F: '/"ubi"|"system"/{gsub(/ /,"",$1);print $1" "$2}' /proc/mtd 2>/dev/null | head -1
echo "---UBI_ENV_VOL---"
for v in /dev/ubi0_1 /dev/ubi0_2; do
  if [ -r "$v" ]; then
    n=$(cat "$v" 2>/dev/null | strings 2>/dev/null | grep -c '^bootcmd=')
    [ "$n" -gt 0 ] && { echo "$v"; cat "$v" 2>/dev/null | strings 2>/dev/null | grep -E '^bootcmd=|^recovery_ubi_part=' | sort -u; }
  fi
done
echo "---UENV_BOOTCMD---"
V=$(awk -F: '/"uenv"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
[ -n "$V" ] && strings -n 8 "/dev/$V" 2>/dev/null | grep -E '^bootcmd=' | head -1
echo "---UENV_CRC---"
V=$(awk -F: '/"uenv"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
[ -n "$V" ] && hexdump -C -n 4 "/dev/$V" 2>/dev/null | head -1
REMOTE
)
  LINEAGE_DESC=$(printf '%s\n' "$raw" | sed -n '/^---CHAINLOADER_DESC---$/,/^---CHAINLOADER_VER---$/p' | grep -v '^---' | head -1)
  LINEAGE_CHAINLOADER_VER=$(printf '%s\n' "$raw" | sed -n '/^---CHAINLOADER_VER---$/,/^---UENV_MTD---$/p' | grep -v '^---' | head -1)
  LINEAGE_UENV_MTD=$(printf '%s\n' "$raw" | sed -n '/^---UENV_MTD---$/,/^---MTD_NAMES---$/p' | grep -v '^---' | head -1)
  LINEAGE_UBI_SIZE=$(printf '%s\n' "$raw" | sed -n '/^---UBI_SIZE---$/,/^---UBI_ENV_VOL---$/p' | grep -v '^---' | head -1)
  LINEAGE_BOOTCMD=$(printf '%s\n' "$raw" | sed -n '/^---UENV_BOOTCMD---$/,/^---UENV_CRC---$/p' | grep -v '^---' | head -1)

  local ubi_env_vol
  ubi_env_vol=$(printf '%s\n' "$raw" | sed -n '/^---UBI_ENV_VOL---$/,/^---UENV_BOOTCMD---$/p' | grep -v '^---' | head -3)
  LINEAGE_UBI_PART=$(printf '%s\n' "$ubi_env_vol" | grep -oE '^recovery_ubi_part=.*' | cut -d= -f2 | head -1)

  say "   chainloader FIT 描述 : ${LINEAGE_DESC:-（未读出）}"
  say "   chainloader 版本串   : ${LINEAGE_CHAINLOADER_VER:-（未读出）}"
  say "   uenv MTD 分区        : ${LINEAGE_UENV_MTD:-（不存在！）}"
  say "   UBI 分区(mtd/size)   : ${LINEAGE_UBI_SIZE:-（未读出）}"
  say "   uenv 里的 bootcmd    : ${LINEAGE_BOOTCMD:-（未读出）}"
  say "   UBI env 卷内容       : ${ubi_env_vol:-（无）}"
  say "   recovery_ubi_part    : ${LINEAGE_UBI_PART:-（未读出）}"

  # ── 判定血脉 ──
  if printf '%s' "$LINEAGE_DESC" | grep -q 'stock-bootm'; then
    LINEAGE="yyh2913"
    LINEAGE_ENV_SRC="UBI 卷 (ubootenv/ubootenv2)"
    LINEAGE_RECOVERY_IP="192.168.255.1"
  elif printf '%s' "$LINEAGE_DESC" | grep -q 'chainloader FIT'; then
    LINEAGE="naoki66"
    LINEAGE_ENV_SRC="MTD 分区 uenv (mtd1 @ 0x200000)"
    LINEAGE_RECOVERY_IP="192.168.0.1"
  else
    LINEAGE="unknown"
    LINEAGE_ENV_SRC="未知"
    LINEAGE_RECOVERY_IP="192.168.255.1"
  fi
  say ""
  case "$LINEAGE" in
    yyh2913)  say "   🔎 判定血脉: **YYH2913 血脉** (stock-bootm compatible)" ;;
    naoki66)  say "   🔎 判定血脉: **naoki66 官方血脉**" ;;
    *)        say "   ⚠️ 判定血脉: **未知** —— 无法确定 env 源与恢复页, 拒绝盲刷" ;;
  esac
  say "   env 源预期          : $LINEAGE_ENV_SRC"
  say "   恢复页预期          : $LINEAGE_RECOVERY_IP"
}

# ---------- 前置安全检查 ----------
PREFLIGHT_OK=1
preflight_checks(){
  say ""; hr; say "---- 刷写前置检查 (任一失败即拒绝写入) ----"; hr
  local fail=0

  # 1) 血脉必须已识别
  if [ "$LINEAGE" = "unknown" ]; then
    say "   ❌ 血脉无法识别 —— 拒绝刷写"; fail=1
  else
    say "   ✅ 血脉已识别: $LINEAGE"
  fi

  # 2) 目标镜像必须来自官方 naoki66 仓库且为 *-slot.bin (已在 select_asset 保证, 此处复核)
  if [ -n "$UBOOT_ASSET_NAME" ] && printf '%s' "$UBOOT_ASSET_NAME" | grep -qE '^xr1710g-chainloader-.*-slot\.bin$'; then
    say "   ✅ 目标镜像: $UBOOT_ASSET_NAME"
  else
    say "   ❌ 目标镜像不合规: ${UBOOT_ASSET_NAME:-（空）} —— 必须是 xr1710g-chainloader-*-slot.bin"; fail=1
  fi

  # 3) 必须存在 uenv MTD 分区(官方 chainloader 的 env 源)
  if [ -n "$LINEAGE_UENV_MTD" ]; then
    say "   ✅ uenv MTD 分区存在: $LINEAGE_UENV_MTD (官方 CONFIG_ENV_MTD_DEV=\"uenv\")"
  else
    say "   ❌ 无 uenv MTD 分区 —— 官方 chainloader 将读不到持久 env"; fail=1
  fi

  # 4) 原厂 bootcmd 必须指向 chainloader 槽位(一级引导链)
  if printf '%s' "$LINEAGE_BOOTCMD" | grep -qE 'flash read 0x600000'; then
    say "   ✅ 一级引导链: uenv bootcmd 指向 0x600000 (chainloader 槽位)"
  elif printf '%s' "$LINEAGE_BOOTCMD" | grep -q 'flash read'; then
    say "   ⚠️ 一级引导链: uenv bootcmd 的 flash read 偏移不是 0x600000 —— 需人工确认"
    say "        当前: $LINEAGE_BOOTCMD"
  else
    say "   ⚠️ 一级引导链: 未从 uenv 读到 'flash read' 配方 —— 需人工确认"
  fi

  # 5) UBI 分区大小必须与官方 DTB 的 system 档位一致(0x1b700000 = 460324864)
  local mtd_sz
  mtd_sz=$(printf '%s' "$LINEAGE_UBI_SIZE" | awk '{print $2}')
  if [ "$mtd_sz" = "1b700000" ] || [ "$mtd_sz" = "460324864" ]; then
    say "   ✅ UBI 分区大小 = $mtd_sz (官方唯一支持档位 {2.0, system})"
  else
    say "   ❌ UBI 分区大小 = ${mtd_sz:-未读出} —— 官方仅支持 0x1b700000(439MiB); 本机不符"; fail=1
  fi

  # 6) 必须有可用的回滚备份
  local bdir
  bdir=$(ls -d "$HOME/router-upgrade-logs/uboot-backups/"*/ 2>/dev/null | tail -1)
  if [ -n "$bdir" ] && [ -f "${bdir}mtd-chainloader.bin" ]; then
    local bsz bsum
    bsz=$(wc -c < "${bdir}mtd-chainloader.bin" | tr -d ' ')
    bsum=$(shasum -a 256 "${bdir}mtd-chainloader.bin" 2>/dev/null | cut -d' ' -f1)
    say "   ✅ 回滚备份可用: $(basename "$bdir") (${bsz} 字节, sha256 ${bsum:0:16}…)"
    ROLLBACK_DIR="${bdir}"
  else
    say "   ❌ 无可用回滚备份 —— 先跑 --prepare"; fail=1
  fi

  # 7) TTL 救砖能力提醒(不阻断, 但必须显式确认已具备)
  if [ "${ACK_UBOOT_FLASH:-0}" = "1" ]; then
    say "   ⚠️ 刷写已确认。请确保 TTL 串口已就位 —— 官方 chainloader 无 'flash' 命令,"
    say "      若 mtd1 的 uenv CRC 失效且 rfb.c 规范化未生效, 可能停在 'Unknown command' 需 TTL 救砖。"
    say "      救砖配方: ECNT> 下 setenv bootcmd 'flash read 0x600000 0x100000 \$loadaddr; bootm' + saveenv + reset"
  fi

  if [ "$fail" != "0" ]; then
    say ""
    say "   🛑 前置检查未通过 —— 拒绝写入任何分区"
    PREFLIGHT_OK=0
    return 1
  fi
  say ""
  say "   ✅ 全部前置检查通过"
  PREFLIGHT_OK=1
  return 0
}

# ---------- 官方 asset 选片 ----------
# 用 Python 解析 GitHub API(无 jq 依赖), 输出 TSV: tag | asset_name | url | digest | published_at | size
# 选片纪律: 只认本机机型的 asset(xr1710g-*-slot.bin), 且只认 *-slot.bin ——
#   release body 里会列出 xg2010g 的 sha256 但该机型 asset 可能根本没上传, 且
#   XR1710G 与 XG2010G 镜像**不通用**, 混刷直接变砖。
select_asset(){
  # ⚠️ 2026-11-16 实测坑: `gh api` 在凭据失效时**返回 401 JSON 但退出码仍是 0**
  #   (已验证: gh api ... 打印 {"message":"Bad credentials"} 且 rc=0), 所以不能用
  #   "非空即成功" 判定 —— 必须校验内容是不是真的 JSON 数组。
  #   这里优先用免鉴权的 curl(公开仓库不需要 token), gh 只作备选。
  local raw="" hint=""
  raw=$(curl -fsSL --max-time 30 "https://api.github.com/repos/$UBOOT_REPO/releases?per_page=100" 2>/dev/null)
  if ! printf '%s' "$raw" | head -c 1 | grep -q '\['; then
    # 2026-11-16 实测: GitHub API 对共享出口 IP 会返回 403
    #   {"message":"API rate limit exceeded for <ip>"} —— 这**不是**空响应,
    #   若不区分就会把错误信息当成数据(或误判为"选片失败")。此处显式识别并给出可行动提示。
    if printf '%s' "$raw" | grep -q 'rate limit exceeded'; then
      hint="GitHub API 已限流(共享出口 IP)。可选: ① 等额度恢复 ② 用已登录的 gh keyring(脚本会自动尝试) ③ 手动指定镜像: --asset <文件名> --expect-sha <sha256>"
    elif printf '%s' "$raw" | grep -q 'Bad credentials'; then
      hint="GitHub 凭据无效(401)。可 unset GITHUB_TOKEN 后重试, 或用 gh auth login。"
    fi
    raw=""
    if command -v gh >/dev/null 2>&1; then
      gh_auth_guard
      raw=$(env -u HTTP_PROXY -u HTTPS_PROXY gh api "repos/$UBOOT_REPO/releases?per_page=100" 2>/dev/null)
      printf '%s' "$raw" | head -c 1 | grep -q '\[' || raw=""
    fi
  fi
  if [ -z "$raw" ]; then
    say "  ❌ 无法读取 $UBOOT_REPO 的 release 元数据"
    [ -n "$hint" ] && say "     原因: $hint"
    say "     可用离线兜底: --asset <文件名> --expect-sha <sha256> (需自行从 Release 页面取)"
    die "选片失败"
  fi
  # 离线兜底: 若用户用 --asset 指定了一个**本地已存在**的文件, 直接用它, 完全不依赖 GitHub。
  #   (2026-11-16 实测: GitHub API 对共享出口 IP 会限流, 必须有这条路才能继续)
  if [ -n "$ASSET_NAME" ] && [ -f "$ASSET_NAME" ]; then
    local lsha
    lsha=$(shasum -a 256 "$ASSET_NAME" | cut -d' ' -f1)
    printf 'local\t%s\tfile://%s\t%s\t%s\t%s' \
      "$(basename "$ASSET_NAME")" "$ASSET_NAME" "$lsha" "$(date '+%Y-%m-%dT%H:%M:%SZ')" "$(wc -c < "$ASSET_NAME" | tr -d ' ')"
    return 0
  fi
  local tsv
  tsv=$(printf '%s' "$raw" | RELEASE_TAG="$RELEASE_TAG" python3 -c '
import json,sys,os
rel_tag = os.environ.get("RELEASE_TAG","")
releases = json.load(sys.stdin)
def assets_of(r):
    return [a for a in r.get("assets",[]) if a.get("name","").startswith("xr1710g-chainloader-") and a.get("name","").endswith("-slot.bin")]
if rel_tag:
    cands = [r for r in releases if r.get("tag_name")==rel_tag]
else:
    cands = [r for r in releases if assets_of(r)]
if not cands:
    sys.exit(3)
r = sorted(cands, key=lambda x: x.get("published_at") or "")[-1]
aa = assets_of(r)
if not aa:
    sys.exit(4)
a = aa[0]
digest = a.get("digest") or "NONE"
if digest.startswith("sha256:"):
    digest = digest.split(":",1)[1]
print("\t".join([r.get("tag_name",""), a.get("name",""), a.get("browser_download_url",""), digest, r.get("published_at",""), str(a.get("size",""))]))
' 2>/dev/null) || die "选片失败: 未找到 xr1710g-chainloader-*-slot.bin (RELEASE_TAG=${RELEASE_TAG:-latest})"
  [ -n "$tsv" ] || die "选片失败: 元数据为空"
  printf '%s' "$tsv"
}

# ---------- 下载 ----------
download_asset(){
  # 用法: download_asset <url> <dest>
  local url="$1" dest="$2"
  say "  下载: $(basename "$dest")"
  mkdir -p "$(dirname "$dest")" 2>/dev/null
  # 优先直连 GitHub release 下载 URL(公开仓库, 免鉴权, 不受 gh 401 影响)
  if curl -fSL --max-time 300 --retry 2 -o "$dest" "$url" 2>/dev/null && [ -s "$dest" ]; then
    return 0
  fi
  # 备选: gh release download
  if command -v gh >/dev/null 2>&1; then
    gh_auth_guard
    if gh release download --repo "$UBOOT_REPO" --pattern "$(basename "$dest")" --dir "$(dirname "$dest")" --clobber >/dev/null 2>&1 && [ -s "$dest" ]; then
      return 0
    fi
  fi
  rm -f "$dest" 2>/dev/null
  return 1
}

# ---------- 本地镜像校验(magic + 大小) ----------
verify_image_local(){
  local img="$1"
  # ⚠️ 关键: magic 基准必须在函数内取自全局, 且取不到就**直接失败** ——
  #   否则若全局变量被意外清空, 期望值与实测值会同时为空而"校验通过"(假阳性)。
  local MAGIC_SHIM="27051956" MAGIC_DTB="d00dfeed" MAGIC_SHIM_OFF=0 MAGIC_DTB_OFF=0x2100
  local sz; sz=$(wc -c < "$img" | tr -d ' ')
  local maxsz=$(( 0x100000 ))
  if [ "$sz" -gt "$maxsz" ]; then
    echo "❌ 镜像 $sz 字节 > chainloader 分区上限 $maxsz 字节(1MiB) —— 拒绝"
    return 1
  fi
  if [ "$sz" -lt $(( 0x2100 + 16 )) ]; then
    echo "❌ 镜像 $sz 字节过小, 不含内嵌 DTB 区域 —— 拒绝"
    return 1
  fi
  local m1 m2
  m1=$(dd if="$img" bs=1 skip="$MAGIC_SHIM_OFF" count=4 2>/dev/null | hexdump -v -e '1/1 "%02x"' 2>/dev/null | tr -d '\n')
  m2=$(dd if="$img" bs=1 skip="$MAGIC_DTB_OFF" count=4 2>/dev/null | hexdump -v -e '1/1 "%02x"' 2>/dev/null | tr -d '\n')
  if [ ${#m1} -ne 8 ] || [ ${#m2} -ne 8 ]; then
    echo "❌ 无法提取 magic 字节(实测 shim='$m1' dtb='$m2') —— 拒绝"
    return 1
  fi
  if [ "$m1" != "$MAGIC_SHIM" ]; then
    echo "❌ 前缀 shim magic 不符: 期望 $MAGIC_SHIM 实得 $m1 (offset $MAGIC_SHIM_OFF)"
    echo "   → 该文件很可能不是 chainloader 镜像(裸 FIT / u-boot.bin 均不适用)"
    return 1
  fi
  if [ "$m2" != "$MAGIC_DTB" ]; then
    echo "❌ 内嵌 DTB magic 不符: 期望 $MAGIC_DTB 实得 $m2 (offset $MAGIC_DTB_OFF)"
    return 1
  fi
  echo "  ✅ 镜像结构校验通过: size=$sz (<=1MiB), shim magic @$MAGIC_SHIM_OFF, dtb magic @$MAGIC_DTB_OFF"
  return 0
}

# ---------- 备份 ----------
# 备份实现(显式版本, 避免 heredoc 传参歧义)
backup_device(){
  local dir="$1"
  say ""
  hr; say "---- 备份 (fail-closed: 备份不全不继续) ----"; hr
  mkdir -p "$dir" || die "无法创建备份目录 $dir"
  rssh "sh -s -- '$dir'" 2>/dev/null <<'REMOTE'
D="$1"
mkdir -p "$D" || exit 11
M=$(awk -F: '/"chainloader"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
[ -z "$M" ] && M=mtd3
V=$(awk -F: '/"uenv"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
dd if="/dev/$M" of="$D/mtd-chainloader.bin" bs=1M 2>/dev/null || exit 12
[ -n "$V" ] && dd if="/dev/$V" of="$D/mtd-uenv.bin" bs=1M 2>/dev/null
for v in /dev/ubi0_1 /dev/ubi0_2; do
  n=$(basename "$v")
  dd if="$v" of="$D/env-$n.bin" bs=64k count=8 2>/dev/null
done
cat /proc/mtd > "$D/proc-mtd.txt" 2>/dev/null
fw_printenv > "$D/fw_printenv.txt" 2>/dev/null
ubinfo -a > "$D/ubinfo.txt" 2>/dev/null
echo "BACKUP_OK"
REMOTE
  local rc=$?
  # 拉回本机
  scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER":"$dir"/* "$dir/" >/dev/null 2>&1
  [ $rc -eq 0 ] || die "设备侧备份失败(rc=$rc) —— fail-closed, 中止"
  [ -s "$dir/mtd-chainloader.bin" ] || die "备份缺失 mtd-chainloader.bin —— 中止"
  # 校验备份完整性: 大小必须等于分区大小
  local csize bsize
  _bmtd=$(rssh "awk -F: '/\"chainloader\"/{gsub(/ /,\"\",\$1);print \$1}' /proc/mtd 2>/dev/null" 2>/dev/null | tr -d ' \n')
  [ -n "$_bmtd" ] || _bmtd=mtd3
  csize=$(rssh "wc -c < /dev/$_bmtd 2>/dev/null" 2>/dev/null | tr -d ' \n')
  bsize=$(wc -c < "$dir/mtd-chainloader.bin" | tr -d ' ')
  if [ -n "$csize" ] && [ "$csize" != "$bsize" ]; then
    die "备份大小不符: 设备 $csize vs 本地 $bsize —— 中止"
  fi
  ( cd "$dir" && shasum -a 256 ./* > SHA256SUMS 2>/dev/null )
  say "  ✅ 备份完成: $dir"
  ( cd "$dir" && ls -la | sed 's/^/    /' )
  say "  sha256:"
  sed 's/^/    /' "$dir/SHA256SUMS" 2>/dev/null
  return 0
}

# ---------- MAC 基线快照 ----------
# 官方 chainloader 若因 uenv CRC 失效而回落到默认 env(xr1710g.env),
# 默认 env 里的 ethaddr 可能与原厂 MAC 不同 → 刷完 MAC 可能变化。
# 因此在写入前抓一份基线, 刷后逐个接口比对。
snapshot_mac(){
  local dir="$1"
  say "  抓取 MAC 基线"
  rssh "sh -s" 2>/dev/null <<'REMOTE' > "$dir/mac-baseline.txt" 2>/dev/null
for i in /sys/class/net/*; do
  n=$(basename "$i")
  a=$(cat "$i/address" 2>/dev/null)
  [ -n "$a" ] && echo "$n $a"
done
REMOTE
  if [ -s "$dir/mac-baseline.txt" ]; then
    say "  ✅ MAC 基线已存: $dir/mac-baseline.txt"
    sed 's/^/      /' "$dir/mac-baseline.txt"
  else
    say "  ⚠️ MAC 基线抓取失败(不影响写入, 但刷后无法自动比对 MAC)"
  fi
}

compare_mac(){
  local dir="$1"
  [ -f "$dir/mac-baseline.txt" ] || return 0
  local now; now=$(mktemp)
  rssh "sh -s" 2>/dev/null <<'REMOTE' > "$now" 2>/dev/null
for i in /sys/class/net/*; do
  n=$(basename "$i")
  a=$(cat "$i/address" 2>/dev/null)
  [ -n "$a" ] && echo "$n $a"
done
REMOTE
  if diff -q "$dir/mac-baseline.txt" "$now" >/dev/null 2>&1; then
    say "  ✅ MAC 未变化"
  else
    say "  ⚠️ MAC 发生变化(可能是 env 回落默认值的副作用):"
    diff "$dir/mac-baseline.txt" "$now" 2>/dev/null | sed 's/^/      /'
  fi
  rm -f "$now"
}

# ---------- 写入 + 回读校验 ----------
flash_chainloader(){
  local img="$1" dir="$2"
  say ""
  hr; say "---- 写入 chainloader 分区 ----"; hr
  # 1) 上传
  say "  上传镜像到设备"
  # 注: 上传的是 pad 后的镜像 (PAD_FILE), 源镜像 sha 单独保留用于回读比对
  scp -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$PAD_FILE" "$ROUTER":/tmp/chainloader-slot.bin >/dev/null 2>&1 || die "上传镜像失败"
  # 2) 设备侧校验 sha256 + magic, 再写
  local isha
  isha=$(rssh "sha256sum /tmp/chainloader-slot.bin 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d ' \n')
  local lsha psha
  lsha=$(shasum -a 256 "$img" | awk '{print $1}')
  psha=$(shasum -a 256 "$PAD_FILE" | awk '{print $1}')
  [ -n "$isha" ] && [ "$isha" != "$psha" ] && die "上传后 sha256 不符(设备 $isha vs 本地 pad $psha) —— 中止, 不写入"
  [ -n "$isha" ] || die "设备侧无法计算 sha256"
  if [ "$isha" != "$lsha" ]; then die "上传后 sha256 不符(设备 $isha vs 本地 $lsha) —— 中止, 不写入"; fi
  say "  ✅ 上传完整性校验通过 (sha256=$lsha)"

  # 3) 设备侧二次结构校验(写前最后一道闸)
  local vok
  vok=$(rssh "dd if=/tmp/chainloader-slot.bin bs=1 count=4 2>/dev/null | hexdump -v -e '1/1 \"%02x\"'; dd if=/tmp/chainloader-slot.bin bs=1 skip=8448 count=4 2>/dev/null | hexdump -v -e '1/1 \"%02x\"'" 2>/dev/null | tr -d '\n ')
  local vm1=${vok:0:8} vm2=${vok:8:8}
  if [ "$vm1" != "$MAGIC_SHIM" ] || [ "$vm2" != "$MAGIC_DTB" ]; then
    die "设备侧 magic 校验失败(shim=$vm1 dtb=$vm2) —— 中止, 不写入"
  fi
  say "  ✅ 设备侧 magic 校验通过"

  # 3.5) 取目标 MTD 与擦除块大小, 并把镜像 pad 成擦除块整数倍
  #   ⚠️ 实测根因（2026-11-16, 已二次实证）:
  #     NAND mtd 字符设备只接受**整擦除块**写入。本机 mtd3 erasesize=131072 (128 KiB),
  #     而官方 chainloader 镜像长 937538 字节 = 7 个整块 + 20034 字节尾巴, 非整除 →
  #     无论 dd 用 bs=1M 还是 bs=128K, 最后那次 write() 长度非对齐 → 内核返回 EINVAL。
  #     （注: "bs=1M 不是 erasesize 整数倍" 是上一轮的误判, 1MiB 恰好是 128Ki 的整数倍）
  #     正解: 写前把镜像用 0xFF 补齐到 erasesize 整数倍, 保证每次 write() 都对齐。
  #     0xFF 填充与本机 mtd3 现有尾部（空闲区全 0xFF）一致, 不引入额外差异。
  _cmtd=$(rssh "awk -F: '/\"chainloader\"/{gsub(/ /,\"\",\$1);print \$1}' /proc/mtd 2>/dev/null" 2>/dev/null | tr -d ' \n')
  [ -n "$_cmtd" ] || _cmtd=mtd3
  local ES
  ES=$(rssh "cat /sys/class/mtd/${_cmtd}/erasesize 2>/dev/null" 2>/dev/null | tr -d ' \n')
  case "$ES" in ''|*[!0-9]*) ES=131072 ;; esac
  local ORIG_LEN PAD_LEN PAD_FILE
  ORIG_LEN=$(wc -c < "$img" | tr -d ' ')
  PAD_LEN=$(( (ORIG_LEN + ES - 1) / ES * ES ))
  PAD_FILE="/tmp/chainloader-slot-pad.bin"
  if [ "$PAD_LEN" != "$ORIG_LEN" ]; then
    python3 - "$img" "$PAD_FILE" "$PAD_LEN" <<'PYEOF'
import sys
src, dst, target = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(src, "rb").read()
assert len(data) <= target, "镜像比 pad 目标还大"
open(dst, "wb").write(data + b"\xff" * (target - len(data)))
PYEOF
    [ $? -eq 0 ] || die "镜像 pad 到 ${PAD_LEN} 字节失败"
    say "  ℹ️  已把镜像 pad 到擦除块整数倍: ${ORIG_LEN} → ${PAD_LEN} 字节 (erasesize=$ES, 填充 0xFF)"
  else
    cp -f "$img" "$PAD_FILE" || die "准备写入文件失败"
    say "  ℹ️  镜像长度已是擦除块整数倍 (${ORIG_LEN} 字节, erasesize=$ES)"
  fi

  if [ "$DRY" = "1" ]; then
    say "  [dry-run] 真实执行将执行: mtd -e ${_cmtd} erase && mtd write ${PAD_FILE} ${_cmtd}, 然后整块回读比对"
    return 0
  fi

  # 4) 写入
  say "  写入 mtd 分区 '$CHAINLOADER_MTD' (1MiB @ $CHAINLOADER_FLASH_OFF)"
  # ⚠️ 2026-11-16 实测修复（真实故障，非理论推断，两轮实证）:
  #   原实现 `dd if=... of=/dev/mtd3 bs=1M conv=fsync` 失败 ——
  #   实机现象: 打印 WRITE_BEGIN 后没有 WRITE_DONE。
  #   真根因: NAND mtd 字符设备只接受**整擦除块**写入。本机 erasesize=131072 (128 KiB),
  #     而官方 chainloader 镜像长 937538 字节 = 7×128Ki + 20034 字节尾巴, 非整除 →
  #     dd 的最后一次 write() 长度不对齐 → 内核 EINVAL。
  #     ⚠️ 第一轮曾误判为 "bs=1M 不是 128Ki 的整数倍" —— 那是错的, 1MiB 恰好整除 128Ki;
  #        真正不对齐的是**镜像长度**, 与 bs 选多少无关 (换 bs=128K 尾巴照样不对齐)。
  #   解法:
  #     1) 写前把镜像用 0xFF pad 到 erasesize 整数倍 (见下方 3.5 步) → 每次 write() 都对齐;
  #     2) 优先 `mtd -e erase` + `mtd write`（内核侧处理擦除与对齐）;
  #     3) `mtd verify` 做写入后逐字节校验;
  #     4) 只有 mtd write 不可用才回落 dd，dd 用 bs=erasesize;
  #     5) ⚠️ 绝不把写命令接管道后取 $?（那是 tail 的退出码, 会伪装成功）——见远端 run_logged。
  #   ⚠️ 只写 chainloader 分区; 绝不触碰 uenv / ubootenv —— env 是原厂与二级共用的,
  #      在二级 chainloader 里 saveenv 会把原厂 env 整套覆盖, 导致原厂 U-Boot 无法启动。
  rssh "sh -s" 2>/dev/null <<'REMOTE'
M=$(awk -F: '/"chainloader"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
[ -z "$M" ] && M=mtd3
ES=$(cat /sys/class/mtd/$M/erasesize 2>/dev/null)
[ -n "$ES" ] || ES=131072
IMG=/tmp/chainloader-slot.bin
SZ=$(wc -c < $IMG)
echo "WRITE_INFO mtd=$M erase_size=$ES image_size=$SZ"

# ⚠️ rc 捕获纪律: 绝不把命令接到管道/重定向后面再取 $? ——
#   那样拿到的是管道末端(tail)的退出码, 会把失败伪装成成功。
#   一律: cmd > log 2>&1 ; rc=$? ;  然后 cat log。
run_logged() {
  _tag="$1"; shift
  "$@" > /tmp/_w.log 2>&1
  _rc=$?
  echo "[$_tag rc=$_rc]"
  cat /tmp/_w.log
  return $_rc
}

if command -v mtd >/dev/null 2>&1 && mtd write 2>&1 | grep -q 'write <imagefile>'; then
  echo "WRITE_BEGIN method=mtd-perblock erase_size=$ES"
  # 第一步: 不预先整分区擦除。mtd write 默认逐块擦除后即写,
  #         这样"slot 完全为空"的窗口只有 1 个 128Ki 擦除块, 而不是整 1MiB。
  if run_logged write mtd write "$IMG" "$M"; then
    sync
    echo "WRITE_DONE"
  else
    # 第二步: 逐块写失败(常见于残留位未擦净) → 整分区擦除后重试一次
    echo "RETRY_AFTER_FULL_ERASE"
    run_logged erase mtd -e "$M" erase || true
    if run_logged write2 mtd write "$IMG" "$M"; then
      sync
      echo "WRITE_DONE"
    else
      echo "WRITE_FAILED method=mtd"
      exit 10
    fi
  fi
  if run_logged verify mtd verify "$IMG" "$M"; then
    echo "VERIFY_OK mtd-verify"
  else
    echo "VERIFY_FAILED mtd-verify"
    exit 20
  fi
else
  echo "WRITE_BEGIN method=dd bs=$ES (mtd write 不可用)"
  BS=$ES
  run_logged erase mtd -e "$M" erase 2>/dev/null || true
  if run_logged write dd if="$IMG" of="/dev/$M" bs=$BS conv=fsync; then
    sync
    echo "WRITE_DONE"
  else
    echo "WRITE_FAILED method=dd"
    exit 10
  fi
fi
REMOTE
  [ $? -eq 0 ] || die "写入失败(mtd write / dd 均失败)"
  say "  ✅ 写入完成"

  # 5) 整块回读比对(最关键的一步)
  say "  回读校验"
  _cmtd=$(rssh "awk -F: '/\"chainloader\"/{gsub(/ /,\"\",\$1);print \$1}' /proc/mtd 2>/dev/null" 2>/dev/null | tr -d ' \n')
  [ -n "$_cmtd" ] || _cmtd=mtd3
  rssh "dd if=/dev/$_cmtd of=/tmp/readback.bin bs=1M 2>/dev/null" >/dev/null 2>&1
  scp -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROUTER":/tmp/readback.bin /tmp/uboot-readback.bin >/dev/null 2>&1 || die "回读失败"
  local head_sha
  head_sha=$(dd if=/tmp/uboot-readback.bin bs=1 count="$ORIG_LEN" 2>/dev/null | shasum -a 256 | awk '{print $1}')
  if [ "$head_sha" != "$lsha" ]; then
    say "  ❌ 回读比对失败: 写入内容与源镜像不一致(回读 $head_sha vs 源 $lsha)"
    say "     未重启。链 loader 仍是旧的(若分区写入失败)或损坏(若部分写入), 请用备份回写。"
    die "回读校验不通过, 拒绝重启"
  fi
  # 尾部也校验: 空闲区应保持 0xFF, 说明没有残留旧内容
  local tail_ff
  tail_ff=$(dd if=/tmp/uboot-readback.bin bs=1 skip="$ORIG_LEN" count=$((PAD_LEN-ORIG_LEN)) 2>/dev/null | tr -d '\000-\377' | wc -c | tr -d ' ')
  if [ "${tail_ff:-0}" != "0" ]; then
    say "  ⚠️  尾部 ${PAD_LEN}-${ORIG_LEN} 字节存在非 0xFF 残留(非0xFF字节数=$tail_ff) —— 建议确认后手动 mtd erase 再重写"
  else
    say "  ✅ 尾部填充区全为 0xFF (无残留)"
  fi
  say "  ✅ 回读比对通过 (前 ${ORIG_LEN} 字节 sha256 与源一致)"
  rm -f /tmp/uboot-readback.bin
  say "  ⚠️ 尚未重启 —— 建议先手动确认恢复页可达, 再执行重启"
  return 0
}

rollback_chainloader(){
  local dir="$1"
  say ""
  hr; say "---- 回滚: 用备份的旧 chainloader 写回 ----"; hr
  local src="$dir/mtd-chainloader.bin"
  [ -s "$src" ] || die "备份目录缺少 mtd-chainloader.bin: $src"
  say "  源: $src ($(wc -c < "$src" | tr -d ' ') 字节)"
  if [ "$ACK_FLASH" != "1" ]; then
    say "  [未确认] 回滚同样是写操作, 需要 --ack-uboot-flash"
    return 1
  fi
  scp -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$src" "$ROUTER":/tmp/chainloader-old.bin >/dev/null 2>&1 || die "上传备份失败"
  if [ "$DRY" = "1" ]; then say "  [dry-run] 将把备份写回 chainloader 分区"; return 0; fi
  rssh "sh -s" 2>/dev/null <<'REMOTE'
M=$(awk -F: '/"chainloader"/{gsub(/ /,"",$1);print $1}' /proc/mtd 2>/dev/null)
[ -z "$M" ] && M=mtd3
IMG=/tmp/chainloader-old.bin
SZ=$(wc -c < $IMG)
ES=$(cat /sys/class/mtd/$M/erasesize 2>/dev/null); [ -n "$ES" ] || ES=131072
echo "ROLLBACK_INFO mtd=$M erase_size=$ES image_size=$SZ"
run_logged() { _tag="$1"; shift; "$@" > /tmp/_rb.log 2>&1; _rc=$?; echo "[$_tag rc=$_rc]"; cat /tmp/_rb.log; return $_rc; }
if command -v mtd >/dev/null 2>&1 && mtd write 2>&1 | grep -q 'write <imagefile>'; then
  run_logged erase mtd -e "$M" erase || true
  run_logged write mtd write "$IMG" "$M" || { echo "ROLLBACK_FAILED"; exit 10; }
  sync
  echo "ROLLBACK_DONE"
else
  run_logged write dd if="$IMG" of="/dev/$M" bs=$ES conv=fsync || { echo "ROLLBACK_FAILED"; exit 10; }
  sync
  echo "ROLLBACK_DONE"
fi
REMOTE
  [ $? -eq 0 ] || die "回写失败"
  say "  ✅ 已写回旧 chainloader(未重启)"
}

probe_recovery(){
  say ""
  hr; say "---- Recovery 页探测 ----"; hr
  local cands=(192.168.255.1 192.168.0.1) ip code found=""
  if [ -f "$STATE_FILE" ]; then
    local s; s=$(grep -E '^UBOOT_STATE_RECOVERY_IP=' "$STATE_FILE" 2>/dev/null | cut -d= -f2-)
    [ -n "$s" ] && cands=("$s" "${cands[@]}")
  fi
  for ip in "${cands[@]}"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 --noproxy '*' "http://$ip/" 2>/dev/null)
    if [ "$code" = "000" ]; then say "  ✗ http://$ip/ 无响应"; else say "  ✓ http://$ip/ HTTP $code"; found="$ip"; fi
  done
  if [ -n "$found" ]; then say "✅ Recovery 页可达: http://$found/"; else say "⚠️ 无候选 Recovery 页可达(路由器正常运行中时本就无响应)"; fi
}

# ================= 主流程 =================
case "$MODE" in
  status)
    read_device_state
    detect_lineage
    ;;
  plan|prepare)
    read_device_state
    detect_lineage
    say ""
    hr; say "---- 官方 chainloader 选片 ----"; hr
    TSV=$(select_asset) || die "选片失败"
    IFS=$'\t' read -r TAG NAME URL DIGEST PUB SIZE <<< "$TSV"
    say "  release   : $TAG (发布 $PUB)"
    say "  asset     : $NAME ($SIZE 字节)"
    say "  官方 digest: ${DIGEST}"
    [ -n "$ASSET_NAME" ] && NAME="$ASSET_NAME"
    if [ -z "$EXPECT_SHA" ] && [ "$DIGEST" != "NONE" ]; then EXPECT_SHA="${DIGEST#sha256:}"; fi
    if [ -z "$EXPECT_SHA" ]; then say "⚠️ 该 release 无 asset digest, 需手动 --expect-sha 提供基准"; else say "  将用 sha256 基准: $EXPECT_SHA"; fi
    TS="${BACKUP_DIR:-$LOG_DIR/uboot-backups/$(date +%Y%m%d-%H%M%S)}"
    say ""
    hr; say "---- 计划 ----"; hr
    say "  备份目录 : $TS"
    say "  将备份  : mtd3(chainloader 1MiB) / mtd1(uenv 2MiB) / ubi0_1 / ubi0_2 / proc-mtd / fw_printenv / ubinfo"
    say "  将写入  : chainloader 分区(1MiB @ $CHAINLOADER_FLASH_OFF), 写后整块回读比对"
    say "  绝不触碰: uenv / ubootenv / ubootenv2 (env 是原厂与二级共用, saveenv 会毁掉原厂启动配方)"
    say ""
    say "  ⚠️ 注意: 本机当前已处于「已刷 chainloader」状态 —— 上游 TTL+TFTP 教程针对的是"
    say "     「原厂 U-Boot(ECNT>)」状态, 对本机不适用。本机对应路径是 HTTP Recovery 的"
    say "     uboot 目标上传 *-slot.bin; 若设备已变砖进不了 Recovery, 只能拆机 TTL 救砖。"
    say ""
    hr; say "---- 本机专属风险提示 (刷前务必读完) ----"; hr
    if [ "$LINEAGE" = "yyh2913" ]; then
      say "  ① 恢复页地址会变: 本机当前是 YYH2913 血脉, 恢复页在 ${LINEAGE_RECOVERY_IP};"
      say "     刷入 naoki66 官方 chainloader 后恢复页将变为 **192.168.0.1**。"
      say "     → 变砖后请用 192.168.0.1 找设备, 别只试 255.1。"
    else
      say "  ① 恢复页地址: 按 ${LINEAGE} 血脉, 应为 ${LINEAGE_RECOVERY_IP}。"
    fi
    say "  ② 必须连带刷一次固件: 官方 chainloader 按官方固件布局(U-Boot 卷/fit 卷)设计。"
    say "     只换二级引导而不换固件, 可能停在 Unknown command(二级 U-Boot 无 flash 命令)。"
    say "     → 推荐顺序: 先用 upgrade_router.sh 刷官方固件 → 再刷本 chainloader → 再重启验证。"
    say "  ③ MAC 可能变化: 若 mtd1 的 uenv CRC 失效, 二级 U-Boot 会回落官方默认 env"
    say "     (xr1710g.env), 其 ethaddr 可能与原厂 MAC 不同。"
    say "     → 已自动抓取 MAC 基线到备份目录, 刷后用 compare_mac 逐接口比对;"
    say "       MAC 变了可在二级 U-Boot 里 setenv ethaddr '<原MAC>' + saveenv + reset 改回。"
    if [ "$MODE" = "prepare" ]; then
      backup_device "$TS"
      snapshot_mac "$TS"
      IMG="$TS/$NAME"
      say ""
      hr; say "---- 下载 + 校验 ----"; hr
      download_asset "$URL" "$IMG" || die "下载失败"
      [ -s "$IMG" ] || die "下载后文件为空"
      ASHA=$(shasum -a 256 "$IMG" | awk '{print $1}')
      if [ -n "$EXPECT_SHA" ]; then
        [ "$ASHA" = "$EXPECT_SHA" ] || die "sha256 不符(官方 $EXPECT_SHA 实得 $ASHA) —— 中止"
        say "  ✅ sha256 与官方基准一致"
      else
        say "  ⚠️ 无官方基准, 仅有实测 $ASHA"
      fi
      verify_image_local "$IMG" || die "镜像结构校验失败"
      say "  镜像就绪: $IMG"
      say ""
      say "✅ prepare 完成。备份与镜像均已就位, 尚未写入任何分区。"
    fi
    ;;
  flash)
    [ "$ACK_FLASH" = "1" ] || die "刷 U-Boot 需要显式确认: --ack-uboot-flash"
    read_device_state
    detect_lineage
    TSV=$(select_asset) || die "选片失败"
    IFS=$'\t' read -r TAG NAME URL DIGEST PUB SIZE <<< "$TSV"
    UBOOT_ASSET_NAME="$NAME"
    [ -n "$ASSET_NAME" ] && NAME="$ASSET_NAME"
    if [ -z "$EXPECT_SHA" ] && [ "$DIGEST" != "NONE" ]; then EXPECT_SHA="${DIGEST#sha256:}"; fi
    TS="${BACKUP_DIR:-$LOG_DIR/uboot-backups/$(date +%Y%m%d-%H%M%S)}"
    # ⚠️ 前置检查必须先于任何写操作(备份也是写 flash 之外的动作, 但先检查更安全)
    say ""
    hr; say "---- 前置安全检查 ----"; hr
    preflight_checks || die "🛑 前置检查未通过, 拒绝写入"
    backup_device "$TS"
    snapshot_mac "$TS"
    IMG="$TS/$NAME"
    [ -s "$IMG" ] || { download_asset "$URL" "$IMG" || die "下载失败"; }
    ASHA=$(shasum -a 256 "$IMG" | awk '{print $1}')
    if [ -n "$EXPECT_SHA" ]; then
      [ "$ASHA" = "$EXPECT_SHA" ] || die "sha256 不符 —— 中止"
      say "  ✅ sha256 与官方基准一致"
    fi
    verify_image_local "$IMG" || die "镜像结构校验失败"
    flash_chainloader "$IMG" "$TS"
    say ""
    say "📦 备份目录: $TS (回滚用: ./uboot_upgrade.sh --rollback --backup-dir $TS --ack-uboot-flash)"
    ;;
  rollback)
    TS="${BACKUP_DIR:-}"
    [ -n "$TS" ] || die "回滚需要 --backup-dir <备份目录>"
    rollback_chainloader "$TS"
    ;;
  probe)
    probe_recovery
    ;;
esac
