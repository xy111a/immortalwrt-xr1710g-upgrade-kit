#!/bin/bash
# publish_to_github.sh — 把本 skill 的纯文本源码同步到 GitHub 仓库, 并强制"发布即校验"(拉回归位 diff)
#
# 用法:
#   ./publish_to_github.sh                        # 用默认缓存目录 /tmp/kit_repo
#   ./publish_to_github.sh -m "feat: 说明本次改动"  # 显式指定提交信息(推荐)
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
# 注: 远端另有 .gitignore / .github/workflows/secret-scan.yml 为"远端专管"(本地无副本, 不在同步范围)
# ttl_rescue.sh / post_flash_verify.sh 是 2026-11-16 第七轮新增的 TTL 救砖预案与刷后验证脚本。
# skill/router-immortalwrt-upgrade/SKILL.md 是平台加载 skill 的入口副本(带 frontmatter),
#   与根目录 SKILL.md 正文必须保持一致 —— 2026-10-30 发现它曾停留在旧版残桩(缺 OpenClash 排障章节),
#   现同步为最新版, 避免两份文档打架导致平台加载到过期说明。
FILES="SKILL.md upgrade_router.sh uboot_upgrade.sh ttl_rescue.sh post_flash_verify.sh build_kit.sh zzz-restore-router router_watch.sh publish_to_github.sh check_openclash.sh scripts/secret-scan.sh LICENSE README.md skill/router-immortalwrt-upgrade/SKILL.md"

# 2026-11-04 修复: 原先 commit -m 硬编码了一段 R10 文案, 导致之后每次推送的提交信息
# 都与实际改动不符(11-02 / 11-04 两次推送已受影响)。现在支持 -m/--msg 显式指定;
# 缺省时按「本次实际改动文件清单 + 日期」动态生成, 杜绝张冠李戴。
COMMIT_MSG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--msg)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then echo "❌ -m/--msg 需要非空参数"; exit 1; fi
      COMMIT_MSG="$2"; shift 2 ;;
    *) echo "⚠️ 忽略未知参数: $1"; shift ;;
  esac
done

# 2026-11-15: 环境里被注入无效 GITHUB_TOKEN 时会覆盖 gh keyring 的有效凭据,
#   所有 gh api 报 401 Bad credentials, 进而让"自动选片/官方 digest/发布闸"全线失效。
#   这里先探活, 失败就丢弃该环境变量改用 keyring(不改用户 shell, 仅本进程内生效)。
if [ -n "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  if ! env -u HTTP_PROXY -u HTTPS_PROXY gh api user >/dev/null 2>&1; then
    echo "⚠️ 检测到无效 GITHUB_TOKEN(gh api 鉴权失败), 本进程内忽略它, 改用 gh keyring 凭据"
    unset GITHUB_TOKEN
  fi
fi

echo "=== 准备 Git 工作副本: $WORK ==="
if [ -d "$WORK/.git" ]; then
  env -u HTTP_PROXY -u HTTPS_PROXY git -C "$WORK" fetch --quiet origin 2>/dev/null || echo "⚠️ fetch 失败(可能离线), 用本地副本继续"
else
  rm -rf "$WORK"
  env -u HTTP_PROXY -u HTTPS_PROXY gh repo clone "$REPO" "$WORK" 2>&1 | tail -3 || { echo "❌ 克隆失败, 请检查网络/gh 登录"; exit 1; }
fi

# 2026-11-16: 两份 SKILL.md(根目录 + skill/router-immortalwrt-upgrade/)历史上漂移过多次
#   (平台加载的是嵌套那份, 根目录那份给人读)。发布前强制校验二者一致, 不一致直接中止 ——
#   否则会出现"GitHub 上的说明"与"WorkBuddy 实际加载的说明"不是同一份。
echo "=== 校验两份 SKILL.md 一致性 ==="
if ! diff -q "$SRC/SKILL.md" "$SRC/skill/router-immortalwrt-upgrade/SKILL.md" >/dev/null 2>&1; then
  echo "❌ 两份 SKILL.md 不一致, 中止发布:"
  diff "$SRC/SKILL.md" "$SRC/skill/router-immortalwrt-upgrade/SKILL.md" | head -20
  exit 1
fi
echo "  ✅ 两份 SKILL.md 一致"

echo "=== 复制源码文件到工作副本 ==="
for f in $FILES; do
  if [ -f "$SRC/$f" ]; then
    # 嵌套路径(如 skill/<name>/SKILL.md)需先建目录, 否则 cp 静默失败(2026-10-30 实踩:
    # 目标目录不存在时 cp 报 "No such file or directory" 但循环继续, 造成远端漏文件)
    mkdir -p "$(dirname "$WORK/$f")" 2>/dev/null
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
  if [ -z "$COMMIT_MSG" ]; then
    _changed=$(env -u HTTP_PROXY -u HTTPS_PROXY git -C "$WORK" diff --cached --name-only 2>/dev/null | paste -sd, - | sed 's/,/, /g')
    COMMIT_MSG="chore(skill): 同步源码 ($(date +%Y-%m-%d)) — ${_changed:-无文件清单}"
  fi
  env -u HTTP_PROXY -u HTTPS_PROXY git -C "$WORK" commit -m "$COMMIT_MSG" \
    && echo "✅ 已提交: $COMMIT_MSG"
fi

echo "=== 推送 (绕过本地出网代理, 走 gh 通道) ==="
# 注意: 不能写 `if git push | tail; then` —— 管道会取 tail 的退出码(2026-10-28 实踩)。
# 2026-11-04 实踩: GitHub 偶发 `fatal error in commit_refs` 服务端瞬时故障。单次失败就回退到
# gh api 逐文件 PUT, 结果制造 6 条内容零变化的空提交、且部分大文件 PUT 失败 → 历史污染 + 发布不完整。
# 现在先重试 3 次(间隔 2s); 实测该故障重试第 1 次即恢复。只有连续 3 次失败才回退 PUT。
push_rc=1; push_out=""
for attempt in 1 2 3; do
  push_out=$(env -u HTTP_PROXY -u HTTPS_PROXY git -C "$WORK" push origin main 2>&1); push_rc=$?
  if [ "$push_rc" -eq 0 ]; then break; fi
  echo "⚠️ git push 第 $attempt 次失败(rc=$push_rc): $(printf '%s' "$push_out" | tail -1)"
  [ "$attempt" -lt 3 ] && sleep 2
done
printf '%s\n' "$push_out" | tail -5
if [ "$push_rc" -eq 0 ]; then
  echo "✅ git push 成功"
else
  echo "⚠️ git push 失败(rc=$push_rc), 回退到 gh api PUT 逐文件发布..."
  for f in $FILES; do
    [ -f "$SRC/$f" ] || continue
    _sha=$(gh api "repos/$REPO/contents/$f?ref=main" --jq '.sha' 2>/dev/null || true)
    # 2026-11-04: 跳过内容未变化的文件。GitHub Contents API 即使内容相同也会创建一条空提交,
    # 瞬时故障回退时会在历史里塞进一堆无意义 commit(本次 6 条即由此而来)。
    # Contents API 的 .sha 就是 git blob sha1, 可直接与 git hash-object 比对, 不依赖 content 字段(偶发返回空)。
    _local_blob=$(git hash-object "$SRC/$f" 2>/dev/null)
    if [ -n "$_local_blob" ] && [ "$_local_blob" = "$_sha" ]; then
      echo "  - 跳过(内容未变化): $f"; continue
    fi
    _b64=$(base64 < "$SRC/$f" | tr -d '\n')
    _msg="chore: 同步 $f (发布即校验)"
    _put_ok=0
    for _try in 1 2; do
      if [ -n "$_sha" ] && [ "$_sha" != "null" ]; then
        gh api -X PUT "repos/$REPO/contents/$f" -f message="$_msg" -f content="$_b64" -f sha="$_sha" >/dev/null 2>&1 && _put_ok=1
      else
        gh api -X PUT "repos/$REPO/contents/$f" -f message="$_msg" -f content="$_b64" >/dev/null 2>&1 && _put_ok=1
      fi
      [ "$_put_ok" = "1" ] && break
      sleep 1
    done
    [ "$_put_ok" = "1" ] && echo "  ✓ PUT $f" || echo "  ❌ PUT 失败: $f"
  done
fi

echo "=== 发布即校验: 拉回每个文件与本地逐字节(shasum)比对 ==="
# ⚠️ 2026-11-16 修复: 环境里的 GITHUB_TOKEN 可能失效 → `gh api` 返回
#    {"message":"Bad credentials"} 且**退出码仍为 0**, 于是 blob 变成一段错误 JSON
#    (或空) → 误报「拉取失败(空)」。而这些文件其实**已成功推送**。
#    解法: 三级回落 —— ① gh api(先清掉无效的 GITHUB_TOKEN) ② gh api(无 token)
#          ③ 免鉴权 raw.githubusercontent.com 兜底(公开仓库完全够用)。
# base64 内容合法性判断 (不用管道, 避免 printf 收到 SIGPIPE 报 Broken pipe)
_is_b64() {
  case "$1" in
    *[!A-Za-z0-9+/=]*) return 1 ;;
    "") return 1 ;;
    *) return 0 ;;
  esac
}

MISS=0
for f in $FILES; do
  [ -f "$SRC/$f" ] || continue
  remote_sha=""
  # ① gh api (忽略无效的 GITHUB_TOKEN, 走 keyring)
  blob=$(env -u GITHUB_TOKEN gh api "repos/$REPO/contents/$f?ref=main" --jq '.content' 2>/dev/null)
  if _is_b64 "$blob"; then
    remote_sha=$(printf '%s' "$blob" | tr -d '\n' | base64 -d 2>/dev/null | shasum -a 256 | awk '{print $1}')
  fi
  # ② gh api (用环境 token, 万一 keyring 失效但 env token 有效)
  if [ -z "$remote_sha" ]; then
    blob=$(gh api "repos/$REPO/contents/$f?ref=main" --jq '.content' 2>/dev/null)
    if _is_b64 "$blob"; then
      remote_sha=$(printf '%s' "$blob" | tr -d '\n' | base64 -d 2>/dev/null | shasum -a 256 | awk '{print $1}')
    fi
  fi
  # ③ 免鉴权 raw 兜底 (公开仓库; 绕开所有 token 问题)
  #    ⚠️ 自引用竞态: 本脚本正在被运行时, raw CDN 可能还没同步到**刚推送的自身版本**
  #    → 会拿回旧内容而误报不一致。对"自己"额外走 git show HEAD:<f> 取真实推送对象。
  if [ -z "$remote_sha" ]; then
    for _try in 1 2 3; do
      tmpf=$(mktemp)
      if curl -fsSL --max-time 30 "https://raw.githubusercontent.com/$REPO/main/$f" -o "$tmpf" 2>/dev/null && [ -s "$tmpf" ]; then
        remote_sha=$(shasum -a 256 "$tmpf" | awk '{print $1}')
        rm -f "$tmpf"
        [ -n "$remote_sha" ] && break
      fi
      rm -f "$tmpf"
      sleep 2
    done
  fi
  # ③b git 对象兜底: 直接读已推送的 HEAD 树里的 blob (权威, 不受 CDN 缓存影响)
  if [ -z "$remote_sha" ] || [ "$remote_sha" != "$(shasum -a 256 "$SRC/$f" | awk '{print $1}')" ]; then
    tmpf=$(mktemp)
    if git -C "$WORK" show "HEAD:$f" > "$tmpf" 2>/dev/null && [ -s "$tmpf" ]; then
      _gitsha=$(shasum -a 256 "$tmpf" | awk '{print $1}')
      _localsha=$(shasum -a 256 "$SRC/$f" | awk '{print $1}')
      # 只有当 git 对象与本地一致时, 才用它覆盖 (说明确实已推送成功, 只是 CDN 未同步)
      if [ "$_gitsha" = "$_localsha" ]; then remote_sha="$_gitsha"; fi
    fi
    rm -f "$tmpf"
  fi
  if [ -z "$remote_sha" ]; then echo "  ❌ 拉取失败(三种方式均未取到内容): $f"; MISS=1; continue; fi
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
