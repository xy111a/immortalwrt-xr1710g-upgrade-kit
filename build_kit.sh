#!/bin/bash
# build_kit.sh — 从源码可复现地组装 kit.tar.gz (替代直接提交 30MB 不透明 tar)
#
# 设计: 仓库只含纯文本源码 (zzz-restore-router + 你的 authorized_keys + 可选 OpenClash 配置),
#        kit.tar.gz 由本脚本在本地生成, 并已在 .gitignore 中排除, 因此永远不会进 Git。
#
# 用法:
#   ./build_kit.sh --keys ~/.ssh/id_ed25519.pub [--openclash /path/to/openclash-dir] [--openclash-core /path/to/clash_meta] [--out <path>] [--force]
#
#   --keys           (必填) 你的 Mac SSH 公钥文件 (一行一把, 可多把), 刷机后仍可 key 免密登录
#   --openclash      (可选) 一个含 OpenClash 配置的目录 (会被复制到 etc/openclash 作为离线兜底)
#                    不提供时, kit 不含 OpenClash 配置 —— 升级时 upgrade_router.sh 的
#                    collect_runtime 会从活路由器重新抓取当前 OpenClash 覆盖进去 (core 除外)
#   --openclash-core (可选但强烈建议) clash_meta 内核二进制路径 (如 mihomo-linux-arm64 解压后)
#                    烘焙进 kit 的 etc/openclash/core/clash_meta, 由 sysupgrade -f 还原 ——
#                    彻底摆脱"大文件经 SSH tar 管道"的脆弱链路, 全清刷后内核不再丢失。
#                    不提供时, kit 不含内核, 依赖 zzz-restore 运行时从 CDN 兜底下載。
#   --target-commit (可选) 该 kit 面向的目标固件 commit(写入 manifest; 升级时 collect_runtime 会覆写为实际目标)
#   --target-kernel  (可选) 目标固件内核版本(写入 manifest, 仅用于跨内核告警)
#   --out          产物路径
#   --force        仅当 --out 指向已存在的 kit.tar.gz 时才需要, 显式允许覆盖
#
# 设计要点 (安全): 默认产物写到 dist/ 而非仓库根的 kit.tar.gz —— 仓库根的 kit.tar.gz 是你正在
#   使用的真 kit (含 OpenClash 订阅 + 你的公钥), 误覆盖会让下次升级连不上代理。本脚本默认
#   拒绝覆盖它, 必须 --force 显式确认, 因此"千万别随手跑 build_kit.sh"这个人工提醒已不再需要。
#
# 产物: <out> (含 etc/uci-defaults/zzz-restore-router + etc/dropbear/authorized_keys + 可选 etc/openclash)
set -eu
# 同 upgrade_router.sh: 阻止 Mac tar 附加 AppleDouble ._* 伴随文件污染 kit
export COPYFILE_DISABLE=1

PREP_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS=""; OC=""; CORE=""; OUT="$PREP_DIR/dist/kit.tar.gz"; FORCE=0; TC=""; TK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keys)           KEYS="$2"; shift 2;;
    --openclash)      OC="$2";   shift 2;;
    --openclash-core) CORE="$2"; shift 2;;
    --out)            OUT="$2";  shift 2;;
    --force)          FORCE=1;   shift 1;;
    --target-commit)  TC="$2";   shift 2;;
    --target-kernel)  TK="$2";   shift 2;;
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
  # cp -R 可能带入源目录的 ._* AppleDouble 垃圾, 打包前清掉
  find "$BUILD" -name '._*' -type f -delete 2>/dev/null
  echo "✅ 已烘焙 OpenClash 配置 (离线兜底; 升级时会从活路由器重新抓取覆盖)"
else
  echo "ℹ️  未提供 --openclash: kit 不含 OpenClash 配置 (升级时由 collect_runtime 从活路由器抓取)"
fi

# 烘焙 OpenClash 内核(clash_meta) —— P1 根治"全清刷后内核丢失":
# 内核二进制随 kit 整包 scp 传输(比 57MB 经 SSH tar 管道稳), sysupgrade -f 还原后即到位,
# 不再依赖 collect_runtime 抓取的脆弱大文件链路。zzz-restore 运行时还会再做一次兜底下载。
if [ -n "$CORE" ] && [ -f "$CORE" ]; then
  mkdir -p "$BUILD/etc/openclash/core"
  cp "$CORE" "$BUILD/etc/openclash/core/clash_meta"
  chmod 0755 "$BUILD/etc/openclash/core/clash_meta"
  echo "✅ 已烘焙 OpenClash 内核 clash_meta ($(wc -c < "$CORE") B) -> kit 的 etc/openclash/core/"
else
  echo "ℹ️  未提供 --openclash-core: kit 不含内核二进制 (升级时依赖 zzz-restore 运行时兜底下载)"
fi

# 2026-11-13: 写入无敏感信息的 kit manifest, 供 upgrade_router.sh 的 verify_kit() 核验
# "这份 kit 是不是按仓库当前源码 / 目标固件重建的"。只记 commit / 内核 / 文件 sha256,
# 绝不写 SSID / WiFi key / root hash / 订阅 / MAC —— manifest 会随 kit 一起进路由器。
{
  echo "kit_schema=1"
  echo "built_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "target_commit=${TC:-unspecified}"
  echo "target_kernel=${TK:-unspecified}"
  echo "source_router_commit=unspecified"
  echo "source_kernel=unspecified"
  echo "restore_script_sha256=$(shasum -a 256 "$BUILD/etc/uci-defaults/zzz-restore-router" 2>/dev/null | awk '{print $1}')"
  if [ -f "$BUILD/etc/openclash/core/clash_meta" ]; then
    echo "clash_core_sha256=$(shasum -a 256 "$BUILD/etc/openclash/core/clash_meta" 2>/dev/null | awk '{print $1}')"
  else
    echo "clash_core_sha256=absent"
  fi
} > "$BUILD/etc/kit-manifest"

mkdir -p "$(dirname "$OUT")"
# --no-mac-files 双保险(不支持该旗标的 tar 会报错, 此时退回普通打包, COPYFILE_DISABLE 仍生效)
tar --no-mac-files -czf "$OUT" -C "$BUILD" . 2>/dev/null || tar -czf "$OUT" -C "$BUILD" .
rm -rf "$BUILD"

echo "✅ 已生成 kit -> $OUT (含 etc/kit-manifest: 无敏感信息, 供刷前核验)"
echo "   升级时 upgrade_router.sh 会从活路由器抓取 root shadow / WiFi key / 三频 SSID / OpenClash 配置(core 除外)"
echo "   以及审计确认的额外配置(dhcp rpcd luci cpufreq watchcat dawn system)与定制路径(crontabs/rc.d/lan_report/token/apk源/http.lua补丁)"
echo "   注入临时 kit (仅存于 /tmp, 脚本退出即清理), 源码与仓库均无任何明文敏感信息。"
echo "   若提供了 --openclash-core, 内核已烘焙进 kit, 全清刷后内核不丢; 否则 zzz-restore 运行时兜底下载。"
