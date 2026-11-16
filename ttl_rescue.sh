#!/usr/bin/env bash
# ============================================================================
# ttl_rescue.sh —— XR1710G chainloader 变砖救援脚本（**完全离线，不碰设备**）
#
# 用途：为「刷官方 11-11 chainloader 后设备变砖」准备一条可执行的救砖路径。
#       本脚本**不会自动向设备写入任何东西**，它做的是：
#         1) 检查本机救砖工具链是否就位（串口 / TFTP / 镜像 / 备份）
#         2) 把镜像与备份摆进 TFTP 根目录
#         3) 生成两份「照着敲」的命令单（TTL 串口 + SSH）
#         4) 校验备份完整性
#
# 依据：官方 docs/flashing-xr1710g.md（naoki66/Gemtek-brightspeed-chainloader）
#
# 用法：
#   ./ttl_rescue.sh --check          # 只检查工具链（默认动作，不写设备）
#   ./ttl_rescue.sh --stage          # 摆放 TFTP 根目录 + 生成命令单
#   ./ttl_rescue.sh --tftp           # 前台启动 TFTP 服务（Ctrl-C 停止）
#   ./ttl_rescue.sh --print-serial   # 打印串口接线与进 ECNT> 的步骤
#   ./ttl_rescue.sh --all            # stage + 打印全部命令单
#
# ⚠️ 关键前提（官方 FAQ 反复强调）：
#   - `saveenv` / `env default -a` **只能在原厂 U-Boot 的 `ECNT>` 提示符下执行**。
#   - 在**二级 chainloader** 提示符下执行 `saveenv` 会把原厂 env（mtd1/uenv）整套覆盖，
#     导致原厂 U-Boot 之后再也找不到自己的启动配方（卡在 `ECNT>` 报 `Unknown command 'ubi'`）。
#   - 链式 U-Boot 已不再调用 env_save()（上游提交 b3b4091），但**不要赌**，一律按上面执行。
# ============================================================================
set -u

LOG_DIR="$HOME/router-upgrade-logs"
STATE_FILE="$LOG_DIR/uboot-state.env"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 官方最新 slot.bin 的缓存位置（由 uboot_upgrade.sh --prepare 产出）
NEW_SLOT=""
for d in "$LOG_DIR"/uboot-backups/*/; do
  [ -d "$d" ] || continue
  f=$(ls "$d"xr1710g-chainloader-*-slot.bin 2>/dev/null | head -1)
  [ -n "$f" ] && NEW_SLOT="$f"
done

# 旧 chainloader 备份（回滚用）
OLD_BACKUP=""
for d in "$LOG_DIR"/uboot-backups/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/mtd-chainloader.bin" ] && OLD_BACKUP="$d/mtd-chainloader.bin"
done

TFTP_ROOT="$LOG_DIR/ttl-tftp-root"
UENV_BACKUP=""
for d in "$LOG_DIR"/uboot-backups/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/mtd-uenv.bin" ] && UENV_BACKUP="$d/mtd-uenv.bin"
done

MODE="check"
while [ $# -gt 0 ]; do
  case "$1" in
    --check)        MODE="check";;
    --stage)        MODE="stage";;
    --tftp)         MODE="tftp";;
    --print-serial) MODE="serial";;
    --all)          MODE="all";;
    -h|--help)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "⚠️ 忽略未知参数: $1";;
  esac
  shift
done

say(){ echo "$1"; }
hr(){ echo "--------------------------------------------------"; }
ok(){ say "  ✓ $1"; }
bad(){ say "  ✗ $1"; }
warn(){ say "  ! $1"; }

# ---------------------------------------------------------------------------
check_toolchain(){
  say ""; hr; say "---- 救砖工具链检查 ----"; hr

  say "① 串口终端"
  local s
  for s in picocom minicom cu screen; do
    if command -v "$s" >/dev/null 2>&1; then ok "$s → $(command -v $s)"; else bad "$s 缺失"; fi
  done
  if [ -z "$(ls /dev/tty.usb* /dev/tty.usbmodem* /dev/cu.usb* 2>/dev/null)" ]; then
    bad "未检测到 USB-TTL 串口设备（/dev/tty.usb* / /dev/cu.usb*）"
    warn "→ 需插入 USB-TTL 模块（CH343 等 3.3V），并确认设备在 /dev 下出现串口节点"
  else
    ok "USB-TTL 设备：$(ls /dev/tty.usb* /dev/cu.usb* 2>/dev/null | tr '\n' ' ')"
  fi

  say ""
  say "② TFTP 服务端"
  if [ -x /usr/libexec/tftpd ]; then
    ok "/usr/libexec/tftpd（macOS 内置，launchd 管理）"
  elif command -v tftpd >/dev/null 2>&1; then
    ok "tftpd → $(command -v tftpd)"
  elif command -v atftpd >/dev/null 2>&1; then
    ok "atftpd → $(command -v atftpd)"
  else
    bad "无 tftpd/atftpd —— brew install atftp"
  fi
  if command -v tftp >/dev/null 2>&1; then ok "tftp 客户端 → $(command -v tftp)"; else warn "无 tftp 客户端（仅做服务端也够）"; fi

  say ""
  say "③ 待刷镜像（新 chainloader）"
  if [ -n "$NEW_SLOT" ]; then
    ok "$NEW_SLOT"
    say "     sha256: $(shasum -a 256 "$NEW_SLOT" | cut -d' ' -f1)"
    say "     大小:   $(stat -f%z "$NEW_SLOT" 2>/dev/null) 字节"
    # 双入口 magic 校验
    local m1 m2
    m1=$(xxd -p -l 4 "$NEW_SLOT" | tr -d '\n')
    m2=$(xxd -p -s 8448 -l 4 "$NEW_SLOT" | tr -d '\n')
    [ "$m1" = "27051956" ] && ok "前缀 shim uImage magic @0 (27 05 19 56)" || bad "前缀 magic 异常: $m1"
    [ "$m2" = "d00dfeed" ] && ok "二级 FIT magic @8448 (d0 0d fe ed)" || bad "FIT magic 异常: $m2"
  else
    bad "未找到新 chainloader slot.bin —— 先跑 uboot_upgrade.sh --prepare"
  fi

  say ""
  say "④ 回滚备份（旧 chainloader）"
  if [ -n "$OLD_BACKUP" ]; then
    ok "$OLD_BACKUP"
    say "     sha256: $(shasum -a 256 "$OLD_BACKUP" | cut -d' ' -f1)"
    say "     大小:   $(stat -f%z "$OLD_BACKUP" 2>/dev/null) 字节（应为 1048576 = mtd3 整分区）"
  else
    bad "未找到 mtd-chainloader.bin 备份 —— 回滚无凭据，必须先 --prepare"
  fi

  say ""
  say "⑤ 原厂 env 备份（mtd1/uenv，2MiB）"
  if [ -n "$UENV_BACKUP" ]; then
    ok "$UENV_BACKUP"
    say "     sha256: $(shasum -a 256 "$UENV_BACKUP" | cut -d' ' -f1)"
  else
    warn "未找到 mtd-uenv.bin —— 救砖时若需恢复原厂 env 会缺素材"
  fi

  say ""
  say "⑥ 状态档案"
  if [ -f "$STATE_FILE" ]; then
    ok "$STATE_FILE"
    grep -E '^UBOOT_STATE_' "$STATE_FILE" | sed 's/^/     /'
  else
    warn "缺少 $STATE_FILE"
  fi
}

# ---------------------------------------------------------------------------
stage(){
  say ""; hr; say "---- 摆放 TFTP 根目录 ----"; hr
  mkdir -p "$TFTP_ROOT"
  say "TFTP 根目录: $TFTP_ROOT"

  # 官方 TTL 教程用短名 xr1710g-chainloader-slot.bin
  if [ -n "$NEW_SLOT" ]; then
    cp -f "$NEW_SLOT" "$TFTP_ROOT/xr1710g-chainloader-slot.bin"
    ok "已放置 xr1710g-chainloader-slot.bin（= $(basename "$NEW_SLOT")）"
  fi
  # 回滚用的旧 chainloader
  if [ -n "$OLD_BACKUP" ]; then
    cp -f "$OLD_BACKUP" "$TFTP_ROOT/mtd3-old-chainloader.bin"
    ok "已放置 mtd3-old-chainloader.bin（回滚用）"
  fi
  # 原厂 env
  if [ -n "$UENV_BACKUP" ]; then
    cp -f "$UENV_BACKUP" "$TFTP_ROOT/01_env_data.bin"
    ok "已放置 01_env_data.bin（原厂 env 恢复用）"
  fi

  say ""
  say "目录内容:"
  ls -la "$TFTP_ROOT" | sed 's/^/  /'
  say ""
  say "⚠️  TFTP 服务需以 root 运行（绑定 69 端口）："
  say "      sudo /usr/libexec/tftpd -l -r $TFTP_ROOT      # macOS 内置"
  say "      或  sudo atftpd --daemon --port 69 --root $TFTP_ROOT"
  say "    本脚本的 --tftp 会尝试直接拉起（可能需要你输入 sudo 密码）。"
}

# ---------------------------------------------------------------------------
print_serial(){
  say ""; hr; say "---- TTL 接线与进入原厂 U-Boot ----"; hr
  cat <<'EOF'
① 接线（RX/TX 交叉，**VCC 不接**，跳线选 3.3V）

     USB-TTL            路由器主板
     ┌────────┐        ┌──────────────┐
     │  GND  ─┼────────┼── GND        │
     │   RX  ─┼────────┼── TX         │   ← 注意交叉
     │   TX  ─┼────────┼── RX         │
     │  VCC  ─┼── ✗ 不接              │   ← 避免供电冲突
     └────────┘        └──────────────┘

② 电脑网卡设静态 192.168.0.10 / 255.255.255.0，网线插**10GbE 口**（fport 4）
   （1G/2.5G 口是 fport 1，恢复模式若连不上就换口，见官方 FAQ）

③ 上电打断 U-Boot
   - 打开串口终端：115200 8N1，无流控
   - 给路由器上电，看到启动日志**立刻按空格或回车**
   - 看到 `T T T...` = 错过窗口，重新上电再来

④ 确认你停在哪个提示符 —— 这决定后续命令怎么敲
   - `ECNT>`  = **原厂 U-Boot**（有 flash 命令，可刷可 saveenv）← 救砖主战场
   - `U-Boot>` = 二级 chainloader（**无 flash 命令**，只能 mtd 读写 + saveenv 禁用）
EOF
}

print_cmds(){
  say ""; hr; say "---- 救砖命令单（照着敲） ----"; hr

  say "【路径 A】原厂 U-Boot（ECNT>）刷入新 chainloader —— 推荐"
  cat <<'EOF'

ECNT> setenv serverip 192.168.0.10
ECNT> setenv ipaddr 192.168.0.1
ECNT> tftpboot 0x81800000 xr1710g-chainloader-slot.bin
    → 应看到 "Bytes transferred = 937538 (0xe51ea)"
ECNT> setenv one "flash read 0x600000 0x100000 \$loadaddr"
ECNT> setenv two "; bootm"
ECNT> setenv bootcmd "$one$two"
ECNT> saveenv
ECNT> flash erase 0x600000 0x100000
ECNT> flash write 0x600000 0x100000 0x81800000
ECNT> reset
EOF

  say "【路径 B】原厂 U-Boot（ECNT>）回滚旧 chainloader —— 最优先尝试"
  cat <<'EOF'

ECNT> setenv serverip 192.168.0.10
ECNT> setenv ipaddr 192.168.0.1
ECNT> tftpboot 0x81800000 mtd3-old-chainloader.bin
ECNT> flash erase 0x600000 0x100000
ECNT> flash write 0x600000 0x100000 0x81800000
ECNT> reset
    → 回滚后设备应恢复成 YYH2913 chainloader（恢复页 192.168.255.1）
EOF

  say "【路径 C】恢复原厂 env（mtd1/uenv，2MiB）—— 仅当出现 Unknown command 'ubi'"
  cat <<'EOF'

ECNT> setenv serverip 192.168.0.10
ECNT> setenv ipaddr 192.168.0.1
ECNT> tftpboot 0x90000000 01_env_data.bin
ECNT> flash erase 0x200000 0x200000
ECNT> flash write 0x200000 0x200000 0x90000000
    若单次 2MiB 写不进去，分四次 0x80000：
ECNT> flash write 0x200000 0x80000 0x90000000
ECNT> flash write 0x280000 0x80000 0x90080000
ECNT> flash write 0x300000 0x80000 0x90100000
ECNT> flash write 0x380000 0x80000 0x90180000
ECNT> reset
EOF

  say "【路径 D】SSH 路径（设备还能 SSH 时最省事，无需拆机）"
  cat <<'EOF'

# 上传新镜像
scp xr1710g-chainloader-20261111-051034-ga9a12de55890-slot.bin root@<IP>:/tmp/new-slot.bin
# 写入 mtd3（用 label，不要用编号）
ssh root@<IP> 'mtd write /tmp/new-slot.bin chainloader'
# 写后整块回读比对
ssh root@<IP> 'dd if=/dev/mtd3 bs=4096 2>/dev/null | head -c 937538 | sha256sum'
# 回滚
scp mtd3-old-chainloader.bin root@<IP>:/tmp/old.bin
ssh root@<IP> 'mtd write /tmp/old.bin chainloader'
EOF

  say "【路径 E】二级 chainloader 提示符下的应急（**绝不在此 saveenv**）"
  cat <<'EOF'

U-Boot> setenv bootcmd 'run boot_ubi || http_recovery'
U-Boot> boot
    ↑ 仅改内存，不 saveenv。用于临时手工启动。
    ↑ 二级没有 flash 命令（strings 实测 "flash write" 命中 0），但有 mtd 读写。

# 二级下恢复原厂 env（官方 FAQ §8.1；注意 mtd write 会动 uenv，谨慎）
U-Boot> setenv serverip 192.168.0.10
U-Boot> setenv ipaddr 192.168.0.1
U-Boot> tftpboot 0x90000000 01_env_data.bin
U-Boot> mtd list
U-Boot> mtd erase uenv 0 0x200000
U-Boot> mtd write uenv 0x90000000 0 0x200000
EOF

  say "【路径 F】HTTP Recovery 页（能进恢复模式时最省事）"
  cat <<'EOF'

① 上电时按住 reset 键，LED 变色后松手
② 电脑网卡设静态 192.168.0.10/24（恢复模式 U-Boot 固定 192.168.0.1/24，不依赖 DHCP）
③ 浏览器打开 http://192.168.0.1
④ 刷 chainloader → 选 **uboot** 目标，上传 xr1710g-chainloader-*-slot.bin
⑤ 刷固件   → 选 **firmware** 目标，上传 *-sysupgrade.itb
   串口应出现： httpd: accepting <bytes>-byte firmware for UBI 2.0
EOF
}

# ---------------------------------------------------------------------------
run_tftp(){
  say ""; hr; say "---- 启动 TFTP ----"; hr
  mkdir -p "$TFTP_ROOT"
  say "根目录: $TFTP_ROOT"
  ls -la "$TFTP_ROOT" | sed 's/^/  /'
  say ""
  say "⚠️  绑定 69 端口需要 root。可能会提示输入 sudo 密码。"
  say "⚠️  Ctrl-C 停止。"
  say ""
  if [ -x /usr/libexec/tftpd ]; then
    say "使用 macOS 内置 tftpd（-l 只读，-r 指定根目录）"
    exec sudo /usr/libexec/tftpd -l -r "$TFTP_ROOT"
  elif command -v atftpd >/dev/null 2>&1; then
    exec sudo atftpd --daemon --port 69 --root "$TFTP_ROOT"
  else
    bad "没有可用的 tftpd —— brew install atftp 后重试"
    exit 1
  fi
}

case "$MODE" in
  check)  check_toolchain;;
  stage)  check_toolchain; stage; print_serial; print_cmds;;
  tftp)   run_tftp;;
  serial) print_serial; print_cmds;;
  all)    check_toolchain; stage; print_serial; print_cmds;;
esac
