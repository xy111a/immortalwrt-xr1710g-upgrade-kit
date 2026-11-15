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
| `router_watch.sh` | 按需守护：查最新 release（按 `published_at` 排序）、72h 沉淀闸、版本性质与配置兼容性双闸、独立 sha256 校验、watch.log 轮转、触发 `upgrade_router.sh --auto`；`--no-download` 为零副作用巡检 | ✅ 入库 |
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

## 当前上游状态与升级建议（2026-11-15 复核，会过期）

- 本机仍在 `20261016-1a34e17c`（6.18.55）。**11-15 21:36 复核时 uptime 仅 57 分钟**，dmesg 有 `UBIFS (ubi0:4): recovery needed/completed`（非干净卸载后的恢复启动），但 pstore 为空、无 Oops/panic/看门狗硬复位记录。`precheck_recent_crash` 会因此在 48h 观察窗内拒绝刷机 —— 闸正确生效。
- **最新是 `20261115` 正式版**（`20261115-5e152df9`，85,561,654 B，`sha256:7a828e88…d0111`，北京 11-15 14:51 发布，`prerelease=false`，无 `sha256sums` 走 `asset.digest`）。发布说明主打「完善全链路 NPU 加速」「桥接拨号 NPU 加速」「修复 1710 无线持续强复核下保护性」「PPE 统计队列堵塞保护」「重写 NPU 监控和风扇控制」「修复默认 APK 安装源」，并加粗警告 **「此版本为后端大改动，和旧版本配置文件不兼容」「默认不得保留配置和导入旧版本配置」**，`OTA: wipe-config`。核查时下载 308 次、发布后零新建 issue（样本太短）。
- **NPU 修复溯源**：最新公开提交仍是 11-13 `9a70b257`（README），其前是 11-11 晚那批 NPU/MT7996 根因修复；release 基线逻辑上包含它们，但镜像内嵌 commit `5e152df9` 在公开 master **查不到**，作者从未明确声明「修了 #82」。`#82` 报告者 11-15 回复「升级以后需要双清，就好了」—— 用户经验，与「配置不兼容」呼应，非作者确认。
- issue 动态：`#95`（1112 AP 模式 Qualcomm 重试风暴）作者 11-15 回复「刷入最新版测试」+ 复测方法，**未确认**已修；`#96`（XG2010G NPU 数据通路卡死）作者求补全日志；其余 open：`#94`（5G/6G VIF flowtable）、`#92`（B17 PCIe）、`#62`（PON 校准）。1029 的 `#81` bridger 断流仍靠停服务规避。
- **72h 沉淀闸**：到 **11-18 14:51（北京）** 才过。叠加 48h 异常复位观察窗、镜像 commit 不可溯源、配置不兼容，**当前不刷机**。
- **U-Boot**：当前 `2026.07-00760-gab7fd65100f1`（恢复页 `192.168.255.1`）；11-11 的 `a9a12de55890` 同源 chainloader、同 mtd3/0x600000/1MiB 槽位，唯一行为变更是 MAC offset，风险中等可控，但下载仅 119 次、0 open issue、恢复页会变 `192.168.0.1`、`ubi` vs `system` 待验证。**不单独刷**，与固件配套做，刷前备份 mtd3 + mtd1/uenv。
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

`selective` 模式下 `collect_runtime()` 会生成 `~/router-upgrade-logs/config-restore-todo-<时间戳>.md`，列出本机全部 `/etc/config` 及「自动恢复 / 人工重配」标记（**只记文件名与大小，不含密钥/订阅**）。典型需人工重配：`dhcp` 的 dnsmasq 定制（`noresolv` / `127.0.0.1#7874` / `cachesize` / 日志开关）、`rpcd` 的 homepage 只读用户、`luci` 主题（glass）、`zerotier` 网络与 secret、`watchcat`、`smartdns`、`uhttpd`、以及 `dawn`/`usteer`/`msd_lite`/`socat`/`udpxy`/`rtp2httpd`/`glass`/`pushbot`/`meshconf` 等新版未预装包的配置。

> 明确**不用改**、跨版本安全：OpenClash 全链路（`/etc/config/openclash` + `zzz-oc-data` + `clash_meta` + rc.local 装机）、root shadow / WiFi key / SSID / LAN IP / DHCP host / dropbear host key / `authorized_keys`、`/etc/crontabs` 用户项、`auto_rollback()` 的 `sysupgrade -F -f rb-config.tar.gz`（回退目标是旧固件，旧配置匹配）。

> ⚠️ **真刷前仍必须重建 `kit.tar.gz`**：当前仓库根 kit 停留在 2026-10-08，内嵌自举脚本不含本次 selective 分支，`verify_kit pre` 会拦下。重建时针对 wipe-config 版本加 `--config-policy selective`。

