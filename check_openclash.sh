#!/usr/bin/env bash
# check_openclash.sh — 路由器 OpenClash 健康诊断(Mac 侧)
# 用途: 升级后或日常排查时, 一次性确认 OpenClash 是否真的在承载上网。
#
# ⚠️ 为什么需要它(3 个曾踩过的诊断坑, 别再犯):
#   1. 控制器 secret 在 clash 实际加载的配置文件(即 clash 进程 `-f <file>` 所指), 不是生成的 /etc/openclash/config.yaml。
#      抓错文件 → 控制器鉴权失败 → 返回 0 节点 → 误判"没节点"。
#   2. mixed 端口(7890/7893 等)需要认证: `curl -x http://127.0.0.1:7890` 会返回 407 Proxy Authentication Required,
#      这不是节点故障! 用户设备走的是透明重定向(TPROXY/REDIRECT)进代理, 那条路不需要认证, 上网不受影响。
#      所以**绝不要用 `curl -x` 来判断代理通不通**。
#   3. fake-ip 模式下, 经 7874 解析任意域名都返回 198.18.0.0/16 的假 IP, 不能据此判断真实服务器可达。
#
# ✅ 正确判断法: 查控制器统计"真实节点数"(排除代理组) + 看 /connections 活跃连接 + 看 nft TCP 重定向计数随出网增长。
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

SSH="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "🔍 目标路由器: $ROUTER"
if ! $SSH "$ROUTER" 'true' >/dev/null 2>&1; then
  echo "❌ 连不上路由器 $ROUTER, 请检查地址/网络/SSH key"
  exit 2
fi

$SSH "$ROUTER" '
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
REAL=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/proxies" 2>/dev/null | grep -oE "\"type\":\"(Vless|Vmess|Trojan|Hysteria2|Hysteria|Shadowsocks|ShadowsocksR|Tuic|WireGuard|Snell)\"" | wc -l | tr -d " ")
echo "真实服务器节点: $REAL 个"
echo "--- 各类型分布 ---"
curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/proxies" 2>/dev/null | grep -oE "\"type\":\"[^\"]+\"" | sort | uniq -c

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
echo "===== 6b. 当前出口节点 -> Google/TikTok 可达性(识别能连TCP但被App封的节点) ====="
EXIT_NODE=$(curl -s --max-time 6 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/connections" 2>/dev/null \
  | jq -r "[.connections[] | select((.chains|length)>0 and (.chains[-1]!=\"DIRECT\") and (.chains[-1]!=\"REJECT\")) | .chains[0]][0] // empty" 2>/dev/null)
if [ -n "$EXIT_NODE" ]; then
  echo "当前出口节点: $EXIT_NODE"
  ENC=$(jq -rn --arg n "$EXIT_NODE" "\$n|@uri" 2>/dev/null)
  for U in "https://www.google.com" "https://www.tiktok.com"; do
    UE=$(jq -rn --arg u "$U" "\$u|@uri" 2>/dev/null)
    printf "  -> %-26s " "$U"
    R=$(curl -s --max-time 9 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090/proxies/$ENC/delay?timeout=7000&url=$UE" 2>/dev/null)
    echo "$R"
  done
  echo "  (出现 An error occurred 但 Google 正常 = 该节点被 TikTok 等站点封 IP, 换可用节点即可)"
else
  echo "(暂无活跃代理连接, 有流量后再跑)"
fi

echo ""
echo "===== 7. 真实节点服务器可达性(绕过 fake-ip, 用公共DNS解析) ====="
SRV=$(grep -oE "server: [a-zA-Z0-9._-]+" "$OC_CFG" 2>/dev/null | grep -v "127.0.0.1" | head -1 | awk "{print \$2}")
if [ -n "$SRV" ]; then
  echo "订阅中节点服务器域名: $SRV"
  echo -n "公共DNS解析($SRV): "; nslookup "$SRV" 223.5.5.5 2>/dev/null | grep -E "Address" | tail -1
else
  echo "(订阅中未找到外部节点服务器域名)"
fi

echo ""
echo "===== 结论 ====="
OC_ENABLE_SW=$(uci get openclash.config.enable 2>/dev/null)
if pgrep -f clash >/dev/null 2>&1 && [ "$REAL" -gt 0 ] 2>/dev/null; then
  if [ "$OC_ENABLE_SW" != "1" ]; then
    echo "🟡 OpenClash 现在在跑($REAL 节点在线), 但启动开关 enable=0 -> 路由一旦重启就不会自启, 需 uci set openclash.config.enable=1!"
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
else
  echo "⚪ OpenClash 未运行/未启用, 上网走直连 WAN(本环境若 WAN 可直出外网则正常)。"
fi
' 2>&1
