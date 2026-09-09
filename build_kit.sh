#!/bin/bash
# build_kit.sh — 从源码可复现地组装 kit.tar.gz (替代直接提交 30MB 不透明 tar)
#
# 设计: 仓库只含纯文本源码 (zzz-restore-router + 你的 authorized_keys + 可选 OpenClash 配置),
#        kit.tar.gz 由本脚本在本地生成, 并已在 .gitignore 中排除, 因此永远不会进 Git。
#
# 用法:
#   ./build_kit.sh --keys ~/.ssh/router_authorized_keys [--openclash /path/to/openclash-dir] [--out <path>] [--force]
#
#   --keys        (必填) 你的 Mac SSH 公钥文件 (一行一把, 可多把), 刷机后仍可 key 免密登录
#   --openclash   (可选) 一个含 OpenClash 配置的目录 (会被复制到 etc/openclash 作为离线兜底)
#                 不提供时, kit 不含 OpenClash 配置 —— 升级时 upgrade_router.sh 的
#                 collect_runtime 会从活路由器重新抓取当前 OpenClash 覆盖进去
#   --out         产物路径 (默认 dist/kit.tar.gz, 已 gitignore)。⚠️ 默认绝不覆盖仓库根的 kit.tar.gz
#   --force       仅当 --out 指向已存在的 kit.tar.gz 时才需要, 显式允许覆盖
#
# 设计要点 (安全): 默认产物写到 dist/ 而非仓库根的 kit.tar.gz —— 仓库根的 kit.tar.gz 是你正在
#   使用的真 kit (含 OpenClash 订阅 + 你的公钥), 误覆盖会让下次升级连不上代理。本脚本默认
#   拒绝覆盖它, 必须 --force 显式确认, 因此"千万别随手跑 build_kit.sh"这个人工提醒已不再需要。
#
# 产物: <out> (含 etc/uci-defaults/zzz-restore-router + etc/dropbear/authorized_keys + 可选 etc/openclash)
set -eu

PREP_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS=""; OC=""; OUT="$PREP_DIR/dist/kit.tar.gz"; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keys)      KEYS="$2"; shift 2;;
    --openclash) OC="$2";   shift 2;;
    --out)       OUT="$2";  shift 2;;
    --force)     FORCE=1;   shift 1;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

[ -n "$KEYS" ] && [ -f "$KEYS" ] || { echo "❌ 需提供 --keys <authorized_keys 文件>"; exit 1; }
[ -f "$PREP_DIR/zzz-restore-router" ] || { echo "❌ 找不到 zzz-restore-router"; exit 1; }

# 安全闸: 默认拒绝覆盖仓库根的 kit.tar.gz (那是用中的真 kit)
REAL_KIT="$PREP_DIR/kit.tar.gz"
OUT_ABS="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")"
if [ "$OUT_ABS" = "$REAL_KIT" ] && [ "$FORCE" != "1" ]; then
  echo "❌ 拒绝覆盖仓库根的真 kit.tar.gz (含 OpenClash 订阅 + 你的公钥)。"
  echo "   若确要重建真 kit, 请显式加 --force:"
  echo "   ./build_kit.sh --keys <keys> --openclash <dir> --out kit.tar.gz --force"
  exit 1
fi
if [ -f "$OUT" ] && [ "$FORCE" != "1" ]; then
  echo "❌ 产物 $OUT 已存在, 加 --force 覆盖。"
  exit 1
fi

BUILD=/tmp/kit_build
rm -rf "$BUILD"
mkdir -p "$BUILD/etc/uci-defaults" "$BUILD/etc/dropbear"

cp "$PREP_DIR/zzz-restore-router" "$BUILD/etc/uci-defaults/zzz-restore-router"
chmod 0755 "$BUILD/etc/uci-defaults/zzz-restore-router"

cp "$KEYS" "$BUILD/etc/dropbear/authorized_keys"
chmod 600 "$BUILD/etc/dropbear/authorized_keys"

if [ -n "$OC" ] && [ -d "$OC" ]; then
  mkdir -p "$BUILD/etc/openclash"
  cp -R "$OC"/. "$BUILD/etc/openclash"/ 2>/dev/null || true
  echo "✅ 已烘焙 OpenClash 配置 (离线兜底; 升级时会从活路由器重新抓取覆盖)"
else
  echo "ℹ️  未提供 --openclash: kit 不含 OpenClash 配置 (升级时由 collect_runtime 从活路由器抓取)"
fi

mkdir -p "$(dirname "$OUT")"
tar -czf "$OUT" -C "$BUILD" .
rm -rf "$BUILD"

echo "✅ 已生成 kit -> $OUT"
echo "   升级时 upgrade_router.sh 会从活路由器抓取 root shadow / WiFi key / 三频 SSID / OpenClash"
echo "   注入临时 kit (仅存于 /tmp, 脚本退出即清理), 源码与仓库均无任何明文敏感信息。"
