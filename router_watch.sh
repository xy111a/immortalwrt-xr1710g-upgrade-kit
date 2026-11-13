#!/bin/bash
# router_watch.sh — Gemtek XR1710G (naoki66 ImmortalWrt) 自动升级守护, Mac 侧运行
#
# 无人值守安全模型:
#   1. 开关文件 ~/.router_autoupgrade_enabled 存在才真正刷机; 否则只检测+备料, 不刷 (默认安全)
#   2. 新版本发布 < 72h 不刷 (等作者热修沉淀, 避开"发布当日炸机")
#   3. 独立校验: 官方 sha256sums 优先, 缺失时用 GitHub asset.digest 兜底, 两者皆无即拒绝
#   3b. 测试版 / wipe-config release 识别闸: 命中即停止备料与刷机 (2026-11-12 新增)
#   4. 强终验失败 -> 自动回退到上一版本 (调用 upgrade_router.sh --auto)
#   5. 全程写日志 watch.log; 最坏情况依赖 U-Boot http_recovery 硬件兜底
#      (当前 U-Boot 恢复页 192.168.255.1; 刷入 11-11 chainloader 后变为 192.168.0.1)
#
# 用法:
#   router_watch.sh          # 自动模式: 检测+安全闸+必要时升级
#   router_watch.sh --force  # 仅跳过"发布满72h"闸 (2026-11-04: 不再关闭 sha256 校验)
#   router_watch.sh --check  # 检测+备料(会下载 itb、写 sha256sums、追加 watch.log), 绝不升级
#   router_watch.sh --no-download  # 纯只读: 只检测报告, 零下载/零文件写入 (定时巡检推荐)
#   router_watch.sh --allow-test-build  # 显式放行测试版/wipe-config release (默认拒绝, 自担风险)
#
# 可由 launchd / WorkBuddy 定时自动化按需调用（本仓库不含 plist, 按需自行配置调度）

set -u
REPO="naoki66/ImmortalWrt-for-Gemtek-brightspeed"
PREP_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$PREP_DIR/watch.log"
ENABLE_FILE="$HOME/.router_autoupgrade_enabled"
FORCE=0; CHECK_ONLY=0; NOW=0; ROUTER_OVERRIDE=""; ALLOW_TEST_BUILD=0; NO_DOWNLOAD=0; LOG_TO_FILE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1;;
    --check) CHECK_ONLY=1;;
    --now)   NOW=1;;
    --allow-test-build) ALLOW_TEST_BUILD=1;;
    --no-download) NO_DOWNLOAD=1; CHECK_ONLY=1; LOG_TO_FILE=0;;
    --router) ROUTER_OVERRIDE="${2:-}"; shift;;
    --router=*) ROUTER_OVERRIDE="${1#*=}";;
    *) ;;
  esac
  shift
done

log(){
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  # --no-download 是零副作用模式: 只打印, 不写 watch.log
  if [ "${LOG_TO_FILE:-1}" = "1" ]; then printf '%s\n' "$line" | tee -a "$LOG"; else printf '%s\n' "$line"; fi
}

# 日志轮转(2026-11-13): 长期 launchd 调用会让 watch.log 无限增长。超过 5000 行就地截断
# 保留最近 2000 行, 不生成额外文件(避免又要改 .gitignore)。零副作用模式下完全不动日志。
rotate_log(){
  [ -f "$LOG" ] || return 0
  local n
  n=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  if [ "${n:-0}" -gt 5000 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    echo "ℹ️ watch.log 已轮转: ${n} 行 -> 最近 2000 行"
  fi
}
[ "${LOG_TO_FILE:-1}" = "1" ] && rotate_log

# 解析路由器 SSH 目标 (不写死个人别名/IP):
#   环境变量 ROUTER > --router 参数 > 本地 router-target.conf(git 忽略) > 自动探测 ~/.ssh/config > 交互询问(持久化)
ROUTER="${ROUTER_OVERRIDE:-}"
if [ -z "$ROUTER" ] && [ -f "$PREP_DIR/router-target.conf" ]; then
  ROUTER="$(cat "$PREP_DIR/router-target.conf" 2>/dev/null)"
fi
if [ -z "$ROUTER" ] && [ -f "$HOME/.ssh/config" ] && command -v awk >/dev/null 2>&1; then
  ROUTER=$(awk '/^[Hh]ost /{h=$2} {l=tolower($0)} (l ~ /openwrt/||l ~ /immortalwrt/||l ~ /router/) && h{print h; exit}' "$HOME/.ssh/config" 2>/dev/null)
fi
if [ -z "$ROUTER" ]; then
  if [ -t 0 ]; then
    printf '请输入路由器的 SSH 地址 (如 root@192.168.50.1 [XR1710G 出厂默认], 或 ssh config 中的主机别名): ' >&2
    read -r ROUTER </dev/tty 2>/dev/null
    [ -n "$ROUTER" ] && printf '%s\n' "$ROUTER" > "$PREP_DIR/router-target.conf" 2>/dev/null
  else
    log "❌ 非交互环境且未配置路由器 SSH 地址 (用 --router 或 ROUTER 环境变量, 或预先创建 router-target.conf)"; exit 1
  fi
fi
[ -n "$ROUTER" ] || { log "❌ 未配置路由器 SSH 地址 (用 --router 或 ROUTER 环境变量指定)"; exit 1; }

# ---------- 1. 路由器当前版本 commit ----------
cur_rev=$(ssh -o ConnectTimeout=8 "$ROUTER" 'grep DISTRIB_REVISION /etc/openwrt_release' 2>/dev/null)
cur_hash=$(printf '%s' "$cur_rev" | grep -oE '[0-9a-f]{7,40}' | tail -1)
[ -n "$cur_hash" ] || { log "❌ 无法读取路由器当前版本 (SSH 不可达?)"; exit 1; }
log "当前固件 commit: $cur_hash"

# ---------- 2. 最新 release ----------
# 上游把 XG2010G 机型 build 设为 GitHub "Latest", releases/latest 不含 XR1710G 固件;
# 故遍历全部 releases(默认按时间倒序), 取首个含 gemtek_xr1710g itb 的 release, 单次 gh 调用取齐四字段(TSV)
# (gojq 子集不支持 any(.name; test()), 改用 any(.assets[]; .name|test()) 存在量词写法)
# 2026-11-04: 增加第 5 字段 asset.digest。上游 1029 release 没附 sha256sums, 但 GitHub API
#   自带官方 asset digest, 可作同等强度的独立校验基准, 避免"无 sums 就静默跳过校验"。
REL_TSV=""
for _try in 1 2 3; do
  REL_TSV=$(gh api "repos/$REPO/releases?per_page=100" --jq '[.[] | select(any(.assets[]; .name|test("gemtek_xr1710g")))] | sort_by(.published_at) | reverse | .[0] | [.tag_name, .published_at, (.assets | map(select(.name|test("gemtek_xr1710g"))) | .[0].browser_download_url), (.assets | map(select(.name=="sha256sums")) | .[0].browser_download_url // "NONE"), (.assets | map(select(.name|test("gemtek_xr1710g"))) | .[0].digest // "NONE"), (if .prerelease then "PRERELEASE" elif ((.body // "") | test("wipe-config|不保留配置|测试固件|测试版")) then "TEST" else "OK" end)] | @tsv' 2>/dev/null)
  [ -n "$REL_TSV" ] && break
  sleep 2
done
[ -n "$REL_TSV" ] || { log "❌ 未找到含 XR1710G 固件的 release (仓库改名/上游未发布 XR1710G build/网络异常)"; exit 1; }
# ⚠️ bash 的 read 把 tab 视为 IFS 空白, 会折叠连续分隔符 —— 1029 release 缺 sha256sums
#   (第 4 字段为空) 时字段会整体左移, digest 被误读进 sums_url。故 jq 用 NONE 占位再归一化。
IFS=$'\t' read -r rel_tag pub itb_url sums_url itb_digest rel_flags <<< "$REL_TSV"
[ "$sums_url" = "NONE" ] && sums_url=""
[ "$itb_digest" = "NONE" ] && itb_digest=""
[ -z "${rel_flags:-}" ] && rel_flags="UNKNOWN"
[ -n "$rel_tag" ] || { log "❌ 无法获取 release (gh 未登录/限流/无网络?)"; exit 1; }
# 2026-11-12 修复: 旧逻辑从 tag 尾部取 commit, 但纯日期 tag(20261112)会被误当成 hash,
#   且路由器 DISTRIB_REVISION 的 commit 是 10 位而镜像文件名是 8 位 -> "已是最新"永不命中。
#   改为从 itb 下载 URL 的文件名提取 8 位 commit, 与运行版本前 8 位比对。
rel_hash=$(printf '%s' "$(basename "$itb_url")" | grep -oE '[0-9]{6,8}-[0-9a-f]{7,40}' | head -1 | cut -d- -f2 | cut -c1-8)
cur_hash8=$(printf '%s' "$cur_hash" | cut -c1-8)
# 2026-11-13: 与 upgrade_router.sh 一致的客观信号, 不依赖发布说明措辞。
# 20261112 标签挂 20261111 镜像 -> 日期错配; 上游若改写英文 beta 而关键字漏判, 这条仍可兜住。
tag_date=$(printf '%s' "$rel_tag" | grep -oE '20[0-9]{6}' | head -1)
img_date=$(printf '%s' "$(basename "$itb_url")" | grep -oE '20[0-9]{6}' | head -1)
if [ -n "$tag_date" ] && [ -n "$img_date" ] && [ "$tag_date" != "$img_date" ]; then
  if [ "$rel_flags" = "OK" ]; then rel_flags="TAG-DATE-MISMATCH"; else rel_flags="${rel_flags}+TAG-DATE-MISMATCH"; fi
fi
log "最新 release: $rel_tag (发布 $pub), 镜像 commit: ${rel_hash:-未知}, 性质标记: ${rel_flags:-UNKNOWN}"

# ---------- 3. 比对 ----------
if [ -n "$rel_hash" ] && [ "$cur_hash8" = "$rel_hash" ]; then
  log "✅ 已是最新 ($cur_hash8), 无需升级"
  exit 0
fi
log "🔔 发现新版本: $rel_tag (当前 $cur_hash8 -> 目标 ${rel_hash:-未知})"

# ---------- 3b. 安全闸: 测试版 / wipe-config release (2026-11-12 新增) ----------
# 20261112 正文写"本次为测试固件""本次升级默认打开测试不保留配置建议""OTA: wipe-config",
# 但 prerelease=false, 光看 tag/元数据看不出来。测试版会清空配置, 且 kit 必须重建,
# 自动升级守护绝不能拿它当正式版刷。默认在此停止(不下载镜像、不触发升级)。
if [ "${rel_flags:-OK}" != "OK" ] && [ "${rel_flags:-OK}" != "UNKNOWN" ] && [ "$ALLOW_TEST_BUILD" = "0" ]; then
  log "🛑 最新 release [$rel_tag] 被识别为测试版/预发布/wipe-config (标记 $rel_flags), 自动升级已停止"
  log "   原因: 该版本默认不保留配置, 会清空 OpenClash 规则与自定义钩子; 且内核/预装包大变时 kit 必须重建"
  log "   处置: 等正式版, 或人工核对后走 upgrade_router.sh --allow-test-build / 本脚本 --allow-test-build 自担风险"
  exit 0
fi
if [ "${rel_flags:-OK}" = "UNKNOWN" ]; then
  log "⚠️ 无法判定 release 性质(标记 UNKNOWN), 请人工核对 $rel_tag 的发布说明"
fi

# ---------- 4. 安全闸: 发布满 72h ----------
if [ "$FORCE" = "0" ]; then
  # macOS BSD date 不认 ISO "Z" 后缀为 UTC, 会当成本地时间导致闸值虚高 8h; 转成 +0000 用 %z 解析
  pub_utc="${pub/Z/+0000}"
  pub_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$pub_utc" +%s 2>/dev/null)
  now_epoch=$(date +%s)
  if [ -n "$pub_epoch" ]; then
    age=$(( (now_epoch - pub_epoch) / 3600 ))
    if [ "$age" -lt 72 ]; then
      log "⏸ 安全闸: 发布仅 ${age}h (<72h), 暂不自动升级, 等版本沉淀 (用 --force 可强制跳过)"
      exit 0
    fi
  fi
fi

# ---------- 4b. 纯只读检测出口(2026-11-13 新增) ----------
# --check 历史上会真下载 itb / 写 sha256sums / 追加 watch.log, 与"纯只读"的措辞不符。
# --no-download 明确零副作用: 只报告 release 与各闸判定, 不落任何文件。
if [ "$NO_DOWNLOAD" = "1" ]; then
  log "NO_DOWNLOAD: 仅检测报告(零下载 / 零文件写入), 未备料、未刷机"
  exit 0
fi

# ---------- 5. 下载 itb + 独立 sha256 校验 ----------
[ -n "$itb_url" ] || { log "❌ 未找到 itb 下载地址"; exit 1; }
itb_name=$(basename "$itb_url")
local_itb="$PREP_DIR/$itb_name"
if [ -f "$local_itb" ]; then
  log "itb 已存在: $itb_name (跳过下载)"
else
  log "下载 itb: $itb_name"
  curl -fL "$itb_url" -o "$local_itb" || { log "❌ 下载失败"; exit 1; }
fi
expect=""
if [ -n "$sums_url" ]; then
  if curl -fL "$sums_url" -o "$PREP_DIR/sha256sums" 2>/dev/null; then
    expect=$(grep -F "$itb_name" "$PREP_DIR/sha256sums" 2>/dev/null | awk '{print $1}' | head -1)
    [ -z "$expect" ] && log "⚠️ sha256sums 中无 $itb_name 的校验行, 转用 GitHub asset digest"
  else
    log "⚠️ sha256sums 下载失败, 转用 GitHub 官方 asset digest"
  fi
fi
# 2026-11-04 修复: 旧逻辑在 sums_url 为空时整段跳过独立校验(静默降级)。现用 GitHub 官方
#   asset.digest 兜底; 两者都拿不到则 fail-closed, 绝不在无外部基准的情况下放行刷机。
if [ -z "$expect" ] && [ -n "${itb_digest:-}" ]; then
  expect="${itb_digest#sha256:}"
  log "ℹ️ 该 release 无 sha256sums, 改用 GitHub 官方 asset digest 作独立基准"
fi
act=$(shasum -a 256 "$local_itb" | awk '{print $1}')
if [ -z "$expect" ]; then
  log "❌ 拿不到任何官方 sha256 基准(无 sha256sums 且无 asset digest), 拒绝备料/升级"
  rm -f "$local_itb"
  exit 1
elif [ "$expect" != "$act" ]; then
  log "❌ sha256 不匹配 (官方基准 $expect 实得 $act) — 中止, 可能下载被篡改/损坏"
  rm -f "$local_itb"
  exit 1
else
  log "✅ itb 独立 sha256 校验通过 ($expect)"
fi

# ---------- 6. (已移除) EXPECT_SHA/FW_NEW 同步 -----
# upgrade_router.sh 现在运行时自行从官方 sha256sums 派生 EXPECT_SHA, 无需此处 sed 改写脚本文件;
# 本步骤保持只读, 不再修改任何源码(避免 --check 产生副作用)。

# ---------- 7. 是否真正刷机 ----------
if [ "$CHECK_ONLY" = "1" ]; then
  log "CHECK_ONLY: 已备好 itb+校验, 未触发刷机 (本模式仍会下载镜像/写日志; 零副作用请用 --no-download)"
  exit 0
fi
if [ "$FORCE" = "0" ] && [ "$NOW" = "0" ] && [ ! -f "$ENABLE_FILE" ]; then
  log "⏸ 自动刷机未授权 (需 --now 或创建 $ENABLE_FILE); 已备好物料, 待你授权"
  exit 0
fi

# ---------- 8. 触发升级 (--auto: 强终验失败自动回退) ----------
log "🚀 触发升级 (--auto)"
# --force 语义已窄化为"仅跳 72h 沉淀闸"; upgrade_router.sh 的 sha256 完整性校验始终生效。
# 2026-11-12 修复: 旧写法 ${FORCE:+--force} 中 FORCE=0 是"非空字符串", 会恒展开成 --force,
#   导致 --now 常规升级也把 upgrade_router.sh 的沉淀闸一并跳过。改为按值判断组装参数数组。
UPG_ARGS=(--auto --router "$ROUTER")
if [ "$FORCE" = "1" ]; then UPG_ARGS[${#UPG_ARGS[@]}]="--force"; fi
if [ "$ALLOW_TEST_BUILD" = "1" ]; then UPG_ARGS[${#UPG_ARGS[@]}]="--allow-test-build"; fi
"$PREP_DIR/upgrade_router.sh" "${UPG_ARGS[@]}"
log "=== watch 流程结束 ==="
