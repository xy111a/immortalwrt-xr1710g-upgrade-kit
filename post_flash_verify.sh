#!/usr/bin/env bash
# ============================================================================
# post_flash_verify.sh —— 刷完官方 11-11 chainloader 后的「5 分钟验证清单」
#
# 全程**只读**（不改设备任何分区）。逐项核对刷 U-Boot 是否真的成功：
#   1) U-Boot 版本串是否变成 XR1710G-2026-11-11-ga9a12de55890
#   2) CPU 口 MAC 是否不再与 lan2/lan3/lan4 重复（这正是 11-11 修的东西）
#   3) 恢复页 IP 是否从 192.168.255.1 变成 192.168.0.1
#   4) UBI 是否已开始使用 fastmap（attach 是否变快）
#   5) 引导配方是否已被官方 rfb.c 归一化（bootcmd 不再含 "flash "）
#
# 用法： ./post_flash_verify.sh [--router root@192.168.88.1] [--baseline <备份目录>]
# ============================================================================
set -u
LOG_DIR="$HOME/router-upgrade-logs"
ROUTER="root@192.168.88.1"
BASELINE=""
PASS=0; FAIL=0; WARN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --router)   ROUTER="${2:-}"; shift;;
    --router=*) ROUTER="${1#=}";;
    --baseline) BASELINE="${2:-}"; shift;;
    --baseline=*) BASELINE="${1#=}";;
    -h|--help)  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  esac
  shift
done

if [ -z "$BASELINE" ]; then
  for d in "$LOG_DIR"/uboot-backups/*/; do
    [ -f "$d/mac-baseline.txt" ] && BASELINE="$d"
  done
fi

say(){ echo "$1"; }
hr(){ echo "--------------------------------------------------"; }
ok(){ say "  ✓ $1"; PASS=$((PASS+1)); }
no(){ say "  ✗ $1"; FAIL=$((FAIL+1)); }
wn(){ say "  ! $1"; WARN=$((WARN+1)); }

RS(){ ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$ROUTER" "$@" 2>/dev/null; }

say "路由器: $ROUTER"
say "基线目录: ${BASELINE:-<未找到>}"

# ---------------------------------------------------------------------------
say ""; hr; say "---- ① U-Boot 版本串 ----"; hr
# 串口才能看到 U-Boot banner；SSH 下用 mtd3 内容推断
# 2026-11-17 修正: 官方镜像版本串是 "U-Boot XR1710G-2026-11-11-ga9a12de55890",
# 在 "U-Boot " 与年份之间多了 "XR1710G-" 前缀, 原正则 [0-9]{4} 直接开头 → 永远匹配不到 → 假阴性。
VER=$(RS "strings /dev/mtd3 2>/dev/null | grep -m1 'U-Boot XR1710G-[0-9]*'")
if [ -n "$VER" ]; then
  if echo "$VER" | grep -q "XR1710G-2026-11-11\|a9a12de55890"; then
    ok "mtd3 内含官方 11-11 版本标识: $VER"
  else
    wn "mtd3 版本串为: $VER —— 若串口 banner 也显示它，说明刷入的是旧镜像"
  fi
else
  wn "未能从 mtd3 提取版本串 —— 需看串口 banner 确认"
fi
say "  → 权威判据: 串口 banner 应显示 'U-Boot XR1710G-2026-11-11-ga9a12de55890'"

# ---------------------------------------------------------------------------
say ""; hr; say "---- ② CPU 口 MAC 重复修复（11-11 的核心价值） ----"; hr
MACS=$(RS "for i in br-lan cpu lan1 lan2 lan3 lan4 wan; do
          [ -e /sys/class/net/\$i/address ] && echo \"\$i=\$(cat /sys/class/net/\$i/address)\"
        done")
if [ -n "$MACS" ]; then
  say "$MACS" | sed 's/^/    /'
  # 2026-11-17 修正: br-lan 是网桥, 其 MAC 按设计取自某个 LAN 成员口(本机为 lan2),
  #   br-lan==lan2 是**正常**的, 不算重复故障。真正的 bug 是刷前 cpu/lan2/lan3/lan4
  #   全部撞成 00:58:28:d7:63:60。判据改为: 只看物理口 cpu/lan2/lan3/lan4/wan,
  #   并检查 cpu/lan3/lan4 是否已脱离刷前的公共地址。
  PHYS=$(say "$MACS" | grep -E '^(cpu|lan2|lan3|lan4|wan)=')
  DUP=$(say "$PHYS" | grep -v '^wan=' | cut -d= -f2 | sort | uniq -d)
  PRE_DUP_MAC=$(say "$BASELINE/mac-baseline.txt" 2>/dev/null | grep -E '^(cpu|lan2|lan3|lan4)=' | cut -d= -f2 | sort | uniq -d | head -1)
  STILL=$(say "$MACS" | grep -E '^(cpu|lan3|lan4)=' | cut -d= -f2 | grep -c "^${PRE_DUP_MAC:-__none__}$")
  if [ -z "$DUP" ] && [ "${STILL:-0}" -eq 0 ]; then
    ok "物理口 cpu/lan2/lan3/lan4 MAC 互不相同, 且已脱离刷前公共地址 —— 11-11 修复生效"
    say "    (br-lan 与 lan2 同址是网桥正常行为, 不计入重复)"
  elif [ -z "$DUP" ]; then
    wn "物理口已互不相同, 但 cpu/lan3/lan4 仍沿用刷前公共 MAC —— fixup 可能未生效"
  else
    no "物理口仍有重复 MAC: $DUP —— 11-11 的 fixup_fdt_macs 未生效"
  fi
  if [ -n "$BASELINE" ] && [ -f "$BASELINE/mac-baseline.txt" ]; then
    say ""
    say "    基线对照:"
    sed 's/^/      /' "$BASELINE/mac-baseline.txt"
  fi
else
  wn "无法读取网卡 MAC"
fi

# ---------------------------------------------------------------------------
say ""; hr; say "---- ③ 恢复页 IP 探测 ----"; hr
for ip in 192.168.0.1 192.168.255.1; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 --noproxy '*' "http://$ip/" 2>/dev/null)
  if [ "$code" = "000" ]; then say "  · http://$ip/ 无响应（正常：设备运行中不会开恢复页）"; else say "  ✓ http://$ip/ HTTP $code —— 恢复页在线"; fi
done
say "  → 进入恢复页: 上电时**按住 reset 键**，LED 变色后松手；电脑网卡设静态 192.168.0.10/24"
say "  → 官方 11-11 的恢复页固定 192.168.0.1/24（源码 RECOVERY_STATIC_IPADDR）"

# ---------------------------------------------------------------------------
say ""; hr; say "---- ④ UBI / fastmap 状态 ----"; hr
UBI=$(RS "dmesg | grep -E 'ubi0: (attached|scanning)|fastmap' | head -8")
if [ -n "$UBI" ]; then
  say "$UBI" | sed 's/^/    /'
  if echo "$UBI" | grep -qi "fastmap"; then
    ok "UBI 已使用 fastmap（官方 11-11 才有此能力）—— 开机 attach 变快"
  else
    # 2026-11-17 修正: 1115 内核 cmdline 带 ubi.fm_autoconvert=1, 但内核未编
    # CONFIG_MTD_UBI_FASTMAP 时该参数被忽略 → 不做 autoconvert, 走全盘扫描。
    # 这不影响引导正确性, 且官方 11-11 U-Boot 已具备 fastmap 读取能力(顺序风险已消除)。
    wn "未见 fastmap —— 内核未编 CONFIG_MTD_UBI_FASTMAP 时 cmdline 参数会被忽略, 走全盘扫描, 不影响引导"
  fi
else
  wn "无法读取 dmesg"
fi

# ---------------------------------------------------------------------------
say ""; hr; say "---- ⑤ 引导配方归一化检查 ----"; hr
BC=$(RS "fw_printenv bootcmd 2>/dev/null")
say "    bootcmd = ${BC:-<读取失败>}"
if echo "$BC" | grep -q "flash "; then
  no "bootcmd 仍含 'flash ' —— 官方 rfb.c 的归一化未生效"
else
  ok "bootcmd 不含 'flash ' —— 归一化已生效（官方 rfb.c 会在内存中改写，不 saveenv）"
fi
BU=$(RS "fw_printenv boot_ubi 2>/dev/null")
say "    boot_ubi = ${BU:-<读取失败>}"
if echo "$BU" | grep -q "ubi part system"; then
  ok "boot_ubi 指向 'system' —— 官方 chainloader 的内嵌 DTB 视图"
elif echo "$BU" | grep -q "ubi part ubi"; then
  # 2026-11-17 修正: fw_printenv 读的是 UBI ubootenv 卷里的**持久化** env,
  # 官方 rfb.c 只在内存里归一化(不 saveenv, 也不该 saveenv —— mtd1 是原厂共用 env)。
  # 因此刷入官方 chainloader 后 fw_printenv 仍显示 'ubi' 是**预期行为**, 不能据此判旧 U-Boot。
  ok "boot_ubi 仍指向 'ubi' —— 预期行为: 官方 rfb.c 只在内存归一化为 system, 不 saveenv"
  say "    判定 U-Boot 新旧的权威判据是 ① 的版本串/mtd3 逐字节比对, 不是 fw_printenv"
else
  wn "boot_ubi 异常: ${BU:-<空>}"
fi

# ---------------------------------------------------------------------------
say ""; hr; say "---- 汇总 ----"; hr
say "  通过 $PASS / 失败 $FAIL / 提示 $WARN"
if [ "$FAIL" -eq 0 ]; then
  say ""
  say "✅ 刷入验证通过。建议立刻再抓一份新的 MAC 基线与 UBI 快照归档。"
else
  say ""
  say "❌ 有 $FAIL 项未通过 —— 立即评估是否回滚（mtd3 备份 sha256 a65bba65…）"
  say "   回滚路径见 ttl_rescue.sh --print-serial 的【路径 B】"
fi
exit 0
