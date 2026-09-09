#!/bin/bash
# secret-scan.sh — 提交前/CI 自动密钥扫描
#
# 把"切勿把 kit / 订阅 / 密码提交进 Git"这条人工提醒变成代码强制:
# 任何敏感内容想进仓库都会被本脚本拦截 (退出码非 0)。
#
# 用法:
#   ./scripts/secret-scan.sh            # 扫描当前仓库内所有将被 git 跟踪的文件
#   ./scripts/secret-scan.sh <path>...  # 扫描指定文件/目录
#
# 设计: 只扫描"会进 Git"的文件 (git ls-files), 因此 kit.tar.gz / *.itb / backups/ 等
#       已被 .gitignore 排除的内容不会被误报; 本脚本自身也会被跳过。源码本身应全部通过。
#
# 兼容: 不依赖 mapfile (macOS 自带 bash 3.2 无此内建), 用 while-read 收集。
set -u

SELF="scripts/secret-scan.sh"

# 匹配规则 (ERE, 大小写不敏感)
PATTERNS=(
  'BEGIN [A-Z ]*PRIVATE KEY'        # 私钥
  'vmess://' 'vless://' 'trojan://' 'ss://'   # 代理订阅
  'gh[pousr]_[A-Za-z0-9]{36,}'      # GitHub token
  'sk-[A-Za-z0-9]{20,}'             # OpenAI / 各类 sk- token
  'xox[baprs]-[A-Za-z0-9-]{10,}'    # Slack token
  'AKIA[0-9A-Z]{16}'                # AWS access key
  'ROOT_PW='                         # 硬编码 root 密码
  "password=['\"][^'\"]{3,}"         # password='...'
  'Huajun#|123789123'               # 本项目历史明文密码 (Huajun# 带 # 才是密码, 不误伤命名/用户名)
)

# 收集待扫描文件
if [ $# -gt 0 ]; then
  # 指定路径模式: 递归展开为文件清单
  FILES=$(find "$@" -type f 2>/dev/null)
else
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    FILES=$(git ls-files)
  else
    FILES=$(find . -type f -not -path './.git/*')
  fi
fi

hits=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # 跳过自身 / 二进制
  case "$f" in
    *secret-scan.sh) continue;;
    *.png|*.jpg|*.itb|*.tar.gz) continue;;
  esac
  [ -f "$f" ] || continue
  for p in "${PATTERNS[@]}"; do
    if grep -qiE "$p" -- "$f" 2>/dev/null; then
      echo "  命中敏感模式 [$p] -> $f"
      grep -niE "$p" -- "$f" 2>/dev/null | sed 's/^/      /' | head -3
      hits=$((hits+1))
    fi
  done
done <<< "$FILES"

if [ "$hits" -gt 0 ]; then
  echo ""
  echo "发现 $hits 处疑似敏感信息, 已阻止。请移除后再提交。"
  exit 1
fi
echo "密钥扫描通过: 未命中任何敏感模式。"
exit 0
