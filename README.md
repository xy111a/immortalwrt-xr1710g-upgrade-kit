# Gemtek XR1710G / ImmortalWrt 安全升级工具包

一套用于给 **Gemtek XR1710G**（Brightspeed 同款）路由器刷 **naoki66 第三方 ImmortalWrt 构建** 的安全升级编排脚本。
核心目标：**全清刷（`sysupgrade -n`，不保留旧配置）也能在刷机窗口内零人工介入地自举回原连网状态**，并带多层兜底防变砖。

> ⚠️ **第三方固件风险提示**：本工具依赖社区第三方构建（非官方 ImmortalWrt，官方 `downloads.immortalwrt.org/airoha/an7581` 目录为空）。
> 该构建由单维护者维护，存在供应链 / bus-factor 风险。使用前请自行评估。U-Boot 常住兜底可避免"刷坏需拆机"，但无法消除固件本身风险。

---

## 文件清单

| 文件 | 作用 | 是否入库 |
|---|---|---|
| `upgrade_router.sh` | Mac 侧编排器：上传固件+kit、路由器侧 sha 复核、触发干净刷、轮询重连、终验、强终验失败自动回退 | ✅ 入库 |
| `router_watch.sh` | 按需守护：查 naoki66 最新 release、72h 发布沉淀闸、独立 sha256 校验、自动改写 `EXPECT_SHA`、触发 `upgrade_router.sh --auto` | ✅ 入库 |
| `zzz-restore-router` | 路由器首启动自举（`/etc/uci-defaults`）：写 LAN/WAN/三频/防火墙、恢复 root 密码与 WiFi key、注入 OpenClash 安装步骤 | ✅ 入库 |
| `build_kit.sh` | 本地从源码组装 `kit.tar.gz`（默认安全写到 `dist/`，**拒绝覆盖真 kit**） | ✅ 入库 |
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
- 已 `ssh` 到路由：`~/.ssh/config` 中 `Host router` → `192.168.88.1`，且 Mac 公钥已能 key 登录
- `gh` CLI 已登录（watch 查 release / 自动刷新 `EXPECT_SHA` 需要）
- `curl`（独立 sha256 校验需要）

---

## 用法

### 1. 首次准备 kit
```bash
./build_kit.sh --keys ~/.ssh/router_authorized_keys
# 产物默认写到 dist/kit.tar.gz (已 gitignore), 绝不碰仓库根在用中的真 kit
# 可选: 带入当前 OpenClash 配置作为离线兜底
# ./build_kit.sh --keys ~/.ssh/router_authorized_keys --openclash /tmp/my-openclash
```
> 安全栏：`build_kit.sh` 默认拒绝覆盖仓库根的 `kit.tar.gz`（那是你正在用的真 kit，含 OpenClash 订阅 + 公钥）。
> 想重建真 kit 必须显式 `--out kit.tar.gz --force`。因此"别随手跑 build_kit.sh"这类人工提醒已不再需要——脚本自己会拦。

### 2. 检查是否有新版本（不升级）
```bash
./router_watch.sh --check
```

### 3. 你通知后全自动升级（推荐，保留 72h 沉淀闸）
```bash
./router_watch.sh --now
```
脚本会：查最新 release → 等发布满 72h → 下载 itb + 官方 `sha256sums` 校验 → 自动改写 `EXPECT_SHA` → 调 `upgrade_router.sh --auto`。

### 4. 直接手动升级（已手动下好 itb 时）
```bash
./upgrade_router.sh            # 真正执行（触发重启）
./upgrade_router.sh --dry-run  # 只校验前置 + 打印将执行的命令
./upgrade_router.sh --auto    # 强终验失败自动回退（供 watch 调用）
./upgrade_router.sh --force   # 忽略 EXPECT_SHA 不匹配强制刷（仅紧急恢复）
```
若 `EXPECT_SHA` 与实测不符且未用 `--force`，脚本会尝试 `gh` 拉官方 `sha256sums` 自动刷新并复校。

---

## 四层安全模型

1. **T0 预防**：首启动 `uci-defaults` 自举恢复 LAN 192.168.88.1 + 原 SSID，刷机窗口内 Mac 无需人工接手（WiFi 主路径，有线兜底）。
2. **T1 检测**：脚本轮询重连 + 终验（版本 / flow offload / 三频 / OpenClash / DNS / U-Boot）。
3. **T2 恢复**：U-Boot 常住兜底 `bootcmd=run boot_ubi || http_recovery`（实测在位）——刷坏自动进 HTTP Recovery，免拆机。
4. **T3 回退**：刷前自动解析"当前运行版本"对应的本地 itb 作回退镜像；强终验失败自动 `sysupgrade -F` 回退**并连带还原升级前配置快照**（`backups/`）。

---

## 升级前自动做的事

- `backup_config()`：升级前 `sysupgrade -b` 对当前运行配置做快照，落 `backups/`（配置级回退点）。
- `collect_runtime()`：从活路由抓取 root shadow / WiFi key / 三频 SSID / OpenClash，注入临时 kit（无明文存储）。
- 退出清理：`trap` 删除 `/tmp/kit_build` 与 `/tmp/kit_injected.tar.gz`（含 root hash，绝不落盘）。

## 升级后自动做的事

- `--auto` 成功：保守清理旧 itb（保留最新 3 个 + 保护回退/兜底镜像）、弹桌面通知。
- `--auto` 失败：自动回退旧固件 + 旧配置，回退后仍失败则提示进 U-Boot Recovery。

---

## License

[MIT](./LICENSE)
