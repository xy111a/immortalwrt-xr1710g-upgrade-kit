---
name: router-immortalwrt-upgrade
description: 安全地对 Gemtek XR1710G（Brightspeed）路由器做 ImmortalWrt 第三方构建（naoki66）的全清刷升级，含 uci-defaults 首启动自举 + 多层防变砖保障。当用户说"升级路由器固件""升 9/x 固件""路由器刷机"或要复用这套升级套件时使用。覆盖：预飞门控、uci-defaults 自举脚本、Mac 侧编排器、全清还原范围（配置/脚本/补丁/启用态）审计法、以及 6 个已固化的 P0 陷阱（chpasswd 缺失 / tar uid 污染 dropbear / SSH host key 变更 / fw_env.config stale mtd0 / apk 时机 / busybox tar 无 --exclude）。
agent_created: true
---

# 路由器 ImmortalWrt 安全全清升级（Gemtek XR1710G / naoki66）

> 本 skill 来自一次真实的全清刷升级复盘。可直接调起，不必重踩坑。

## ✅ 当前状态（2026-11-17 真机实证，最新）

**B+A 双刷均已完成并验证通过，设备正常运行。后续加载本 skill 请勿再把刷机当作"待办"。**

| 项 | 现状 |
|---|---|
| 固件 | **`20261115-5e152df9`**（内核 6.18.60），2026-11-16 下午刷入 |
| U-Boot / chainloader | **官方 11-11 `U-Boot XR1710G-2026-11-11-ga9a12de55890`** |
| 刷写完整性 | mtd3 前 937538B 与官方 slot.bin **逐字节 cmp 完全一致**（sha `5990b9fd…`） |
| MAC 重复 | **已修复**：cpu=`…64`/lan3=`…65`/lan4=`…66`（刷前全撞 `…60`） |
| mtd1 原厂 env | 未改动（sha `19aae29f…`） |
| UBI | 6 卷全 OK、0 坏块、3.3s attach；fastmap 未写（内核未编 `CONFIG_MTD_UBI_FASTMAP`，不影响引导） |
| 验证脚本 | `post_flash_verify.sh` 重跑 **3 pass / 0 fail / 2 warn** |
| 刷后基线归档 | `~/router-upgrade-logs/post-flash-20261117-0650/` + 双份异地副本 |

**TTL 结论（用户 2026-11-17 明确）**：U-Boot 已刷好，**不需要拆机**，不再主动准备 TTL 硬件。
`ttl_rescue.sh` / `ttl_purchase_guide.md` 保留为**真变砖时的最后兜底资产**，非刷机前置条件。

> 下方第六/七轮的"未闭环"清单是**当时（2026-11-16 14:30）的历史快照**，已被本节取代。

## 何时用
用户要升级路由器固件（ImmortalWrt，第三方构建 naoki66，Airoha AN7581 平台）。
**关键前提**：固件来自第三方 GitHub `naoki66/ImmortalWrt-for-Gemtek-brightspeed`（原仓库名 `ImmortalWrt-for-Gemtek-XR1710G` 已改名；非官方，官方 airoha/an7581 目录空）。⚠️ 上游把 XG2010G 机型 build 标为 GitHub "Latest"，`releases/latest` 不含 XR1710G 固件，故脚本统一改用**遍历 `releases` 取首个含 `gemtek_xr1710g` itb 的 release**（见 `upgrade_router.sh`/`router_watch.sh` 的 `REPO` 与 release 解析）。升前**必看该仓库 release note** 是否写"不建议保留配置升级"——若写，则**必须全清刷**（keep-settings OFF），不可走"保留 network/wireless"捷径（子系统重构会导致首启动网络异常）。

## 资产位置（本 skill 自带）
脚本随 skill 一同安装，位于 skill 根目录（与 SKILL.md 同级）：
- `upgrade_router.sh` — Mac 侧编排器（上传 itb+kit → `sysupgrade -n -f` → 轮询重连 → 终验；支持 `--dry-run` / `--auto` / `--force`）。
- `zzz-restore-router` — uci-defaults 首启动自举脚本（设 LAN、三频 SSID、开 flow offload、注入 rc.local 装 OpenClash）。
- `build_kit.sh` — 本地从源码组装 `kit.tar.gz`（**不入库**；含你的 SSH 公钥、可选 OpenClash 配置、**强烈建议用 `--openclash-core` 烘焙内核**）。
- `uboot_upgrade.sh` — **U-Boot(chainloader) 独立升级/回滚子流程**（与固件升级完全分离，两个独立窗口）：只读探测 / 规划 / 备份下载校验 / 真刷 / 回滚 / Recovery 探测。详见下方「U-Boot 执行手册」。
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
| 启用态 | `/etc/rc.d`（排除 openclash 链） | `full` 策略保留"用户禁用 watchcat/igmpproxy"这类状态；openclash 链由 rc.local 的 `enable` 重建。`selective` 策略不导入旧 rc.d，禁用清单改抓服务名 |
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
5. **U-Boot env 校验陷阱（2026-11-16 实测校准）**：活跃 env 在 **UBI 卷 ubootenv(ubi0_1) / ubootenv2(ubi0_2)**，正确校验：`cat /dev/ubi0_2 | strings | grep -E '^bootcmd='`。**旧文档说「`fw_env.config` 把 mtd0 陈旧副本列首位导致读不到真 env」——此说法已被实机证伪**：本机 `/etc/fw_env.config` 实为 `/dev/ubi0_1 0x0 0x4000 0x1f000 1` + `/dev/ubi0_2 ...`，指向的正是**活跃 UBI 卷**，`fw_printenv` 读到的 `bootcmd=run boot_ubi || http_recovery` 与直读 UBI 卷完全一致。但结论不变：**判据一律直读 UBI 卷**（不依赖 fw_env.config，因为该文件本身可能被刷机覆盖，且它只覆盖两个卷、非完整真相），且**必须逐卷读** —— 旧实现把 ubi0_1/ubi0_2/fw_printenv 三路并联进同一管道，任一路命中即判「兜底在位」，掩盖了「哪一路真的在位」。现已改为逐卷分离判定 + 冗余健康度报告。
   - **✅ 2026-11-16 已修复：env 冗余对单点失效** —— 排查确认 `ubi0_1`(ubootenv) 是 **dynamic 卷但内容全 0xFF（0 个变量，CRC 必然不通过）**，真实 env 只存在于 `ubi0_2`(ubootenv2，**static 卷**，34 个变量，CRC 有效)。已用 `uboot_upgrade.sh --fix-env-redundancy --ack-env-fix` 修复：把 ubootenv2 的 env_t 原样复制成 ubootenv 的**有效副本**，仅把 `flags` 改为 `0xFF`(obsolete) —— 命中 `env_check_redund` 的 `flags1==255 && flags2==0 → ENV_REDUND` 分支，**U-Boot 仍选 ubootenv2，引导行为零变化**（`fw_printenv` 输出修复前后逐行一致），但 ubootenv2 一旦损坏即可回落到 ubootenv。ubootenv2 全程未被触碰（首字节比对 `92ffd9c2 00` → `92ffd9c2 00` 保持不变）。
  - **📐 env_t 布局（2026-11-16 实机反推 + 上游源码交叉验证，本 skill 最重要的格式知识）**：
    ```
    env_t = { u32 crc(LE) ; u8 flags ; u8 data[ENV_SIZE-5] }   总长 == CONFIG_ENV_SIZE == 16384
    CRC   = crc32(0, data, ENV_SIZE-5)        // 即 crc32(data[0:16379])
    data  = "key=value\0" 串, 尾部用 0xFF 填充到 16379 字节
    ```
    ⚠️ **踩过的坑**：`fw_env.config` 里写的 size 是 `0x4000`，容易误以为 CRC 覆盖 16384 字节；实测**第 5 个字节是 flags（不是 data 的首字节）**，data 从偏移 **5** 开始、长度 **16379**。用偏移 4 + 长度 16380 / 16379 全试都对不上，只有 `data=raw[5:5+16379]` 精确命中 `crc32`。
    - 判定依据链：YYH2913 `defconfig`(`CONFIG_ENV_SIZE=0x4000` `CONFIG_ENV_IS_IN_UBI=y` `CONFIG_ENV_REDUNDANT=y` `CONFIG_ENV_UBI_VOLUME="ubootenv"` `CONFIG_ENV_UBI_VOLUME_REDUND="ubootenv2"`) + `env/ubi.c` 的 `ubi_volume_write(..., 0, CONFIG_ENV_SIZE)` + `env_check_redund` 的 flags 比较逻辑 + 实机 CRC 穷举。
    - **flags 语义**：`255`=obsolete、`0`=active。两份 CRC 都有效时按 flags 大小选：`flags1==255&&flags2==0→ENV_REDUND(用 buf2)`；`flags2==255&&flags1==0→ENV_VALID(用 buf1)`；否则 flags 大者胜。
    - **`ubootenv2` 是 static 卷**（UBI static 卷不可原地重写），所以修复策略必须是「**只写 ubootenv、绝不碰 ubootenv2**」；`ubootenv` 是 dynamic 卷可安全覆盖。
    - 修复用 `ubiupdatevol /dev/ubi0_1 <env_t.img>`（设备上有 mtd-utils 2.3.1），**不要用 `fw_setenv`** —— 它会走 `ubi_ioctl` 并自行管理 flags 语义，无法精确控制"只写一份、且让 ubootenv2 保持 active"。
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
8. **路由器 shell 直连会被 nft 劫持，测出来是假阳性**（2026-10-30）：承载 `ip protocol tcp → redirect to :7892` 的那条 openclash 链会把本机出向 TCP 劫持到本地 clash 端口。于是 `bash -c 'exec 3<>/dev/tcp/<服务器IP>/<端口>'` 会**秒连成功**，但连的其实是本地 7892，**根本不是远端服务器**——我据此差点误判"入口正常"。要测真实路径必须先插豁免，测完按 handle 删除。（另：BusyBox `nc` **不支持 `-z`**，一切 `nc -z` 探测都是假阴性；`/dev/tcp` 需 bash，路由器有 `/bin/bash`。）
   - **⚠️ 2026-11-17 重大更正：链名绝不能硬编码。** 本文旧版与 `check_openclash.sh` 都写死 `inet fw4 openclash_output`，但**1115 固件 + 新版 OpenClash 上该链不存在**，真正承载 TCP redirect 的是 **`inet fw4 openclash`**。硬编码 + `2>/dev/null` 会让插入**静默失败**，脚本却照样打印"已豁免"并给出"真实可达 / 入口 IP 被封"的**假结论**。本次实战即被此坑误导：把"机场拒绝代理节点出口"错判成"订阅失效 / 家宽 IP 被封 / 443 不通"，而修好豁免后实测**真·直连 443 通、根路径 HTTP 200**。
   - **正确做法**（已落进 `check_openclash.sh` 的 `oc_find_redirect_chain` / `oc_exempt` / `oc_unexempt`）：① 动态定位链——扫 ruleset 找"含 `ip protocol tcp` 且 `redirect to :<port>`"的 openclash 链（排除 DNS 劫持链的 `:53`）；② 检查 `nft insert` 的 **rc**；③ **回读自证**规则确实在链里（拿到 handle）；④ 任一环节失败就**跳过本节并声明结果不可信**，绝不输出可达性判定；⑤ 测完按 handle 删除并**核查残留为 0**。
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
  2b. **版本闸（2026-11-15 拆分）**：`TEST` / `PRERELEASE` = 版本性质（`本次为测试固件`/`测试版` + `prerelease=true`），默认拒绝、需 `--allow-test-build`；`WIPE-CONFIG` = 配置兼容性（`wipe-config`/`不保留配置`），**不是拒绝刷的理由**，而是强制切 `selective` 配置策略 + 需 `--ack-config-reset` 显式确认。`TAG-DATE-MISMATCH` 保留为独立客观信号。旧逻辑把 `wipe-config` 算进 `TEST`，对 1115 这类正式版给出「等正式版」的错误建议，已修正。release 元数据仍按 `published_at` 降序、单次 gh 调用取齐。
  3. **强终验+自动回退**：`--auto` 模式跑硬终验(版本/外网直连/三频) + 软终验(OpenClash代理DNS, 仅启用时)；连不上路由器不触发回退。终验失败才自动 `sysupgrade -F <回退itb>`，回退后同样做 DNS 兜底。
  4. **U-Boot 兜底**：最终防线，刷坏自动进 Recovery（恢复页 IP 见上方 T2；刷 chainloader 后会变，必须重学）。

## 🔧 2026-11-12 上游复评后的 Skill 更新（本轮改动）

1. **测试版 / wipe-config 识别闸（P1）**：`official_asset_meta()` 旁新增 `official_release_flags()`，单独取目标 release 的 `tag_name` / `prerelease` / `body`（jq `gsub` 归一化成单行，避免 tab 折叠），正文命中 `本次为测试固件|测试版|不保留配置|wipe-config` 或 `prerelease=true` 时：`upgrade_router.sh` 真实执行默认 `die`（dry-run 高亮告警 + 打印正文摘录），需 `--allow-test-build`；`router_watch.sh` 命中即停止备料、不触发刷机。显式 `--itb` 指定历史版本时该闸不适用（目标已不是最新 release，标记不该张冠李戴）。读不到正文时为 `UNKNOWN`，只提示不阻断，避免 gh 抖动把正常升级卡死。

   > ⚠️ **本条已于 2026-11-15 拆分重写**：`wipe-config` 不再计入 `TEST`，正式版带 `wipe-config` 时改为强制 `selective` 策略 + `--ack-config-reset` 确认，详见下方「wipe-config 版本适配」。
2. **`router_watch.sh` 版本比对修复（P1）**：旧代码 `rel_hash` 从 tag 尾部取 commit，纯日期 tag（`20261112`）会被误当 hash，且路由器 commit 10 位 vs 镜像文件名 8 位 →「已是最新」永不命中。改为从 itb 下载 URL 的文件名提取 8 位 commit，与运行版本前 8 位比对。
3. **`${FORCE:+--force}` 恒真修复（P1）**：`FORCE=0` 是**非空字符串**，`${FORCE:+--force}` 会恒展开成 `--force`，导致 `--now` 常规升级也把 `upgrade_router.sh` 的 72h 闸一并跳过（watch 自己的闸仍在，但语义不一致）。改为按值判断组装参数数组，并透传 `--allow-test-build`。
4. **T2 兜底入口补全 + 文档纠偏**：恢复页 IP / 触发时序写进 README、两份 SKILL.md、两个脚本头注释与重连失败提示；同时修掉 README 与 SKILL.md 里「`--force` 忽略 EXPECT_SHA 不匹配强制刷」「`--force` 跳过校验」「只下载 sha256sums」三处**与现行代码相反**的旧描述（现行：有基准不匹配任何参数都不放行，`--force` 仅跳 72h 闸，校验优先 asset.digest）。**72h 沉淀闸本身逻辑正确，未改**。

验证：`bash -n` 双脚本通过；`upgrade_router.sh --dry-run` 应同时打印「沉淀闸 <72h」与「测试版闸」告警；`router_watch.sh --check` 应在测试版闸处停止且零下载；`scripts/secret-scan.sh` 无命中。**全程只读，未刷机、未改路由器配置。**

## ⚠️ NAND 写入路径踩坑（2026-11-16 实机故障，两轮实证，**别再改回 dd bs=1M**）

**故障现象**：`dd if=镜像 of=/dev/mtd3 bs=1M conv=fsync` 打印 `WRITE_BEGIN` 后**没有 `WRITE_DONE`**，dd 静默非零退出。

**根因（第二轮才定位准，第一轮判断错了）**：
- ❌ 第一轮误判：「`bs=1M` 不是 erasesize 的整数倍 → 必然 EINVAL」。**错** —— 本机 `erasesize=131072`（128 KiB），1 MiB 恰好是它的整数倍（`1048576 % 131072 == 0`）。
- ✅ 真根因：**NAND mtd 字符设备只接受「整擦除块」写入**。官方 chainloader 镜像长 **937538** 字节 = 7×131072 + **20034 字节尾巴**，非整除 → dd 的最后一次 `write()` 长度不对齐 → 内核返回 **EINVAL**。换 `bs=128K` 尾巴照样不对齐 —— 关键在**镜像长度**，不在 `bs` 选多少。

**修法（已落地 `uboot_upgrade.sh`）**：
1. **写前把镜像用 `0xFF` pad 到 erasesize 整数倍**（937538 → 1048576，填 111038 字节 0xFF）。0xFF 与本机 mtd3 现有空闲区一致，不引入额外差异；pad 后双入口 magic 不变。
2. 优先 `mtd write`（内核侧处理擦除与对齐）+ `mtd verify` 逐字节校验；不可用才回落 `dd bs=erasesize`。
3. **不预先整分区 `mtd -e erase`** —— 让 `mtd write` 逐块擦后即写，把"slot 全空"的窗口从 1 MiB 缩到 1 个 128 KiB 块；只有逐块写明确失败才整分区擦除重试一次。
4. ⚠️ **rc 捕获纪律**：绝不能 `cmd | tail -2` 后取 `$?` —— 那是 `tail` 的退出码，**会把失败伪装成成功**。远端统一用 `run_logged`：`cmd > log 2>&1; rc=$?; cat log`。

**副作用**：mtd 二进制里没有 `padd` 相关字符串 → 该版本 `mtd write` **不会自动补齐末块**，所以第 1 步的自行 pad 是必需的，不能省。

**离线验证（已通过）**：pad 后双 magic 完好、尾部全 0xFF、8 次写入全部 128 KiB 对齐、整块回读 == pad 后镜像、**回滚写回备份逐字节完全恢复原 sha256**。

## 🧩 env 冗余对修复（2026-11-16 已实施，可复现）

**问题**：YYH2913 血脉的 U-Boot 用 UBI 冗余 env 对（`CONFIG_ENV_UBI_VOLUME="ubootenv"` + `CONFIG_ENV_UBI_VOLUME_REDUND="ubootenv2"` + `CONFIG_ENV_REDUNDANT=y`）。本机 `ubootenv`(ubi0_1, dynamic) **内容全 0xFF**、0 个变量（CRC 必然不通过），真实 env 只在 `ubootenv2`(ubi0_2, **static**)。→ 冗余对实际只有一份保险。

**修法**（已实施并验证）：
```bash
./uboot_upgrade.sh --fix-env-redundancy --dry-run    # 只读体检 + 备份 + 构造，不写
./uboot_upgrade.sh --fix-env-redundancy --ack-env-fix # 真写（只写 ubootenv）
```
原理：把 ubootenv2 的 env_t **原样**复制成 ubootenv 的有效副本，仅把 `flags` 改成 `0xFF`(obsolete) → 命中 `env_check_redund` 的 `flags1==255 && flags2==0 → ENV_REDUND`，U-Boot **仍用 ubootenv2**，引导行为零变化；但 ubootenv2 损坏时能回落到 ubootenv。

**安全设计**：
- **绝不写 ubootenv2**（static 卷 = 唯一有效保险，写了不可原地恢复）
- 目标必须是 dynamic 且当前无有效变量，否则拒绝写入（不覆盖未知内容）
- 写前备份两卷 + `fw_printenv` + `ubinfo`，备份失败 = fail-closed
- 写后回读：变量数、flags 字节、`fw_printenv` 前后逐行比对
- **幂等**：已修复时重跑只报"无需修复"

**实测结果**：`ubootenv` 首字节 `92ffd9c2 ff bootd...`（flags=0xFF ✅）、`ubootenv2` 首字节 `92ffd9c2 00 bootd...`（**未被触碰** ✅）、两卷各 34 个变量、`fw_printenv` 前后逐行一致、mtd1/mtd3 sha256 与基线一致。


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
| 恢复页 | 192.168.255.1 | 192.168.0.1 |

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

## 🔧 U-Boot 执行手册（2026-11-16 新增，评估基线 → 可执行流程）

**为什么单独成篇**：固件升级刷 UBI/fit 卷，U-Boot 升级刷 mtd3(chainloader) + env 层，**写入路径、失败模式、回退手段完全不同**。塞进同一次 sysupgrade 等于同时引入两个未验证变量，变砖后无法归因。**结论：两个独立窗口，先固件稳定，再 U-Boot。**

**执行 `uboot_upgrade.sh`（本机路径 = HTTP Recovery 的 uboot 目标）**：

```bash
cd ~/.workbuddy/skills/router-immortalwrt-upgrade

# 1) 只读探测现状（mtd 布局 / env 冗余健康度 / chainloader 版本串 / magic）
bash uboot_upgrade.sh --status

# 2) 规划：官方选片 + digest + 结构校验（不写入）
bash uboot_upgrade.sh --plan

# 3) 备份 + 下载 + 校验（不写入任何分区）—— 推荐先跑这步
bash uboot_upgrade.sh --prepare

# 4) 真刷（必须显式 --ack-uboot-flash；写后整块回读比对，不符则不重启）
bash uboot_upgrade.sh --flash --ack-uboot-flash

# 5) 回滚（用 prepare 阶段的备份写回旧 chainloader）
bash uboot_upgrade.sh --rollback --ack-uboot-flash --backup-dir ~/router-upgrade-logs/uboot-backups/<ts>

# 6) 救砖时探测 Recovery 页
bash uboot_upgrade.sh --probe-recovery
```

**脚本内置的五道闸**（对应"变砖"的每个入口）：
1. **官方选片纪律**：只认本机机型 `xr1710g-chainloader-*-slot.bin`，只认 `*-slot.bin`（**绝不刷 `u-boot.bin` / 裸 `.itb`** —— 上游明确说裸 FIT 不能通过 HTTP Recovery 上传）。release body 常列 xg2010g 的 sha256 但该 asset 可能未上传，XR1710G 与 XG2010G 镜像**不通用**，混刷直接变砖。
2. **备份 fail-closed**：刷前必备份 `mtd3`(chainloader 1MiB) + `mtd1`(uenv 2MiB) + `ubi0_1`/`ubi0_2` + `/proc/mtd` + `fw_printenv` 全量 + `ubinfo`，落盘并生成 sha256；备份不全/大小不符直接中止。
3. **三层 sha256**：下载后本机校验 → 设备侧上传后复算 → 与 GitHub `asset.digest` 官方基准比对，任一不符即中止。
4. **双入口 magic 校验**（实机确认的判据）：`0x0` = `27 05 19 56`（prefix shim）+ `0x2100` = `d0 0d fe ed`（内嵌控制 DTB `airoha,xr1710g-chainloader-control`），且镜像必须 ≤ 1MiB。**已做负向测试**：裸 itb / 随机数据 / 超大文件全部正确拒绝。
5. **写后整块回读比对**：回读前 N 字节与源镜像 sha256 必须一致，**不一致则拒绝重启**（设备仍可重写），并提示用备份回滚。

**绝不触碰 env**：脚本只写 chainloader 分区，**从不执行 `saveenv` / `env default -a`**。原因：`uenv`(mtd1) 是**原厂 U-Boot 的 env 分区**，二级 chainloader 只是共用读取；一旦在 chainloader 里 `saveenv`，原厂环境会被整套替换成 chainloader 的环境（如 `bootcmd=run boot_ubi || http_recovery`），原厂 U-Boot 再启动时找不到自己的启动配方（表现为卡在 `ECNT>` 报 `Unknown command 'ubi'`）。恢复办法是在**原厂** `ECNT>` 提示符下 `setenv bootcmd 'flash read 0x600000 0x100000 0x81800000; bootm 0x81800000'` + `saveenv` + `reset`。

**⚠️ 本机现状与上游教程前提不同（2026-11-16 实机确认）**：上游 `docs/flashing-xr1710g.md` 的 TTL+TFTP 流程针对的是「**原厂** U-Boot(`ECNT>`)」状态；**本机已处于「已刷 chainloader」状态**（mtd3 已是 chainloader FIT，mtd1 uenv 的 bootcmd 已是 `flash read 0x600000 0x100000 $loadaddr; bootm`）。所以本机日常路径是「HTTP Recovery 的 uboot 目标上传 `*-slot.bin`」，**拆机 TTL 是最后的救砖手段而非常规路径**。

**✅ 兼容点已闭环（2026-11-16 离线实证，撤销此前"system vs ubi 可能变砖"的判断）**：本机 mtd4 名为 `ubi`、`recovery_ubi_part=ubi`；官方 11-11 chainloader 的上游 DTS 标签为 `system`。**两者并不冲突**，原因有两层实证：
- **Recovery 侧写固件只按 UBI 卷名 `fit` 写**（`recovery_mtd=fit`），**与分区 label 无关** —— 所以 `ubi` / `system` 命名差异在刷固件路径上无影响。
- **官方文档 §7.2 明写**：一级/二级引导都按**固定偏移**读取（`uboot_ofs=0x600000`、`recovery_size_uboot=0x100000`），**不查分区表** —— 所以二级 chainloader 也不会因为 `system` 标签不存在而失败。
- 附：官方 DTB 的分区表与本机 `/proc/mtd` **逐一精确吻合**（`@0=bootloader(2M)` / `@200000=uenv(2M)` / `@400000=dsd(2M)` / `@600000=chainloader(1M)` / `@700000=system(0x1b700000)`）；本机 YYH2913 DTB 只是把 `0x0-0x600000` 合并为 `vendor`（6MB）并多出 ubi1.5/ubi1.0 两个备选档。

**⚠️ 撤销的另一处旧判断**：「一级 bootcmd 不兼容」同样被推翻 —— `0x602100 - 0x600000 = 0x2100`，官方 SSH 文档回读偏移正是 `skip=8448`（=0x2100），YYH2913 README 明写 dual-entry 支持从 `0x600000` 无参 `bootm`。本机 uenv 实测 `bootcmd=flash read 0x600000 0x100000 $loadaddr; bootm` **与官方完全一致**。

**恢复页地址会变**：当前血脉 `192.168.255.1` → 11-11 chainloader `192.168.0.1`（DHCP 改为按 MAC 的租约表）。`upgrade_router.sh` 现维护状态档案 `~/router-upgrade-logs/uboot-state.env`（恢复页 IP / 触发方式 / U-Boot 版本串 / env 健康度 / 最近实测时间），重连候选与失败提示一律读它，**不再散落硬编码**。刷完 U-Boot 请更新该文件并实测一次 Recovery 页。

## 🔬 第五轮实证：mtd1(uenv) 的真相 + 官方 chainloader 的引导链（2026-11-16）

### A. 撤销「mtd1(uenv) CRC 失效」的旧判断 ✅

此前据「mtd1 存的 `0xa42efba6` vs `crc32(0, mtd1[4:4+0x4000])=0xc7d824ec`」判定 mtd1 env CRC 失效。
**那是长度用错了**。精确穷举结果：

```
mtd1 非 0xFF 区间 = [(0, 16383), (131072, 2097151)]      # 第一份 env 只占前 16 KiB
crc32(mtd1[4 : 4+16380]) == 0xa6fb2ea4 (LE) == 存储值 0xa42efba6 (BE)  ✅ 精确命中
```

即 **mtd1 的 env CRC 完全有效**，只是它用的是**原厂 ECNT bootloader 自己的 env 格式**（`crc(4) + data[16380]`，无 flags 字段），不是 U-Boot 的 `env_t`。
→ **「mtd1 CRC 失效 → 二级 U-Boot 回落官方默认 env → ethaddr 可能变」这条推断链整个不成立**，本机 MAC 不会因 env 回落而变。

**mtd1(uenv) 里是原厂 env 的实证内容**（`strings /dev/mtd1`）：
```
bootcmd=flash read 0x600000 0x100000 $loadaddr; bootm     ← 与官方教程完全一致
arch=arm  baudrate=115200  board=an7581_evb  ethact=ecnt_eth
ethaddr=00:AA:BB:01:23:40                                  ← 占位符, 非本机真实 MAC
ipaddr=192.168.1.1  serverip=192.168.1.10  loadaddr=0x81800000
root=/dev/mtdblock4 ro  product_name=xPON ONU  fdt_high=0xac000000
```

> ⚠️ `ethaddr=00:AA:BB:01:23:40` 是原厂**占位符**，不是本机 MAC。本机真实 MAC 由 factory/DSR 决定，
> 二级 U-Boot 启动时通过 `xr1710g_sync_runtime_ethaddrs()` 从 factory 卷同步，**不依赖 mtd1 的 ethaddr**。

### B. 官方 chainloader 的引导链逐环实证（读官方源码 `board/airoha/an7581/xr1710g_rfb.c`）

| 环节 | 官方 11-11 行为 | 本机现状 | 结论 |
|---|---|---|---|
| env 存储 | `CONFIG_ENV_IS_IN_MTD=y` / `CONFIG_ENV_MTD_DEV="uenv"` / `CONFIG_ENV_OFFSET=0x0` | mtd1 名 `uenv`、偏移 0、CRC 有效 | ✅ 完美匹配 |
| 冗余 env | `# CONFIG_ENV_REDUNDANT is not set`（**官方不用 UBI 冗余对**） | 本机 YYH2913 用 UBI 冗余对 | ⚠️ 官方 chainloader 只读 mtd1，不读 ubootenv/ubootenv2 —— 之前那对冗余是给**现役 YYH2913 二级**用的，刷官方后即失效（无害） |
| 一级 bootcmd 归一化 | `board_late_init()` 检测 `bootcmd` 含 `"flash "` → 改写为 `run boot_ubi \|\| http_recovery` | mtd1 bootcmd 正是 `flash read 0x600000 ...` | ✅ 官方代码**主动**处理这个配方，无需手工干预 |
| UBI 分区名 | `xr1710g_detect_ubi_part()` → 布局表只有 `{"2.0", "system"}` | 本机 mtd4 名为 `ubi` | ⚠️ `ubi part system` 会失败 → 但 `select_ubi()` 先比对 `ubi->mtd->name` |
| fit 卷 | `ubi_read_production=ubi read ${loadaddr} fit` → 读 **UBI 卷名 `fit`** | ubi0_0 名 `fit`，46.2 MiB，内容是 FIT（magic `d00dfeed`，含 `config-1`/`kernel-1`/`rootfs-1`） | ✅ 精确匹配 |
| bootargs | `root=/dev/fit0` | 本机 `/proc/cmdline` 含 `root=/dev/fit0` | ✅ 一致 |
| DRAM 容量 | `ubi read ${loadaddr} fit` 要把 46 MiB 读进 RAM | MemTotal 1.86 GB，loadaddr=0x81800000 | ✅ 容量充裕 |
| 恢复页 | `ipaddr=192.168.0.1`（`board_late_init` 硬编码） | 本机现为 192.168.255.1 | ⚠️ 刷完**会变** |

**mtd4 名字问题的实质**（此前列为「待验证兼容点」，本轮已定性）：
- 二级 chainloader 用**自己内嵌的 DTB** 解析 MTD 分区表 —— 官方 DTB 标签是 `system`（@0x700000, 0x1b700000），
  与本机 mtd4 的**偏移与大小完全一致**，只是本机运行时对外报的名字叫 `ubi`（内核侧视角）。
- `xr1710g_select_ubi()` 的逻辑是 `strcmp(ubi->mtd->name, part)`，即比较**二级 U-Boot 自己 DTB 里的名字**。
  二级用的是官方 DTB（`system`），对它自己而言 `system` 存在 → 匹配 → `ubi part system` 成立。
- ⇒ **`ubi` vs `system` 命名差异在引导链上无影响**，此前「待验证」项可以关闭。

### C. 本次 prepare 产出的实证资产

`~/router-upgrade-logs/uboot-backups/20261116-130340/`：
- 备份 8 项（mtd3 / mtd1 / ubi0_1 / ubi0_2 / fw_printenv / ubinfo / proc-mtd + SHA256SUMS）→ 复核 **7/7 OK**
- `mtd-chainloader.bin` sha256 = `a65bba65300a381b…` 与设备当前 mtd3 **逐字节一致** → 回滚可用
- 官方镜像 `xr1710g-chainloader-20261111-051034-ga9a12de55890-slot.bin`（937538 B），sha256 与官方 release 说明**完全一致**（`dbe285a7…`）
- MAC 基线已快照（10 个接口）

### D. 本轮修复：`--rollback` 写入路径与 `--flash` 对齐

原 `--rollback` 用「先整分区 erase → 再 `mtd write`」，与 `--flash` 不一致，且**无回读比对**。已统一为：
pad 到 erasesize 整数倍 → 上传后 sha256 校验 → `mtd write` 逐块擦写（失败才整分区擦除重试一次）→ **整块回读 sha256 与备份比对，不符则明确报错并拒绝"成功"**。

### E. DTB 命名差异的最终定性（三方 DTB 交叉比对）

用 `pyfdt` 把三份 DTB 的分区表拉平对比，**命名差异彻底闭环**：

| DTB 来源 | mtd4 的 label | offset / size | 谁在用 |
|---|---|---|---|
| 本机 mtd3（YYH2913 11-02，内嵌） | `ubi` | 0x700000 / 460324864 | 现役二级 U-Boot（**刷官方后即不再使用**） |
| 官方 naoki66 chainloader 11-11（内嵌） | **`system`** | 0x700000 / 460324864 | **刷入后的二级 U-Boot** |
| 官方 1115 固件 itb（内核 DTB） | **`ubi`** | 0x700000 / 460324864 | 刷完固件后的 **Linux 内核** |

- 三者 offset 与 size **完全一致**（0x700000 / 460324864），指向同一块物理 mtd4。
- 二级 U-Boot 用**自己内嵌的 DTB** 解析 MTD（`system`）→ `ubi part system` 在二级内**成立**。
- Linux 内核用**固件 itb 里的 DTB**（`ubi`）→ 内核侧看到 `ubi`，与现在一致。
- ⇒ **`system` vs `ubi` 在任何一环都不冲突**，是「两份 DTB 各说各话」的正常现象。此前的「待验证兼容点」彻底关闭。

### F. `bootargs` 三方一致

```
官方 XR1710G_BOOTARGS = "console=ttyS0,115200 earlycon ubi.block=0,fit root=/dev/fit0 rootwait rdinit=/sbin/init"
1115 固件 chosen/bootargs = 同上（逐字节一致）
本机 /proc/cmdline      = 同上 + " ubi.fm_autoconvert=1"（内核自动追加，不影响引导）
```
→ 内核 root 路径 `/dev/fit0` 与 fit 卷内容自洽。

### G. prepare 已就绪的资产清单（2026-11-16 13:03）

**备份目录**：`~/router-upgrade-logs/uboot-backups/20261116-130340/`
- 8 项备份 + `SHA256SUMS`，复核 **7/7 OK**
- `mtd-chainloader.bin` sha256 `a65bba65300a381b…` == 设备当前 mtd3（**回滚可用**）
- `mtd-uenv.bin` sha256 `19aae29fd16dbe8e…`（原厂 env，CRC 有效）
- `mac-baseline.txt`（10 个接口）

**chainloader 镜像**（官方 11-11，与 release 说明 sha256 完全一致）
`xr1710g-chainloader-20261111-051034-ga9a12de55890-slot.bin` · 937538 B · `dbe285a7ce09884650daee5df65571809c96b6a89a2d3a0495f3e6870c688d68`

**连带刷的官方固件**（已下载并校验）
`~/router-upgrade-logs/firmware-cache/immortalwrt-naoki66-20261115-5e152df9-airoha-an7581-gemtek_xr1710g-squashfs-sysupgrade.itb`
85,561,654 B · sha256 `7a828e881ed1a7bfc7c632293f1203e545dd27f4a6df77f1a16624a1b67d0111`（与官方 digest 一致）· FIT magic `d00dfeed` ✅

### H. prepare 阶段顺带修复：`--rollback` 与 `--flash` 写入路径对齐

原 `--rollback` 用「先整分区 erase → `mtd write`」，与 `--flash` 不一致且**无回读比对**（失败会被当成成功）。
已统一为：**pad 到 erasesize 整数倍 → 上传后 sha256 校验 → `mtd write` 逐块擦写（失败才整分区擦除重试一次）→ 整块回读 sha256 与备份比对，不符则明确报错**。

## 🔬 第六轮实证：官方 1112 固件 layout 确认 + A/B 顺序定案（2026-11-16 14:30，只读）

> 本轮全程**只读**，未对任何 MTD/UBI 分区写入。资产：`/tmp/xr1710g-analysis/`。

### A. 关键更正：官方 1112 固件的 UBI 分区 label 也是 `ubi`（推翻上一轮"命名不一致"担忧）

上一轮把 `off11.dtb`（label=`system`）误当作"官方 11-11 配套固件的内核 DTB"，据此推断"1115 固件（label=`ubi`）与官方 chainloader 布局不匹配"。
**该推断有误**：`off11.dtb` 实际是**官方 chainloader 镜像内嵌的控制 DTB**（`ctrl.dtb`，从 slot.bin 偏移 920252 提取），不是固件内核 DTB。

本轮下载并解析官方 20261112 release 的真实固件 itb：

| 固件 | 文件 | sha256 | 内核 DTB 中 partition@700000 label |
|---|---|---|---|
| 官方 20261112（`20261111-a6d84923`） | `fw1112.itb` 96977206B | `05b0a65299b6603e…39fa80e` | **`ubi`** ✅ |
| 官方 20261115（`5e152df9`） | 已缓存 85561654B | — | **`ubi`** ✅ |
| 本机现役 1016（fit 卷内 fdt-1） | `f1016.dtb` | — | **`ubi`** ✅ |

三份固件的 `partition@700000` **offset/size 完全一致**（0x700000 / 460324864），且卷集完全一致：
`ubootenv` + `ubootenv2`（均 `u-boot,env-redundant-bool`）+ `fit` + `factory`（`mac-base` @0x5000 WAN / @0x6000 LAN），
`fm_autoconvert=1` 三者都有。

**⇒ 结论：官方 11-11 chainloader 与 1115/1112/1016 固件的 UBI 布局完全兼容，无任何命名或卷集不匹配风险。此前的"待验证兼容点"由"高危"降级为"已闭环"。**

### B. 1112 vs 1115 内核 DTB 全量差异（71 项值差 + 8 项新增，均与 UBI 无关）

- 仅 1115 有：`/reserved-memory/dma-pool`（NPU DMA 池）、`/soc/phy@1fae0000 airoha,pcie-analog-init`
- 71 项差异全部是 `phandle` 数值顺延（LED/eth/mmc/nand/npu/pcie）与 `npu memory-region-names`（`binary`→`firmware`、多 `dma`）
- UBI / partition / volume / nvmem 相关属性 **0 处差异**

⇒ 从 U-Boot 与引导视角，**1115 与 1112 的内核 DTB 等价**，选 1115 无 layout 风险。

### C. 官方 20261112 release note 明确绑定关系（原文）

> 2.1710开放ssh刷写引导功能，后期引导uboot也可以OTA。
> 3.修复1710 的lan cpu 的mac地址相同问题，后续不再需要手改
> （**需刷入** `chainloader/releases/tag/2026-11-11-a9a12de55890` 实现）

⇒ 官方把 **1112 固件 + 11-11 chainloader** 作为一套发布。1115 是 11-15 的后续固件（release note 只提"后端大改动，不得保留配置"），**未对 chainloader 提出新要求**；chainloader 仓库 11-11 之后无新提交（`git log` 已确认，最新仍为 `2026-11-11-a9a12de55890`）。⇒ 1115 + 11-11 chainloader 组合合法。

### D. 官方 `xr1710g.env`（内置默认 env，全文）

```
loadaddr=0x81800000
bootconf=config-1
bootargs=console=ttyS0,115200 earlycon ubi.block=0,fit root=/dev/fit0 rootwait rdinit=/sbin/init
boot_ubi=ubi part system && run boot_production
boot_production=run ubi_read_production && bootm ${loadaddr}#${bootconf}
bootcmd=run boot_ubi || http_recovery
ubi_read_production=ubi read ${loadaddr} fit
recovery_addr=0x81800000
recovery_mtd=fit
recovery_ubi_part=system
recovery_dev_uboot=spi-nand0
uboot_ofs=0x600000
recovery_size_uboot=0x100000
```

关键点：
- `bootconf=config-1` → 需 fit 卷内 FIT 有 `/configurations/config-1`。**本机 fit 卷已实证存在** ✅
- `ubi_read_production=ubi read ${loadaddr} fit` → 读的是 **UBI 卷名 `fit`**（不是分区名）→ 与 partition label 无关 ✅
- `bootargs` 与本机 `/proc/cmdline` 逐字节一致（仅内核自动追加 `ubi.fm_autoconvert=1`）✅
- `ubi part system` 在二级 U-Boot 内用**自己内嵌 DTB**（label=`system`）解析 → 成立 ✅

### E. 🔥 决定 A/B 顺序的关键差异：**fastmap**

| | 旧 YYH2913 chainloader（mtd3 现役） | 官方 11-11 chainloader |
|---|---|---|
| `ubi_attach_fastmap` 等符号 | **strings 命中 0** | 全有（`ubi_attach_fastmap` / `ubi_update_fastmap` / `ubi_write_fastmap` / `fastmap-wl.c`） |
| `CONFIG_MTD_UBI_FASTMAP` | 无 | `=y` + `AUTOCONVERT=1` |
| 引导时 UBI attach | 全盘扫 ≈3512 PEB | 读 fastmap（秒级） |

**本机当前 UBI 状态（只读实证）**：`dmesg` 显示 `ubi0: attached mtd4`，`internal volumes: 1`，**无 fastmap**；五卷 `fit`/`ubootenv`/`ubootenv2`/`factory`/`rootfs_data`，0 坏块，`available PEBs: 0`（已满）。

**⇒ 由此得出顺序的硬约束**：
- 刷完 1115/1112 固件后，**内核会因 `ubi.fm_autoconvert=1` 把 fastmap 写进 UBI**（内核侧 `CONFIG_MTD_UBI_FASTMAP_AUTOCONVERT` 生效）。
- 若此时二级 U-Boot 还是**旧 YYH2913（无 fastmap 支持）**，它 attach UBI 时会走全盘扫描路径，遇到已被内核写下的 fastmap 卷有可能行为不一致（旧 U-Boot 忽略 fastmap，通常安全，但官方显式为 fastmap 做了适配）。
- 反向：**先刷官方 chainloader（带 fastmap 支持）**，再刷固件 —— 官方 U-Boot 能正确处理 fastmap 卷，且官方 rfb.c 有 `xr1710g_sync_factory_part()` 主动同步 factory。

### F. A/B 顺序的最终定案

**推荐顺序：B（刷官方 11-11 chainloader）→ A（刷 1115 固件 wipe-config）**，理由按权重排序：

1. **fastmap 归因顺序**（新增，最硬）：fastmap 由固件内核写入、由 U-Boot 读取。先固件后 U-Boot = 先写入再换读取器；先 U-Boot 后固件 = 先装好读取器再写。**后者在原理上更稳**。
2. **B 是唯一不可 SSH 挽救的环节**：mtd3 被覆盖后若新 chainloader 不工作，只能靠 TTL 或 mtd3 备份写回。先做 B = 把最大风险提前暴露在还有完整准备的时间窗内；B 成功后立即可验证（版本串 / MAC / 恢复页 IP），失败则可立刻 `--rollback` 写回旧 mtd3（备份已双份，见下）。
3. **A 的失败可 SSH 自愈**：sysupgrade 只写 UBI `fit` 卷，不碰 mtd3，旧 chainloader + 旧固件仍可启动，SSH 可用。
4. **A→B 的额外成本**：1115 是"后端大改动、不得保留配置"，会重装约 49 个第三方包、恢复约 50 项配置（备份在 `~/router-upgrade-logs/pre-wipe-config/20261116-133420/`）。若在 B 之后做 A，A 失败时**新 U-Boot 仍在位**，SSH 可达性不受影响；若在 A 之后做 B，B 失败时设备已被换过固件，回退路径多一层。

**若以"任何一步失败都不至于变砖"为第一优先**：仍推荐 B→A，因为 B 的回滚手段（mtd3 备份写回 + TTL）比 A 的失败后果（旧固件继续跑）更完备，且 B 前已完成双份备份。

### G. 本轮只读准备完成清单

| 项 | 状态 |
|---|---|
| 官方 1112 固件下载 + sha256 + 内核 DTB 解析 | ✅ `05b0a65299b6603eefacf5f14c07de415bbaebfa184bdc4494b598f9439fa80e` |
| 1112 / 1115 / 1016 三方内核 DTB 逐属性比对 | ✅ UBI 相关 0 差异 |
| 官方 1112 release note 绑定关系确认 | ✅ 明确指向 11-11 chainloader |
| 官方 `xr1710g.env` 全文取回 + 与设备现状交叉核对 | ✅ bootconf / bootargs / fit 卷名 / uboot_ofs 全部对齐 |
| 官方 `xr1710g_rfb.c` 的 `xr1710g_select_ubi()` 语义复核 | ✅ 二级用自己的 DTB 解析 `system` |
| fastmap 支持差异 strings 实测 | ✅ 旧 0 命中 / 官方全有 |
| 设备 UBI fastmap 现状、坏块、PEB 计数 | ✅ 无 fastmap / 0 坏块 / available PEBs=0 |
| 设备 `/proc/cmdline` vs 官方 bootargs 交叉核对 | ✅ 逐字节一致 |
| mtd3 备份双份异地副本 | ✅ `~/router-upgrade-logs/uboot-backups/MIRROR-20261116/` + `/tmp/xr1710g-mirror-20261116/`，三份 sha256 一致 `a65bba65…` |
| fit 卷 48.5MB 备份双份异地副本 | ✅ `~/router-upgrade-logs/fit-backup/MIRROR-20261116/`，sha256 `b9a550eb…` 一致 |

### H. 当时的未闭环项（2026-11-16 14:30 历史快照；已于 2026-11-17 全部完成或撤销，见文首「当前状态」）

- ~~❌ TTL 救砖预案未落地~~ → **2026-11-17 撤销**：U-Boot 已刷成功，用户明确不需拆机。TTL 降为最后兜底，非前置条件（工具与命令单保留在 `ttl_rescue.sh`）。
- ❌ **恢复页 IP 变更未实地演练**：刷入 11-11 后恢复页由 `192.168.255.1` → `192.168.0.1`（官方 HTTP Recovery）。刷前必须重学入口与 IP，否则"兜底在位但连不上"。
- ❌ **MAC 基线比对未执行**：`mac-baseline.txt` 已抓，但刷后需逐接口（`br-lan`/`cpu`/`lan2`/`lan3`/`lan4`）核对。已知问题：现役 `br-lan/cpu/lan2/lan3/lan4` MAC **全为 `00:58:28:d7:63:60`**（重复），官方 11-11 的 `give the XR1710G CPU port its own MAC offset` 正是修这个；factory 卷 WAN=`00:58:28:d7:63:5f` / LAN=`00:58:28:d7:63:60`（与基线一致，可还原）。
- ❌ **`--probe-recovery` 未演练**：需在真实故障态下验证脚本能扫到 `192.168.0.1`。

---

## 🔧 第七轮：三项链路闭环（2026-11-16 15:00，全部只读 + 离线演练）

> 本轮把原先挂着的三项「进入真实写入前必须处理」全部闭环，产出 2 个新脚本 + 1 份机制实证。

### A. 官方 TTL 文档全文已获取（`docs/flashing-xr1710g.md`，22111 B）

此前只读了 `docs/ssh-flash-chainloader.md`。本轮取到 TTL 教程全文，纠正/新增以下**此前完全缺失**的关键事实：

| 事实 | 内容 | 对本机的意义 |
|---|---|---|
| **原厂 env 布局** | `uenv` 2 MiB = `0x0000` 处 0x4000 字节 U-Boot env 块（**小端** u32 CRC32 + NUL 分隔）+ `0x4000-0x1FFFF` 全 0xFF + `0x20000` 后全 0x00 | 与我方对 mtd1 的实测**完全吻合**（非 0xFF 区间 = `[(0,16383),(131072,2097151)]`）→ 交叉验证成立，mtd1 备份可直接用于恢复 |
| **原厂 env 关键变量** | `bootcmd=flash imgread 2048;bootm`、`loadaddr=0x81800000`、`bootdelay=4`、`fdt_high=0xac000000`、`ubi.mtd=system`、`serverip=192.168.0.205`、`ipaddr=192.168.0.1` | 本机 mtd1 的 `bootcmd` 是 `flash read 0x600000 0x100000 $loadaddr; bootm` → 说明**已被改过**（原厂是 imgread 2048），这正是官方 FAQ 描述的"TTL 教程写入的配方" |
| **原厂 env 恢复法** | `ECNT>` 下 `flash erase 0x200000 0x200000` + `flash write`（2 MiB 写不进就分 4×0x80000）；或二级下 `mtd erase uenv` + `mtd write uenv 0x90000000 0 0x200000` | 两条路径都有了 |
| **chainloader 提示符的 `mtd` 写能力** | 二级 U-Boot **没有** `flash` 命令（我方 `strings` 实测 `"flash write"` 命中 **0**），但**有** `mtd` 命令（官方 FAQ §8.1 就在用 `mtd write uenv`） | 二级下能写 `uenv` 但不能写 `chainloader` 自身（无 flash）→ **回滚 mtd3 必须走原厂 `ECNT>` 或 SSH** |
| **TFTP 客户端** | 二级 U-Boot 有 `tftpboot`（`net/lwip/tftp.c` 符号在），但 `tftpd` 客户端只有 `tftpboot`、服务端未编入（`TFTP server not enabled` 字样） | 官方 TTL 教程的 TFTP 是**原厂 `ECNT>`** 的能力，二级也能用 tftpboot |
| **恢复页网口要求** | 必须插 **10GbE 口（fport 4）**，走 GDM4/XSI；1G/2.5G 口是 fport 1，走交换机常规路径 —— 两边都试 | 官方 FAQ 明确，是"进不去恢复页"的常见原因 |
| **DHCP 兜底** | 恢复页固定 `192.168.0.1/24`，DHCP 池 `192.168.0.2`–`192.168.0.50`；拿不到 IP 就改静态 `192.168.0.10/24` | 静态更可靠 |
| **缩短一级读取长度** | 原厂 `bootcmd` 若为 `flash read 0x602100 0x4000000 $loadaddr; bootm`，可把长度 `0x4000000`→`0x100000`（**偏移不动**），显著缩短启动时间 | 可选优化，本机 bootcmd 已是 0x100000，无需改 |

### B. 恢复模式触发机制（源码级，此前完全未知）

`xr1710g_rfb.c` 的 `board_late_init()` 揭示**两个独立触发条件**：

1. **`recovery_trigger=1` 一次性标志**（`xr1710g_uenv_consume_recovery_trigger()`）
   - 存在**共享**的 `uenv`(mtd1) 里，值必须精确是 `recovery_trigger=1`（`len == sizeof(name)` 严格比较）。
   - 用**裸读-改-写**移除该条目，**绝不用 `env_save()`**（源码注释明写：否则会替换原厂 env 让原厂引导失效）。
   - 写回后重启即恢复正常引导 → **一次性**。
   - ⚠️ 本机 mtd1 实测**不含**该条目（`strings /dev/mtd1` 只有 `bootcmd=` 与 `one=`）→ 官方 chainloader 启动时不会因它进恢复模式。
2. **reset 按钮按住**（`xr1710g_recovery_button_pressed()`，读 `recovery-gpios`）
   - 串口打印 `Recovery button detected, starting web recovery...`

判定逻辑：`if (uenv_triggered) → 消费标志进恢复`；`else if (!recovery_button_pressed()) → return 0`（正常引导）；`else → 进恢复`。

**恢复页 IP 源码确认**（`httpd_rec.c`）：
```
RECOVERY_STATIC_IPADDR      "192.168.0.1"   ← 官方 11-11 固定 IP
RECOVERY_DHCP_CLIENT_IPADDR "192.168.0.2"
RECOVERY_DHCP_POOL_END_IPADDR "192.168.0.50"
RECOVERY_DHCP_BROADCAST_IPADDR "192.168.0.255"
```
镜像内 `strings` 实测确认这 4 个 IP 全部硬编码在 binary 中（`192.168.0.1` / `.0.2` / `.0.50` / `.0.255`）。HTTP Recovery 页在 DTB 里也内嵌了 `192.168.0.1` 的文案。

**上传目标与写入路径**（`httpd_rec.c`）：
| 目标 | env 名 | 默认值 | 偏移 |
|---|---|---|---|
| `firmware` | `recovery_mtd` | `fit`（**UBI 卷名**） | `recovery_ofs` |
| `uboot` | `recovery_mtd_uboot` | `uboot`（**MTD 分区名**） | `uboot_ofs` = 0x600000 |

官方 `xr1710g.env` 里 `recovery_mtd=fit`、`recovery_ubi_part=system`、`uboot_ofs=0x600000`、`recovery_size_uboot=0x100000` → 选 `uboot` 目标上传即写 mtd3 的 0x600000/1MiB，**与 SSH `mtd write ... chainloader` 是同一位置**。

### C. 三项闭环的产出

| 项 | 产出 | 验证状态 |
|---|---|---|
| ① TTL 救砖预案 | **新脚本 `ttl_rescue.sh`**：`--check`（工具链体检）/`--stage`（摆 TFTP 根目录）/`--tftp`（起服务）/`--print-serial`（打印 6 条救砖路径 A–F） | ✅ 已跑 `--check`，7 项检查全过（除缺 USB-TTL 硬件与 picocom/minicom） |
| ② 恢复页入口重学 | 源码级确认 IP/网口/触发机制；**新脚本 `post_flash_verify.sh`** 做刷后 5 分钟核对 | ✅ 已在**未刷的真机**上实跑，脚本正确识别出"未刷"状态（MAC 重复、boot_ubi→ubi） |
| ③ `--probe-recovery` 演练 | 增强：去重、候选覆盖 `RECOVERY_PROBE_IPS`、可达时给救援指引、不可达时给 4 条原因排查 | ✅ **正向/负向/混合三分支全部实跑验证**（本地模拟恢复页 HTTP 200 → 判可达；真机两个真 IP HTTP 000 → 判不可达） |

### D. `post_flash_verify.sh` 的 5 项判据（刷后逐项打勾）

1. **U-Boot 版本串** → 串口 banner 应为 `U-Boot XR1710G-2026-11-11-ga9a12de55890`
2. **MAC 重复是否修复** → 刷前实测 `br-lan/cpu/lan2/lan3/lan4` 全为 `00:58:28:d7:63:60`（重复），`wan=00:58:28:d7:63:5f`；刷后应各不相同（这正是 11-11 的 `give the XR1710G CPU port its own MAC offset`）
3. **恢复页 IP** → `192.168.0.1`（新）vs `192.168.255.1`（旧）
4. **UBI fastmap** → 应开始出现 fastmap 字样（官方 11-11 独有）
5. **引导配方归一化** → `boot_ubi` 应从 `ubi part ubi` 变为 `ubi part system`（官方 chainloader 内嵌 DTB 视图），`bootcmd` 不含 `flash `

### E. 仍需人工/硬件的残余（诚实列出）

- ❌ **USB-TTL 硬件不在手边**：本机 `/dev` 下无任何 `tty.usb*` 串口节点，`system_profiler` 也未检出 CH34/FTDI/CP210 芯片。TTL 救砖路径**已备好命令单与工具，但未做实机演练**。
- ❌ **picocom/minicom 未安装**：本机只有 macOS 自带 `cu` 与 `screen`（功能足够：115200 8N1 双向交互）。可选 `brew install picocom` 提升手感。
- ❌ **未做断电演练**：真实断电/拔线场景无法在只读约束下验证。
- ⚠️ `tftpd` 需 root 绑定 69 端口 → `--tftp` 会触发 sudo 密码提示。

---

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
- ✅ **已闭环（原「待验证兼容点」，2026-11-16 第五轮实证）**：本机 mtd4 名为 `ubi`、`recovery_ubi_part=ubi`，新仓库板级代码只认 `system` —— **在引导链上无影响**。理由：二级 chainloader 用**自己内嵌的官方 DTB** 解析 MTD（标签 `system` @0x700000/0x1b700000，与本机 mtd4 偏移大小完全一致），`xr1710g_select_ubi()` 比较的正是二级自己 DTB 里的名字，故 `ubi part system` 在二级内成立。恢复模式刷 firmware 只按 **UBI 卷名 `fit`** 写，与分区 label 无关。详见上方「第五轮实证」章节。
- 11-11 release 只挂 1 个 asset（xr1710g 937538 B），发布说明却列了 2 个文件并给出 xg2010g 的 SHA256 —— 产物与说明不符，XG2010G 镜像缺失。
- 两条并行线：上游 `YYH2913/http-uboot` 11-02 仍在更新（分区备份下载、RTL8261 延迟初始化），恢复页仍 `192.168.255.1`。评估「新版本 U-Boot」时别只看 naoki66 新仓库。

**结论（2026-11-16 第六轮修订，取代 2026-11-12 旧结论）**：不再「一概不单独刷」，改为**按路径量化 + 分步执行**（数值来自多维度离线实证，见下节）：

| 路径 | 成功率 | 说明 |
|---|---|---|
| B 只刷 U-Boot（不换固件） | **88%** ↑ | **2026-11-16 第六轮实证上修**。引导链逐环实证吻合：官方 env 走 `ubi read ${loadaddr} fit` + `bootm ${loadaddr}#config-1`（**按 UBI 卷名，不靠 `flash` 命令、不靠分区 label**），本机 fit 卷已实证含 `/configurations/config-1`；且 1112/1115/1016 三方内核 DTB 的 UBI 属性 0 差异 → **layout 零风险**。原"无 flash 命令可能停在 Unknown command"是**误判，已撤销** |
| A 只刷固件（不碰 U-Boot） | **70%** ↑ | 链路最短，失败可 SSH 自愈（只写 UBI `fit` 卷）。原 55% 低估 —— 因 layout 风险已消除。**但 1115 明令配置不兼容，需重装约 49 包 + 恢复约 50 项配置** |
| C U-Boot + 连带刷固件 | **72%** ↑ | 变量最多，收益也最小（MAC 问题由 U-Boot 侧 `fixup_fdt_macs` 解决，不需要为它刷固件）。仅当确实需要 1115 的 NPU/桥接改进时才做 |

**推荐执行顺序（2026-11-16 第六轮修订，取代下方旧三段式）**：
1. **先刷 U-Boot（B 路径）** → 立即验证：版本串应变为 `U-Boot XR1710G-2026-11-11-ga9a12de55890`、CPU 口 MAC 应不再与 lan2/3/4 重复、恢复页应为 `192.168.0.1`。失败则 `--rollback` 写回 mtd3 备份（已双份异地）。
2. **再刷 1115 固件（A 路径，如需 NPU/桥接改进）** → 只写 UBI `fit` 卷，失败 SSH 可达、旧 chainloader 仍可启动。
3. env 冗余对**已于 2026-11-16 修复完成**，无需再做。

**为何不先刷固件（fastmap 硬约束）**：1115/1112/1016 内核 DTB 均带 `ubi.fm_autoconvert=1`，固件内核会向 UBI **写入 fastmap**；而旧 YYH2913 chainloader 的 `ubi_attach_fastmap` 符号 **strings 命中 0**（无 fastmap 支持），官方 11-11 才有全套（`CONFIG_MTD_UBI_FASTMAP=y` + `AUTOCONVERT=1`）。⇒ **先装 fastmap 读取器（B），再让内核写 fastmap（A）**，比反过来更稳。

**刷前必备（2026-11-17 已全部完成）**：备份 mtd3 + mtd1/uenv ✅、确认新恢复页 `192.168.0.1` ✅、MAC 基线快照 ✅。~~TTL 串口就位~~ **已撤销**（U-Boot 刷成功，用户明确不拆机；且不要在 `ECNT>` 下 `saveenv`——会覆写原厂 env 毁掉启动配方）。

## 📌 当前固件状态（2026-11-17 活体复核，会过期）

- **已完成升级**：本机现实测 `DISTRIB_RELEASE='20261115-5e152df9'`（`DISTRIB_REVISION='2026-11-15-32bec3df41-5e152df97c'`），即 1016 → 1115 全清刷（`--force --allow-recent-crash --ack-config-reset`，用户显式授权自担风险）已执行完毕。下面这段历史判断**已过期，仅留档**：1115 为 `OTA: wipe-config` 版本、72h 沉淀闸到 11-18 14:51、当时结论「仍不刷机」。
- **U-Boot 也已升级**：chainloader 由 YYH2913 旧版换为 naoki66 主线，走 **HTTP Recovery（物理按 reset 进恢复页 192.168.0.1，用户亲自上传）**，非活体 `mtd write`。旧 chainloader 整块备份留档于 `~/router-upgrade-logs/uboot-backups/MIRROR-20261116/mtd-chainloader.bin`。
- **⚠️ 分区可写性已变化（关键，影响 U-Boot 升级路径选择）**：旧固件 1016 上 chainloader 分区只读，活体 `mtd write` 报 `Can't open device for writing`；**升级到 1115 后实测 `mtd3 flags=0x400`（`MTD_WRITEABLE` 已置位），非破坏性 `O_WRONLY` 打开成功** → 当前固件下活体 `mtd write` 路径可用。对照：`mtd0`/`mtd5` 为 `0x0`（只读）。**可写性随固件版本变化，每次写前必须实测**，已做成 `assert_mtd_writable` 预检（见下方 2026-11-17 修复）。
- 刷后实测：OpenClash 内核 `v1.19.34`、Tailscale 重启服务即自动恢复在线（`tailscaled.state` 在 `/etc/tailscale`，无需重新登录）、`geo_auto_update` 四项已置 1。
- **仍未解决**：订阅 `bingling.yaml` 已 15 天未刷新。用**修好的 nft 豁免**做真·直连判别后定性为**路径级拒绝**（详见下方 2026-11-17 修复第 6 项），**不是**订阅过期、**不是**家宽 IP 被封、**不是**本地 OpenClash 配置问题；需机场面板侧处理。

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

## 🔧 2026-11-17 实战后修复（6 项，全部活体/单元实证）

本轮修复全部来自 11-16 真实升级过程中踩到的坑，**不是理论推断**。改前副本留档于 `~/router-upgrade-logs/skill-prefix-20261117-071126/`（该目录非 git 仓库，故先存副本再改）。

**① P0：`check_openclash.sh` nft 豁免链名硬编码失效 + 失败被吞掉还谎报成功**

原第 223 行写死 `nft insert rule inet fw4 openclash_output ... 2>/dev/null`，紧接着**无条件**打印「已临时豁免」。活体实测该链在 1115 + 新版 OpenClash 上**不存在**（`nft list chain inet fw4 openclash_output` → 不存在），真正承载 TCP redirect 的是 **`inet fw4 openclash`**。于是插入静默失败、豁免从未生效，`/dev/tcp` 与 `curl` 测的仍是**本地 clash / 代理出口**，却输出「✅ 真实可达」或「❌ 入口 IP 已被封锁」——**两种结论都可能是假的**。清理规则同样打在不存在的链上空转。

修法：新增 `oc_find_redirect_chain`（扫 ruleset 定位含 `ip protocol tcp` + `redirect to :<port>` 的 openclash 链，排除 DNS 劫持的 `:53`）、`oc_exempt`（检查插入 rc + **回读自证**拿到 handle）、`oc_unexempt`（按 handle 删除并报告成败）。8d 改为**只有豁免自证生效才给可达性判定**，否则明确打印「⛔ 豁免未生效 → 本节跳过，不给可达性结论」。文件头第 5 条教学注释与本文第 119 行同步更正。

实证：动态定位活体返回 `inet fw4 openclash`；把**写进文件的函数原样抽出**在路由器跑闭环 → 插入成功、真·直连 443 **通**、HTTP **200**、清理成功、**残留 0**；完整跑 `check_openclash.sh` 后 8d 正确豁免节点入口 `<入口IP>:<端口>`（真实值不入库）并判「真实可达」，残留复核 0。

**② P0：`uboot_upgrade.sh` 缺写权限预检（并更正一处误判）**

原实现直接以 `mtd write` 为主路径，注释断言「官方同款可行」，**从不读 `/sys/class/mtd/mtdX/flags`**。在只读分区上会依次空烧「label 写 → 整分区 erase → mtdN 写 → dd」四条必败路径才 die，且注释把历史根因归到「末块对齐」（那是另一种故障）。

**⚠️ 诚实更正**：本轮曾据此断言「主路径在本机必然失败」——**该断言对当前固件是错的**。活体实测 `mtd3 flags=0x400`（`MTD_WRITEABLE` 已置位）、非破坏性 `O_WRONLY` 打开成功，即**1115 下 chainloader 可写**；历史上的 `Can't open device for writing` 发生在**旧固件 1016**。可写性随固件版本变化，所以正确修法不是「改主路径为 Recovery」，而是**每次写前实测并分支**。

修法：新增 `assert_mtd_writable`，按位与判 `0x400`；可写 → 放行 `mtd write`；不可写 → 立即给 HTTP Recovery（192.168.0.1，不拆机）指引并 `die`，**不做任何写入尝试**；`--dry-run` 下只报告不中止；flags 读不到/格式异常 → 明示跳过预检而非假通过。`flash_chainloader` 与 `rollback_chainloader` 均在上传/pad 之前调用（fail fast）。3.5 节注释补上「两个不同故障」的更正说明。

实证（含假值对照，三分支全验）：真设备 → `✅ 预检通过 flags=0x400` rc=0；stub `flags=0x0` + DRY=0 → `🛑` + Recovery 指引 + **退出码 1**；stub `flags=0x0` + DRY=1 → 报告但 **rc=0 不中止**。**全程未对 bootloader 做任何写入**。

**③ P1：itb 下载 300s 硬上限（本次真失败点）**

原 `curl -fL --max-time 300 ... 2>/dev/null`：85MB itb 在 300s 内下不完 → **本次实战真超时失败**；单次、无重试、无续传，且错误全被吞掉只剩一句「下载失败」。回退路径 `curl -fL` **连 `--max-time` 都没有**，可能无限挂住。

修法：新增 `fetch_itb`，改用 **stall 检测**（`--speed-limit 10240 --speed-time 60`，低于 10KB/s 持续 60s 才判停滞）替代总时长硬帽，总上限兜底 `ITB_DL_MAXTIME`（默认 1800，可环境变量覆盖）；加 `--retry 3 --retry-delay 5 --retry-all-errors -C -` 断点续传；`--no-progress-meter` + stderr **落 `<dest>.curl.log`**，失败时打印 curl rc 与日志末行。主路径与回退路径统一走它。

实证：坏 URL → `rc=1`、日志落盘、末行 `curl: (56) The requested URL returned error: 404`（判因可见，不再静默）。

**④ P1：回退镜像完全不校验完整性（缺口在"出事时才走"的安全路径上）**

主路径明确「无 digest 就拒绝下载」，但回退镜像下载后**无任何 sha256 校验**就被 `scp` 上去刷机；本地命中的回退镜像同样不校验。

修法：新增 `verify_itb_sha`（0=通过 / 1=不符 / 2=无基准）与 `asset_digest_by_name`（与主路径同一权威来源 GitHub `asset.digest`）。`ensure_rollback_itb` 三个入口全部覆盖：已选定的 ROLLBACK、本地命中、新下载。**无 digest 基准就不下载**无校验镜像；校验不符则弃用/删除并回落 `FALLBACK_ITB`；已在本地的文件若取不到基准则**明示「未经校验，仅 best-effort」**而不是静默当作可信。另修一个边界缺陷：`gh` 出错时会把 JSON 错误体打到 stdout，原样返回会被当成期望 sha → 现**只接受 64 位 hex**，否则返回 `NONE`。

实证：真资产 digest `7a828e88…d0111` 与本地 1115 itb 实际 sha **逐字一致**；`verify_itb_sha` 四例（正确/错误/无基准/带 `sha256:` 前缀）rc 分别 0/1/2/0；假值对照——错误 REPO → `NONE`（不再吐 JSON）、不存在资产名 → `NONE`。

**⑤ P2：`SKILL.md` 含裸 NUL 字节，整份文档被当成二进制**

env 布局代码块里 `data = "key=value<NUL>"` 混进了**真实 NUL 字节**，导致 `file` 报 `data`、`grep` 只回 `Binary file matches`——本轮**两度让文档内容搜不出来**。根目录与打包目录 `skill/router-immortalwrt-upgrade/SKILL.md` **两份都有**。

修法：裸 NUL 替换为可见转义文本 `\0`（语义不变）。实证：两份均 `file` → `Unicode text, UTF-8`，`grep -c 订阅` → 15（搜索恢复正常），`cmp` 两份**一致**；全仓扫描确认其余文件无 NUL。

**⑥ P2：新增订阅拉取诊断节（2d），并撤回一个错误结论**

原脚本只测节点入口可达性，对「订阅长期不刷新」零覆盖。新增 2d：订阅文件**龄期**（≥7 天告警）+ **豁免自证后**的真·直连四路对照（根路径 / 随机不存在路径 / 真实订阅地址 / 末位改坏 token），据此分类而**不是**一律断言订阅失效。全程**只打印域名与指标，绝不打印订阅 URL / token / 响应正文**。

**⚠️ 撤回**：本轮先前基于坏豁免得出的「订阅 403 → 订阅失效 / 家宽 IP 被机场封 / 443 不通」**结论错误，现公开撤回**。修好豁免后的可信实测：

| 探测（真·直连，豁免自证生效） | 结果 |
|---|---|
| 订阅服务器 TCP 443 | **通** |
| 根路径 `/` | **HTTP 200** |
| 随机不存在路径 | HTTP 404 |
| 真实订阅地址 | HTTP 403（6614B HTML，title `Forbidden`） |
| 末位改坏 token | HTTP 403，**响应体与真实订阅字节完全相同** |
| 6 种客户端/浏览器 UA、HTTP1.1/2、Referer、Accept | **一律 403** |
| 随机路径 + `?token=abc` / 根路径 + `?token=abc` | 404 / 200（**`token=` 不是触发点**） |

定性：**路径级拒绝，且拒绝发生在校验 token 之前**（真/假 token 响应完全相同）。根路径 200 证明**家宽 IP 未被封**；随机路径 404 证明**路由存在、URL 没写错**。故**不能断言订阅过期/失效**——用户「订阅应该还是有效的」的判断与证据一致。这不是本地 OpenClash 配置能修的。处置指向机场侧：面板**重新生成/复制订阅链接**（旧路径可能已作废）→ 找**备用/海外订阅域名** → **手机关 WiFi 用蜂窝**做跨网对照 → 仍 403 则联系机场（响应头有 `cf-ray: …-HKG`，疑似边缘 WAF 规则或订阅下发被关闭）。

**验证汇总**：`bash -n` 三脚本全通过；`check_openclash.sh` 完整活体跑通（2d/8d 均正确豁免、判定、清理，nft 残留 0）；预检与下载/校验函数均做**假值对照**单元验证；`uboot_upgrade.sh --flash --dry-run` 确认 ack 闸仍在最前（未带 `--ack-uboot-flash` 时 rc=1 拒刷）。**本轮未刷机、未写 bootloader、未改路由器任何配置**（nft 豁免为临时插入且已自证清零）。

