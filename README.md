# Gemtek XR1710G / ImmortalWrt 安全升级工具包

一套用于给 **Gemtek XR1710G**（Brightspeed 同款）路由器刷 **naoki66 第三方 ImmortalWrt 构建** 的安全升级编排脚本。
核心目标：**全清刷（`sysupgrade -n`，不保留旧配置）也能在刷机窗口内零人工介入地自举回原连网状态**，并带多层兜底防变砖。

> ⚠️ **第三方固件风险提示**：本工具依赖社区第三方构建（非官方 ImmortalWrt，官方 `downloads.immortalwrt.org/airoha/an7581` 目录为空）。
> 该构建由单维护者维护，存在供应链 / bus-factor 风险。使用前请自行评估。U-Boot 常住兜底可避免"刷坏需拆机"，但无法消除固件本身风险。

---

## ✅ 当前状态（2026-11-17 真机实证）

**B+A 双刷已完成，设备正常**：固件 `20261115-5e152df9`（内核 6.18.60）+ 官方 11-11 chainloader `U-Boot XR1710G-2026-11-11-ga9a12de55890`。mtd3 前 937538B 与官方镜像逐字节一致，MAC 重复已修复（cpu/lan3/lan4 = `…64`/`…65`/`…66`），mtd1 未动，`post_flash_verify.sh` 重跑 3 pass / 0 fail / 2 warn。刷后基线在 `~/router-upgrade-logs/post-flash-20261117-0650/`。

**TTL 不再需要**（用户 2026-11-17 明确）：U-Boot 已刷好，不拆机。TTL 工具保留为最后兜底，非刷机前置条件。下方第六/七轮的"待办清单"是历史快照。

---

## 文件清单

| 文件 | 作用 | 是否入库 |
|---|---|---|
| `upgrade_router.sh` | Mac 侧编排器：上传固件+kit、路由器侧 sha 复核、触发干净刷、轮询重连、终验、强终验失败自动回退；刷前还有 T2 兜底实测核验与 kit 有效性核验 | ✅ 入库 |
| `router_watch.sh` | 按需守护：查最新 release（按 `published_at` 排序）、72h 沉淀闸、版本性质与配置兼容性双闸、独立 sha256 校验、watch.log 轮转、触发 `upgrade_router.sh --auto`；`--no-download` 为零副作用巡检 | ✅ 入库 |
| `check_openclash.sh` | Mac 侧 OpenClash 一键健康诊断：真实节点数 / 订阅自动更新三层闸门 / config_path 一致性 / 出口节点对关键站点可达性（识别被封节点） | ✅ 入库 |
| `ttl_rescue.sh` | **TTL 救砖预案**：工具链体检 / 摆 TFTP 根目录 / 起 TFTP / 打印 6 条救砖路径（A: TTL 刷新 B: TTL 回滚 C: 恢复原厂 env D: SSH E: 二级提示符应急 F: HTTP Recovery） |
| `post_flash_verify.sh` | **刷后 5 分钟验证**：版本串 / MAC 重复是否修复 / 恢复页 IP / fastmap / 引导配方归一化 |
| `uboot_upgrade.sh` | **U-Boot(chainloader) 独立升级/回滚 + env 冗余对修复**（`--fix-env-redundancy`）：`--status` 只读探测 / `--plan` 选片校验 / `--prepare` 备份+下载校验 / `--flash` 真刷（写后整块回读比对）/ `--rollback` 回滚 / `--probe-recovery` 救砖探测。五道闸：官方选片纪律、备份 fail-closed、三层 sha256、双入口 magic、写后回读；**绝不触碰 uenv/ubootenv** | ✅ 入库 |
| `zzz-restore-router` | 路由器首启动自举（`/etc/uci-defaults`）：写 LAN/WAN/三频/防火墙、恢复 root 密码与 WiFi key、注入 OpenClash 安装步骤 | ✅ 入库 |
| `build_kit.sh` | 本地从源码组装 `kit.tar.gz`（默认安全写到 `dist/`，**拒绝覆盖真 kit**），写入无敏感信息的 `etc/kit-manifest` | ✅ 入库 |
| `scripts/secret-scan.sh` | 提交前/CI 自动密钥扫描：拦截任何明文密码/订阅/token 进 Git | ✅ 入库 |
| `.github/workflows/secret-scan.yml` | 每次 push/PR 自动跑密钥扫描 | ✅ 入库 |
| `kit.tar.gz` | 打包后的 kit（含 `zzz-restore-router` + 你的 `authorized_keys` + 可选 OpenClash 配置） | ❌ `.gitignore` 排除 |
| `*.itb` | 第三方固件镜像（53MB，由 watch 自动下载） | ❌ 排除 |
| `backups/` | 升级前 `sysupgrade -b` 配置快照 | ❌ 排除 |
| `watch.log` | 守护运行日志 | ❌ 排除 |

---

## 敏感信息处理（关键设计）

**本仓库源码不含任何明文密码 / WiFi key / 机场订阅。** 所有敏感数据都在**升级前从活路由器实时抓取**，注入到仅存在于 `/tmp` 的临时 kit，脚本退出即被 `trap` 清理：

- `collect_runtime()`（`upgrade_router.sh`）升级前 SSH 抓取：root 的 `/etc/shadow` 行、WiFi key、三频 SSID、`/etc/openclash/*`（订阅会过期，必须取活路由当前的）
- 写入临时 kit 的 `etc/router-secrets`，`zzz-restore-router` 首启动读取并写回，用后即删
- `kit.tar.gz` 本身**不入库**，由你本地 `build_kit.sh` 用**自己的** `authorized_keys` 生成

> 因此本仓库可以安全公开。**入库前 `scripts/secret-scan.sh` 会自动扫描（本地可手动跑、CI 每次 push/PR 也会跑），任何明文密码 / 订阅 / token 想进 Git 都会被自动拦截。** 同时 `.gitignore` 已排除 `kit.tar.gz`、`*.itb`、`backups/`、`dist/` 等。

---

## 前置条件

- macOS（脚本用到 `osascript` 桌面通知、`sed -i ''`、BSD `date`）
- 已 `ssh` 到路由：`~/.ssh/config` 中 `Host <router>` → 路由器 LAN 地址（如 `192.168.x.1`），且 Mac 公钥已能 key 登录。脚本也会自动探测该配置或交互询问，无需写死地址。
- `gh` CLI 已登录（watch 查 release / 自动刷新 `EXPECT_SHA` 需要）
- `curl`（独立 sha256 校验需要）

---

## 用法

### 1. 首次准备 kit
```bash
./build_kit.sh --keys ~/.ssh/id_ed25519.pub
# 产物默认写到 dist/kit.tar.gz (已 gitignore), 绝不碰仓库根在用中的真 kit
# --keys 接受任意"一行一把"的 authorized_keys 格式公钥文件; 也可用 kit 内现成的 etc/dropbear/authorized_keys
# 可选: 带入当前 OpenClash 配置作为离线兜底
# ./build_kit.sh --keys ~/.ssh/id_ed25519.pub --openclash /tmp/my-openclash
```
> 安全栏：`build_kit.sh` 默认拒绝覆盖仓库根的 `kit.tar.gz`（那是你正在用的真 kit，含 OpenClash 订阅 + 公钥）。
> 想重建真 kit 必须显式 `--out kit.tar.gz --force`。因此"别随手跑 build_kit.sh"这类人工提醒已不再需要——脚本自己会拦。

### 2. 检查是否有新版本（不升级）
```bash
./router_watch.sh --no-download   # 纯只读: 只检测报告, 零下载 / 零文件写入 (定时巡检推荐)
./router_watch.sh --check         # 检测 + 备料: 会下载 itb、写 sha256sums、追加 watch.log, 但绝不刷机
```
> `--check` 的「只检测」指的是不刷机, **不是零副作用**；真要零副作用用 `--no-download`。

### 3. 你通知后全自动升级（推荐，保留 72h 沉淀闸）
```bash
./router_watch.sh --now
```
脚本会：查最新 release → 版本性质 `TEST`/`PRERELEASE` 默认停；正式版但要求 `wipe-config` 时停在「配置重建显式确认」处（需 `--now --ack-config-reset`）→ 等发布满 72h → 下载 itb + 官方 `sha256sums` / `asset.digest` 独立校验 → 调 `upgrade_router.sh --auto`（`EXPECT_SHA` 由其运行时派生）。

### 4. 直接手动升级（已手动下好 itb 时）
```bash
./upgrade_router.sh            # 真正执行（触发重启）
./upgrade_router.sh --dry-run  # 只校验前置 + 打印将执行的命令
./upgrade_router.sh --auto    # 强终验失败自动回退（供 watch 调用）
./upgrade_router.sh --force   # 仅跳过"发布满 72h"沉淀闸（不影响 sha256 完整性校验）
./upgrade_router.sh --allow-test-build  # 显式放行测试版/预发布 (默认拒绝)
./upgrade_router.sh --ack-config-reset  # wipe-config 正式版: 显式确认"配置不保真、需人工重配"
./upgrade_router.sh --config-policy selective  # 强制版本感知选择性重建(通常自动切换, 无需手加)
./upgrade_router.sh --allow-unverified-t2  # 刷前读不到 U-Boot/T2 兜底时仍刷(自担风险)
./upgrade_router.sh --allow-stale-kit       # 允许使用陈旧 kit(自担风险; 默认拒绝)
```
`EXPECT_SHA` 由 `derive_expect_sha()` 运行时派生（优先 GitHub `asset.digest`，缺失时按文件名查历史 digest，再退 `sha256sums`）。**有官方基准但不匹配时任何参数都不放行**；完全拿不到基准才可用 `--allow-unverified-sha`（其它放行开关：`--allow-same-version` / `--allow-recent-crash` / `--allow-test-build`）。

---

## 四层安全模型

1. **T0 预防**：首启动 `uci-defaults` 自举恢复 LAN IP（**XR1710G 出厂默认 `192.168.50.1/24`**；正常路径升级前从活路由器抓取真实 LAN IP 注入，`192.168.1.1` 是 XG2010G/Nokia 的地址，别混用）+ 原 SSID，刷机窗口内 Mac 无需人工接手（WiFi 主路径，有线兜底）。
2. **T1 检测**：脚本轮询重连（候选含出厂 `192.168.50.1`）+ 终验；刷前另有 `verify_t2_fallback()` 实测核验 U-Boot 兜底是否在位、`verify_kit()` 核验 kit 是否按当前源码/目标固件重建。
3. **T2 恢复**：U-Boot 常住兜底 `bootcmd=run boot_ubi || http_recovery`（实测在位）——刷坏自动进 HTTP Recovery，免拆机。**恢复页地址随 U-Boot 变**：2026-11-17 已刷入官方 11-11 chainloader，**当前恢复页 = `192.168.0.1`**（刷前旧版为 `192.168.255.1`）。进入方式上电按 reset、LED 变色松手。⚠️ 恢复页尚未实地进入验证过。
4. **T3 回退**：刷前自动解析"当前运行版本"对应的本地 itb 作回退镜像；强终验失败自动 `sysupgrade -F` 回退**并连带还原升级前配置快照**（`backups/`）。

---

## 升级前自动做的事

- `backup_config()`：升级前 `sysupgrade -b` 对当前运行配置做快照，落 `backups/`（配置级回退点）。
- `verify_t2_fallback()`：刷前读活跃 UBI 卷 `bootcmd` + mtd3 版本串 + 恢复页 IP，兜底不在位即拒绝刷机（可用 `--allow-unverified-t2` 放行）；基线写进 `report.md` 与刷后实测对比。
- `verify_kit()`：只提取 2 个非敏感成员核验「自举脚本 sha256 == 仓库源码」「必需文件齐全」「manifest 绑定目标固件」，陈旧 kit 默认拒绝（`--allow-stale-kit` 放行）。
- `collect_runtime()`：
- 退出清理：`trap` 删除 `/tmp/kit_build` 与 `/tmp/kit_injected.tar.gz`（含 root hash，绝不落盘）。

## 升级后自动做的事

- 结构化报告 `report.md` 第 8 节输出 **U-Boot / T2 刷前基线 vs 刷后实测**（bootcmd、U-Boot 版本串、恢复页 IP），刷过 chainloader 后兜底变化一眼可见。
- `--auto` 成功：
- `--auto` 失败：自动回退旧固件 + 旧配置，回退后仍失败则提示进 U-Boot Recovery。

---


## 官方 SSH 刷写路径（naoki66 官方文档，2026-11-11 新增）

官方已提供**完整的 SSH 刷 chainloader 文档**：`docs/ssh-flash-chainloader.md`（仓库
`naoki66/Gemtek-brightspeed-chainloader`）。本 skill 的 `--flash` 已与其对齐。

官方第 4 步原文：

```sh
ssh root@<设备IP> 'mtd write /tmp/new-slot.bin chainloader'
```

关键事实（实测确认）：

- 设备 `mtd` usage 明写 **"The device is in the format of mtdX (eg: mtd4) or its label"**
  → **可直接用 label `chainloader` 写，不依赖 mtd 编号**（编号可能随固件变）。
- `mtd` 支持子命令：`dump / unlock / refresh / erase / verify / write / jffs2write`。
- 官方说明 "写入只覆盖镜像长度，尾部保持擦除后的 `0xff`" → **mtd 内部自行处理末块对齐**，
  因此**不需要**本地 pad（pad 版只留给 `dd` 兜底路径）。
- ⚠️ **`dd` 直写 `/dev/mtdX` 仍受限**：只接受**整擦除块**写入。官方镜像 937538 B
  = 7×131072 + 20034 B 尾巴 → dd 最后一次 `write()` 非对齐 → 内核 EINVAL。
  这是 2026-11-16 实测故障（`WRITE_BEGIN` 后无 `WRITE_DONE`），设备未受损。
  **结论：`mtd write` 是唯一可靠路径，`dd` 必须先 pad。**

### 官方固件 release note 明确要求固件与 U-Boot 配套升级

naoki66 固件 `20261112` release note 原文：

> 2. 1710 开放 ssh 刷写引导功能，后期引导 uboot 也可以 OTA。
> 3. 修复 1710 的 lan cpu 的 mac 地址相同问题，后续不再需要手改
>    （需刷入 `2026-11-11-a9a12de55890` 实现）

⇒ **只刷固件不刷 U-Boot，CPU 口 MAC 重复不会修好**。官方把两者绑定为一次升级。

### 本机实测：CPU 口 MAC 重复（官方 11-11 正好修这个）

```
br-lan = cpu = lan2 = lan3 = lan4 = 00:58:28:d7:63:60   ← 5 个接口同 MAC
```

官方 11-11 提交 `board: airoha: an7581: give the XR1710G CPU port its own MAC offset`
专治此病，官方 SSH 文档亦实测确认："重启前 CPU 口与 lan2 的 MAC 重复，重启后 CPU 口变为 LAN base + 4"。

### UBI fastmap：官方版独有的启动加速

| | 本机 YYH2913 `2026.07-00760-gab7fd65100f1` | 官方 `2026-11-11-ga9a12de55890` |
|---|---|---|
| `ubi_attach_fastmap` 符号 | **0 个**（实测 strings 计数） | `ubi_attach_fastmap` / `ubi_update_fastmap` / `ubi_write_fastmap` 全有 |
| `CONFIG_MTD_UBI_FASTMAP` | 无 | `=y` + `AUTOCONVERT=1` |
| U-Boot 侧 UBI attach | 全盘扫 ≈3500 PEB | 读几个 anchor PEB |
| `CONFIG_BOOTDELAY` | 3（本机 env 实为 2） | 1 |
| env 后端 | UBI `ubootenv`/`ubootenv2` | MTD `uenv`（共享原厂，**不可 saveenv**） |
| 恢复页 | 192.168.255.1（刷前） | 192.168.0.1（**现用，已刷 11-11**） |

内核侧 attach 实测耗时：`1.635s attaching → 3.348s scanning finished`（约 1.84 s）。

### sysupgrade 路径（本机走 fit_do_upgrade，不碰 mtd3）

- 本机 `board_name = gemtek,xr1710g`（**不带 `-ubi`**）→ `platform_check_image` 走
  `fit_check_image` 分支，**不触发** `gemtek_ubi_layout_check`（后者要求 `bl2` 分区 +
  `fip`/`ubootenv`/`ubootenv2`/`factory`/`fit` 五卷，本机无 `bl2`/`fip`，故必须走非 `-ubi` 分支）。
- `fit_do_upgrade` → `export_fitblk_bootdev` 检出 `CI_METHOD=ubi` → `nand_do_upgrade`
  → **只写 fit 卷，不动 mtd3** ⇒ 固件升级与 U-Boot 升级**完全解耦**。
- 平台脚本在 **`/lib/upgrade/`**（不是 `/usr/lib/upgrade/`），后者目录为空属正常。
- **`sysupgrade -T <itb>` 是只读校验模式**（EXIT=0 即兼容），刷前必跑。
  实测 1115 固件：`sysupgrade -T` EXIT=0，`fit_check_sign` 全 OK（kernel-1 6.18.60 /
  fdt-1 / rootfs-1 三项 crc32+sha1 全过）。

### 🔧 救砖与刷后验证（2026-11-16 第七轮闭环）

| 脚本 | 作用 | 用法 |
|---|---|---|
| `ttl_rescue.sh` | TTL 救砖预案：工具链体检 + 摆 TFTP 根目录 + 起 TFTP + 打印 6 条救砖路径 | `./ttl_rescue.sh --check` / `--stage` / `--tftp` / `--print-serial` / `--all` |
| `post_flash_verify.sh` | 刷完 chainloader 后的 5 分钟验证：版本串 / MAC 重复修复 / 恢复页 IP / fastmap / 引导配方归一化 | `./post_flash_verify.sh [--router root@IP] [--baseline <备份目录>]` |

**官方 TTL 教程全文已核对**（`docs/flashing-xr1710g.md`），要点：
- 原厂 env（mtd1/uenv）布局 = `0x0000` 处 0x4000 字节 env 块（小端 CRC32）+ `0x4000-0x1FFFF` 全 0xFF + `0x20000` 后全 0x00 → **与我方实测完全吻合**，mtd1 备份可直接用于恢复
- 原厂提示符 `ECNT>` 有 `flash` 命令；**二级 chainloader 没有 `flash`**（`strings` 实测命中 0），但有 `mtd` → 回滚 mtd3 只能走 `ECNT>` 或 SSH
- 恢复页必须插 **10GbE 口（fport 4）**；固定 `192.168.0.1/24`，静态 `192.168.0.10/24` 更可靠
- 恢复模式两个触发条件：`recovery_trigger=1`（一次性标志，在共享 uenv 里）或 **上电按住 reset 键**
- 选 `uboot` 目标上传 = 写 mtd3 的 0x600000/1MiB，与 SSH `mtd write ... chainloader` 同一位置

**`--probe-recovery` 已增强并实跑验证**：候选去重 + `RECOVERY_PROBE_IPS` 覆盖（可自检）+ 可达时给救援指引 + 不可达时给 4 条原因排查（没进恢复模式 / 网卡网段不对 / 网口不对 / 其实没变砖）。

**TTL 残余（2026-11-17 用户决定不需要）**：USB-TTL 硬件不在手边，因 U-Boot 已刷成功、不拆机，TTL 演练已撤销。工具与命令单保留为最后兜底（真变砖时才用）。

### 🔬 A/B 顺序定案（2026-11-16 第六轮只读实证）

| 步骤 | 内容 | 失败后果 | 可恢复性 |
|---|---|---|---|
| **B** | 刷官方 11-11 chainloader（写 mtd3，937538B） | 二级引导失效 → 设备变砖 | **仅** TTL / mtd3 备份写回（备份已双份异地，sha256 `a65bba65…`） |
| **A** | 刷 1115 固件 wipe-config（只写 UBI `fit` 卷，不碰 mtd3） | 新固件起不来 | SSH 可达，旧 chainloader + 旧固件仍可启动 |

**推荐 B → A**。新增决定性理由：**fastmap**。旧 YYH2913 chainloader 无 `ubi_attach_fastmap` 符号（strings 命中 0），官方 11-11 有全套 fastmap 支持（`CONFIG_MTD_UBI_FASTMAP=y` + `AUTOCONVERT=1`）；而 1115/1112/1016 固件内核 DTB 都带 `ubi.fm_autoconvert=1` —— 固件内核写 fastmap、U-Boot 读 fastmap，**先装读取器再写数据**比反过来更稳。

**本轮推翻了上一轮的"布局不匹配"担忧**：官方 20261112 固件内核 DTB 的 partition@700000 label 是 `ubi`（不是 `system`），与 1115、1016 逐属性一致；label=`system` 的那份是**官方 chainloader 内嵌的控制 DTB**，不是固件 DTB。三份固件 UBI 卷集完全相同（`ubootenv`/`ubootenv2`/`fit`/`factory`），offset/size 完全相同 → **零 layout 风险**。

官方 20261112 release note 原文绑定："修复1710 的lan cpu 的mac地址相同问题…（**需刷入** chainloader `2026-11-11-a9a12de55890` 实现）"；1115 未对 chainloader 提新要求，chainloader 仓库 11-11 后无新提交 → **1115 + 11-11 chainloader 组合合法**。

**B 之前必须先落实（2026-11-17 已完成/撤销）**：① ~~TTL 救砖预案~~ **已撤销**（U-Boot 刷成功，不拆机）；② 恢复页 IP `192.168.255.1` → `192.168.0.1` 入口已记录；③ mtd3 备份双份异地 ✅；④ MAC 基线逐接口比对 ✅（刷前全同 `…60` → 刷后 cpu/lan3/lan4 = `…64`/`…65`/`…66`）。

## 🔧 U-Boot(chainloader) 升级（独立窗口，与固件升级分离）

固件升级刷 UBI/fit 卷，U-Boot 升级刷 mtd3(chainloader) + env 层，写入路径与失败模式完全不同 —— **两个独立窗口，先固件稳定再 U-Boot**。

```bash
cd ~/.workbuddy/skills/router-immortalwrt-upgrade
bash uboot_upgrade.sh --status      # 只读探测(mtd布局/env冗余/版本串/magic)
bash uboot_upgrade.sh --plan        # 官方选片+digest+结构校验(不写入)
bash uboot_upgrade.sh --prepare     # 备份+下载+校验(不写入)—— 推荐先跑
bash uboot_upgrade.sh --flash --ack-uboot-flash   # 真刷(写后整块回读比对)
bash uboot_upgrade.sh --rollback --ack-uboot-flash --backup-dir <备份目录>
bash uboot_upgrade.sh --probe-recovery             # 救砖时探测恢复页
```

**刷前必看**：
- 只刷 `xr1710g-chainloader-*-slot.bin`；**绝不刷 `u-boot.bin` / 裸 `.itb`**（上游明确说裸 FIT 不能通过 HTTP Recovery 上传）。XR1710G 与 XG2010G 镜像不通用。
- **绝不**在 chainloader 里 `saveenv` / `env default -a` —— `uenv`(mtd1) 是原厂 U-Boot 的 env 分区，chainloader 只是共用读取；saveenv 会让原厂 U-Boot 找不到启动配方（卡在 `ECNT>` 报 `Unknown command 'ubi'`）。
- 本机**已处于「已刷 chainloader」状态**，上游 TTL+TFTP 教程针对的是原厂 U-Boot 状态 → 本机日常路径是 HTTP Recovery 的 `uboot` 目标上传；TTL 是最后的救砖手段。
- 恢复页随 U-Boot 变：刷前 `192.168.255.1` → **现用 `192.168.0.1`**（已刷 11-11）。状态档案在 `~/router-upgrade-logs/uboot-state.env`（待更新为实测值）。
- ✅ **env 冗余对已修复**（2026-11-16）：`ubootenv`(`ubi0_1`, dynamic) 原为全 0xFF 空卷，真实 env 只在 `ubootenv2`(`ubi0_2`, **static**)，属单点保险。已用 `uboot_upgrade.sh --fix-env-redundancy --ack-env-fix` 把 ubootenv2 的 env_t 复制成 ubootenv 的有效副本（`flags` 置 `0xFF` obsolete）→ U-Boot 仍选 ubootenv2（引导行为零变化），但 ubootenv2 损坏时可回落。ubootenv2 未被触碰。
- ⚠️ **NAND 写入必须按擦除块对齐**（2026-11-16 实机故障，两轮实证）：官方镜像长 **937538** 字节，不是 `erasesize`(131072) 的整数倍 → NAND 字符设备拒绝非整擦除块写入，内核 **EINVAL**。**症状是 `WRITE_BEGIN` 后没有 `WRITE_DONE` 且 dd 静默失败**。解法：写前把镜像用 `0xFF` pad 到 1048576 字节，优先 `mtd write` + `mtd verify`；**绝不把写命令接管道后取 `$?`**（那是 `tail` 的退出码，会伪装成功）。详见 `SKILL.md`「NAND 写入路径踩坑」。
- 📌 **MAC 说明（2026-11-16 第五轮更正）**：`mtd1` 的 env CRC **完全有效**（此前"CRC 失效"是长度用错），只是原厂 ECNT 格式（`crc(4)+data[16380]`，无 flags），与 U-Boot `env_t` 不同。二级 U-Boot 通过 `xr1710g_sync_runtime_ethaddrs()` 从 **factory 卷**同步 MAC，不依赖 `mtd1` 的 `ethaddr`（那是原厂占位符 `00:AA:BB:01:23:40`）→ **MAC 不会因 env 回落而变**。脚本已抓 MAC 基线，刷后逐接口比对即可。
  - ⚠️ **绝对不要在 chainloader 里 `saveenv`**：`mtd1` 是原厂 env 分区，覆写会让原厂 U-Boot 找不到自己的启动配方（卡在 `ECNT>` 报 `Unknown command 'ubi'`）。脚本从不执行 `saveenv`。
- 🧭 ~~必须连带刷一次固件~~ → **已更正（2026-11-16 第六轮实证）**：官方 env 走 `ubi read ${loadaddr} fit` + `bootm ${loadaddr}#config-1`，按 **UBI 卷名 `fit`** 定位，不依赖 `flash` 命令、不依赖分区 label；本机 fit 卷已实证含 `/configurations/config-1`。⇒ **刷 chainloader 可独立完成**。
  - 官方 20261112 release note 的「修复 lan cpu mac 地址相同（需刷入 11-11 chainloader 实现）」正是 **U-Boot 侧** `fixup_fdt_macs` 做的 —— 刷 chainloader 即修复，**不需要为此刷固件**。
  - env 冗余对已修（2026-11-16），固件升级与 chainloader 升级完全解耦。

## 当前上游状态与升级建议（2026-11-15 复核，会过期）

- 本机仍在 `20261016-1a34e17c`（6.18.55）。**11-15 21:36 复核时 uptime 仅 57 分钟**，dmesg 有 `UBIFS (ubi0:4): recovery needed/completed`（非干净卸载后的恢复启动），但 pstore 为空、无 Oops/panic/看门狗硬复位记录。`precheck_recent_crash` 会因此在 48h 观察窗内拒绝刷机 —— 闸正确生效。
- **最新是 `20261115` 正式版**（`20261115-5e152df9`，85,561,654 B，`sha256:7a828e88…d0111`，北京 11-15 14:51 发布，`prerelease=false`，无 `sha256sums` 走 `asset.digest`）。发布说明主打「完善全链路 NPU 加速」「桥接拨号 NPU 加速」「修复 1710 无线持续强复核下保护性」「PPE 统计队列堵塞保护」「重写 NPU 监控和风扇控制」「修复默认 APK 安装源」，并加粗警告 **「此版本为后端大改动，和旧版本配置文件不兼容」「默认不得保留配置和导入旧版本配置」**，`OTA: wipe-config`。核查时下载 308 次、发布后零新建 issue（样本太短）。
- **NPU 修复溯源**：最新公开提交仍是 11-13 `9a70b257`（README），其前是 11-11 晚那批 NPU/MT7996 根因修复；release 基线逻辑上包含它们，但镜像内嵌 commit `5e152df9` 在公开 master **查不到**，作者从未明确声明「修了 #82」。`#82` 报告者 11-15 回复「升级以后需要双清，就好了」—— 用户经验，与「配置不兼容」呼应，非作者确认。
- issue 动态：`#95`（1112 AP 模式 Qualcomm 重试风暴）作者 11-15 回复「刷入最新版测试」+ 复测方法，**未确认**已修；`#96`（XG2010G NPU 数据通路卡死）作者求补全日志；其余 open：`#94`（5G/6G VIF flowtable）、`#92`（B17 PCIe）、`#62`（PON 校准）。1029 的 `#81` bridger 断流仍靠停服务规避。
- **72h 沉淀闸**：到 **11-18 14:51（北京）** 才过。叠加 48h 异常复位观察窗、镜像 commit 不可溯源、配置不兼容，**当前不刷机**。
- **U-Boot**：2026-11-17 已刷入官方 11-11 `ga9a12de55890`（版本串 `U-Boot XR1710G-2026-11-11-ga9a12de55890`，恢复页 `192.168.0.1`）；刷前为 `2026.07-00760-gab7fd65100f1`（恢复页 `192.168.255.1`），同 mtd3/0x600000/1MiB 槽位。**`ubi` vs `system` 的兼容疑点已于 2026-11-16 彻底闭环**（第六轮实证：官方 1112 固件内核 DTB 的 partition label 也是 `ubi`，与 1115/1016 逐属性一致；label=`system` 的那份是 chainloader 内嵌控制 DTB，非固件 DTB）。**成功率（第六轮上修）：只刷 U-Boot 88% / 只刷固件 70% / 两者都刷 72%**，推荐顺序：**先刷官方 11-11 chainloader**（fastmap 硬约束：固件内核写 fastmap，旧 chainloader 无 `ubi_attach_fastmap` 符号）→ 立即验证版本串/MAC/恢复页 IP `192.168.0.1` → 需要 NPU 改进再单独刷 1115 固件。刷前必备：mtd3 + mtd1/uenv 备份（已双份异地）+ MAC 基线。~~TTL 串口~~ 已撤销（2026-11-17 刷成功，不拆机）。
- **固件建议（触发条件）**：过 72h → 复核新 issue 与作者是否确认 #82 → **先按新固件重建 kit（`--config-policy selective`）** → 人工核对 `config-restore-todo-*.md` 重配清单 → `upgrade_router.sh --ack-config-reset` 全清刷（**不走 LuCI OTA**）。旧的「全量配置保真」路径对 1115 已不适用，详见下方「wipe-config 版本适配」。

### ⚠️ 真刷前必须先重建 kit（2026-11-13 实测）

当前仓库根的 `kit.tar.gz` 停留在 **2026-10-08**，内嵌 `zzz-restore-router` 只有 339 行（仓库源码 445 行），缺 `zzz-disabled-services` 禁用态还原等后续修复，sha256 不一致。`collect_runtime()` 只会往这份旧 kit 里注入配置，**不会更新自举脚本** —— 用它全清刷会静默丢配置。现在 `verify_kit()` 会在刷前拦下：

```bash
# 从现有 kit 自提取素材, 无需任何外部文件
mkdir -p /tmp/kit_rebuild
tar -xOf kit.tar.gz ./etc/dropbear/authorized_keys   > /tmp/kit_rebuild/authorized_keys
tar -xOf kit.tar.gz ./etc/openclash/core/clash_meta  > /tmp/kit_rebuild/clash_meta
./build_kit.sh --keys /tmp/kit_rebuild/authorized_keys \
  --openclash-core /tmp/kit_rebuild/clash_meta \
  --config-policy selective \
  --out kit.tar.gz --force
```

> 目标是 `20261115` 这类 `wipe-config` 版本时**必须**加 `--config-policy selective`；若刷的是配置兼容的同代版本，用默认值 `full`。`collect_runtime()` 运行时还会按实际策略覆写 manifest，`verify_kit final` 会核对两者一致。
>
> `--force` 在这里是**故意**的：本步就是要覆盖仓库根的真 kit，而素材已在覆盖前从旧 kit 提取完毕（含 57MB 的 `clash_meta`，不重新烘焙会让全清刷后代理内核缺失）。重建后自举脚本 sha 与源码一致、manifest 齐备，`verify_kit()` 才放行。`--allow-stale-kit` 可显式绕过，但等于自担丢配置风险。

> 完整证据链、历次误判更正与 `saveenv` 陷阱见 `SKILL.md`「U-Boot / chainloader 评估基线」。

## License

[MIT](./LICENSE)

## 🧩 wipe-config 版本适配（2026-11-15，重大行为变更）

**结论先行**：`20261115` 是 `prerelease=false` 的正式版，但发布说明明令「此版本为后端大改动，和旧版本配置文件不兼容」「默认不得保留配置和导入旧版本配置」。本工具原来的核心是 `sysupgrade -F -n -f kit.tar.gz` + `collect_runtime()` **全量兜底导入活机 `/etc/config`** —— 这正是官方禁止的动作。因此 Skill 已从「全量配置保真」升级为**版本感知的选择性重建**；`TEST`（版本性质）与 `WIPE-CONFIG`（配置兼容性）也拆成两个独立信号。

### 真实 diff 证据（不是推断）

解包 1115 官方 itb（85,561,654 B，digest `sha256:7a828e88…d0111`）切出 rootfs.squashfs，导出出厂 `/etc/config`，与本机 `20261016` 运行态逐文件比对：

| 分类 | 数量 | 代表 | 处理 |
|---|---|---|---|
| 逐字节相同 | 22 | `fan` / `ddns` / `upnpd` / `xray` | 出厂本来就有，无需导入 |
| 内容被新版改写 | 9 | `firewall` 3261→4159B、`uhttpd` 742→4569B、`dhcp` 2280→1325B、`zerotier` 617→1918B、`luci`/`rpcd`/`smartdns`/`watchcat`/`openssl` | **禁止导入**（会覆盖新版默认） |
| 仅本机有 | 19 | `airoha_npu` / `npu-monitor` / `cpufreq` / `network` / `wireless` / `system` / `fstab` / `openclash` | 除 `openclash` 外全部排除 |
| 仅出厂有 | 9 | `bridger` / `pbr` / `sing-box` / `naoki66-ota` / `naoki66-overview` / `nlbwmon` / `easytier` / `argon` / `ac` | 保留出厂默认 |

关键实证：
- **1115 出厂 `/etc/config` 里没有 `network` / `wireless` / `system`** —— 由 `board.d` + `03_wireless` + `22_airoha-network-migrate-v4` 在首启动生成。导入旧文件会跳过生成并造成混合状态（`03_wireless` 还会覆写 radio 硬件参数）。
- 本机 `distfeeds.list` 指向 `mirrors.vsean.net`，1115 出厂指向 `downloads.immortalwrt.org`（发布说明「修复默认 APK 安装源」即此事）。该文件注释明写 *auto-generated and build-specific, changes will be intentionally lost in sysupgrade*。导入旧源会覆盖修复，而 `zzz-restore` 的 `rc.local` 靠 `apk add luci-app-openclash` 装回代理，源错则全清刷后代理起不来 → 只抓 `customfeeds.list`。
- 新版移除了 `airoha_npu` / `npu-monitor` / `cpufreq`（正是「重写 NPU 监控和风扇控制」的对象），导入即悬空 UCI 文件。

**两处早期推断已按实测纠正**（避免误伤）：① `fan` 与出厂**逐字节相同**（重写的是控制程序，不是配置格式），排除它只为让新版出厂值生效；② 出厂 `firewall` **自带 `fullcone=1`**，`18-xr1710g-firewall-defaults` 只设两个 offload —— 因此不是删掉 `fullcone`，而是改为「仅当该 option 已存在才回写」。

### 两种配置策略

| | `full`（默认） | `selective`（wipe-config 自动切换） |
|---|---|---|
| 适用 | 同代小版本，配置格式兼容 | 官方声明配置不兼容 / `OTA: wipe-config` |
| `/etc/config` | 全量兜底 + `EXTRA_CONFIGS` 整文件导入 | **完全不导入**，仅白名单 `openclash` |
| 身份数据 | 全量 + 补丁 | 补丁式 `uci set`：LAN IP / 三频 SSID+key / 6G 关闭 / DHCP 静态租约 |
| 网络与无线 | 整文件还原 | **不覆写**，沿用新版 `board.d` + uci-defaults 生成结果 |
| 定制路径 | 全部 `EXTRA_PATHS` | 仅 `SAFE_EXTRA_PATHS`（crontab / lan_report / token / 脚本 / known_hosts / `customfeeds.list`），排除 LuCI 补丁 |
| 服务启用态 | 导入旧 `/etc/rc.d` + 链接名禁用清单 | 不导入；禁用清单改抓**服务名**，首启动 `init.d disable`，与 S/K 编号解耦 |
| 保真度校验 | 逐字节一致 = 成功 | 分层：白名单必须还原，其余**期望变化** |

自动规则：release 标记含 `WIPE-CONFIG` → 自动切 `selective`；可用 `--config-policy full|selective` 显式覆盖（覆盖=自担风险）。`verify_kit final` 会扫注入 kit 的 `etc/config/*`：命中 `INCOMPATIBLE_CONFIGS` 黑名单、或 selective 下出现白名单外文件、或 manifest 的 `config_policy` 与本次策略不符，一律 **fail-closed 拒绝刷机**。

### 新增参数与闸语义

```bash
./upgrade_router.sh --dry-run                       # 1115 现在标记 WIPE-CONFIG(不再误报 TEST), 自动切 selective
./upgrade_router.sh --ack-config-reset             # 真实刷 wipe-config 版本需显式确认"配置不保真"
./upgrade_router.sh --config-policy full           # 显式覆盖策略(自担风险)
./build_kit.sh --keys <pub> --config-policy selective --out kit.tar.gz --force
router_watch.sh --now --ack-config-reset           # 守护默认停在配置确认处, 不擅自丢配置
```

- **`TEST` / `PRERELEASE`**：版本性质，仍是默认拒绝，需 `--allow-test-build`。
- **`WIPE-CONFIG`**：不是拒绝刷的理由，而是**强制启用 selective + 显式确认**。旧逻辑把它算进 `TEST`，会给 1115 这类正式版输出「等正式版」的错误建议（它本身就是正式版），过了 72h 还得用「自担测试版风险」的参数才能刷 —— 已修正。
- `TAG-DATE-MISMATCH` 保留为独立客观信号，仅告警。
- `gh` 401 兜底：环境注入无效 `GITHUB_TOKEN` 时自动丢弃改用 keyring，避免「自动选片 / 官方 digest / 发布闸」全线静默降级。

### 升级后要人工做什么

`selective` 模式下 `collect_runtime()` 会生成 `~/router-upgrade-logs/config-restore-todo-<时间戳>.md`，列出本机全部 `/etc/config` 及处理标记（**只记文件名与大小，不含密钥/订阅**）。2026-11-15（二）之后，下表绝大多数项已自动恢复：10 个 ONLY-LIVE 第三方配置整文件导入、9 个 DIFF 文件按键级迁移表回写、OpenClash 与 4 个第三方程序离线注入；仍需人工核对的主要是 `glass` 主题（1115 出厂无，需另装）、`openssl` 空文件语义，以及未离线化的 `usteer`/`socat`/`udpxy` 等程序本体（配置已保真，程序需另行装回）。

> 明确**不用改**、跨版本安全：OpenClash 全链路（`/etc/config/openclash` + `zzz-oc-data` + `clash_meta` + **kit 离线程序注入**）、root shadow / WiFi key / SSID / LAN IP / DHCP host / dropbear host key / `authorized_keys`、`/etc/crontabs` 用户项、`auto_rollback()` 的 `sysupgrade -F -f rb-config.tar.gz`（回退目标是旧固件，旧配置匹配）。

> ✅ **`kit.tar.gz` 已重建为 selective 版**（2026-11-15 二），内嵌自举脚本 sha 与仓库源码逐字节一致、manifest `kit_schema=3` / `config_policy=selective`，`verify_kit pre` 通过。旧 10-08 kit 已备份到 `dist/kit-legacy-20261008.tar.gz`。注意：`zzz-oc-app` / `zzz-extra-app` / `zzz-config-ref` 是 `collect_runtime()` 在真实刷机时从活路由动态注入的，静态 kit 不含它们，这是设计而非缺陷。

### 2026-11-15 深度审计后的加固（源码级 + 沙盒实证）

**① 第三方程序离线化（决定性）**
解包 1115 官方镜像并比对 tag `20261115` 源码（9/9 逐字节一致）后发现：`1710.config` 明写 `# CONFIG_PACKAGE_luci-app-openclash is not set`，出厂 `init.d` / `config` 全无；`downloads.immortalwrt.org` 与 `mirrors.vsean.net` 的 `luci/packages.adb`(422120B)、`packages.adb`(802074B) 中 openclash 命中均为 **0** —— 旧 `rc.local` 的 `apk add luci-app-openclash` 重试 8 次必然失败，配置导入了而程序不在，代理网关断、强终验 FAIL、自动回退。

改为：`collect_runtime()` 在 `selective` 下从活路由导出 `apk info -L luci-app-openclash` 的 222 个包内文件 + `/usr/share/openclash`（9.1M 运行时脚本）+ luci cbi/view，打成 `etc/zzz-oc-app.tar.gz` 注入 kit；`zzz-restore-router` 在 uci-defaults 阶段（零联网）解到 `/`。OpenClash 的 13 个依赖（bash/ruby/dnsmasq-full/kmod-tun/kmod-nft-tproxy/…）在 1115 出厂 **全部齐备**，故无需装包。`verify_kit final` 强制校验包内 `etc/init.d/openclash` 与 `usr/share/openclash/`；强终验增加「配置在但程序不在 → FAIL」。

> ✅ **本条已于 2026-11-15（二）闭环**：`dawn` / `pushbot` / `tailscale` / `wifihistory` 已纳入 `etc/zzz-extra-app.tar.gz` 离线注入（详见下方 ④）；1115 出厂**自带** `smartdns` / `zerotier` / `watchcat`，其用户定制由 ③ 的键级迁移表恢复，不再是人工重配项。

**② 无线身份补丁不再谎报成功（离线 UCI 沙盒实证）**
在 `/tmp` 用 Python UCI 兼容层 + 命令 mock 真跑 1115 的 `03_wireless` / `11_network-migrate-bridges` / `18-firewall-defaults` / `22-migrate` 与 zzz 的 selective 补丁段，三场景结果：

| 场景 | 结果 |
|---|---|
| phy 就绪、3 个 wifi-iface | ✅ SSID/key/LAN IP/radio2 全部正确 |
| phy 未就绪、无 wireless | ❌ 补丁全静默失败，**旧代码仍打印「已按补丁方式恢复」并成功退出** |
| 只生成 2 个 wifi-iface | ❌ 6G SSID 丢失，同样谎报成功 |

根因：`03_wireless` 等 `phy0` 最多 20s 才 `wifi config`；驱动晚于 uci-defaults 时 `@wifi-iface[*]` 不存在，真实 `uci set` 报 `Invalid argument`，被 `2>/dev/null || true` 吞掉。现改为逐项 `uci -q get` 判存在、失败写 `/etc/zzz-wifi-pending` 且明确告警，`rc.local`（S95done 之后，驱动已就绪）二次补丁并 `wifi reload`，完成后删除 `router-secrets`；强终验发现残留标记即判 FAIL。


### 2026-11-15（二）剩余问题闭环：配置还原 / 第三方程序 / 闸语义

**③ 语义级配置迁移表 ——「配置不丢」闭环**

逐文件比对本机 50 个 `/etc/config` 与 1115 出厂 40 个：**22 逐字节相同**（出厂自带，无需导入）、**9 被新版改写（DIFF）**、**19 仅本机有（ONLY-LIVE）**。DIFF 的 9 个绝不能整文件导入：出厂 `firewall` 已自带 `fullcone=1` 且规则更全、`uhttpd` 4569B vs 本机 742B、`luci` 出厂**无 glass 主题**（只有 argon/bootstrap，导入 `mediaurlbase=/luci-static/glass` 会白屏）、`rpcd` 出厂**无 homepage 系统用户**（只导 login 段仍认证失败）。

- `collect_runtime()` 把活路由全量 `/etc/config` + `homepage` 的 passwd/shadow 行打成**不生效**的嵌套归档 `etc/zzz-config-ref.tar.gz` 注入 kit；值只在运行时 kit，源码与 GitHub 零明文。
- `zzz-restore-router` 在新版出厂配置之上，按硬编码**键白名单**用 `uci -c <参考目录>` 逐键取值回写：dhcp 的 dnsmasq 定制（`noresolv` / `127.0.0.1#7874` / `cachesize` / 日志项）、`odhcpd` 段、lan 的 RA 定制、firewall 的 4 个 include 段与 `tailscale0`、luci 仅语言（主题保留出厂默认，防白屏）、rpcd 的 homepage login **并同步创建系统用户**、watchcat `223.5.5.5`、zerotier secret+network、uhttpd 性能项；openssl 升级前是空文件，保留出厂默认。
- 归档用后移到 `~/router-upgrade-logs/config-reference-*.tar.gz`（chmod 600）供人工核对，临时解包目录即删。
- ONLY-LIVE 里 10 个第三方配置（`openclash dawn pushbot glass meshconf msd_lite rtp2httpd socat udpxy usteer`）在 1115 出厂**根本不存在**，整文件导入不覆盖任何出厂默认，加入 `SAFE_CONFIGS` 白名单自动恢复；其余 9 个（network/wireless/system/airoha_npu/npu-monitor/cpufreq/fstab/ubootenv/ubihealthd）明确不导入。

沙盒实证：以 1115 出厂配置为基底、脱敏升级前配置为参考，真跑迁移段 **23/23 断言通过**（含 `fullcone` 出厂默认未被破坏、主题未指向 glass、secret 动态恢复、系统用户创建、firewall include 段生成）。过程中抓到并修正一处真实缺陷：UCI 键第 2 段是 **section 名**（`config core 'main'` → `main`），早期写成 `luci.core.main.lang` 四段键会被真实 uci 判为 `Invalid argument` 并静默吞掉。

**④ 其余第三方程序离线化 + 刷前空间预检**

1115 出厂 `init.d` 与本机差 8 个服务：`airoha-npu` / `cpufreq` 是新版明确移除的（绝不恢复），`openclash` 已处理，余下 `dawn` / `luci-app-pushbot`（apk 包）与 `tailscale` / `wifihistory`（手工部署，不属任何 apk 包）由 `etc/zzz-extra-app.tar.gz` 离线注入。实测 **36MB / 48 条目**，含 `tailscale`(30MB) + `tailscaled`(39MB)、5 个 init.d 与 `tailscaled.state` 节点身份；首启动解到 `/` 并按服务名重建启用态，零联网。

踩坑实录：BusyBox `sort -u -o FILE FILE` **不写目标文件、把排序结果吐到 stdout**，污染 SSH 返回的 tar 流，造成「文件 36MB 但 `tar -tzf` 读出 0 条目」；改为 `sort -u FILE > tmp && mv` 后通过。`apk info -L` 输出不带前导 `/`，须按路径前缀白名单匹配。

因 kit 从 20MB 增至约 56MB，新增**刷前 `/overlay` 空间预检**（实测该机可用 256MB，`sysupgrade -f` 解压约需 130MB+；空间不足会在写 UBI 中途失败 = 半写变砖，故 fail-closed）。`verify_kit final` 新增强制校验：`zzz-extra-app` 含 `usr/sbin/tailscaled` 与 `etc/init.d/dawn`、`zzz-config-ref` 含 `etc/config/dhcp`，缺一即拒 —— 只列文件名，不读归档内容，避免触碰 zerotier secret / shadow hash / 节点私钥。单元测试 **8/8**。

**⑤ 复位闸语义：`--ack-manual-reboot`**

`precheck_recent_crash()` 是纯机械判据（`UBIFS recovery>0 && uptime<48h`），区分不了人工硬重启与故障。新增 `--ack-manual-reboot`：默认闸不变，只是给「已确认是本人主动重启」一条可审计的显式放行路径，且**仍实测并打印** recovery/uptime 留痕，不把人工操作误记为故障。`--allow-recent-crash` 保留兼容；72h 沉淀闸不动。


**⑥ 无人值守链路：四道闸 + 48h 钥匙透传修复（2026-11-16）**

`--auto` 只负责「强终验 + 失败自动回退」，**不是无人值守总开关**；无人值守由 `router_watch.sh --now`（或 `~/.router_autoupgrade_enabled`）启动，它再调 `upgrade_router.sh --auto`。一次完整无人值守需同时满足：

| 闸 | 所在层 | 默认 | 放行方式 | 性质 |
|---|---|---|---|---|
| 授权总闸 | watch | 停止 | `--now` 或创建 `ENABLE_FILE` | 每次显式/常驻 |
| WIPE-CONFIG 确认 | watch + upgrade | 停止 | `--ack-config-reset` | 每个 wipe-config 版本一次性 |
| 72h 发布沉淀 | watch + upgrade | 停止 | 等发布满 72h，或 `--force` | 时间窗，自然过期 |
| 48h 复位观察窗 | upgrade | 拒绝 | `--ack-manual-reboot`（推荐）/ `--allow-recent-crash` | 人工重启时一次性 |

2026-11-16 修复：`--ack-manual-reboot` / `--allow-recent-crash` 原先只在 `upgrade_router.sh` 里存在，`router_watch.sh` 既不解析也不透传 —— **闸在、钥匙递不到**：即使人工已确认是自己重启，`--now` 启动的升级仍会在 `precheck_recent_crash()` 里 `die`。现已按值组装透传，并打印「闸状态汇总」便于无人值守排障；不用 `${VAR:+--flag}`（`FORCE=0` 也是非空串，会恒展开成 `--flag`，2026-11-12 已踩过）。完整一次配置示例（可写进 launchd）：

```bash
router_watch.sh --now --ack-config-reset --ack-manual-reboot         # 等 72h 自然过闸
router_watch.sh --now --force --ack-config-reset --ack-manual-reboot   # 立即刷, 自担沉淀风险
```

**固件级回退兼容性静态实证（L2 新增证据）**：1016 与 1115 的 ITB metadata 三项完全一致 —— `compat_version=1.0`、`supported_devices=["gemtek,xr1710g"]`、`board=gemtek_xr1710g`；1115 DTB 分区标签仍是旧 6-mtd 布局（bootloader/uenv/dsd/chainloader/ubi/reserved_bmt，无 `bl2`/`fip`），与本机实测 `/sys/class/mtd` 一致，故 `06_gemtek-ubi-compat`（只认 `*-ubi` board）不会改写 `compat_version`。从两版镜像分别解出升级链 7 个关键文件逐字节对比：`platform.sh` / `fit.sh` / `gemtek-ubi.sh` / `nand.sh` / `common.sh` / `sysupgrade.conf` **6/6 完全一致**，仅 `/sbin/sysupgrade` 差 138B（`SAVE_PARTITIONS` 改为 `export` + 帮助文本补充；`-F` / `-n` / `-f CONF_IMAGE` 核心逻辑未变）。两版 `platform_do_upgrade` 对 `gemtek,xr1710g` 都走 `fit_do_upgrade → nand_do_upgrade` 写 UBI volume `fit`，`auto_rollback` 的 `sysupgrade -F` 与升级写入目标一致 —— 「旧固件 + 旧配置」自动回退在固件格式层可行；仍不等于运行期零风险（首启动驱动、断电、坏块属 L3）。

**当前实测（2026-11-16 00:02，只读）**：固件 `20261016-1a34e17ca0`，`uptime=3.4h`，`UBIFS recovery=1`，`Oops/panic=0` → 48h 闸机械判据成立且确认为人工重启；1115 发布于 11-15 14:51，72h 闸到 **11-18 14:51** 才过。故此刻 `router_watch.sh --now --ack-config-reset --ack-manual-reboot`（不带 `--force`）仍会在 72h 闸处等待，属预期行为。

**剩余已知缺口**：1115 完整 rootfs 3,101 节点中 10 个第三方包关键词 0 命中，出厂确不含；kit 已离线注入 `openclash`/`dawn`/`pushbot`/`tailscale`/`wifihistory` 程序本体，但 `glass`/`usteer`/`socat`/`udpxy`/`msd_lite`/`rtp2httpd` 仍是「配置已保真、程序未装回」的悬空配置（无害但不生效），需刷后按需装回。

### prepare 阶段已就绪的资产（2026-11-16）

| 资产 | 位置 | 校验 |
|---|---|---|
| 备份（mtd3/mtd1/ubi0_1/ubi0_2/fw_printenv/ubinfo/proc-mtd） | `~/router-upgrade-logs/uboot-backups/20261116-130340/` | SHA256SUMS 复核 **7/7 OK** |
| chainloader 镜像（官方 11-11） | 同上目录 | sha256 `dbe285a7…` == 官方 release ✅ |
| 连带刷的官方固件（1115 itb） | `~/router-upgrade-logs/firmware-cache/` | sha256 `7a828e88…` == 官方 digest ✅ |
| MAC 基线（10 接口） | 备份目录 `mac-baseline.txt` | ✅ |

### U-Boot 引导链实证台账（2026-11-16 第五轮）

| 环节 | 本机实测 | 与官方 11-11 chainloader |
|---|---|---|
| 一级 env (mtd1 `uenv`) | 原厂 ECNT 格式，`crc32(data[16380])` **CRC 有效**，`bootcmd=flash read 0x600000 0x100000 $loadaddr; bootm` | `CONFIG_ENV_IS_IN_MTD` + `ENV_MTD_DEV="uenv"` ✅ 完全匹配 |
| 一级 bootcmd 含 `flash` | 是 | 官方 `board_late_init()` **主动**归一化为 `run boot_ubi \|\| http_recovery` ✅ 无需手工干预 |
| UBI 分区名 | mtd4 = `ubi` | 官方 DTB = `system`（偏移/大小相同）→ 二级用自己 DTB 解析，**无影响** ✅ |
| fit 卷 | ubi0_0 名 `fit`，46.2 MiB，FIT magic `d00dfeed`，含 `config-1`/`kernel-1`/`rootfs-1` | `ubi read ${loadaddr} fit` ✅ 精确匹配 |
| bootargs | `root=/dev/fit0` | 一致 ✅ |
| DRAM | 1.86 GB | 读 46 MiB 到 0x81800000 容量充裕 ✅ |
| 恢复页 | 刷前 `192.168.255.1` | **现用 `192.168.0.1`**（已刷 11-11）✅ |

> ✅ **撤销旧结论**：「mtd1 uenv CRC 失效 → 二级回落官方默认 env → ethaddr/MAC 可能变」——**不成立**。
> 此前是 CRC 长度用错（用了 16384，实际 16380）。本机 MAC 不受 env 影响。

