# XR1710G TTL 救砖 · 采购清单与接线指南

> 依据：官方 `docs/flashing-xr1710g.md`（naoki66/Gemtek-brightspeed-chainloader）
> 生成时间：2026-11-16 · 本 skill 配套资产

---

## 一、结论先说：买哪种 USB-TTL 模块

| 芯片 | 官方是否点名 | macOS 支持 | 价格 | 结论 |
|---|---|---|---|---|
| **CH343 / CH343P** | ✅ 官方原文点名（"USB-TTL module (3.3 V, e.g. CH343)"） | 需装 WCH 官方 CH34x 驱动（DriverKit 扩展，**无需降级安全策略**） | ¥8–20 | **首选**，与官方教程零差异 |
| **CH340G** | ✅ 同属 CH34x 家族 | 同一份 WCH 驱动即可 | ¥5–12 | **性价比最优**，115200 波特率完全够用 |
| CP2102N | ❌ | 需装 Silicon Labs 驱动 | ¥10–25 | 备选 |
| FT232RL | ❌ | macOS 现代版本**不再内置** FTDI 驱动，需第三方安装 | ¥15–30 | 不推荐 |

**唯一硬性要求：3.3V 电平。** 5V 模块可能烧毁 SoC 的 UART 引脚。

> 本机实测（2026-11-16）：`/System/Library/Extensions` 与 `/Library/Extensions` 中**无任何 WCH/CH34 驱动**，
> `kextstat` 亦无 `ch34` → macOS **不内置** WCH 驱动，需手动装一次（免费、官方签名、免 SIP 降级）。

---

## 二、购物清单（按优先级）

### 必买

| # | 物品 | 规格要求 | 搜索关键词 | 参考价 |
|---|---|---|---|---|
| 1 | USB 转 TTL 串口模块 | **3.3V**（带 3.3/5V 跳线）、CH343 或 CH340G 芯片、USB-A 口 | `CH343 USB转TTL 3.3V 串口模块` / `CH340G USB TTL 3.3V` | ¥6–20 |
| 2 | 杜邦线 | 公对公 **3 根**（黑/红/黄）+ 备用 3 根 | `杜邦线 公对公 20cm` | ¥3–8 |
| 3 | USB 数据线 | **必须是数据线**，很多线只供电 | `USB A-A 数据线 1m` | ¥5–15 |

### 可选但强烈建议

| # | 物品 | 用途 |
|---|---|---|
| 4 | 万用表（带通断档） | 确认主板排针的 GND/TX/RX 顺序 —— **官方文档只标了 GND/RX/TX，没给排针位置图**，只能靠测或丝印 |
| 5 | 强光手电 / 放大镜 | 找主板上的 TTL 排针丝印 |
| 6 | T10 螺丝刀 | 官方明确：拆机需 T10 |
| 7 | 千兆网线 | TFTP 刷写时需接路由器 **10GbE 口**（官方 §3.1） |

### 绝对不要买 / 不要做

- ❌ **5V-only 的 TTL 模块** —— 会毁 SoC 引脚
- ❌ **带 5V 供电输出的模块且把它接到主板 VCC** —— 官方原话：*"VCC 不接，避免供电冲突"*
- ❌ **RS-232 电平转换模块**（DB9 那种）—— 电平不兼容，会烧板
- ❌ **不要用 USB 集线器** —— 直插 Mac 本机口

---

## 三、接线（官方原表，RX/TX 交叉）

| USB-TTL 模块 | 路由器主板 TTL 排针 |
|---|---|
| **GND** | **GND** |
| **RX** | **TX** |
| **TX** | **RX** |
| ~~VCC~~ | ~~不接~~ |

关键点：
1. **VCC 一律不接** —— 官方明确"避免供电冲突"。模块自己有 USB 供电就够了。
2. **模块跳线必须拨到 3.3V** —— 很多模块出厂默认 5V。
3. **RX/TX 必须交叉** —— 同名相连会完全无输出，这是最常见的"接了没反应"原因。

### 排针怎么找

官方文档**没有给排针位置图**，只说"拆机，在主板上找到 TTL 接口（标识 GND / RX / TX）"。实测办法：

1. T10 螺丝拆外壳
2. 找 PCB 上 3 针排针 + 丝印 `GND`/`RX`/`TX`（或 `TXD`/`RXD`/`GND`）
3. 万用表通断档：任意一根与电源地相连的 → 那根是 **GND**
4. 剩下两根，用 USB-TTL 接上后看串口有没有输出 → 有输出的那根是**主板 TX**（对应模块 RX）

> 本机 1016 固件的内核 cmdline 是 `console=ttyS0,115200n8` → **UART 0 就是 TTL 排针**，无需猜。

---

## 四、到货后的 10 分钟验证流程（不写设备）

```bash
# 1. 插上模块
ls /dev/cu.*          # 期望出现 /dev/cu.wchusbserialXXXX 或 /dev/cu.SLAB_USBtoUART

# 2. 打开串口（macOS 自带，无需装 picocom）
cu -l /dev/cu.wchusbserialXXXX -s 115200

# 3. 路由器断电 → 上电，串口应刷出 bootlog
#    看到 ECNT> 或 U-Boot> 说明接线正确 ✅
```

看到提示符后**先不要做任何写入**，直接 `reset` 退出，确认链路通即可。

之后用本 skill 的：

```bash
./ttl_rescue.sh --check      # 工具链体检（含串口节点探测）
./ttl_rescue.sh --stage      # 摆好 TFTP 根目录
./ttl_rescue.sh --print-serial   # 打印 6 条救砖路径 A–F
```

---

## 五、macOS 驱动安装（CH343/CH340G）

1. 到 WCH 官网下载 **CH34x macOS 驱动**（`CH34xUARTDriver` / `CH341SER_MAC`，认准官方 `wch.cn` 域名）
2. 解压 → 运行 `CH34x_Install.pkg`
3. 若提示"系统软件被阻止"→ 系统设置 → 隐私与安全性 → 点"仍要允许" → 认证
4. **重启 Mac**（DriverKit 扩展加载的可靠方式）
5. `ls /dev/cu.*` 确认出现 `wchusbserial`

> Apple Silicon（M 系列）**不需要**进 Recovery 改启动安全策略 —— 当前 WCH 驱动是 DriverKit 系统扩展而非内核扩展。
> 网上那些"必须 Reduced Security / csrutil disable"的教程是给旧版 kext 时代的，**已过时**。

---

## 六、串口终端选择

| 工具 | 状态 | 说明 |
|---|---|---|
| `cu` | ✅ macOS 自带 | `cu -l /dev/cu.xxx -s 115200` |
| `screen` | ✅ macOS 自带 | `screen /dev/cu.xxx 115200`（退出：`Ctrl-A` 然后 `k`） |
| `picocom` | 需 brew install | 握手控制最舒服，救砖时推荐 |
| `minicom` | 需 brew install | 官方文档点名 |
| MobaXterm / SecureCRT | Windows 为主 | 官方文档点名 |

本 skill 的 `ttl_rescue.sh --check` 已确认本机 `cu` / `screen` 可用、`picocom` / `minicom` 缺失（**不影响救砖**）。
