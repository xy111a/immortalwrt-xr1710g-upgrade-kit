#!/bin/bash
# publish_to_github.sh — 把本 skill 的纯文本源码同步到 GitHub 仓库, 并强制"发布即校验"(拉回归位 diff)
#
# 用法:
#   ./publish_to_github.sh                        # 用默认缓存目录 /tmp/kit_repo
#   GIT_WORK_DIR=/path/to/repo ./publish_to_github.sh
#
# 安全: 只同步白名单内的纯文本源码(SKILL.md + 脚本), 绝不触碰 *.itb / kit.tar.gz / backups/(均不入库)
# 校验: 推送后用 gh api 拉回每个文件的 blob 与本地逐字节(shasum)比对, 一致才算发布成功,
#       杜绝此前"macOS base64 误推空文件"类事故。
#
# 推送策略: 优先 git clone + commit + push(走 gh 通道绕过出网代理); 若 git push 失败,
#           自动回退到 gh api Contents API PUT(逐文件, 需先取现存 blob sha 做更新)。
set -u
REPO="xy111a/immortalwrt-xr1710g-upgrade-kit"
SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="${GIT_WORK_DIR:-/tmp/kit_repo}"
# 白名单: 仅这些纯文本源码入库; itb/kit.tar.gz/backups 永不入库
FILES="SKILL.md upgrade_router.sh build_kit.sh zzz-restore-router router_watch.sh publish_to_github.sh check_openclash.sh LICENSE README.md"

echo "=== 准备 Git 工作副本: $WORK ==="
if [ -d "$WORK/.git" ]; then
  env -u HTTP_PROXY -u HTTPS_PROXY git -C "$WORK" fetch --quiet origin 2>/dev/null || echo "⚠️ fetch 失败(可能离线), 用本地副本继续"
else
  rm -rf "$WORK"
  env -u HTTP_PROXY -u HTTPS_PROXY gh repo clone "$REPO" "$WORK" 2>&1 | tail -3 || { echo "❌ 克隆失败, 请检查网络/gh 登录"; exit 1; }
fi

echo "=== 复制源码文件到工作副本 ==="
for f in $FILES; do
  if [ -f "$SRC/$f" ]; then
    cp "$SRC/$f" "$WORK/$f" && echo "  ✓ $f ($(wc -c < "$SRC/$f") B)" || echo "  ❌ 复制失败: $f"
  else
    echo "  - 跳过(本地不存在): $f"
  fi
done

echo "=== 提交 ==="
env -u HTTP_PROXY -u HTTPS_PROXY git -C "$WORK" add -A
if env -u HTTP_PROXY -u HTTPS_PROXY git -C "$WORK" diff --cached --quiet 2>/dev/null; then
  echo "ℹ️ 无变更, 无需提交"
else
  env -u HTTP_PROXY -u HTTPS_PROXY git -C "$WORK" commit -m "chore: 阶段2/3 运维加固 (真实配置还原/固件级回退点/RC=2重试/日志持久化+结构化报告/发布即校验)" \
    && echo "✅ 已提交"
fi

echo "=== 推送 (绕过本地出网代理, 走 gh 通道) ==="
if env -u HTTP_PROXY -u HTTPS_PROXY git -C "$WORK" push origin main 2>&1 | tail -5; then
  echo "✅ git push 成功"
else
  echo "⚠️ git push 失败, 回退到 gh api PUT 逐文件发布..."
  for f in $FILES; do
    [ -f "$SRC/$f" ] || continue
    _b64=$(base64 -i "$SRC/$f" | tr -d '\n')
    _sha=$(gh api "repos/$REPO/contents/$f?ref=main" --jq '.sha' 2>/dev/null || true)
    _msg="chore: 同步 $f (发布即校验)"
    if [ -n "$_sha" ] && [ "$_sha" != "null" ]; then
      gh api -X PUT "repos/$REPO/contents/$f" -f message="$_msg" -f content="$_b64" -f sha="$_sha" >/dev/null 2>&1 \
        && echo "  ✓ PUT(更新) $f" || echo "  ❌ PUT 失败: $f"
    else
      gh api -X PUT "repos/$REPO/contents/$f" -f message="$_msg" -f content="$_b64" >/dev/null 2>&1 \
        && echo "  ✓ PUT(新建) $f" || echo "  ❌ PUT 失败: $f"
    fi
  done
fi

echo "=== 发布即校验: 拉回每个文件与本地逐字节(shasum)比对 ==="
MISS=0
for f in $FILES; do
  [ -f "$SRC/$f" ] || continue
  blob=$(gh api "repos/$REPO/contents/$f?ref=main" --jq '.content' 2>/dev/null)
  if [ -z "$blob" ]; then echo "  ❌ 拉取失败(空): $f"; MISS=1; continue; fi
  remote_sha=$(printf '%s' "$blob" | tr -d '\n' | base64 -d 2>/dev/null | shasum -a 256 | awk '{print $1}')
  local_sha=$(shasum -a 256 "$SRC/$f" | awk '{print $1}')
  if [ "$local_sha" = "$remote_sha" ]; then
    echo "  ✅ 一致: $f ($local_sha)"
  else
    echo "  ❌ 不一致: $f (本地 $local_sha / 远端 $remote_sha)"
    MISS=1
  fi
done
if [ "$MISS" = "1" ]; then
  echo "❌ 发布校验未通过, 请检查上述文件"
  exit 1
fi
echo "✅ 发布即校验全部通过: 远端文件与本地逐字节一致"
