#!/bin/bash
# router_watch.sh — Gemtek XR1710G (naoki66 ImmortalWrt) 自动升级守护, Mac 侧运行
#
# 无人值守安全模型:
#   1. 开关文件 ~/.router_autoupgrade_enabled 存在才真正刷机; 否则只检测+备料, 不刷 (默认安全)
#   2. 新版本发布 < 72h 不刷 (等作者热修沉淀, 避开"发布当日炸机")
#   3. 独立校验: 下载官方 sha256sums, 比对 itb 真实 sha256 (防 GFW/中间人篡改)
#   4. 强终验失败 -> 自动回退到上一版本 (调用 upgrade_router.sh --auto)
#   5. 全程写日志 watch.log; 最坏情况依赖 U-Boot http_recovery 硬件兜底
#
# 用法:
#   router_watch.sh          # 自动模式: 检测+安全闸+必要时升级
#   router_watch.sh --force  # 跳过"发布满72h"闸, 立即升级 (手动测试新版本用)
#   router_watch.sh --check  # 只检测报告, 绝不升级 (默认无开关文件时等价)
#
# 建议由 launchd 每天 03:00 调用本脚本 (见 com.huajun.router-watch.plist)

set -u
REPO="naoki66/ImmortalWrt-for-Gemtek-XR1710G"
PREP_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$PREP_DIR/watch.log"
ENABLE_FILE="$HOME/.router_autoupgrade_enabled"
FORCE=0; CHECK_ONLY=0; NOW=0; ROUTER_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1;;
    --check) CHECK_ONLY=1;;
    --now)   NOW=1;;
    --router) ROUTER_OVERRIDE="${2:-}"; shift;;
    --router=*) ROUTER_OVERRIDE="${1#*=}";;
    *) ;;
  esac
  shift
done

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

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
    printf '请输入路由器的 SSH 地址 (如 root@192.168.1.1, 或 ssh config 中的主机别名): ' >&2
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
rel_tag=$(gh api "repos/$REPO/releases/latest" --jq '.tag_name' 2>/dev/null)
pub=$(gh api "repos/$REPO/releases/latest" --jq '.published_at' 2>/dev/null)
itb_url=$(gh api "repos/$REPO/releases/latest" --jq '[.assets[] | select(.name|test("gemtek_xr1710g")) | .browser_download_url][0]' 2>/dev/null)
sums_url=$(gh api "repos/$REPO/releases/latest" --jq '[.assets[] | select(.name=="sha256sums") | .browser_download_url][0]' 2>/dev/null)
[ -n "$rel_tag" ] || { log "❌ 无法获取 release (gh 未登录/限流/无网络?)"; exit 1; }
rel_hash=$(printf '%s' "$rel_tag" | grep -oE '[0-9a-f]{7,40}$')
log "最新 release: $rel_tag (发布 $pub)"

# ---------- 3. 比对 ----------
if [ "$cur_hash" = "$rel_hash" ]; then
  log "✅ 已是最新 ($cur_hash), 无需升级"
  exit 0
fi
log "🔔 发现新版本: $rel_tag (当前 $cur_hash)"

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
  curl -fL "$sums_url" -o "$PREP_DIR/sha256sums" || log "⚠️ sha256sums 下载失败, 跳过独立校验"
  expect=$(grep "$itb_name" "$PREP_DIR/sha256sums" 2>/dev/null | awk '{print $1}')
  if [ -n "$expect" ]; then
    act=$(shasum -a 256 "$local_itb" | awk '{print $1}')
    if [ "$expect" != "$act" ]; then
      log "❌ sha256 不匹配 (期望 $expect 实得 $act) — 中止, 可能下载被篡改/损坏"
      rm -f "$local_itb"
      exit 1
    fi
    log "✅ itb 独立 sha256 校验通过 ($expect)"
  else
    log "⚠️ sha256sums 中未找到 $itb_name 的校验行, 跳过独立校验 (仍依赖路由器侧复核)"
  fi
fi

# ---------- 6. (已移除) EXPECT_SHA/FW_NEW 同步 -----
# upgrade_router.sh 现在运行时自行从官方 sha256sums 派生 EXPECT_SHA, 无需此处 sed 改写脚本文件;
# 本步骤保持只读, 不再修改任何源码(避免 --check 产生副作用)。

# ---------- 7. 是否真正刷机 ----------
if [ "$CHECK_ONLY" = "1" ]; then
  log "CHECK_ONLY: 已备好 itb+校验, 未触发刷机"
  exit 0
fi
if [ "$FORCE" = "0" ] && [ "$NOW" = "0" ] && [ ! -f "$ENABLE_FILE" ]; then
  log "⏸ 自动刷机未授权 (需 --now 或创建 $ENABLE_FILE); 已备好物料, 待你授权"
  exit 0
fi

# ---------- 8. 触发升级 (--auto: 强终验失败自动回退) ----------
log "🚀 触发升级 (--auto)"
"$PREP_DIR/upgrade_router.sh" --auto ${FORCE:+--force} --router "$ROUTER"
log "=== watch 流程结束 ==="
