---
name: router-immortalwrt-upgrade
description: 安全地对 Gemtek XR1710G（Brightspeed）路由器做 ImmortalWrt 第三方构建（naoki66）的全清刷升级，含 uci-defaults 首启动自举 + 多层防变砖保障。当用户说"升级路由器固件""升 9/x 固件""路由器刷机"或要复用这套升级套件时使用。覆盖：预飞门控、uci-defaults 自举脚本、Mac 侧编排器、全清还原范围（配置/脚本/补丁/启用态）审计法、以及 6 个已固化的 P0 陷阱（chpasswd 缺失 / tar uid 污染 dropbear / SSH host key 变更 / fw_env.config stale mtd0 / apk 时机 / busybox tar 无 --exclude）。
agent_created: true
---

# 路由器 ImmortalWrt 安全全清升级（Gemtek XR1710G / naoki66）

> 本 skill 来自一次真实的全清刷升级复盘。可直接调起，不必重踩坑。

## 何时用
用户要升级路由器固件（ImmortalWrt，第三方构建 naoki66，Airoha AN7581 平台）。
**关键前提**：固件来自第三方 GitHub `naoki66/ImmortalWrt-for-Gemtek-brightspeed`（原仓库名 `ImmortalWrt-for-Gemtek-XR1710G` 已改名；非官方，官方 airoha/an7581 目录空）。⚠️ 上游把 XG2010G 机型 build 标为 GitHub "Latest"，`releases/latest` 不含 XR1710G 固件，故脚本统一改用**遍历 `releases` 取首个含 `gemtek_xr1710g` itb 的 release**（见 `upgrade_router.sh`/`router_watch.sh` 的 `REPO` 与 release 解析）。升前**必看该仓库 release note** 是否写"不建议保留配置升级"——若写，则**必须全清刷**（keep-settings OFF），不可走"保留 network/wireless"捷径（子系统重构会导致首启动网络异常）。

## 资产位置（本 skill 自带）
脚本随 skill 一同安装，位于 skill 根目录（与 SKILL.md 同级）：
- `upgrade_router.sh` — Mac 侧编排器（上传 itb+kit → `sysupgrade -n -f` → 轮询重连 → 终验；支持 `--dry-run` / `--auto` / `--force`）。
- `zzz-restore-router` — uci-defaults 首启动自举脚本（设 LAN、三频 SSID、开 flow offload、注入 rc.local 装 OpenClash）。
- `build_kit.sh` — 本地从源码组装 `kit.tar.gz`（**不入库**；含你的 SSH 公钥、可选 OpenClash 配置、**强烈建议用 `--openclash-core` 烘焙内核**）。
- `*.itb` — 待刷固件（sha256 须先校验；从作者 Release 下载，不要入库）。

> **敏感信息处理方式（零明文）**：`zzz-restore-router` 与 `upgrade_router.sh` 源码**不存储任何明文密码/WiFi key/订阅/MAC**。升级前 `upgrade_router.sh` 的 `collect_runtime()` 会从活路由器实时抓取 root shadow hash + WiFi key + 三频 SSID + OpenClash 配置 + **DHCP 静态租约** + **SSH host key**（dropbear，使升级后其他终端无需更新 known_hosts），注入**临时** kit（仅存于 `/tmp`，脚本退出即清理）。DHCP 租约以 `etc/dhcp-hosts.uci`（每行 `host <name> <mac> <ip> <leasetime>`）随 kit 携带、首启动自举按文件重建——不写死任何 MAC，设备变更后升级自动跟手。因此本仓库可安全公开。

## 备份机制：全清还原范围（2026-10-21 审计后定版）

全清刷（`sysupgrade -n`）只保留 kit 内的文件，"备份机制"的本质是**把活路由上所有出厂之上被改过/新增的东西都圈进 kit**。定版的抓取范围（`upgrade_router.sh` 顶部 `EXTRA_CONFIGS` / `EXTRA_PATHS` 两个变量，按需增删）：

| 类别 | 内容 | 说明 |
|---|---|---|
| 基础 | root shadow / WiFi key / 三频 SSID / LAN IP / DHCP 静态租约 / dropbear host key | 既有通道 |
| 网络 | `/etc/config/network` + `/etc/config/wireless` 整配置 | 真实配置还原通道（flag: `etc/zzz-realconfig.flag`）；**注意 kit 里没有 `etc/config/` 目录，`mkdir -p "$build/etc/config"` 不能漏**（漏了重定向失败会静默降级） |
| 配置 | `EXTRA_CONFIGS="dhcp rpcd luci cpufreq watchcat dawn system"` + **全量 `/etc/config` 兜底**（2026-10-27 修复 R5） | EXTRA_CONFIGS 逐个 `cat` 抓取（健全性校验含 `^config`，失败不阻断）；**另加全量 `tar etc/config` 兜底**，覆盖 firewall/ddns-go/lucky/wechatpush/zerotier/smartdns/upnpd/usteer/xray/socat/udpxy 等所有未被显式抓取的包配置，未来新增包自动覆盖。firewall 的 openclash/zerotier `/var` include 段由 zzz-restore 首启动剥离（见下） |
| 路径 | `EXTRA_PATHS`：`etc/crontabs` `etc/lan_report.token` `etc/apk/repositories.d` `usr/sbin/lan_report.sh` `usr/lib/lua/luci/http.lua` `usr/share/ucode/luci/http.uc` `root/.ssh/known_hosts` | tar 整包抓取，排除 `._*`/`*.bak`；成功判定用 `etc/crontabs/root` 作探针 |
| 启用态 | `/etc/rc.d`（排除 openclash 链） | 保留"用户禁用 watchcat/igmpproxy"这类状态；openclash 链由 rc.local 的 `enable` 重建 |
| 禁用态 | `etc/zzz-disabled-services`（刷前生成） | **overlay 白名单（whiteout，字符设备 0/0）不是普通文件，tar 抓不到**——禁用服务=删开机链，全清刷后 `/rom` 下层出厂链会重新可见，服务被默默重启（2026-10-08 升级后实际复发过）。修法：刷前算"出厂有链、现网无链、且 init.d 仍在（包未卸=用户主动禁用）"清单写入 kit，`zzz-restore` 首启动对每个链 `rm -f` 重建白名单。注意区分"包被卸"（init.d 不在）——那种不能禁，新固件自带该包时应保持出厂启用。**2026-10-28 修正**：`zzz-restore`(uci-defaults) 早期的 `rm` 会被部分服务(如 watchcat)的**包 postinst 在首启动后续阶段重建 rc.d 链接**而失效（实测升级后 watchcat 又被启用）。故禁用清单不再在 uci-defaults 阶段删除，改由注入的 `rc.local` 末段再强制 `rm` 一次并最终消费清单，确保禁用态真正生效。 |

**为什么全量抓 `/etc/config/firewall` 但要剥离 include（2026-10-27 修复 R5）**：现网 firewall 含用户大量自定义区域/转发/规则（实测 129 行），此前因"include 指向 `/var` 运行时文件、首启动尚不存在 → fw4 加载失败"而刻意不抓，导致这些自定义规则全清刷后回退包默认、需手动重建。现改为「全量抓 firewall + 首启动剥离 `/var` include 段」：剥离的是 openclash/zerotier 指向 `/var/etc/openclash.include`、`/var/run/zerotier-one/_fw4/*.nft` 的 `config include`（这些由对应服务自身启动时重新添加），保留的是用户全部自定义规则——既不丢配置、又避免启动失败。**注意**：这条是 2026-10-21 审计"覆盖率 100%"的盲区修正（当时 100% 是相对设计抓取集，未覆盖全清模型下的全部 live 配置）；R5 修复后才是真正的全量覆盖。

**怎么审计"还缺什么"**（下次换设备/换构建时重跑）：① `for f in /etc/config/*; do cmp -s $f /rom/etc/config/$f`（路由器无 `diff`/`cmp` 时拉回本机比）；② `comm -13 <(rom/etc 文件清单) <(etc 文件清单)` 找 /etc 新增文件；③ `/etc/rc.d` vs `/rom/etc/rc.d` 比启用态；④ `find /usr /www /bin /sbin /lib -type f` 与 `/rom` 对照找 NEW/MODIFIED（MODIFIED 要分清是**用户补丁**还是**包升级**：本机 `http.lua`/`http.uc` 的 100kB→10MB 是用户补丁，必须抓；`network.lua` 的 "OpenClash Append" 是包安装追加，会随 apk 重装回来，不抓）。

**AppleDouble 卫生（2026-10-21 整治）**：Mac 侧 tar（bsdtar）默认给每个文件附 `._*` 伴随文件，曾随 kit 刷进路由器 `/etc`（29 个垃圾）。四道防线：① Mac 侧所有 tar 设 `COPYFILE_DISABLE=1`（`upgrade_router.sh`/`build_kit.sh` 均已加）；② 路由侧抓取 tar 用 `-X` 排除 `._*`/`*.bak`；③ kit 打包前 `find "$build" -name '._*' -delete`；④ `zzz-restore-router` 首启动对 `/etc`、`/etc/openclash` 全树兜底清理。路由器上已存的垃圾：`find /etc -name '._*' -type f -exec rm -f {} \;`（纯元数据，删之无副作用；dropbear/uci 功能不受影响，已实测）。

## 四层安全保障（fail-safe，非 fail-proof）
- **T0 预防**：全清刷 + restore-kit 打成 `uci-defaults` 脚本随 `sysupgrade -f kit.tar.gz` 在首启动自举 → 路由自配自己，无需在刷机窗口在线值守。
- **T1 检测**：Mac 侧轮询重连（候选含 XR1710G 出厂默认 `192.168.50.1`；`192.168.1.1` 是 XG2010G/Nokia 的，别混用）+ 终验；刷前另有 `verify_t2_fallback()` 实测核验 T2、`verify_kit()` 核验 kit 是否陈旧（2026-11-13 代码化）。
- **T2 恢复（命门）**：U-Boot 常住兜底 `bootcmd=run boot_ubi || http_recovery` + `recovery_mtd=fit`（在 UBI 卷 ubootenv/ubootenv2，**不受 sysupgrade 影响**）。刷坏自动进 HTTP Recovery，免拆机。
  - **⚠️ 兜底入口不是恒定的**：当前 U-Boot（`2026.07-00760-gab7fd65100f1` / `YYH2913/http-uboot` 血脉）恢复页为 **`192.168.255.1`**（mtd3 实测字符串含 `.1/.2/.255`），进入方式「上电后按 reset、LED 变色松手」（窗口宽裕，**不可按住 reset 上电**）。刷入 `2026-11-11-a9a12de55890` chainloader 后恢复页变为 **`192.168.0.1`**，DHCP 改为按 MAC 的租约表。刷 U-Boot 后旧救砖流程/脚本会失效，必须重学入口并实测一次再依赖它。
- **T3 回退**：`upgrade_router.sh` 在刷前预飞阶段**自动解析当前路由器运行版本的 commit hash，并在本地 `*.itb` 中匹配同名 itb 作为回退镜像**（见 `resolve_rollback`）。即"当前版本"会被自动选为回退点——**前提是旧 itb 文件别删掉**。无匹配时回退到手动指定的 `FALLBACK_ITB`。回退操作：`sysupgrade -F <回退 itb>`。

## 执行顺序（每次升级）
1. **只读预飞**（不刷机）：Mac 仍连路由？路由可达且版本未漂移？U-Boot 兜底在位（**现在是代码实测，不再是人工勾选项**）？kit 是否按当前源码/目标固件重建？itb sha256 匹配？套件齐备？
2. **WAN 核对**：自举脚本须显式写 `wan`/`wan6`（device `wan`, proto dhcp），否则全清后上不了网、apk 装不了 OpenClash。
3. **执行**：`bash upgrade_router.sh`（Mac 可 WiFi 发起，网线放手边作安全网）。触发用 `nohup sysupgrade ... &`，SSH 立即返回不卡。
4. **终验（硬+软）**：硬终验=固件版本匹配 + 三频启用 + 外网直连 DNS 通（不依赖 OpenClash）；软终验=仅当用户真正启用 OpenClash 时才检查 7874 代理 DNS。连不上路由器时**不触发回退**（避免误改状态）。

## ⚠️ 6 个已固化 P0 陷阱（少一个就翻车）
1. **设 root 密码用 `passwd root`，绝不用 `chpasswd`**。`echo "root:$PW" | chpasswd` 会静默失败（ImmortalWrt **无 chpasswd 二进制**）→ root 无密码、内网空密码可进 root。正确：`printf '%s\n%s\n' "$PW" "$PW" | passwd root`（root 不强制长度，too short 警告可忽略）。
2. **sysupgrade -f 还原的 tar 会保留源机 uid** → `/etc/dropbear` 属主变成原机的 uid（如 503）→ dropbear 报 `must be owned by user or root` 并**直接禁用公钥认证** → SSH key 登录全挂（密码仍能进）。自举脚本必须 `chown root:root /etc/dropbear /etc/dropbear/authorized_keys`（原只 chmod 漏 chown，这是根因）。
3. **authorized_keys 每行必须换行结尾**。缺尾 `\n` 时 `cat >>` 追加会拼成非法长行，两把 key 全被拒。
4. **SSH host key 变更陷阱**：干净刷后路由器默认生成**全新 host key**，`StrictHostKeyChecking=accept-new` 语义是"接受新 key、拒绝密钥变更" → 对 clean flush **直接拒连**（脚本误报"重连失败"）。**根治**：`upgrade_router.sh` 的 `collect_runtime()` 在刷前从活路由抓取 `/etc/dropbear/dropbear_*_host_key` 注入 kit，`sysupgrade -f` 还原后 host key 不变 → **其他终端零感知，无需 `ssh-keygen -R`**；自举脚本 `zzz-restore-router` 再 `chown root:root` 这些 host key 兜底。仅当抓取失败才降级：轮询/终验前 `ssh-keygen -R <路由器地址或别名>` 清旧 key，或验证用 `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`。
5. **U-Boot env 校验陷阱**：`fw_printenv` 默认 `fw_env.config` 把 **mtd0 "vendor" 陈旧出厂副本列首位**，读它报 `Incompatible flash types!` 即中止，读不到真正活跃 env → **会误判兜底消失**。活跃 env 在 **UBI 卷 ubi0_1/ubi0_2**，正确校验：`cat /dev/ubi0_2 | strings | grep -E '^bootcmd='`。根治：升级脚本终验段直接读 UBI 卷，不依赖 fw_env.config。
6. **⚠️ BusyBox tar 没有 `--exclude`（2026-10-21 实测，曾长期静默失败）**：路由器 busybox tar 只认 `-X <模式文件>`；写 `--exclude=xxx` 会报 `unrecognized option` 并使整条抓取管道失败——**而失败被 fallback 分支掩盖**，表现为"功能在文档里、实际从未跑过"（P1 的 oc-data 另存、P2 的真实配置还原都因此静默失效过，直到只读审计+试抓测试才发现）。三条纪律：① 路由侧 tar 一律用 `-X`；② Mac 侧 bsdtar 解 busybox 流**退出码不可信**（对 `._*` 条目会报 `Truncated tar archive` 但文件已抽全），成功判定必须校验落盘内容而非 `$?`；③ 抓取/打包链路要有用 `find -name '._*' -delete` 的本地兜底清理。

## ⚠️ 执行机拓扑前提（P0，已加固）
升级"担任网关/隧道路由器"时，**执行机绝不能依赖该路由器通信**。`upgrade_router.sh` 现在在预检阶段做 `precheck_executor_location()`：在路由侧读 `SSH_CONNECTION` 取执行机源 IP，若**不在路由器 LAN 网段**（即疑似经隧道/VPN 回家），交互环境会要求确认、非交互环境直接拒绝——因为路由器一旦重启，执行机将永久失联，无法终验/回退。安全做法：执行机用独立上网路径（手机热点/另一网卡），并用**有线直连路由器 LAN 口**后再升级。

## 其他要点
- **apk add 时机与自愈（2026-10-28 实战后修正）**：必须在 `rc.local`（S95done 后、网络就绪）执行，不可在 uci-defaults（S10boot，网络未起）。加 sentinel 文件（`zzz-postinstall-done`）防重复。**关键修正**：`rc.local` 的 apk 循环前以 **`apk update` 成功**为连通判据（不再只 ping 仓库主机——实测主机可达但 `.adb` 文件 `unexpected end of file` 时旧逻辑误判连通、6 次 `apk add` 全失败），上限 ~5 分钟；成功后重试 `apk add`（最多 8 次）。若最终 `/etc/init.d/openclash` 仍未安装（仓库仍不可用），**本次跳过、不设 sentinel，下次开机自动重试（自愈）**，限 6 次避免无限重试刷屏——根治"首启动 OpenClash 没装上、需手动补救"的问题。仓库主机改为从 `/etc/apk/repositories.d/*` 动态派生（不再硬编码 `mirrors.vsean.net`）。
- **-F 强刷安全护栏（2026-10-28 新增）**：`sysupgrade -F` 跳过设备名校验是双刃剑（误指向异构镜像会直接变砖）。触发前新增**设备名兼容性预检**：归一化（去 `-ubi` 后缀）比对运行板名（`/tmp/sysinfo/board_name`）与 itb 支持设备（从 itb 字符串提取），**仅当差异仅为 `-ubi` 后缀时才允许 -F**，否则中止刷写。提取失败（字符串解析未命中）则放行并信任 sha256 完整性，不误伤已知可用路径。背景：naoki66 的 1016 构建把板名 `gemtek,xr1710g-ubi` 改名为 `gemtek,xr1710g`（仅元数据改名，UBI 布局/硬件与现网完全一致，已比对两 itb 的 ubi-volume 结构确认）。
- **DNS 链（已修正）**：dnsmasq 上游指向 `127.0.0.1#7874` 必须以 OpenClash **实际监听该端口**为前提，绝不硬编码把 DNS 指死。自举脚本 `zzz-restore-router` 与 `auto_rollback` 均内置 **DNS 卫生检查**——若 7874 无进程监听则自动回退公共 DNS(223.5.5.5/8.8.8.8) 并重启 dnsmasq，避免"连WiFi没网"。
- **itb 完整性（走 WiFi 专用）**：上传后路由器侧复核 sha256，防 WiFi 抖动传坏镜像变砖。
- **6G**：`zzz-restore-router` 已默认关闭 6G（设备层 `radio2` 与接口层 `default_radio2` 均 `disabled='1'`，用户明确"6G不用"）；如需启用，改这两处 + `wifi reload`。
- **OpenClash 内核固化（P1，已根治"全清刷后报没有内核"）**：`build_kit.sh` 用 `--openclash-core <clash_meta 路径>` 把内核二进制烘焙进 kit 的 `etc/openclash/core/`（随 kit 整包 scp + `sysupgrade -f` 还原，不再走 57MB 经 SSH tar 管道的脆弱链路）；`collect_runtime` 抓取活路由 OpenClash 时**排除 `etc/openclash/core`**，避免重复搬运。双保险：`zzz-restore` 的 `rc.local` 在 apk 装完 OpenClash 后若发现内核缺失/不可执行，会运行时从官方 CDN（GitHub + ghproxy 镜像，v1.19.32）多源重试下载，失败仅 `notify` 告警不阻断启动；`verify_router` 在 OpenClash 启用时额外校验内核存在且可执行，缺失则判 FAIL 暴露问题。**重建真 kit 必须带 `--openclash-core`**，否则下次全清刷仍会丢内核。
- **进程名**：判代理活死用端口 `7874` 监听或 `ps w | grep [c]lash`（进程名是 `clash` 非 `clash_meta`，`grep clash_meta` 必误报 0）。
- **⚠️ OpenClash 实为上网网关（本机模型，务必牢记）**：本路由 OpenClash 是 **DNS 接管 + TCP 透明重定向（nftables `jump openclash`）+ DNS 由 `127.0.0.1#7874` 接管**，**全屋出网实际都走 OpenClash 代理**，不是"可选加速"。注意 DNS 模式**随订阅模板而变**：当前订阅（bingling）是 **`redir-host`**（返回真实 IP），历史本地配置曾是 **`fake-ip`（`198.18.0.0/16`）**——不要写死假设它是 fake-ip，排错前先 `grep enhanced-mode $(ps w|grep [c]lash|grep -oE '-f [^ ]+'|awk '{print $2}')`。由此推出两个铁律（与模式无关，始终成立）：① 启动开关 `uci set openclash.config.enable='1'`（**注意是本构建 `start_service` 实际检查的 `enable` 不带 d**，见 `/etc/init.d/openclash:3594`；`enabled` 带 d 只是 LuCI 显示开关，两者都设 1 才稳）必须为真，否则开机 `start` 提前返回（报 `Now Disabled, Need Start From Luci Page`）→ 重启路由后 OpenClash 不启动 → dnsmasq 仍把 DNS 指死 7874 → **连上 WiFi 没网**。`zzz-restore` 现已显式把 `enable` 和 `enabled` 都设 1 双保险。② "已启用但 **0 真实节点**" = 用户**静默断网**（进程在、7874 在、DNS 通，但出不去）。`verify_router` 软终验在"OpenClash 是 DNS 网关"时若查到 0 节点直接判 FAIL 暴露此故障。

## ⚠️ OpenClash 诊断陷阱（排错时别再踩，已固化为 check_openclash.sh）
日常排查用仓库自带的 **`check_openclash.sh`**（Mac 侧 `bash check_openclash.sh`，自动定位路由器），它已固化正确方法。手动排错避开这几个坑：
1. **控制器 secret 在 clash 实际加载的配置文件**，即 `ps w | grep [c]lash` 里 `-f <file>` 所指（**订阅模式**下运行时是 `/etc/openclash/<name>.yaml`，如 `bingling.yaml`；本地配置时代曾是 `lipa_bingling_click.yaml`），**不是**生成的 `/etc/openclash/config.yaml`。抓错文件 → 控制器鉴权失败 → 返回 0 节点 → **误判"没节点"**。⚠️ **根/子目录架构**：OpenClash 订阅把「源配置」放在 `/etc/openclash/config/<name>.yaml`（`uci openclash.config.config_path` 指向它），每次启动再**编译同步到根目录** `/etc/openclash/<name>.yaml` 供 clash `-f` 加载；两个位置内容/md5 不同是**正常**（根目录是编译后的运行时）。若 `config_path` 与 `-f` 不一致或两份长期不同步，才需留意。
2. **mixed 端口（7890/7893 等）需要认证**：`curl -x http://127.0.0.1:7890` 会返回 `407 Proxy Authentication Required`，**这不是节点故障**！用户设备走的是透明重定向（TPROXY/REDIRECT）进代理，那条路不需要认证、上网不受影响。**绝不要用 `curl -x` 判断代理通不通。**
3. **经 7874 解析域名不能当"服务器可达性"判据**：`fake-ip` 模式下经 7874 解析任意域名都返回 `198.18.x` 假 IP；`redir-host` 模式下虽返回真实 IP，但受 DNS 污染/缓存影响也未必可靠。判断真实节点服务器可达性，须用**公共 DNS**（如 `nslookup <节点域名> 223.5.5.5`）或直接看控制器节点延迟。
4. **`curl -x http://127.0.0.1:7890`（或 `[::1]:7890`）多半返回 407 或 `HTTP=000`，都是假象**，不代表代理挂了：前者要认证、后者是路由器自身回环被 `router_self_proxy`/回环路由吃掉。**判断代理是否在服务，用控制器 `/proxies` 的真实节点数 + `/connections` 活跃连接**（真实 LAN 客户端连接最可信），不要用路由器本机 curl。
5. **节点"能连 TCP" ≠ "App 能用"（2026-10-28 TikTok 实战）**：`自动选择`(url-test) 会挑"延迟最低"的节点，但某节点可能**能被 TikTok/Netflix 等封 IP**（TCP 通、业务不给数据，App 反复重试/转圈）。定位：对每个候选节点测 `GET /proxies/<name>/delay?url=https://www.tiktok.com&timeout=7000`，返回 `{"delay":N}`=能连、`{"message":"An error occurred..."}`=被该站封/不可达；把可用节点固定或从自动选择池剔除即可。
6. **provider 模式下节点不在 `/proxies` 顶层**（2026-10-30）：机场新订阅是 `proxy-providers` 结构，节点在 `/providers/proxies` 里。只查 `/proxies` 会**误报 0 节点**并触发"静默断网"结论。两个来源都要查、取大值。
7. **provider 内节点的 delay API 两条路径都 404**（2026-10-30）：`GET /proxies/<name>/delay` 和 `GET /providers/proxies/<prov>/proxies/<name>/delay` 对 provider 内节点都返回 `{"message":"Resource not found"}`（emoji 名 URL 编码亦然）。**唯一可靠的读法是直接读 `/providers/proxies` 响应里的 `history` 数组**：`{n:.name, d:((.history//[])[-1].delay // 0)}`，配合 `.alive` 字段。
8. **路由器 shell 直连会被 nft 劫持，测出来是假阳性**（2026-10-30）：`openclash_output` 链最后一条是 `ip protocol tcp → redirect to :7892`，凡 gid≠65534 的本机出向 TCP 都被劫持到本地 clash 端口。于是 `bash -c 'exec 3<>/dev/tcp/<服务器IP>/<端口>'` 会**秒连成功**，但连的其实是本地 7892，**根本不是远端服务器**——我据此差点误判"入口正常"。要测真实路径必须先插豁免：`nft insert rule inet fw4 openclash_output ip daddr <IP> return`，测完按 handle 删除。（另：BusyBox `nc` **不支持 `-z`**，一切 `nc -z` 探测都是假阴性；`/dev/tcp` 需 bash，路由器有 `/bin/bash`。）
- **正确验证法**：查控制器统计"真实节点数"（过滤掉 Selector/URLTest/Fallback 等代理组，只数 `Vless/Vmess/Trojan/Hysteria2/...` 等真实类型，**且要合并 `/proxies` 与 `/providers/proxies` 两个来源**）+ 看 `/connections` 活跃连接数 + 看 `nft` 的 `openclash` TCP 重定向包计数随出网探针**增长**。三者任一成立即证明代理真在扛流量。

### 🚨 入口 IP 被封：全体节点超时但 DNS 正常（2026-10-30 实战，故障率最高）

**症状**：所有走代理的流量报 `dial tcp <入口IP>:<端口>: i/o timeout`（日志里连你家里每台设备都在刷），但**DNS 解析完全正常**、国内站直连正常、`/proxies` 节点数一个不少。极易误判成"节点坏了/订阅过期/机场倒闭"。

**根因**：机场入口域名（形如 `entry.<机场域名>`，常带 CNAME 到另一子域）会在**多个 IP 间轮转**。旧 IP 被墙后，clash 仍**缓存**着旧 A 记录并一直往那个死 IP 上连，而 DNS 查出来"看着没问题"。上游 DNS 其实早已返回新 IP——**只有 clash 自己缓存没刷新**。

**判定流程**（`check_openclash.sh` 第 8 节已固化）：
1. 从 provider 缓存 `/etc/openclash/proxy_provider/*.yaml` 提取入口域名分布（`grep -oE "server: [a-zA-Z0-9._-]+" | sort | uniq -c | sort -rn`），找**出现次数最多的那个**（机场往往 36 个节点共用一个入口）。
2. 对比各上游 DNS（`192.168.1.1` / `223.5.5.5` / `114.114.114.114`）对该域名的解析 —— 若**上游已是新 IP，而 clash DNS(7874) 还是旧 IP**，即确诊。
3. 真实握手验证（见上文陷阱 8，必须先插 nft 豁免）：`timeout 10 bash -c "exec 3<>/dev/tcp/<IP>/<端口>"`。**不可达 = 入口 IP 被封**；同时用 `nc`/多端口扫描确认是不是整个 IP 段全灭（我那次是 19 个端口全不通，含 80/443）。
4. 处置：**重启 clash 清 DNS 缓存**（`/etc/init.d/openclash restart`）通常即刻恢复；再配 `nameserver-policy` 把入口域名绑到多个上游，降低再次命中死 IP 的概率。

**持久化配置（`nameserver-policy`）的两个硬坑**：
- `overwrite` 钩子里 `ruby_edit` 的 hash 参数必须是**合法 Ruby 源码**（用 `=>` 而非 YAML 的 `:`），否则被 OpenClash 的 overwrite 安全检查判为 `skip unsafe Overwrite command` **静默跳过**（日志在 `/tmp/openclash.log`）。
- mihomo 的 `nameserver-policy` 里 `+` 通配符**必须独占一个标签**：`+.entry.example.com` ✅，`+entry.example.com` ❌（后者直接让 clash 启动失败：`invalid domain "+entry.example.com": "+" wildcard must occupy the entire label 1`）。
- **OpenClash 启动失败会自动把 `uci openclash.config.enable` 置 0**，日志打 `OpenClash Now Disabled, Need Start From Luci Page`。恢复：`uci set openclash.config.enable=1` + `/etc/init.d/openclash start`。

### 自定义规则的持久化（2026-10-30 修复）

`/etc/openclash/custom/openclash_custom_rules.list` **会被订阅更新 / LuCI 保存设置重置**（`luci/model/cbi/openclash/config-overwrite.lua` 会在保存时覆盖它）。所以自定义规则不能只写这个文件，必须配 **`/etc/openclash/custom/openclash_custom_overwrite.sh`** 钩子（该脚本由 `/etc/init.d/openclash` 在**每次启动后**调用），在钩子里**幂等**补回规则：先 `sed -i` 删掉旧行再 `sed "/^rules:/a\\..."` 插入，保证重复执行不产生重复条目。

**规则目标必须是"代理组"而非 provider 内的节点名**：像 `DOMAIN-SUFFIX,tiktok.com,🇭🇰香港01【防失联↑↑↑】` 这种写法会被 `yml_rules_change.sh` 的 `CONFIG_GROUP` 校验**过滤掉**（`CONFIG_GROUP` 只含组名 + 内联 proxies，不含 provider 里的节点名），规则静默消失。正确写法指向组（如 `🚀 HK`）。运行配置里中文/emoji 会以 Ruby 的 Unicode 转义形式出现（`"\U0001F680 HK"`），**这是正常的 YAML 写法，能正确解析**。

**验证规则是否真的生效**：看控制器 `/rules` 返回的 `type,payload -> proxy` 三元组，而不是只看运行配置文件里有没有那行文本；再用 `/tmp/openclash.log` 的 `match DomainSuffix(xxx) using <目标>` 确认实际路由决策。


### 订阅自动更新：三层闸门缺一不可（2026-10-28 修复，实测）
本构建的订阅自动更新由 **`openclash_watchdog.sh` 守护进程按"间隔"触发，不是系统 crontab**（`crontab -l` 里看不到 openclash 项是正常的；`auto_update_time` 时钟字段在本版本**未使用**）。要它真正跑，以下**三层闸门必须同时打开**，缺任一则静默不更新：
1. `uci set openclash.config.auto_update='1'`（总开关）
2. `uci set openclash.config.config_auto_update_mode='1'`（watchdog 判定条件，**默认 0**，只开 auto_update 没用）
3. `uci set openclash.@config_subscribe[0].enabled='1'`（`sub_info_get` 对禁用订阅会直接 `return` 跳过，更新循环永远不碰它）
- 另 `uci set openclash.config.config_update_interval='1440'`（分钟，每日一次；内容无变化则 `DOWNLOAD_RESULT=2` 跳过重启，不扰动）。
- **验证管线真能跑**：手动 `/usr/share/openclash/openclash.sh`（=watchdog 同款无参调用）后看 `/tmp/openclash.log` 是否出现 `Start Updating Config File`；日志显示 `No Change, Do Nothing` 属正常（无实质变化）。**注意**：普通 `/etc/init.d/openclash restart` 不会重新下载订阅，只从现有源配置重编译。
- 全清刷还原：订阅 uci（含上述开关+URL）在 `/etc/config/openclash`，订阅生成的 yaml 在 `/etc/openclash/*`，两者均由 kit 的 `sysupgrade -f` 原样还原（`apk add` 重装会清空 `/etc/openclash/config`，故另有 `etc/zzz-oc-data` 兜底）。

## 运维加固（阶段 2/3，已落地，非破坏性）

- **真实配置还原（P2）**：`upgrade_router.sh` 的 `collect_runtime()` 现在额外抓取活路由的 `/etc/config/network` 与 `/etc/config/wireless` 注入 kit（标记文件 `etc/zzz-realconfig.flag` 标记"已带真实配置"）。首启动 `zzz-restore-router` 检测到该标记且真实配置通过健全性校验（`config interface 'lan'` + `config wifi-device 'radio0'`）后，**跳过写死 heredoc、改用真实配置还原**——用户自定义的信道/功率/桥接/额外 SSID 不再被覆盖。任一环节失败自动降级回已知良好 heredoc（含 SSID/LAN IP/密码占位），不会因新逻辑出错而失联。注意：真实配置内的 WiFi key 以明文存于 `/etc/config/wireless`，随临时 kit（`/tmp`，不进 Git）注入，源码与仓库仍零明文。
- **固件级回退点自动化（P2）**：预飞阶段 `ensure_rollback_itb()` 确保"当前运行版本"的 itb 本地存在；缺失则 best-effort 从官方 release 按日期/commit 匹配下载，与 `backup_config()` 的配置级快照（`sysupgrade -b` → `backups/`）形成"固件+配置"双保险。失败不阻断升级，回落 `FALLBACK_ITB`。
- **RC=2 重试（P2）**：`--auto` 强终验连不上路由器（RC=2）不再立即放弃，改为 6×10s 重试后再判定，避免早启动/执行机抖动导致的误判或过早放弃。
- **日志持久化 + 结构化报告（P3）**：`archive_logs()` 改为归档到 `~/router-upgrade-logs/<时间戳>/`（不再只存易失的 `/tmp`）；新增 `post_upgrade_report()` 生成 Markdown 报告——版本/外网直连 DNS/三频/OpenClash 进程+内核/DHCP 静态租约数/fw4 check/配置持久化（uci changes 空），升级结束与回退后各生成一份，一眼看清"到底恢复全了没"。
- **发布即校验固化（P3）**：仓库提供 `publish_to_github.sh`——提交→推送后，强制用 `gh api` 拉回每个文件的 blob 与本地 `diff`，非空且一致才算发布成功，杜绝空文件/截断事故（见该脚本）。
- **OpenClash 订阅数据还原兜底（P1 后补）**：`sysupgrade -n -f` 全清刷后，`zzz-restore` 的 `rc.local` 里 `apk add luci-app-openclash` **重装会清空 `/etc/openclash/config`**，曾导致实机升级后订阅丢失（只能从升级前快照回拷）。现 `collect_runtime()` 在刷前把活路由 OpenClash 数据（**除 57MB 内核**，避免 kit 膨胀）另存进 kit 的 `etc/zzz-oc-data/`（`apk add` 不触碰此路径）；`zzz-restore` 在 `apk add` 之后、启动 OpenClash **之前**据此原样还原，并清掉 macOS `._` 垃圾文件。与内核的 kit 烘焙+运行时下载兜底一起，构成"内核+订阅"双保险。

## 🔧 残留风险修复记录（2026-11-02，代码级审计的 5 项加固）

对升级/备份流程做了一轮代码级审计，堵住此前定性评估遗留的 5 处残留风险（均非"变砖级"，最差是"升级没成自动退回旧版"）：

1. **配置保真度独立校验（修复 #1）**：新增 `config_fidelity_check()`。`verify_router` 此前只查连通性/节点数/信道/DHCP 条数/`uci changes`，不比对"还原前后 `/etc/config` 是否一致"。现用升级前 `sysupgrade -b` 快照对比升级后运行态 `/etc/config`（SHA256 逐文件比对），暴露"抓进 kit 但首启动未还原"的漂移。非 fail-closed，仅告警不回退，`post_upgrade_report` 自动调用。
2. **72h 沉淀闸兜底（修复 #2）**：此前手动跑 `upgrade_router.sh`（不带 `--itb`）会经 `resolve_target_itb` 自动选官方最新 release，绕过 `router_watch.sh` 的 72h 闸。现补同一道闸——无 `--itb` 且非 `--force` 时取 release 发布时间，`<72h` 真实执行直接 fail-closed 拒绝（dry-run 仅告警）。强制二选一：`--itb` 指定已确认版本 / `--force` 跳过。
3. **回退误报修复（修复 #3）**：新增 `verify_rollback()` 取代 `auto_rollback` 里误用的 `verify_router`。旧逻辑拿新 commit 比对刚刷回的旧固件，必然判 FAIL 误报"回退后仍失败"。现判据：已回到非目标旧版本 + 外网通 + 三频启用。
4. **慢首启动误回退修复（修复 #4）**：`--auto` 强终验原在首次 `verify` 返回 RC=1（连上但终验失败）即 break 并触发回退；但首启动 `rc.local`（apk 装 OpenClash+还原订阅）可能未跑完 → 0 节点误判 → 不必要回退。现 RC=1 也重试（12×10s），连续失败才回退。
5. **FALLBACK_ITB 锚定 + 快照防堆积（修复 #5）**：`FALLBACK_ITB` 由过时的 9/16 锚到当前运行版本 10/16（本地已确认该 itb 存在）；`backup_config` 失败告警强化（提示失去本机唯一配置级回退点）；新增 `prune_old_backups()` 仅保留最近 10 份 `pre-upg-*` 快照，避免 `backups/` 无限膨胀。

验证：`bash -n` 语法通过；`--dry-run` 只读预演确认沉淀闸在 `<72h` 时正确告警、回退镜像自动匹配 10/16、全流程无报错退出。未做真实刷机。

## 🔧 升级风险复评后新暴露的 3 项修复（2026-11-04，实证 dry-run + GitHub API）

11-03 路由器发生一次原因未明的卡死 + 异常硬复位；11-04 复评升级风险时，用 `--dry-run` 与 GitHub API 实证出 3 个此前未覆盖的问题，已全部代码级修复（**仍未执行真实刷机**）：

1. **P0 · 静默 fallback 会白刷成当前版本**：`resolve_target_itb()` 原先在"官方 itb 本地不存在"时退回 `ls -t` 最新 itb；本地只有 9/16、9/23、10/16，于是静默选中 **1016（正在跑的版本）**——完整全清刷一遍收益为零、风险全担，回退镜像还是同一个。修复：删除 mtime 兜底，按官方元数据精确选片；本地缺失时真实执行自动下载（带官方 digest 校验），解析不出直接 fail-closed。另加**同版本白刷保护**（比对路由器 `DISTRIB_REVISION` 与目标 itb 的 commit 前 8 位）作为独立第二道闸。
2. **P1 · 1029 缺 `sha256sums` 导致校验路径断裂 + `--force` 危险耦合**：该 release 只有 1 个 itb 资产、无校验文件，旧代码 `EXPECT_SHA` 取不到就 `die`，很容易让人顺手加 `--force`——而旧版 `--force` 会**同时关掉 sha256 完整性校验**（防 WiFi 传坏变砖最关键一环）并绕过沉淀闸。修复：① 新增 `official_asset_meta()`，用 **GitHub API 原生 `asset.digest`**（`sha256:...`，官方外部基准）替代缺失的 sha256sums；`derive_expect_sha()` 优先级 `--expect-sha` > 最新 asset digest > 按文件名查历史 asset digest > sha256sums。② `--force` **窄化为仅跳过 72h 沉淀闸**，校验段零引用；有基准但不匹配时**任何参数都不放行**，完全无基准才可用 `--allow-unverified-sha` 自担风险。③ `router_watch.sh` 无 sums 时不再静默跳过独立校验，改用 digest 兜底，两者皆无则 fail-closed。
3. **P1 · 近期异常硬复位抬高刷机窗口风险**：刷机是往 UBI 写数据的几分钟窗口，卡死根因未明时若复发（断电/网口锁死）即半写变砖，且 T2 兜底（HTTP Recovery 由 chainloader 提供）在供电/硬件级故障时可能一起失效。修复：新增 `precheck_recent_crash()`——本次启动带 `UBIFS recovery`（上次非正常关机）且 `uptime < 48h` 时默认拒绝刷机，需显式 `--allow-recent-crash`；dry-run 仅告警。

**配套一致性修复**：
- 沉淀闸从"校验官方最新 release"改为**绑定到实际待刷 ITB**（仅当两者同一镜像时用其所属 release 的 `published_at` 校验），堵住"闸校验 A、实际刷 B"的缝隙。
- `gh api` 加 3 次重试（实测过一次瞬时 `EOF`）。
- ⚠️ 踩坑固化：**bash `read` 把 tab 当 IFS 空白会折叠连续分隔符** —— `sums_url` 为空时后续字段整体左移，digest 被误读成 URL 去下载。现 jq 用 `NONE` 占位、read 后归一化。
- 新参数：`--allow-same-version` / `--allow-recent-crash` / `--allow-unverified-sha`，每个危险动作独立显式开关，不再一个 `--force` 全放开。

**实测验证（全部只读）**：`bash -n` 双脚本通过；`router_watch.sh --check` 下载 1029 itb（46M）并用官方 digest 独立校验通过（`a5a22cf0…10d`）；`upgrade_router.sh --dry-run` 确认目标为 `8f57dd40`（不再是 `1a34e17c`）、沉淀闸 98h 通过、版本递增校验通过、近期异常复位预检告警、回退镜像自动匹配 1016；显式 `--itb 1016` 时同版本保护正确命中；历史 itb 也能按文件名取到官方 digest。

> 当前状态：1029 已备料且校验通过，但 11-03 卡死未满 48h 观察窗，**真实执行仍会被 `precheck_recent_crash` 拦下**。要升需先过观察窗，或显式 `--allow-recent-crash` 自担风险。

## 收尾
- 升级后改默认密码：`ssh <路由器地址> 'passwd root'`。

## ⚠️ 路由器地址如何配置（不写死、不外泄）
脚本**不含任何个人 SSH 别名或局域网 IP**。运行时按以下优先级确定路由器 SSH 目标：
1. 环境变量 `ROUTER`（如 `export ROUTER=root@192.168.1.1`）
2. 命令行 `--router root@192.168.1.1`
3. 仓库本地文件 `router-target.conf`（已被 `.gitignore` 忽略，**不会进 Git**；首次成功连接后自动写入）
4. 自动探测 `~/.ssh/config` 中主机名含 `openwrt`/`immortalwrt`/`router` 的条目
5. 以上都没有时，**交互询问**你输入，并持久化到 `router-target.conf` 供下次免问

因此克隆本仓库的人无需改任何源码即可适配自己的网络；你的 `router-target.conf` 只存在于你自己机器上。
- 回退镜像已自动化：`upgrade_router.sh` 刷前会自动把"当前运行版本"的本地 itb 选为回退点（见 `resolve_rollback`）。**只需保证 `*.itb` 里别删掉旧版本文件**。待刷 itb 的选择与校验均已自动化：`ITB` 按"官方最新 release 的 itb 资源名"精确匹配本地文件（`--itb` 可显式指定，避免回退镜像因 mtime 更新被误选）；`EXPECT_SHA` 运行时从官方 `sha256sums` 派生（不再硬编码旧版本 sha，杜绝"误刷回退镜像假通过"）；离线或刷旧 itb 时用 `--expect-sha` 显式给定，`--force` **只跳 72h 沉淀闸，不能跳过 sha256 校验**；完全无基准时才可用 `--allow-unverified-sha`。

## 🤖 自动化无人值守（router_watch.sh）
- **何时加这层**：用户要"平时零介入"。此时升级从"手动触发"变"按需检测+满足条件自动刷"。
- **按需模式（推荐，非常驻）**：`router_watch.sh --now` 用户授权升级（保留 72h 发布沉淀闸）；`--check` 检测+备料（**会下载 itb、写 sha256sums、追加日志，不是零副作用**）；`--no-download` 纯只读巡检（零下载/零文件写入）；`--force` 跳过 72h 闸。无需 launchd 常驻。
- **非交互安全**：未配置路由器地址时，非 tty（launchd 等）环境直接报错退出而非挂起；`--router` / `ROUTER` 环境变量 / `router-target.conf` 任一就绪即可无人值守运行。`--no-download` 才是纯只读（不写任何文件）；`--check` 不修改源码但会备料落盘。watch.log 超 5000 行自动轮转保留最近 2000 行。
- **安全闸（缺一不可）**：
  1. **发布沉淀闸**：新版本发布 < 72h 不刷（单维护者构建，避开发布当日热修炸机）。
  2. **独立校验**：官方 `sha256sums` 优先，缺失时用 GitHub API 原生 `asset.digest` 兜底（1029 / 1112 均无 sums），两者皆无即 fail-closed；`EXPECT_SHA` 由 `upgrade_router.sh` **运行时**派生（watch 不再回写脚本文件，`--check` 零副作用）。
  2b. **测试版 / wipe-config 闸（2026-11-12 新增，11-13 加固）**：识别 release 正文的 `本次为测试固件` / `不保留配置` / `wipe-config` 及 `prerelease=true`；**再加一条不依赖措辞的客观信号** `TAG-DATE-MISMATCH`（tag 日期 != 镜像名日期）。release 元数据统一按 `published_at` 降序取、单次 gh 调用取齐，杜绝「闸校验 A、实际刷 B」。命中则 watch 停止备料、`upgrade_router.sh` 真实执行 fail-closed（dry-run 高亮告警），需 `--allow-test-build`。
  3. **强终验+自动回退**：`--auto` 模式跑硬终验(版本/外网直连/三频) + 软终验(OpenClash代理DNS, 仅启用时)；连不上路由器不触发回退。终验失败才自动 `sysupgrade -F <回退itb>`，回退后同样做 DNS 兜底。
  4. **U-Boot 兜底**：最终防线，刷坏自动进 Recovery（恢复页 IP 见上方 T2；刷 chainloader 后会变，必须重学）。

## 🔧 2026-11-12 上游复评后的 Skill 更新（本轮改动）

1. **测试版 / wipe-config 识别闸（P1）**：`official_asset_meta()` 旁新增 `official_release_flags()`，单独取目标 release 的 `tag_name` / `prerelease` / `body`（jq `gsub` 归一化成单行，避免 tab 折叠），正文命中 `本次为测试固件|测试版|不保留配置|wipe-config` 或 `prerelease=true` 时：`upgrade_router.sh` 真实执行默认 `die`（dry-run 高亮告警 + 打印正文摘录），需 `--allow-test-build`；`router_watch.sh` 命中即停止备料、不触发刷机。显式 `--itb` 指定历史版本时该闸不适用（目标已不是最新 release，标记不该张冠李戴）。读不到正文时为 `UNKNOWN`，只提示不阻断，避免 gh 抖动把正常升级卡死。
2. **`router_watch.sh` 版本比对修复（P1）**：旧代码 `rel_hash` 从 tag 尾部取 commit，纯日期 tag（`20261112`）会被误当 hash，且路由器 commit 10 位 vs 镜像文件名 8 位 →「已是最新」永不命中。改为从 itb 下载 URL 的文件名提取 8 位 commit，与运行版本前 8 位比对。
3. **`${FORCE:+--force}` 恒真修复（P1）**：`FORCE=0` 是**非空字符串**，`${FORCE:+--force}` 会恒展开成 `--force`，导致 `--now` 常规升级也把 `upgrade_router.sh` 的 72h 闸一并跳过（watch 自己的闸仍在，但语义不一致）。改为按值判断组装参数数组，并透传 `--allow-test-build`。
4. **T2 兜底入口补全 + 文档纠偏**：恢复页 IP / 触发时序写进 README、两份 SKILL.md、两个脚本头注释与重连失败提示；同时修掉 README 与 SKILL.md 里「`--force` 忽略 EXPECT_SHA 不匹配强制刷」「`--force` 跳过校验」「只下载 sha256sums」三处**与现行代码相反**的旧描述（现行：有基准不匹配任何参数都不放行，`--force` 仅跳 72h 闸，校验优先 asset.digest）。**72h 沉淀闸本身逻辑正确，未改**。

验证：`bash -n` 双脚本通过；`upgrade_router.sh --dry-run` 应同时打印「沉淀闸 <72h」与「测试版闸」告警；`router_watch.sh --check` 应在测试版闸处停止且零下载；`scripts/secret-scan.sh` 无命中。**全程只读，未刷机、未改路由器配置。**

## 🧭 U-Boot / chainloader 评估基线（2026-11-12 复核，取代早期误判）

**先记住四条曾经判错、不要再重复**：
- ❌「新 U-Boot 换了一整套实现 / 跨实现不兼容」——错。新仓库 README 那节标题是「与 **uboot-an758x**（TF-A BL2/FIP 方案）区别」，被误读成「与老仓库区别」。
- ❌「对运行期零收益」——错。U-Boot 经 FDT fixup 传 MAC 给内核，11-11 的 `ee2bc2608053` 正是修 CPU/conduit 与 lan2 共用 base MAC；本机实测 `cpu` / `lan2` / `lan3@cpu` / `lan4@cpu` / `br-lan` 五个接口共用同一个 base MAC（具体值不入库，见本地工作日志）。
- ❌「UBI 写入缺回读校验 → 刷 U-Boot 易变砖」——错。那是优化文档 §3.3 / §11 的**待办改进**，不是现存缺陷；刷 slot 走 raw MTD（逐块校验）+ SSH 文档要求回读 SHA256 + 保留回滚，根本不经过 UBI 写路径。
- ❌「所有 C 改动未编译验证 → 项目不成熟」——过度推断。作者本机无 aarch64 工具链，但 CI 有全量构建、clean-tree 守卫、1MiB 体积闸门、bot 发布；真正缺的是 §12 **真机判据清单**（WAN PCS / flood map）的逐项实测。

**正确事实**：
- 本机 U-Boot `U-Boot 2026.07-00760-gab7fd65100f1` 的 commit `ab7fd65100f1` 精确对应上游 `YYH2913/http-uboot` 2026-07-12 提交；`naoki66/Gemtek-brightspeed-chainloader` 是 10-15 另起的干净仓库（非 fork，历史压成 2 个提交），**同一条 chainloader 血脉**。
- 槽位格式实测一致：mtd3 `0x0 = 27 05 19 56`、`0x2100 = d0 0d fe ed`（双入口 magic）；`fw_printenv` 的 `bootcmd=run boot_ubi || http_recovery`、`recovery_dev_uboot=spi-nand0`、`uboot_ofs=0x600000`、`recovery_size_uboot=0x100000` 与新仓库 §5.3 几乎逐行一致。刷写目标相同（mtd3 / 0x600000 / 1MiB），**路径兼容**，风险等级是中等可控而非「易变砖」。
- fastmap、DHCP 租约表、WAN PCS、备份 API 都是 **10-16~10-19 那批**就有的；11-11 的 5 个提交里**唯一行为变更是 MAC offset**（另 4 个：SSH 刷写文档、裁 FAT/ext4/SPI-NOR 死代码使体积 1002314→937538、CI 固定 ubuntu-24.04、GCC14 编译修复）。别把「新仓库相对老仓库的全部改进」当成 11-11 的更新内容。
- 恢复页：`192.168.255.1`（当前 / YYH2913 上游）→ `192.168.0.1`（11-11 chainloader，提交 `d59b7f54cb94`）；进入方式两边都是「上电后按 reset、LED 变色松手」，只是措辞与 LED 判据不同，**不要写成「触发时序变了」**。
- `saveenv` 陷阱：README §5.1 留了一句危险旧话「用 `setenv bootdelay 1; saveenv` 覆盖」，与优化文档 §2.2 / §10 坑 6「连 bootdelay 这种小事也别为它去 save」冲突（作者其实已在优化文档里明确）。本机 `bootdelay=2` 正是坑 8 说的「被 saveenv 持久化过」。**二级 chainloader 里绝不执行 `saveenv` / `env default -a`**（uenv 是原厂共享分区）。
- 待验证兼容点：本机 mtd4 名为 `ubi`、`recovery_ubi_part=ubi`，新仓库板级代码只认 `system`。env 在 mtd1 会被沿用、启动大概率不受影响；但恢复模式刷 firmware 时是否识别，既不能断言会变砖也不能当无风险。
- 11-11 release 只挂 1 个 asset（xr1710g 937538 B），发布说明却列了 2 个文件并给出 xg2010g 的 SHA256 —— 产物与说明不符，XG2010G 镜像缺失。
- 两条并行线：上游 `YYH2913/http-uboot` 11-02 仍在更新（分区备份下载、RTL8261 延迟初始化），恢复页仍 `192.168.255.1`。评估「新版本 U-Boot」时别只看 naoki66 新仓库。

**结论（截至 2026-11-12）**：不单独刷 U-Boot；与「把 NPU 根因修复编进去的下一版正式固件」配套做（1112 发布说明已把 MAC 修复绑成固件+U-Boot 配套件，推翻了早期「先固件、U-Boot 后置」的顺序）。刷前备份 mtd3 + mtd1/uenv、确认新恢复页 `192.168.0.1`、验证 `ubi`/`system` 恢复路径、备好 TTL。

## 📌 当前固件状态（2026-11-13，会过期）

- `20261112`（镜像 `20261111-a6d84923`，97MB，digest `05b0a652…9fa80e`）仍是唯一含 XR1710G 镜像的最新版，OTA 测试版、`OTA: wipe-config`，下载 **874 次**；72h 闸按 `published_at`（北京 11-11 13:06）到 **11-14 13:06** 才过。`20261111` 标签里**没有 XR1710G 镜像**。
- **11-13 新增 issue #95**（11-12 15:51 北京，0 评论）：1112 上 AP 模式 mt7996 对 Qualcomm 客户端下行单播重试风暴（`failed==retries`，~200/s），频段/PHY/信道/BF/TWT/驱动全排除，Intel BE200 对照干净；报告者写明 **1016 与 1112 都复现**，属跨版本 mt76 问题 —— **升级不解决它**。本机是网关模式而非「一键 AP」，不能推断必现。11-12 记的「零故障 issue」作废。
- 11-11 晚间那批 NPU 根因修复之后，**11-13 复核仍无新 release、无新提交**，所以「等下一版把 NPU 修复编进去」的触发条件**还没到**。
- 1108：#94（5G/6G VIF 不在 fw4 硬件 flowtable、手动加入后掉速）、#90（5GHz 13 分钟后 MT7996/PCIe AER/full-reset 失败）；1029：#81 bridger 断流仍靠停 bridger 规避。
- Issue #82（1016 NPU Oops）是**报告者自行关闭**，作者从未确认根因、未声明修复；本机 dmesg 近 10 天无 Oops/panic。「官方已确认缺陷并已修」不成立。
- U-Boot 两条线 11-13 仍静止：chainloader 11-11 版下载 17→81 次、0 open issue、仍缺 XG2010G asset；YYH2913 上游停在 11-02。
- **触发条件**：等「把 11-11 晚间那批 NPU 根因修复编进去」的下一版正式固件 → 过 72h → 看新 issue → **先重建 kit**（当前 kit 是 10-08 旧版，`verify_kit` 会拦）→ 全清刷（不走 LuCI OTA）。

## 🔧 2026-11-13 二次审计后的修复（本轮改动，7 项 + 1 项实测新发现）

**先说最要紧的实证发现**：仓库根的 `kit.tar.gz` 是 2026-10-08 的，内嵌 `zzz-restore-router` 仅 **339 行**（仓库源码 445 行），缺 `zzz-disabled-services` 禁用态还原等后续修复，sha256 与源码不一致。`collect_runtime()` 只往这份旧 kit 注入配置、**不更新自举脚本**，所以上一轮记的「kit 重建未自动化」不只是人工环节，而是**真刷就会静默丢配置的现存缺陷**。已做成代码闸。

| # | 级别 | 修复 |
|---|---|---|
| 1 | 🔴 P1 | **出厂默认 IP 用错机型**：官方 README 首次启动表写明 XR1710G=`192.168.50.1`，`192.168.1.1` 属 XG2010G/Nokia。重连候选、`zzz-restore-router` 的 `LAN_IP` fallback、各处提示全部纠正；`192.168.0.1` 保留作兼容候选（它同时是 11-11 chainloader 的恢复页）。此前自举失败时 T1 会轮询 400s 试不到正确地址然后 `die`。 |
| 2 | 🔴 P1 | **T2 兜底预飞核验**：新增 `verify_t2_fallback()`，刷前读活跃 UBI 卷 `bootcmd`、mtd3 的 U-Boot 版本串与恢复页 IP，兜底不在位即 fail-closed（`--allow-unverified-t2` 放行）。此前 `bootcmd` 只出现在终验的 `echo` 里，刷前从不判定。刷前基线写进 `report.md` 第 8 节与刷后实测对比。 |
| 3 | 🟠 P2 | **kit 有效性闸**：新增 `verify_kit(pre/final)` + `build_kit.sh` 写无敏感信息 `etc/kit-manifest`（schema/commit/内核/文件 sha256）。只 `tar -xOf` 提取 2 个非敏感成员，**绝不整包解包注入后的 kit**（那含 root shadow/WiFi key/订阅）。核验自举脚本 sha == 仓库源码、必需文件齐全、final 阶段 manifest 绑定本次 `TARGET_COMMIT`；跨内核打印「勿恢复旧 `kmod-*`」强提示。陈旧 kit 默认拒绝（`--allow-stale-kit` 放行）。 |
| 4 | 🟠 P2 | **测试版闸补客观信号**：`official_asset_meta()` 与 `official_release_flags()` 合并为**单次 gh 调用** `official_release_meta()`，并 `sort_by(.published_at) \| reverse \| .[0]`（原来两次独立调用可能指向不同 release，且 `/releases` 默认按 `created_at` 排序）。新增 `TAG-DATE-MISMATCH`：tag 日期 != 镜像名日期（`20261112` 挂 `20261111` 镜像），不依赖发布说明措辞，上游改写英文 beta 也仍有机会兜住。`router_watch.sh` 同步。 |
| 5 | 🟠 P2 | **恢复页 / U-Boot 状态进报告**：`report.md` 新增第 8 节，刷前基线 vs 刷后实测（bootcmd、版本串、恢复页 IP）。刷过 chainloader 后恢复页从 `192.168.255.1` 变 `192.168.0.1`，报告里能直接看出来。 |
| 6 | 🟡 P3 | **watch.log 轮转**：超 5000 行就地截断保留最近 2000 行，不产生新文件（无需改 .gitignore）。 |
| 7 | 🟡 P3 | **`--check` 语义纠正 + `--no-download`**：`--check` 其实会下载 itb / 写 sha256sums / 追加日志，文档原写「纯只读」是错的。新增 `--no-download` 为真正零副作用模式（只报告、不下载、不写日志），定时巡检推荐用它。 |

验证：`bash -n` 四个脚本全过；`--dry-run` 应同时命中沉淀闸、测试版闸、T2 核验、kit 陈旧告警；`router_watch.sh --no-download` 零文件写入；`secret-scan` 无命中。**全程只读：未刷机、未改路由器配置、未推 GitHub。**

## ⚠️ 免责声明
本工具针对**非官方第三方固件**（naoki66 社区构建）。使用即自担风险：全清刷有变砖可能（虽有 U-Boot 兜底），请确认你的设备型号与固件来源匹配，并备份好当前配置与回退镜像。作者不对任何刷机后果负责。
