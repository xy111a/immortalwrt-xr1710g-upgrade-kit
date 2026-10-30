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
  # 2026-10-30 新增: 订阅 URL 的 token 参数 —— 这是最容易被忽略的泄露形式。
  # 机场订阅链接长这样: https://<机场域名>/<path>?token=<32位hex>
  # 域名可能换、路径可能换, 但 token= 后面那段是长期有效的凭证。
  '[?&]token=[A-Za-z0-9]{16,}'
  'token=[a-f0-9]{32}'
  # 订阅主机 + 路径的完整形态(即使暂时没写 token, 主机+路径也等于半个凭证:
  # 拿到订阅主机路径后, token 往往可由机场用户面板/工单/社工推断出来)。
  # 用通用形态匹配, 不写死任何具体机场域名(写死会随机场更换而失效, 且等于公开其入口)。
  # 拆成几条精确规则而不是一个大正则 —— 大正则里前段 ".*" 会把关键词段吃掉导致漏匹配(2026-10-30 实测)。
  # ⚠️ 误伤权衡(2026-10-30 实测): 单独出现 "/subscribe" "/sub" 这种路径在正常文档站很常见,
  #   一律拦会误伤(如 https://my.site/subscribe)。因此这里只拦"订阅路径 + 凭证/query"的组合,
  #   纯路径形态交给上面 token= 规则去覆盖。
  'https?://[^ /]+/[^ ?]*(subscribe|sub|client/subscribe)[^ ]*[?&]token='   # 订阅路径 + token
  'https?://[^ /]+/(hnlf|ikfc|api/link|link|token)([/?][^ ]*)?'            # 机场自建短路径(该形态本身即凭证)
)
# ⚠️ 刻意不包含任何真实密码/WiFi key 的明文特征：
#   本仓库是公开的, 扫描规则里写明文特征=把密码本身公开(2026-10-28 审计发现, 已删除泄露条目)。
#   真实 root 密码/WiFi key 由 upgrade_router.sh 运行期从活路由器抓取注入临时 kit, 源码零明文,
#   因此"防止密码入库"靠的是"源码里根本没有密码" + .gitignore 排除 kit/backups, 不靠明文特征匹配。
# ⚠️ 同理不写"机场域名"的明文特征(那等于公开订阅服务商的入口域名),
#   但上面 token= 规则能拦住真正要命的部分 —— 订阅链接一旦带 token 等于把全部节点交出去。

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
