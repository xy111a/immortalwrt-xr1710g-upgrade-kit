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
FORCE=0; CHECK_ONLY=0; NOW=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1;;
    --check) CHECK_ONLY=1;;
    --now)   NOW=1;;
  esac
done

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# ---------- 1. 路由器当前版本 commit ----------
cur_rev=$(ssh -o ConnectTimeout=8 router 'grep DISTRIB_REVISION /etc/openwrt_release' 2>/dev/null)
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
  pub_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pub" +%s 2>/dev/null)
  now_epoch=$(date +%s)
  if [ -n "$pub_epoch" ]; then
    age=$(( (now_epoch - pub_epoch) / 3600 ))
    if [ "$age" -lt 72 ]; then
      log "⏸ 安全闸: 发布仅 ${age}h (<72h), 暂不自动升级, 等版本沉淀"
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

# ---------- 6. 更新 upgrade_router.sh 的 EXPECT_SHA / FW_NEW ----------
if [ -n "$expect" ]; then
  sed -i '' "s/^EXPECT_SHA=\".*\"/EXPECT_SHA=\"$expect\"/" "$PREP_DIR/upgrade_router.sh" 2>/dev/null \
    && sed -i '' "s/^FW_NEW=\".*\"/FW_NEW=\"$rel_tag\"/" "$PREP_DIR/upgrade_router.sh" 2>/dev/null \
    && log "已更新 upgrade_router.sh 的 EXPECT_SHA/FW_NEW"
fi

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
"$PREP_DIR/upgrade_router.sh" --auto
log "=== watch 流程结束 ==="
