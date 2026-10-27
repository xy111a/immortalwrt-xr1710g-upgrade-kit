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
| 禁用态 | `etc/zzz-disabled-services`（刷前生成） | **overlay 白名单（whiteout，字符设备 0/0）不是普通文件，tar 抓不到**——禁用服务=删开机链，全清刷后 `/rom` 下层出厂链会重新可见，服务被默默重启（2026-10-08 升级后实际复发过）。修法：刷前算"出厂有链、现网无链、且 init.d 仍在（包未卸=用户主动禁用）"清单写入 kit，`zzz-restore` 首启动对每个链 `rm -f` 重建白名单。注意区分"包被卸"（init.d 不在）——那种不能禁，新固件自带该包时应保持出厂启用 |

**为什么全量抓 `/etc/config/firewall` 但要剥离 include（2026-10-27 修复 R5）**：现网 firewall 含用户大量自定义区域/转发/规则（实测 129 行），此前因"include 指向 `/var` 运行时文件、首启动尚不存在 → fw4 加载失败"而刻意不抓，导致这些自定义规则全清刷后回退包默认、需手动重建。现改为「全量抓 firewall + 首启动剥离 `/var` include 段」：剥离的是 openclash/zerotier 指向 `/var/etc/openclash.include`、`/var/run/zerotier-one/_fw4/*.nft` 的 `config include`（这些由对应服务自身启动时重新添加），保留的是用户全部自定义规则——既不丢配置、又避免启动失败。**注意**：这条是 2026-10-21 审计"覆盖率 100%"的盲区修正（当时 100% 是相对设计抓取集，未覆盖全清模型下的全部 live 配置）；R5 修复后才是真正的全量覆盖。

**怎么审计"还缺什么"**（下次换设备/换构建时重跑）：① `for f in /etc/config/*; do cmp -s $f /rom/etc/config/$f`（路由器无 `diff`/`cmp` 时拉回本机比）；② `comm -13 <(rom/etc 文件清单) <(etc 文件清单)` 找 /etc 新增文件；③ `/etc/rc.d` vs `/rom/etc/rc.d` 比启用态；④ `find /usr /www /bin /sbin /lib -type f` 与 `/rom` 对照找 NEW/MODIFIED（MODIFIED 要分清是**用户补丁**还是**包升级**：本机 `http.lua`/`http.uc` 的 100kB→10MB 是用户补丁，必须抓；`network.lua` 的 "OpenClash Append" 是包安装追加，会随 apk 重装回来，不抓）。

**AppleDouble 卫生（2026-10-21 整治）**：Mac 侧 tar（bsdtar）默认给每个文件附 `._*` 伴随文件，曾随 kit 刷进路由器 `/etc`（29 个垃圾）。四道防线：① Mac 侧所有 tar 设 `COPYFILE_DISABLE=1`（`upgrade_router.sh`/`build_kit.sh` 均已加）；② 路由侧抓取 tar 用 `-X` 排除 `._*`/`*.bak`；③ kit 打包前 `find "$build" -name '._*' -delete`；④ `zzz-restore-router` 首启动对 `/etc`、`/etc/openclash` 全树兜底清理。路由器上已存的垃圾：`find /etc -name '._*' -type f -exec rm -f {} \;`（纯元数据，删之无副作用；dropbear/uci 功能不受影响，已实测）。

## 四层安全保障（fail-safe，非 fail-proof）
- **T0 预防**：全清刷 + restore-kit 打成 `uci-defaults` 脚本随 `sysupgrade -f kit.tar.gz` 在首启动自举 → 路由自配自己，无需在刷机窗口在线值守。
- **T1 检测**：Mac 侧轮询重连（路由器地址 / 常见出厂 IP 如 192.168.1.1，每 5s 最多 80 次 = 400s）+ 终验。
- **T2 恢复（命门）**：U-Boot 常住兜底 `bootcmd=run boot_ubi || http_recovery` + `recovery_mtd=fit`（在 UBI 卷 ubootenv/ubootenv2，**不受 sysupgrade 影响**）。刷坏自动进 HTTP Recovery，免拆机。
- **T3 回退**：`upgrade_router.sh` 在刷前预飞阶段**自动解析当前路由器运行版本的 commit hash，并在本地 `*.itb` 中匹配同名 itb 作为回退镜像**（见 `resolve_rollback`）。即"当前版本"会被自动选为回退点——**前提是旧 itb 文件别删掉**。无匹配时回退到手动指定的 `FALLBACK_ITB`。回退操作：`sysupgrade -F <回退 itb>`。

## 执行顺序（每次升级）
1. **只读预飞**（不刷机）：Mac 仍连路由？路由可达且版本未漂移？U-Boot 兜底在位？itb sha256 匹配？套件齐备？
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
- **apk add 时机**：必须在 `rc.local`（S95done 后、网络就绪）执行，不可在 uci-defaults（S10boot，网络未起）。加 sentinel 文件防重复。
- **DNS 链（已修正）**：dnsmasq 上游指向 `127.0.0.1#7874` 必须以 OpenClash **实际监听该端口**为前提，绝不硬编码把 DNS 指死。自举脚本 `zzz-restore-router` 与 `auto_rollback` 均内置 **DNS 卫生检查**——若 7874 无进程监听则自动回退公共 DNS(223.5.5.5/8.8.8.8) 并重启 dnsmasq，避免"连WiFi没网"。
- **itb 完整性（走 WiFi 专用）**：上传后路由器侧复核 sha256，防 WiFi 抖动传坏镜像变砖。
- **6G**：`zzz-restore-router` 已默认关闭 6G（设备层 `radio2` 与接口层 `default_radio2` 均 `disabled='1'`，用户明确"6G不用"）；如需启用，改这两处 + `wifi reload`。
- **OpenClash 内核固化（P1，已根治"全清刷后报没有内核"）**：`build_kit.sh` 用 `--openclash-core <clash_meta 路径>` 把内核二进制烘焙进 kit 的 `etc/openclash/core/`（随 kit 整包 scp + `sysupgrade -f` 还原，不再走 57MB 经 SSH tar 管道的脆弱链路）；`collect_runtime` 抓取活路由 OpenClash 时**排除 `etc/openclash/core`**，避免重复搬运。双保险：`zzz-restore` 的 `rc.local` 在 apk 装完 OpenClash 后若发现内核缺失/不可执行，会运行时从官方 CDN（GitHub + ghproxy 镜像，v1.19.32）多源重试下载，失败仅 `notify` 告警不阻断启动；`verify_router` 在 OpenClash 启用时额外校验内核存在且可执行，缺失则判 FAIL 暴露问题。**重建真 kit 必须带 `--openclash-core`**，否则下次全清刷仍会丢内核。
- **进程名**：判代理活死用端口 `7874` 监听或 `ps w | grep [c]lash`（进程名是 `clash` 非 `clash_meta`，`grep clash_meta` 必误报 0）。
- **⚠️ OpenClash 实为上网网关（本机模型，务必牢记）**：本路由 OpenClash 是 **fake-ip 模式（`enhanced-mode: fake-ip`，`198.18.0.0/16`）+ TCP 重定向（nftables `jump openclash`）+ DNS 由 `127.0.0.1#7874` 接管**。即**全屋出网实际都走 OpenClash 代理**，不是"可选加速"。由此推出两个铁律：① 启动开关 `uci set openclash.config.enable='1'`（**注意是本构建 `start_service` 实际检查的 `enable` 不带 d**，见 `/etc/init.d/openclash:3594`；`enabled` 带 d 只是 LuCI 显示开关，两者都设 1 才稳）必须为真，否则开机 `start` 提前返回（报 `Now Disabled, Need Start From Luci Page`）→ 重启路由后 OpenClash 不启动 → dnsmasq 仍把 DNS 指死 7874 → **连上 WiFi 没网**。`zzz-restore` 现已显式把 `enable` 和 `enabled` 都设 1 双保险。② "已启用但 **0 真实节点**" = 用户**静默断网**（进程在、7874 在、DNS 通，但出不去）。`verify_router` 软终验在"OpenClash 是 DNS 网关"时若查到 0 节点直接判 FAIL 暴露此故障。

## ⚠️ OpenClash 诊断陷阱（排错时别再踩，已固化为 check_openclash.sh）
日常排查用仓库自带的 **`check_openclash.sh`**（Mac 侧 `bash check_openclash.sh`，自动定位路由器），它已固化正确方法。手动排错避开这 3 个坑：
1. **控制器 secret 在 clash 实际加载的配置文件**，即 `ps w | grep [c]lash` 里 `-f <file>` 所指（本机是 `/etc/openclash/lipa_bingling_click.yaml`），**不是**生成的 `/etc/openclash/config.yaml`。抓错文件 → 控制器鉴权失败 → 返回 0 节点 → **误判"没节点"**。
2. **mixed 端口（7890/7893 等）需要认证**：`curl -x http://127.0.0.1:7890` 会返回 `407 Proxy Authentication Required`，**这不是节点故障**！用户设备走的是透明重定向（TPROXY/REDIRECT）进代理，那条路不需要认证、上网不受影响。**绝不要用 `curl -x` 判断代理通不通。**
3. **fake-ip 模式下，经 7874 解析任意域名都返回 `198.18.x` 假 IP**，不能据此判断真实服务器（`mjl.sahytg.top` 等）是否可达；要判断真实节点服务器可达性，须用**公共 DNS**（如 `nslookup mjl.sahytg.top 223.5.5.5`）解析。
- **正确验证法**：查控制器统计"真实节点数"（过滤掉 Selector/URLTest/Fallback 等代理组，只数 `Vless/Vmess/Trojan/Hysteria2/...` 等真实类型）+ 看 `/connections` 活跃连接数 + 看 `nft` 的 `openclash` TCP 重定向包计数随出网探针**增长**。三者任一成立即证明代理真在扛流量。

## 运维加固（阶段 2/3，已落地，非破坏性）

- **真实配置还原（P2）**：`upgrade_router.sh` 的 `collect_runtime()` 现在额外抓取活路由的 `/etc/config/network` 与 `/etc/config/wireless` 注入 kit（标记文件 `etc/zzz-realconfig.flag` 标记"已带真实配置"）。首启动 `zzz-restore-router` 检测到该标记且真实配置通过健全性校验（`config interface 'lan'` + `config wifi-device 'radio0'`）后，**跳过写死 heredoc、改用真实配置还原**——用户自定义的信道/功率/桥接/额外 SSID 不再被覆盖。任一环节失败自动降级回已知良好 heredoc（含 SSID/LAN IP/密码占位），不会因新逻辑出错而失联。注意：真实配置内的 WiFi key 以明文存于 `/etc/config/wireless`，随临时 kit（`/tmp`，不进 Git）注入，源码与仓库仍零明文。
- **固件级回退点自动化（P2）**：预飞阶段 `ensure_rollback_itb()` 确保"当前运行版本"的 itb 本地存在；缺失则 best-effort 从官方 release 按日期/commit 匹配下载，与 `backup_config()` 的配置级快照（`sysupgrade -b` → `backups/`）形成"固件+配置"双保险。失败不阻断升级，回落 `FALLBACK_ITB`。
- **RC=2 重试（P2）**：`--auto` 强终验连不上路由器（RC=2）不再立即放弃，改为 6×10s 重试后再判定，避免早启动/执行机抖动导致的误判或过早放弃。
- **日志持久化 + 结构化报告（P3）**：`archive_logs()` 改为归档到 `~/router-upgrade-logs/<时间戳>/`（不再只存易失的 `/tmp`）；新增 `post_upgrade_report()` 生成 Markdown 报告——版本/外网直连 DNS/三频/OpenClash 进程+内核/DHCP 静态租约数/fw4 check/配置持久化（uci changes 空），升级结束与回退后各生成一份，一眼看清"到底恢复全了没"。
- **发布即校验固化（P3）**：仓库提供 `publish_to_github.sh`——提交→推送后，强制用 `gh api` 拉回每个文件的 blob 与本地 `diff`，非空且一致才算发布成功，杜绝空文件/截断事故（见该脚本）。
- **OpenClash 订阅数据还原兜底（P1 后补）**：`sysupgrade -n -f` 全清刷后，`zzz-restore` 的 `rc.local` 里 `apk add luci-app-openclash` **重装会清空 `/etc/openclash/config`**，曾导致实机升级后订阅丢失（只能从升级前快照回拷）。现 `collect_runtime()` 在刷前把活路由 OpenClash 数据（**除 57MB 内核**，避免 kit 膨胀）另存进 kit 的 `etc/zzz-oc-data/`（`apk add` 不触碰此路径）；`zzz-restore` 在 `apk add` 之后、启动 OpenClash **之前**据此原样还原，并清掉 macOS `._` 垃圾文件。与内核的 kit 烘焙+运行时下载兜底一起，构成"内核+订阅"双保险。

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
- 回退镜像已自动化：`upgrade_router.sh` 刷前会自动把"当前运行版本"的本地 itb 选为回退点（见 `resolve_rollback`）。**只需保证 `*.itb` 里别删掉旧版本文件**。待刷 itb 的选择与校验均已自动化：`ITB` 按"官方最新 release 的 itb 资源名"精确匹配本地文件（`--itb` 可显式指定，避免回退镜像因 mtime 更新被误选）；`EXPECT_SHA` 运行时从官方 `sha256sums` 派生（不再硬编码旧版本 sha，杜绝"误刷回退镜像假通过"）；离线或刷旧 itb 时用 `--expect-sha` 显式给定，或 `--force` 跳过校验（紧急恢复用）。

## 🤖 自动化无人值守（router_watch.sh）
- **何时加这层**：用户要"平时零介入"。此时升级从"手动触发"变"按需检测+满足条件自动刷"。
- **按需模式（推荐，非常驻）**：`router_watch.sh --now` 用户授权升级（保留 72h 发布沉淀闸）；`--check` 只检测；`--force` 跳过 72h 闸。无需 launchd 常驻。
- **非交互安全**：未配置路由器地址时，非 tty（launchd 等）环境直接报错退出而非挂起；`--router` / `ROUTER` 环境变量 / `router-target.conf` 任一就绪即可无人值守运行。`--check` 为纯只读，不修改任何源码。
- **安全闸（缺一不可）**：
  1. **发布沉淀闸**：新版本发布 < 72h 不刷（单维护者构建，避开发布当日热修炸机）。
  2. **独立校验**：下载官方 `sha256sums`，比对 itb 真实 sha256（防篡改）；并自动写入 `upgrade_router.sh` 的 `EXPECT_SHA`，避免人工改漏。
  3. **强终验+自动回退**：`--auto` 模式跑硬终验(版本/外网直连/三频) + 软终验(OpenClash代理DNS, 仅启用时)；连不上路由器不触发回退。终验失败才自动 `sysupgrade -F <回退itb>`，回退后同样做 DNS 兜底。
  4. **U-Boot 兜底**：最终防线，刷坏自动进 Recovery。

## ⚠️ 免责声明
本工具针对**非官方第三方固件**（naoki66 社区构建）。使用即自担风险：全清刷有变砖可能（虽有 U-Boot 兜底），请确认你的设备型号与固件来源匹配，并备份好当前配置与回退镜像。作者不对任何刷机后果负责。
