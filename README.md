# Gemtek XR1710G / ImmortalWrt 安全升级工具包

一套用于给 **Gemtek XR1710G**（Brightspeed 同款）路由器刷 **naoki66 第三方 ImmortalWrt 构建** 的安全升级编排脚本。
核心目标：**全清刷（`sysupgrade -n`，不保留旧配置）也能在刷机窗口内零人工介入地自举回原连网状态**，并带多层兜底防变砖。

> ⚠️ **第三方固件风险提示**：本工具依赖社区第三方构建（非官方 ImmortalWrt，官方 `downloads.immortalwrt.org/airoha/an7581` 目录为空）。
> 该构建由单维护者维护，存在供应链 / bus-factor 风险。使用前请自行评估。U-Boot 常住兜底可避免"刷坏需拆机"，但无法消除固件本身风险。

---

## 文件清单

| 文件 | 作用 | 是否入库 |
|---|---|---|
| `upgrade_router.sh` | Mac 侧编排器：上传固件+kit、路由器侧 sha 复核、触发干净刷、轮询重连、终验、强终验失败自动回退；刷前还有 T2 兜底实测核验与 kit 有效性核验 | ✅ 入库 |
| `router_watch.sh` | 按需守护：查最新 release（按 `published_at` 排序）、72h 沉淀闸、测试版/wipe-config + tag 日期错配识别闸、独立 sha256 校验、watch.log 轮转、触发 `upgrade_router.sh --auto`；`--no-download` 为零副作用巡检 | ✅ 入库 |
| `check_openclash.sh` | Mac 侧 OpenClash 一键健康诊断：真实节点数 / 订阅自动更新三层闸门 / config_path 一致性 / 出口节点对关键站点可达性（识别被封节点） | ✅ 入库 |
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
脚本会：查最新 release → 识别测试版 / `wipe-config`（命中即停）→ 等发布满 72h → 下载 itb + 官方 `sha256sums` / `asset.digest` 独立校验 → 调 `upgrade_router.sh --auto`（`EXPECT_SHA` 由其运行时派生）。

### 4. 直接手动升级（已手动下好 itb 时）
```bash
./upgrade_router.sh            # 真正执行（触发重启）
./upgrade_router.sh --dry-run  # 只校验前置 + 打印将执行的命令
./upgrade_router.sh --auto    # 强终验失败自动回退（供 watch 调用）
./upgrade_router.sh --force   # 仅跳过"发布满 72h"沉淀闸（不影响 sha256 完整性校验）
./upgrade_router.sh --allow-test-build  # 显式放行被识别为测试版/wipe-config 的最新 release
./upgrade_router.sh --allow-unverified-t2  # 刷前读不到 U-Boot/T2 兜底时仍刷(自担风险)
./upgrade_router.sh --allow-stale-kit       # 允许使用陈旧 kit(自担风险; 默认拒绝)
```
`EXPECT_SHA` 由 `derive_expect_sha()` 运行时派生（优先 GitHub `asset.digest`，缺失时按文件名查历史 digest，再退 `sha256sums`）。**有官方基准但不匹配时任何参数都不放行**；完全拿不到基准才可用 `--allow-unverified-sha`（其它放行开关：`--allow-same-version` / `--allow-recent-crash` / `--allow-test-build`）。

---

## 四层安全模型

1. **T0 预防**：首启动 `uci-defaults` 自举恢复 LAN IP（**XR1710G 出厂默认 `192.168.50.1/24`**；正常路径升级前从活路由器抓取真实 LAN IP 注入，`192.168.1.1` 是 XG2010G/Nokia 的地址，别混用）+ 原 SSID，刷机窗口内 Mac 无需人工接手（WiFi 主路径，有线兜底）。
2. **T1 检测**：脚本轮询重连（候选含出厂 `192.168.50.1`）+ 终验；刷前另有 `verify_t2_fallback()` 实测核验 U-Boot 兜底是否在位、`verify_kit()` 核验 kit 是否按当前源码/目标固件重建。
3. **T2 恢复**：U-Boot 常住兜底 `bootcmd=run boot_ubi || http_recovery`（实测在位）——刷坏自动进 HTTP Recovery，免拆机。**恢复页地址随 U-Boot 变**：当前 chainloader 为 `192.168.255.1`（上电后按 reset、LED 变色松手）；刷入 2026-11-11 版 chainloader 后变为 `192.168.0.1`。刷 U-Boot 前必须重学入口，否则兜底会"在位但连不上"。
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

## 当前上游状态与升级建议（2026-11-13 复核，会过期）

- 本机仍在 `20261016-1a34e17c`（6.18.55），已稳跑 9 天 15h+，dmesg 无新 Oops/panic。Issue #82（1016 NPU Oops）是**报告者自行关闭**，作者未确认根因、未声明修复。无时间压力。
- `20261112` 标签（镜像 `20261111-a6d84923`，97MB，digest `05b0a652…9fa80e`）仍是唯一含 XR1710G 镜像的最新版，**OTA 测试版**：「本次为测试固件」「不保留配置」「OTA: wipe-config」，`prerelease=false`、tag 日期与镜像名日期错配。下载 **874 次**；72h 闸按 `published_at`（北京 11-11 13:06）要到 **11-14 13:06** 才过，本工具会拒绝自动刷入。
- **11-13 新增首条针对 1112 的故障 issue #95**（11-12 15:51 北京，0 评论）：AP 模式下 mt7996 对 Qualcomm 客户端下行单播重试风暴（`failed==retries`，~200/s），频段/PHY/信道/BF/TWT/客户端驱动全排除，Intel BE200 对照干净。报告者写明 **1016 与 1112 都复现**，属跨版本 mt76 问题 —— **升级不解决它**。注意本机是网关模式而非「一键 AP」，不能推断必现。11-12 记的「606 次下载零故障 issue」已作废。
- 11-11 晚间一批 **NPU 根因修复**（npu_dma 一致性池 / RX ring irqsave / full-reset / PCIe MT7996 MCU 超时）在镜像上传后 5.5h 才入库；**11-13 复核仍无新 release、无新提交**，因此「等下一版把 NPU 修复编进去」的触发条件**还没到**。
- 1108 的 #94（5G/6G VIF 不在 fw4 硬件 flowtable、手动加入后掉速）、#90（5GHz 13 分钟后 MT7996/PCIe AER/full-reset 失败）；1029 的 #81 bridger 断流仍靠停 bridger 规避。
- **固件建议**：等「把 NPU 修复编进去的下一版正式固件」→ 过 72h → 看新 issue → 用本工具的 `sysupgrade -n -f kit.tar.gz` 全清刷（**不要走 LuCI OTA**，那会回出厂默认并丢 OpenClash 配置）→ 刷前按新固件重建 kit（勿恢复旧 `kmod-*`）。
- **U-Boot 建议**：当前 `2026.07-00760-gab7fd65100f1`；11-11 的 `a9a12de55890` 出自**同一套 chainloader 血脉、同一 mtd3/0x600000/1MiB 槽位**，不是异构替换。唯一行为变更是修 CPU/lan2/br-lan MAC 重复，且 1112 固件把它绑成配套件。风险中等可控（SSH 在线刷有备份+回读+回滚），但 11-11 版只下载 81 次、仍 0 open issue、真机验证清单未完成、产物缺 XG2010G、恢复页会变。**不要单独刷**，与下一版固件配套做，刷前备份 mtd3 + mtd1/uenv、验证 `ubi` vs `system` 分区名路径。

### ⚠️ 真刷前必须先重建 kit（2026-11-13 实测）

当前仓库根的 `kit.tar.gz` 停留在 **2026-10-08**，内嵌 `zzz-restore-router` 只有 339 行（仓库源码 445 行），缺 `zzz-disabled-services` 禁用态还原等后续修复，sha256 不一致。`collect_runtime()` 只会往这份旧 kit 里注入配置，**不会更新自举脚本** —— 用它全清刷会静默丢配置。现在 `verify_kit()` 会在刷前拦下：

```bash
# 从现有 kit 自提取素材, 无需任何外部文件
mkdir -p /tmp/kit_rebuild
tar -xOf kit.tar.gz ./etc/dropbear/authorized_keys   > /tmp/kit_rebuild/authorized_keys
tar -xOf kit.tar.gz ./etc/openclash/core/clash_meta  > /tmp/kit_rebuild/clash_meta
./build_kit.sh --keys /tmp/kit_rebuild/authorized_keys \
  --openclash-core /tmp/kit_rebuild/clash_meta \
  --out kit.tar.gz --force
```

> `--force` 在这里是**故意**的：本步就是要覆盖仓库根的真 kit，而素材已在覆盖前从旧 kit 提取完毕（含 57MB 的 `clash_meta`，不重新烘焙会让全清刷后代理内核缺失）。重建后自举脚本 sha 与源码一致、manifest 齐备，`verify_kit()` 才放行。`--allow-stale-kit` 可显式绕过，但等于自担丢配置风险。

> 完整证据链、历次误判更正与 `saveenv` 陷阱见 `SKILL.md`「U-Boot / chainloader 评估基线」。

## License

[MIT](./LICENSE)
