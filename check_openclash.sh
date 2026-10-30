#!/usr/bin/env bash
# check_openclash.sh — 路由器 OpenClash 健康诊断(Mac 侧)
# 用途: 升级后或日常排查时, 一次性确认 OpenClash 是否真的在承载上网。
#
# ⚠️ 为什么需要它(7 个曾踩过的诊断坑, 别再犯):
#   1. 控制器 secret 在 clash 实际加载的配置文件(即 clash 进程 `-f <file>` 所指), 不是生成的 /etc/openclash/config.yaml。
#      抓错文件 → 控制器鉴权失败 → 返回 0 节点 → 误判"没节点"。
#   2. mixed 端口(7890/7893 等)需要认证: `curl -x http://127.0.0.1:7890` 会返回 407 Proxy Authentication Required,
#      这不是节点故障! 用户设备走的是透明重定向(TPROXY/REDIRECT)进代理, 那条路不需要认证, 上网不受影响。
#      所以**绝不要用 `curl -x` 来判断代理通不通**。
#   3. fake-ip 模式下, 经 7874 解析任意域名都返回 198.18.0.0/16 的假 IP, 不能据此判断真实服务器可达。
#   4. 2026-10-30: 机场入口域名的**旧 IP 被封**, clash 缓存了旧 IP -> 所有节点
#      全部 `dial tcp <ip>:58777: i/o timeout`, 但 DNS 解析看起来完全正常, 极易误判成"节点坏了/订阅过期"。
#      判定法见第 8 节: 必须真实 TCP 握手节点端口, 不能只看 DNS。
#   5. 2026-10-30: BusyBox `nc` **不支持 -z** 参数(报 Usage), 一切基于 `nc -z` 的探测都是假阴性;
#      `/dev/tcp` 需 bash(路由器有 /bin/bash)。更坑的是: 从路由器 shell 直连会被 nft
#      `redirect to :7892` 劫持, **测的是本地 clash 端口而非远端服务器** —— 必须先插 nft 豁免规则
#      (`nft insert rule inet fw4 openclash_output ip daddr <IP> return`) 才能测到真实路径, 测完记得删。
#   6. 2026-10-30: OpenClash 的 `openclash_custom_overwrite.sh` 里 ruby_edit 的 hash 参数必须是
#      **合法 Ruby 源码**(用 `=>` 而非 YAML 的 `:`), 否则被 OpenClash 的 overwrite 安全检查判为
#      "skip unsafe Overwrite command" 静默跳过; 且 mihomo 的 nameserver-policy 里 `+` 通配符
#      必须独占一个标签(`+.example.com`, 不能 `+example.com`), 写错会让 clash 启动失败。
#   7. 2026-10-30: OpenClash 启动失败会**自动把 uci openclash.config.enable 置 0** 并打印
#      "OpenClash Now Disabled, Need Start From Luci Page"。恢复要先 `uci set openclash.config.enable=1`。
#   8. 2026-10-30(本脚本自身): 诊断脚本必须用 `ssh ... bash -s <<'EOF'` 的 **stdin 形式**传给路由器,
#      不能用 `ssh ... '<脚本>'` 的命令参数形式 —— 后者下脚本里任何**裸单引号**(如 date -r "$f" '+%F')
#      都会提前结束 SSH 的引号包裹, 表现为 "Connection to <ip> closed by remote host" 且无任何输出。
#      症状与"路由器拒连"极像, 但根因在本地脚本。EOF 标记也要用带引号的形式防止本地变量展开。
#
# ✅ 正确判断法: 查控制器统计"真实节点数"(排除代理组) + 看 /connections 活跃连接 + 看 nft TCP 重定向计数随出网增长。
#   若节点数正常但全部超时, 立刻做第 8 节的"入口 IP 真实握手"——十有八九是入口 IP 被封。
#
# 用法:
#   bash check_openclash.sh                 # 自动按优先级确定路由器地址
#   bash check_openclash.sh --router root@192.168.1.1
#   ROUTER=root@192.168.1.1 bash check_openclash.sh

set -u

# ---- 解析路由器地址(与 upgrade_router.sh 同优先级) ----
ROUTER="${ROUTER:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --router) ROUTER="$2"; shift 2;;
    *) shift;;
  esac
done
if [ -z "$ROUTER" ] && [ -f "$(dirname "$0")/router-target.conf" ]; then
  ROUTER="$(cat "$(dirname "$0")/router-target.conf" 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "$ROUTER" ]; then
  # 探测 ~/.ssh/config 中主机名含 openwrt/immortalwrt/router 的条目
  ROUTER="$(grep -iE 'host .*(openwrt|immortalwrt|router)' ~/.ssh/config 2>/dev/null | head -1 | awk '{print $2}')"
fi
ROUTER="${ROUTER:-root@192.168.1.1}"

SSH="ssh -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "🔍 目标路由器: $ROUTER"
if ! $SSH "$ROUTER" 'true' >/dev/null 2>&1; then
  echo "❌ 连不上路由器 $ROUTER, 请检查地址/网络/SSH key"
  exit 2
fi

# 用 stdin(heredoc) 把诊断脚本传给路由器, 而不是作为命令参数。
# 原因: 命令参数形式下, 脚本里任何裸单引号都会提前结束 SSH 的引号包裹, 导致连接被关闭;
#       heredoc 形式下引号无需转义, 也更不容易踩坑。
$SSH "$ROUTER" bash -s <<'OC_SCRIPT_EOF'
OC_PASS() { [ "$(uci get openclash.config.enabled 2>/dev/null)" = "1" ] && echo 启用 || echo 未启用; }
# 本构建 OpenClash 的 start_service 检查的是 option enable(不带 d, /etc/init.d/openclash:3594), 而非 enabled!
OC_STARTSW() { [ "$(uci get openclash.config.enable 2>/dev/null)" = "1" ] && echo "1(开机可自启)" || echo "0(开机不自启-致命)"; }
echo ""
echo "===== 1. 基本状态 ====="
echo "OpenClash 启用(LuCI 显示): $(OC_PASS)"
echo "启动开关 enable(不带d, 决定开机自启): $(OC_STARTSW)"
pgrep -f clash >/dev/null 2>&1 && echo "clash 进程: ✅ 运行中" || echo "clash 进程: ❌ 未运行"
[ -x /etc/openclash/core/clash_meta ] && echo "内核 clash_meta: ✅ 存在可执行" || echo "内核 clash_meta: ❌ 缺失/不可执行"

echo ""
echo "===== 2. 实际加载配置 + 控制器 secret ====="
OC_CFG=$(ps w | grep "[c]lash" | grep -oE "\-f [^ ]+" | awk "{print \$2}")
[ -z "$OC_CFG" ] && OC_CFG=$(ls -1 /etc/openclash/*.yaml 2>/dev/null | head -1)
echo "clash 实际配置文件: $OC_CFG"
SEC=$(grep -m1 "secret:" "$OC_CFG" 2>/dev/null | sed -E "s/.*secret:[ ]*[\"]?([A-Za-z0-9_]+)[\"]?.*/\1/")
echo "控制器 secret: ${SEC:-<未找到>}"

echo ""
echo "===== 2b. config_path 与实际加载一致性 ====="
CUR=$(uci get openclash.config.config_path 2>/dev/null)
echo "uci config_path: ${CUR:-<未设置>}"
echo "clash 实际 -f : $OC_CFG"
if [ -z "$CUR" ] || [ "$CUR" = "$OC_CFG" ]; then
  echo "✅ 一致。"
elif echo "$CUR" | grep -q "/config/" && [ "$(dirname "$OC_CFG")" = "/etc/openclash" ]; then
  echo "ℹ️ 不同属正常: config_path 指向 config/ 源配置, -f 指向根目录编译产物(订阅模式常态)。"
else
  echo "🟡 不一致且非标准订阅布局, 建议核对 config_path 是否指错(可能导致重启加载旧配置)。"
fi

echo ""
echo "===== 2c. 订阅自动更新三层闸门 ====="
AU=$(uci get openclash.config.auto_update 2>/dev/null)
AUM=$(uci get openclash.config.config_auto_update_mode 2>/dev/null)
INT=$(uci get openclash.config.config_update_interval 2>/dev/null)
SE=$(uci get openclash.@config_subscribe[0].enabled 2>/dev/null)
echo "auto_update             = ${AU:-<未设>}"
echo "config_auto_update_mode = ${AUM:-<未设>}   (默认 0, 不开则 watchdog 不触发)"
echo "config_update_interval  = ${INT:-<未设>} 分钟 (本版按间隔触发, 非 cron)"
echo "订阅 enabled            = ${SE:-<未设>}   (禁用的订阅会被更新循环跳过)"
if [ "$AU" = "1" ] && [ "$AUM" = "1" ] && [ "$SE" = "1" ]; then
  echo "✅ 三层闸门全开, 订阅会自动刷新节点。"
else
  echo "🟡 有闸门未开 -> 订阅不会自动更新(机场换节点后你仍用旧配置)!"
fi

echo ""
echo "===== 3. 真实节点数(排除代理组) ====="
# 注意: 机场新订阅多为 provider 模式, 节点不在 /proxies 顶层而在 /providers 里。
# 只查 /proxies 会误报 0 节点 -> 必须合并两个来源。
REAL=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/proxies" 2>/dev/null | grep -oE "\"type\":\"(Vless|Vmess|Trojan|Hysteria2|Hysteria|Shadowsocks|ShadowsocksR|Tuic|WireGuard|Snell)\"" | wc -l | tr -d " ")
PREAL=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/providers/proxies" 2>/dev/null | grep -oE "\"type\":\"(Vless|Vmess|Trojan|Hysteria2|Hysteria|Shadowsocks|ShadowsocksR|Tuic|WireGuard|Snell)\"" | wc -l | tr -d " ")
# 同一个节点可能两边都算到, 取较大值即可(判断有无节点, 不需要精确计数)
if [ "${PREAL:-0}" -gt "${REAL:-0}" ] 2>/dev/null; then REAL="$PREAL"; fi
echo "真实服务器节点: $REAL 个 (顶层 $REAL / provider 内 $PREAL)"
echo "--- 各类型分布 ---"
{ curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/proxies" 2>/dev/null
  curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/providers/proxies" 2>/dev/null; } | grep -oE "\"type\":\"[^\"]+\"" | sort | uniq -c
echo "--- provider 概况 ---"
curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/providers/proxies" 2>/dev/null | grep -oE "\"(type|vehicleType|updatedAt)\":\"?[^\",]*" | head -6 | sed "s/^/    /"

echo ""
echo "===== 4. 活跃外部连接(证明代理正承载上网) ====="
CONN=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/connections" 2>/dev/null | grep -oE "\"id\":\"[^\"]+\"" | wc -l | tr -d " ")
echo "当前活跃连接: $CONN 条"
echo "--- 外部目标取样(非假IP/内网) ---"
curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/connections" 2>/dev/null | grep -oE "\"destinationIP\":\"[0-9.]+\"" | grep -vE "198\.18\.|192\.168\.|127\.|10\.|172\." | head -8

echo ""
echo "===== 5. TCP 重定向是否在扛流量(出网探针前后计数) ====="
B=$(nft list ruleset 2>/dev/null | grep -E "ip protocol tcp .*jump openclash" | grep -oE "packets [0-9]+" | head -1 | awk "{print \$2}")
curl -s --max-time 6 -o /dev/null https://www.google.com 2>/dev/null
curl -s --max-time 6 -o /dev/null https://www.youtube.com 2>/dev/null
A=$(nft list ruleset 2>/dev/null | grep -E "ip protocol tcp .*jump openclash" | grep -oE "packets [0-9]+" | head -1 | awk "{print \$2}")
if [ "${A:-0}" -gt "${B:-0}" ] 2>/dev/null; then TAG="增长-流量经代理✅"; else TAG="未增长"; fi
echo "openclash TCP 重定向包计数: ${B:-?} -> ${A:-?}  [$TAG]"

echo ""
echo "===== 6. 工作模式 + 重定向规则 ====="
grep -E "enhanced-mode|fake-ip-range" "$OC_CFG" 2>/dev/null | head
nft list ruleset 2>/dev/null | grep -qE "jump openclash" && echo "nft 重定向规则: ✅ 已安装" || echo "nft 重定向规则: ❌ 未见"

echo ""
echo "===== 6b. 当前出口节点 -> 可达性(识别能连TCP但被App封的节点) ====="
EXIT_NODE=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/connections" 2>/dev/null \
  | jq -r "[.connections[] | select((.chains|length)>0 and (.chains[-1]!=\"DIRECT\") and (.chains[-1]!=\"REJECT\")) | .chains[0]][0] // empty" 2>/dev/null)
if [ -n "$EXIT_NODE" ]; then
  echo "当前出口节点: $EXIT_NODE"
  # 延迟数据取自 provider 的 healthcheck history。
  # 注意: 对 provider 内的节点调用 /proxies/<name>/delay 或
  # /providers/proxies/<prov>/proxies/<name>/delay 都会返回 Resource not found,
  # 唯一可靠的读法是直接读 providers 响应里的 history 数组。
  NODEINFO=$(curl -s --max-time 8 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/providers/proxies" 2>/dev/null \
    | jq -r --arg n "$EXIT_NODE" '[.providers[].proxies[]? | select(.name==$n)] | if length>0 then "alive=\(.[0].alive) delay=\((.[0].history//[])[-1].delay // 0)ms" else "未在 provider 中找到" end' 2>/dev/null)
  echo "  健康检查状态: ${NODEINFO:-<读取失败>}"
  echo ""
  echo "  --- 可用真实节点延迟排行(前10, 用于挑节点) ---"
  curl -s --max-time 8 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/providers/proxies" 2>/dev/null \
    | jq -r '[.providers[].proxies[]? | select(.alive==true) | select((.type=="Vless") or (.type=="Vmess") or (.type=="Trojan") or (.type=="Hysteria2") or (.type=="Shadowsocks") or (.type=="Tuic") or (.type=="WireGuard")) | {n:.name, d:((.history//[])[-1].delay // 99999)}] | unique_by(.n) | sort_by(.d) | .[0:10][] | "    \(.d)ms  \(.n)"' 2>/dev/null
  echo ""
  echo "  (delay 数值=可达; alive=false 或 delay=0 = 不可用; 某节点延迟正常但被 App 拒绝则需换地区)"
else
  echo "(暂无活跃代理连接, 有流量后再跑)"
fi

echo ""
echo "===== 7. 节点服务器域名(仅作参考, 真正判定看第 8 节) ====="
# 注意: 运行配置里 server 字段可能混有无关域名(如 time.apple.com), 只取出现次数最多的
SRV=$(grep -oE "server: [a-zA-Z0-9._-]+" "$OC_CFG" 2>/dev/null | sed "s/server: //" | grep -vE "^(127\.0\.0\.1|time\.apple\.com|.*apple.*)$" | sort | uniq -c | sort -rn | head -1 | awk "{print \$2}")
if [ -n "$SRV" ]; then
  echo "订阅中节点服务器域名: $SRV"
  echo "⚠️ 仅看 DNS 解析不足以判定可达 —— IP 可能已被封锁而 DNS 仍正常返回。请看第 8 节真实握手结果。"
else
  echo "(运行配置中未找到节点服务器域名, provider 模式下请看第 8 节)"
fi

echo ""
echo "===== 8. 节点入口 IP 真实连通性(核心: 区分节点坏了 vs 入口 IP 被封) ====="
echo "--- 8a. 从 provider 缓存提取入口域名与端口 ---"
PC=$(ls -1 /etc/openclash/proxy_provider/*.yaml 2>/dev/null | head -1)
if [ -n "$PC" ]; then
  echo "provider 缓存: $PC"
  SRVS=$(grep -oE "server: [a-zA-Z0-9._-]+" "$PC" 2>/dev/null | sed "s/server: //" | grep -v "^127\.0\.0\.1$" | sort | uniq -c | sort -rn | head -5)
  echo "入口域名分布(域名 出现次数):"
  echo "$SRVS" | sed "s/^/    /"
  MAIN_SRV=$(echo "$SRVS" | head -1 | awk "{print \$2}")
  MAIN_PORT=$(grep -oE "server: $MAIN_SRV, port: [0-9]+" "$PC" 2>/dev/null | head -1 | grep -oE "[0-9]+$")
  [ -z "$MAIN_PORT" ] && MAIN_PORT=$(grep -oE "port: [0-9]+" "$PC" 2>/dev/null | head -1 | grep -oE "[0-9]+")
  echo "主入口: ${MAIN_SRV:-<无>} : ${MAIN_PORT:-<无>}"
else
  echo "(无 provider 缓存, 可能是旧式静态订阅)"
  MAIN_SRV=$(grep -oE "server: [a-zA-Z0-9._-]+" "$OC_CFG" 2>/dev/null | grep -v "127.0.0.1" | head -1 | awk "{print \$2}")
  MAIN_PORT=$(grep -oE "port: [0-9]+" "$OC_CFG" 2>/dev/null | head -1 | grep -oE "[0-9]+")
  echo "主入口: ${MAIN_SRV:-<无>} : ${MAIN_PORT:-<无>}"
fi

if [ -n "${MAIN_SRV:-}" ]; then
  echo ""
  echo "--- 8b. 各上游 DNS 对该入口的解析(看是否轮转) ---"
  for DS in 192.168.1.1 223.5.5.5 114.114.114.114; do
    DIP=$(nslookup "$MAIN_SRV" "$DS" 2>/dev/null | grep -A1 "Name:" | tail -1 | awk "{print \$2}")
    echo "    [$DS] -> ${DIP:-超时/无响应}"
  done

  echo ""
  echo "--- 8c. clash 自身 DNS(7874)的解析结果(它缓存的才是实际在用的) ---"
  CIP=$(nslookup -port=7874 "$MAIN_SRV" 127.0.0.1 2>/dev/null | grep -A1 "Name:" | tail -1 | awk "{print \$2}")
  echo "    clash DNS -> ${CIP:-解析失败}"

  echo ""
  echo "--- 8d. 真实 TCP 握手测试(必须绕开 nft redirect, 否则测到的是本地 clash 端口) ---"
  if [ -n "${CIP:-}" ] && [ -n "${MAIN_PORT:-}" ]; then
    # 临时插豁免规则, 让本机出向流量不走 redirect
    nft insert rule inet fw4 openclash_output ip daddr "$CIP" return 2>/dev/null
    echo "    已临时豁免 $CIP (测完自动删除)"
    if timeout 10 bash -c "exec 3<>/dev/tcp/$CIP/$MAIN_PORT" 2>/dev/null; then
      echo "    ✅ $CIP:$MAIN_PORT 真实可达 -> 入口正常"
      echo "    (若日志仍报 i/o timeout, 说明 clash 缓存了别的旧 IP, 重启 clash 即可重新解析)"
    else
      echo "    ❌ $CIP:$MAIN_PORT 真实不可达 -> 入口 IP 已被封锁!"
      echo "    ---- 处置方案 ----"
      echo "    1) 机场入口域名会轮转多 IP, 等几分钟让 DNS 刷新, 再跑本节复测"
      echo "    2) 手工查各上游 DNS 的最新解析, 用 --resolve 或临时 hosts 指向可达 IP"
      echo "    3) 重启 clash 清 DNS 缓存: /etc/init.d/openclash restart"
      echo "    4) 给入口域名配 nameserver-policy 绑定多上游(见 skill 文档第 8 节)"
    fi
    # 清理临时规则
    H=$(nft -a list chain inet fw4 openclash_output 2>/dev/null | grep "$CIP" | grep -oE "handle [0-9]+" | awk "{print \$2}" | head -1)
    [ -n "$H" ] && nft delete rule inet fw4 openclash_output handle "$H" 2>/dev/null && echo "    已清理临时 nft 规则"
  else
    echo "    (缺少 IP 或端口, 跳过)"
  fi
fi

echo ""
echo "===== 9. 自定义规则是否被订阅更新冲掉 ====="
CR=/etc/openclash/custom/openclash_custom_rules.list
if [ -f "$CR" ]; then
  echo "自定义规则文件: $CR (mtime: $(date -r "$CR" +%Y-%m-%d_%H:%M 2>/dev/null))"
  echo "自定义规则条数: $(awk "/^rules:/{f=1;next} /^[a-zA-Z]/{f=0} f" "$CR" 2>/dev/null | grep -cE "^\s*- ")"
  echo "--- 当前生效的自定义规则 ---"
  awk "/^rules:/{f=1;next} /^[a-zA-Z]/{f=0} f" "$CR" 2>/dev/null | grep -E "^\s*- " | grep -v "^\s*##" | head -10 | sed "s/^/    /"
  if grep -q "overwrite" /etc/openclash/custom/openclash_custom_overwrite.sh 2>/dev/null; then
    echo "✅ overwrite 钩子存在(会在每次启动后自动补回规则)"
  else
    echo "🟡 无 overwrite 钩子 -> 订阅更新/LuCI 保存可能把自定义规则清空"
  fi
else
  echo "(无自定义规则文件)"
fi

echo ""
echo "===== 10. overwrite 钩子注入的字段是否被 mihomo 接受 ====="
if grep -q "nameserver-policy" "$OC_CFG" 2>/dev/null; then
  echo "运行配置含 nameserver-policy:"
  grep -A6 "nameserver-policy" "$OC_CFG" 2>/dev/null | head -8 | sed "s/^/    /"
  echo "注意: key 必须是 +.domain.com 形式, + 不能与域名同标签(否则 clash 启动失败)"
else
  echo "(运行配置无 nameserver-policy)"
fi
if grep -q "level=fatal" /tmp/openclash.log 2>/dev/null; then
  echo "🔴 日志中有 fatal(配置被拒):"
  grep "level=fatal" /tmp/openclash.log 2>/dev/null | tail -3 | sed "s/^/    /"
fi
OC_ENABLE_SW=$(uci get openclash.config.enable 2>/dev/null)
# 近期 dial 超时计数: 节点数正常但大量超时 = 入口 IP 被封(见第 8 节)
DIAL_TIMEOUTS=$(grep -cE "connect error.*i/o timeout|context deadline exceeded" /tmp/openclash.log 2>/dev/null | tr -d " ")
DIAL_TIMEOUTS_RECENT=$(tail -300 /tmp/openclash.log 2>/dev/null | grep -cE "connect error.*i/o timeout|context deadline exceeded" | tr -d " ")
if pgrep -f clash >/dev/null 2>&1 && [ "$REAL" -gt 0 ] 2>/dev/null; then
  if [ "$OC_ENABLE_SW" != "1" ]; then
    echo "🟡 OpenClash 现在在跑($REAL 节点在线), 但启动开关 enable=0 -> 路由一旦重启就不会自启, 需 uci set openclash.config.enable=1!"
  elif [ "${DIAL_TIMEOUTS_RECENT:-0}" -ge 5 ] 2>/dev/null; then
    echo "🔴 节点已加载($REAL 个)但最近有 $DIAL_TIMEOUTS_RECENT 次 dial 超时 -> 高度疑似入口 IP 被封!"
    echo "   请直接看第 8 节的真实握手结果, 按那里的处置方案操作(重启 clash 清 DNS 缓存 / 等 DNS 轮转)。"
  else
    echo "✅ OpenClash 正常: $REAL 个真实节点在线, 代理正在承载上网, 重启可自启。"
  fi
elif pgrep -f clash >/dev/null 2>&1 && [ "$REAL" -eq 0 ] 2>/dev/null; then
  DNS_VIA_OC=$(uci get dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "7874" && echo 1 || echo 0)
  if [ "$DNS_VIA_OC" = "1" ]; then
    echo "🔴 危险: OpenClash 已启用且是 DNS 网关, 但 0 真实节点 -> 用户实际无可用外网(静默断网)! 检查订阅是否加载/过期。"
  else
    echo "🟡 OpenClash 启用但 0 真实节点(非 DNS 网关, 影响有限), 检查订阅加载。"
  fi
elif [ "$OC_ENABLE_SW" = "1" ] && ! pgrep -f clash >/dev/null 2>&1; then
  echo "🔴 启动开关 enable=1 但 clash 没跑起来 -> 启动被 OpenClash 自我保护拦截(配置曾被外部改过), 需 uci set openclash.config.enable=1 后 /etc/init.d/openclash restart, 或去 LuCI 页面启动。"
  if grep -q "level=fatal" /tmp/openclash.log 2>/dev/null; then
    echo "   日志里的 fatal 就是原因(通常是配置字段被注入成了 mihomo 不接受的格式), 见第 10 节。"
  fi
else
  echo "⚪ OpenClash 未运行/未启用, 上网走直连 WAN(本环境若 WAN 可直出外网则正常)。"
fi
OC_SCRIPT_EOF
