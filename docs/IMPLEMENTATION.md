# Vantage — 实现与设计笔记

> 本文是 Vantage 的中文技术笔记，按功能域组织：采集层的数据来源、口径、
> 权限边界、i18n 机制、各窗口的实现取舍。面向想改代码或了解「为什么这样实现」的读者。
>
> 只想编译运行请看 [README](../README.md)；SDK 差异、构建约束与已知限制见
> [COMPATIBILITY.md](COMPATIBILITY.md)；建仓清单见 [PUBLISHING.md](PUBLISHING.md)。

---

## 项目概览

**Vantage** 是一个 macOS 原生 GUI 进程管理器，用 **C（系统采集）+ Swift / AppKit（界面）** 实现，
功能定位参考 **Activity Monitor**，窗口定位等交互参考 **System Informer**。

- 完全使用 macOS SDK（`sysctl` / `libproc` / `Mach` / `IOKit` / `Security.framework` / `AppKit`），
  不依赖 `powermetrics`、不要求 root、不依赖 Electron / 跨平台 UI。
  性能监控里的 IOReport / AppleSMC 是**运行时动态解析的可选私有接口**，拿不到就优雅降级。
- 交付形态为 **SwiftPM 工程 + 一键打包脚本**，既能在终端 `swift run` 调试，
  也能生成可双击的 `Vantage.app`。
- 性能面板参考 **macmon**（`vladkens/macmon`）的采集分层，但用 C + AppKit 实现为原生 GUI。

---

## App Icon

深蓝（`#0B1B33`）→ 青绿（`#0E6E7A`）对角渐变，细网格上一条居中的青白发光脉冲波形，呼应「进程 / 性能遥测」。1024×1024 主图带 macOS 标准圆角（半径 22.37%）与透明 alpha，四角干净，16px 小尺寸仍可辨认。

```
Assets/
├── Vantage.png              1024×1024 RGBA 主图（透明圆角）
├── Vantage.icns             PNG 内嵌的 ICNS（icp4/5/6、ic07–ic14 共 11 项）
└── Vantage.iconset/         iconutil 用的 10 个尺寸（16…1024，含 @2x）
```

`Packaging/Info.plist` 里 `CFBundleIconFile = Vantage`。`Scripts/build_app.sh` 打包时：

```bash
iconutil -c icns Assets/Vantage.iconset -o Vantage.app/Contents/Resources/Vantage.icns
```

优先用系统 `iconutil`（Xcode CLT 自带）从 iconset 现生成；若不可用则直接拷仓库里预置的 `Vantage.icns`（格式等价，构造时不依赖 macOS）。想换图标，替换 `Assets/Vantage.png` 后跑 `python3 Tools/make_icon.py`（仅依赖 Pillow）即可重建 iconset 与 icns，或直接覆盖 `.iconset`。

---

## 功能

### 进程列表（主视图）
| 能力 | 说明 |
|---|---|
| 树形 / 扁平 | `NSOutlineView` 按 PPID 还原父子层级（launchd 为根），可一键切列表 |
| 列 | 图标+进程名、PID、PPID、**TTY**、用户、%CPU、内存、线程、FD、状态、架构、CPU 时间、启动时间、完整命令 |
| 实时刷新 | 0.5 / 1 / 2 / 5 秒可调；后台队列采集，主线程刷新，保留选中项与展开状态 |
| %CPU | 用 `PROC_PIDTASKINFO` 的累积 CPU 时间做两次采样差分（Activity Monitor 口径：单核 100%） |
| 排序 | **14 列全部可排序**，同一表头三态循环：单击排序 → 再单击反序 → 再单击恢复树形；换一列重新从第一态开始。排序时自动切扁平列表，表头显示自绘升降序三角，二级键为 PID |
| 过滤 | 所有 / 我的 / 系统 / 非僵死 / 仅 GUI 应用；全文搜索名称、PID、用户名、命令行 |
| 名称显示 | 区分 `.app` 目录名、`CFBundleExecutable`、实际 exe basename 与 `argv[0]` 四个可能互不相同的值；helper 在应用名后标注原始短名（`WeChat (crashpad_handler)`），调用名不同时也可标注（`bash (sh)`）；两者并列时改用文字标签消歧（`Visual Studio Code (Electron) 以 Code 调用`）；可选本地化显示名与 3 种格式，搜索/排序/复制/tooltip/检查器标题同步 |
| 提示行 | 详情页里 C 层追加的说明性「提示」行（SIP / task port 等）**默认隐藏**，可在偏好里打开；占位提示不受影响 |
| 国际化 | 简体中文 / English / 跟随系统，运行时切换、无需重启；语义 key 作唯一标识（中文只是 value），切换后菜单、窗口标题、列头、按钮、偏好文字即时刷新 |
| 偏好设置 | `⌘,` 打开：**「通用」「样式」「信号」三个页签** —— 采集上限、详情缓存 TTL、刷新/采样间隔、默认视图、排序与行为开关、**进程名称显示**、**界面（提示行 / 语言）**、已退出进程高亮与 11 项可定制配色、以及 31 个信号的显示配置，全部即时生效 |
| 退出宽限期 | 进程退出后仍以高亮行保留 **N 次刷新**（默认 3，可在样式页配置 0–20）：名称前缀 `✕`、状态列 `已退出·N`、整行背景染色 |
| 窗口定位 | ⌘⌥L 准星选取（SystemInformer 风格）、「窗口列表…」按 owner PID 定位；⌘0 找回主窗口 |
| PID 跳转 | 双击详情表里「对端 PID」等蓝色单元格、或主表 PID/PPID 列 → 选中该进程并打开检查器；**同一 PID 只激活已有窗口，不重复创建**（「监控」页整页不显示链接） |
| FD 跨页跳转 | **「文件」页双击任意行**：SOCKET → 网络、PIPE → Pipe、tty 设备 → TTY、其它 → 监控，自动切页并选中/滚动到该 FD 那一行 |
| 激活窗口 | 检查器「窗口」页双击条目、或全局「窗口列表」**⌘/⌥+单击** → 把该窗口取消最小化并前置（AXUIElement，需「辅助功能」授权） |
| 修饰键单击 | **除「窗口列表」外，所有双击动作都支持 ⌘ / ⌥ + 单击且效果相同**；窗口列表双击仍是定位进程 |
| 进程右键菜单 | 动态构建：检查器 / 窗口定位 / 退出·强制退出·暂停 / **发送信号 ▸** / Finder 显示 / sample 采样 / 复制 PID·命令行·可执行路径 / 配置菜单信号 |
| 信号 | 31 个 Darwin 信号可选，默认显示 12 个；右键与主菜单「进程」都有子菜单；可配置发送前确认与危险信号强制确认 |

### 详情面板（13 个 Tab）
1. **概览** — 应用图标、名称、状态、架构、内存/CPU/线程/缺页/系统调用/flags/**TTY 摘要**/task port/路径
2. **文件** — `PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`，列出 vnode 路径、打开标志
3. **环境** — `KERN_PROCARGS`，按 `KEY / VALUE` 表格展示
4. **镜像** — 有 task port 时走 `TASK_DYLD_INFO` 精确列表；**SIP 下自动回退** `PROC_PIDREGIONINFO` + `proc_regionfilename`
5. **网络** — `PROC_PIDFDSOCKETINFO` 解析 TCP / UDP / UNIX / 其他族，含本地与远端地址、TCP 状态、kind / PCB / 类型，并区分「没有 socket」与「读取失败」
6. **监控** — pipe / kqueue / FD 类型汇总，pipe 行直接标出**对端 PID / 进程名 / FD**
7. **Pipe** — 全系统 pipe 句柄索引，逐条列出本端/对端句柄、对端进程、自环与「对端已关闭」
8. **映射** — `PROC_PIDREGIONINFO` 枚举全部 VM region（地址范围、大小、rwx 保护、映射文件），**不需要 task port**
9. **TTY** — 控制终端 `e_tdev` → `/dev/ttysNNN`、主/次设备号、PGID / TPGID / jobc、前台或后台、FD 0/1/2 是否被重定向、`PROC_TTY_ONLY` 列出同终端所有进程、窗口大小 / termios 波特率与本地模式
10. **窗口** — `CGWindowListCopyWindowInfo` 按 owner PID 过滤，列出该进程的**全部**窗口（含最小化 / 其他 Space / 隐藏）：窗口号、标题、层、位置尺寸、屏幕状态与 Z 序、共享状态 / Alpha；**不需要屏幕录制授权**也能看到除标题外的全部字段；**双击条目可把该具体窗口前置激活**（需「辅助功能」授权）
11. **签名** — `Security.framework` 的 `SecCode` / `SecCodeCopySigningInformation`：Identifier、Team ID、CS flags、Entitlements（递归展开）
12. **Mach** — `proc_bsdinfo` 标志位、`csops(CS_OPS_STATUS)` 的 CS flags、`task_name_for_pid` + `task_info(TASK_AUDIT_TOKEN)` 的审计令牌、SIP 说明
13. **命令** — 完整 argv 与可执行路径，可复制

每个 Tab 都有独立过滤框；双击进程行可打开**独立检查器窗口**（Activity Monitor 风格）。
页签统一压到 2 个字，13 个在 1140pt 检查器 / 880pt 主窗口详情区里能完整显示。

**详情是惰性加载的**：选中进程时只更新「概览 / 命令」（纯快照、零系统调用），
其余各页在**第一次切到该页时**才采集，结果按 `(pid, 页)` 缓存（FD/socket/pipe 2 秒，
环境/镜像/映射/签名 60 秒）。⌘R 或「刷新」按钮会丢弃当前进程缓存强制重采。
详见「详情采集为什么慢」章节。

### 底部统计（Activity Monitor 风格）
自绘面积曲线：CPU 用户态/系统态堆叠、内存占用；另有进程数、线程数、逻辑/物理核、
物理内存/已用/可用/Wired/已压缩、Swap、1/5/15 分钟负载。

### 性能监控窗口（⌘P，参考 macmon）
独立窗口，6 张仪表卡片 + 6 组自动缩放曲线 + 数值条 + 数据源状态说明：

| 区块 | 内容 |
|---|---|
| 卡片 | CPU 功耗（右上角 **CPU 温度** + 均值/峰值）、GPU 功耗（**GPU 温度**）、ANE/DRAM、**整机功率 SMC PSTR**、**CPU 分簇频率**（E-CPU / S-CPU / P-CPU 各自 `xx% @ xxxx MHz`，含 GPU）、**RAM / SWAP 百分比** |
| 曲线 | CPU/GPU/ANE/DRAM 功耗；CPU 总计 + 分簇利用率（启发式 + residency）；CPU/GPU 活跃占比；**分簇实时频率**（E/P/S + GPU）；磁盘读/写；网络下行/上行 |
| 数值条 | 磁盘读 / 写速率、网络上下行速率、**内存已用百分比 + 绝对值**、**Swap 百分比 + 绝对值**、热压等级、**CPU/GPU 温度** |
| 静态信息 | SoC 名称、P/E 核心数、GPU 核心数、DVFS 频率上限（pmgr `voltage-states`）、CPU tier 数、匹配通道数、功耗源、温度源 |
| 控制 | 采样间隔 0.5 / 1 / 2 / 5 秒、暂停刷新；历史保留 120 点 |

与 macmon 顶栏逐项对齐：`E-CPU 13% @ 1863 MHz`、`S-CPU 15% @ 3699 MHz`、
`GPU 4% @ 338 MHz`、`RAM 83% · SWAP 80%`、`CPU 2.65W 32°C`、`GPU 0.12W 33°C`、
`ANE 0.00W`、`Total 6.83W (均值, 峰值)` 都有对应位置。**unavailable 仍显示「—」**，
不会用 0 补齐。

状态栏底部有**「逐通道诊断」**（可滚动）：pmgr 表池每张 `voltage-statesN` 的
编号 / 档数 / 频率范围 / 单位（Hz 还是 kHz）、每个 Energy Model 通道名 / unit /
换算后的 W、每个 P-state 通道的 state 名 / 频率态数 / 命中的表 / 平均 MHz / 活跃占比、
SMC 的 `#KEY` 总数与温度键读数（参与 CPU/GPU 平均的会打 `[CPU]` / `[GPU]` 标记并
优先列出）、IOHID 的全部传感器 product 名与温度。
数值与 macmon 对不上时，先看这段原始列表，不必猜——它直接回答
「哪些通道被算进去了」「频率表是 0 档还是解析错了」「温度来自哪个传感器」。

采样在 **C 层自己的 pthread** 里连续进行（IOReport subscription 必须留在创建它的线程上，
`DispatchQueue` 不保证固定 OS 线程），Swift 侧只按时间戳轮询最新帧并画曲线。
窗口关闭不停止采样，重新打开时历史曲线不断档。

深色模式、窗口尺寸记忆、原生菜单与快捷键（⌘R 刷新、⌘F 搜索、**⌘⇧F 全局搜索**、
⌘I 检查器、**⌘P 性能监控**、**⌘⌥B 设备树**、**⌘⌥E 系统扩展**、
⌥⌘K 退出、⇧⌥⌘K 强制退出等）均已适配。

---

## 搜索：正则模式与全局搜索（⌘⇧F）

### 一套匹配规则，三个入口共用

`SearchMatcher.swift` 把搜索统一成两种模式：

| 模式 | 行为 |
|---|---|
| 字面量（默认） | 大小写 / 变音不敏感的子串匹配，就是原来的行为 |
| 正则（`.*` 开） | `NSRegularExpression`，大小写不敏感 |

- **主表**：按**字段**匹配（`^WeChat$` 能精确命中名称字段，不会先把十几个字段拼成一整行再失配）；覆盖应用名、本地化名、raw 名、argv[0]、`CFBundleExecutable`、BSD 短/长名、命令行、可执行路径、Bundle、PID、用户、TTY、状态、架构。
- **详情页当前页**：按整行匹配，命中已有的 `allRows`，切换模式**不重采数据**。
- **全局搜索窗口**：按结果显示行匹配。
- 三个入口和 `⌘, → 通用 → 搜索` 的开关通过 `.searchModeDidChange` 互相同步；工具栏搜索框旁有 `.*` 按钮，全局搜索窗口也有一个。
- **正则写错时自动回退到字面量**并在状态栏 / 结果栏明确标注错误原因。敲到一半输入 `[` 不会把整个列表清空让人误以为「没有匹配进程」。

### 全局搜索：先拍快照，再对所有进程取样

主表搜索每 1 秒刷新一次，输入关键字时结果会漂移。独立窗口（**⌘⇧F**，或「编辑 / 窗口」菜单）在打开的那一刻复制一份 `ProcessSnapshot` 数组（值类型），之后**采集与匹配都只针对这份固定快照**：进程退出、新进程启动、主表过滤条件变化都不会改变结果集，快照里能搜到已经退出的进程。

取样覆盖快照里每一个 PID：

| 默认采集 | 可选（「包含重量级页」开） |
|---|---|
| 进程字段、打开文件、环境变量、网络连接、文件监控、TTY、Mach 安全、窗口、代码签名 | 已加载镜像、Pipe 对端、内存映射 |

- 复用 `DetailLoadCache`（命中就不重复付系统调用）；失败 / 无数据都记入 `failures`，可勾选「显示失败 / 无数据」查看，不会静默跳过。
- 每页最多 2000 行、整场取样最多 `globalSearchMaxRows` 行（默认 50000），超出即截断并标注，避免 regions 一页上万行淹没结果。
- 采集与详情页**共用串行队列**（C 层 `g_pipe_index` 是全局静态变量、无锁，不能并发），但按**每批 4 个进程**分片提交：详情页的惰性采集最多排在一批之后，不会被几百个进程饿死。
- 进度显示「正在取样 x/N · 快照时间」；「重新取样」按钮随时拍新快照。窗口关闭不销毁会话，再打开沿用上一次结果。
- 双击（或 ⌘/⌥ + 单击）命中行 → 打开 / 激活该 PID 的检查器、切到对应页签并定位到那一行；右键可「在主表中定位」「复制行」；⌘C 复制选中行。

偏好设置 `⌘, → 通用 → 搜索 / 全局搜索` 里的三个选项：正则模式开关、是否包含重量级页、行数上限（1000–500000）。全部即时生效，切换语言后结果行按新语言重新解析再过滤。

---

## 设备树（⌘⌥B）与系统扩展（⌘⌥E）

两个独立窗口，互相可以跳转：设备树里双击「驱动 Bundle」→ 扩展列表按该 id 过滤；扩展列表里双击「Bundle ID」→ 设备树里找使用该驱动的设备。窗口都是单实例，重复打开只激活已有窗口。

### 1. IORegistry 设备树

**数据源**：纯公开 IOKit API，不需要 root、不需要 task port。`IORegistryGetRootEntry` 起，用 `IORegistryEntryGetChildIterator` + 显式栈做 DFS（不用递归，避免 ACPI / USB 深层树爆栈），逐节点取 `IORegistryEntryGetName` / `IOObjectGetClass` / `IORegistryEntryGetPath` / `IORegistryEntryGetRegistryEntryID` / `IORegistryEntryCreateCFProperties`。可切换 7 个 plane（IOService 默认、IODeviceTree、IOPower、IOUSB、IOACPIPlane、IOFireWire、IOAudioCodecEngine）；某个 plane 不存在时状态栏明确提示，不是一片空白。

**driver bundle 怎么拿**（不调用私有 `IOCatalogue`）：

| 优先级 | 来源 |
|---|---|
| 1 | 节点属性 `CFBundleIdentifier`（`kIOBundleIdentifierKey`） |
| 2 | `IOPersonality` 字典里的 `CFBundleIdentifier` |
| 3 | 都没有时至少给 `IOClass` / `IOProviderClass`，Swift 用扩展列表里每个 bundle 的 `IOKitPersonalities` 建立 **IOClass → bundle** 索引反查路径、版本、状态 |

**client PID（尽力而为，不猜）**：xnu 的 `IOService::newUserClient` 会把创建者写进 `kIOUserClientCreatorKey`（`"IOUserClientCreator"`），历史上有多种形态，C 层逐类型解析：

| 属性形态 | 解析方式 |
|---|---|
| `CFString` `"pid 123, WindowServer"` | 抓 `pid` 数字 + 逗号后的进程名 |
| `CFNumber` | 直接当 PID |
| `CFData` | `audit_token_t` 的 `val[0]` 就是 pid |
| `CFArray` / `CFDictionary` | 递归遍历 / 取 `"pid"` 键 |

没有该属性的设备（绝大多数）本来就没有 user client，显示 `—` 并在详情里标注来源类型（string / number / audit）。这是「有办法得到」的部分；IORegistry 不暴露更通用的「谁打开了这个设备」关系。

**界面与交互**：树列 `名称 / 类 / 驱动 Bundle / Client PID / Entry ID / Registry Path`；下栏列出选中节点全部属性（最多 400 条，超出标注截断）+ 解析出的驱动与 client 信息。双击 Client PID → 主表定位并打开检查器；双击驱动 Bundle → 跳扩展列表。搜索复用全局正则 / 字面量模式，**保留匹配节点 + 整条祖先链**，树不会断；还可按「仅看有驱动 bundle / 仅看有 client PID」筛选。⌘C 复制选中行，⌘/⌥ + 单击 ≡ 双击。

### 2. 系统所有 extension bundles

四类：**`.kext`**（传统内核扩展）、**`.dext`**（DriverKit）、**`.systemextension`**（系统扩展）、**`.appex`**（App Extension）。

扫描根目录：`/System/Library/Extensions`、`/Library/Extensions`、`/System/Library/DriverExtensions`、`/Library/DriverExtensions`、`/Library/SystemExtensions`、`/System/Library/SystemExtensions`、`/System/Library/CoreServices`、`Frameworks`、`PrivateFrameworks`、`/System/Applications`；`⌘, → 通用 → 设备树 / 扩展列表` 里可额外开启扫描 `/Applications` 下 App 内嵌的扩展（默认关，目录层级深、明显变慢）。单场上限 20000 个，按路径去重。

每个字段都来自 bundle 自带的 `Contents/Info.plist`：`CFBundleIdentifier`、版本、`CFBundleExecutable`、`NSExtensionPointIdentifier`、`IOKitPersonalities` 里的全部 `IOClass`。

状态来自两个公开 CLI，任一不可用就显示 `—`，**绝不用「查不到」冒充「未加载」**：

| 状态 | 来源 |
|---|---|
| 已加载 | `/usr/bin/kmutil showloaded` |
| 已激活 | `/usr/bin/systemextensionsctl list` |

签名 Team ID 与签名标识（`SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation`）**按需读取** —— 选中某行才校验，不会为几百个 bundle 逐个做签名校验拖慢扫描。

交互：双击路径 → Finder 显示；双击 Bundle ID → 设备树按该 id 过滤；类型过滤 + 正则搜索；⌘C 复制行；⌘/⌥ + 单击 ≡ 双击。

### 两个新偏好

| 项 | 默认 | 说明 |
|---|---|---|
| IORegistry 节点上限 | 30000 | 1000–200000，超出即截断并标注；通过 `cproc_ioreg_set_max_nodes` 下发 C 层 |
| 扫描 /Applications 内的扩展 | 关 | 开则额外枚举 App 内嵌 `.appex` / `.systemextension` |

两项都即时生效，不需要重启 App。

> 一个实现上的取舍：C 层 `ioreg.c` **只输出 ASCII 结构行**（`NODE` / `PROP` / `META`），所有界面文案由 Swift 侧 `L()` 生成。这样新增窗口完全不碰 `cproc_l10n_data` 的「中文是 value」机制，也避开 Swift 直接桥接 `CFMutableDictionary` 在新 SDK 上的编译差异（`as? CFArray` 会报 "always succeeds"）。

---

## 目录结构

```
Vantage/
├── Package.swift                       # SwiftPM，target: CProc (C) + Vantage (Swift)
├── Packaging/                          # .app / .dmg 元数据（不进源码目录）
│   ├── Info.plist                      # CFBundleIdentifier / 图标 / 权限用途说明
│   ├── Vantage.entitlements            # ad-hoc 签名用的 entitlement
│   └── dmg-background.png              # DMG 拖拽引导背景图（已入库，CI 无需 Pillow）
├── Scripts/                            # 构建与打包脚本
│   ├── build_app.sh                    # 编译并组装 .app
│   └── make_dmg.sh                     # UDZO：diskutil image 主路径 + hdiutil 回退 + 拖拽引导
├── Sources/
│   ├── CProc/
│   │   ├── include/CProc.h             # 对外 C 接口（扁平结构 + accessor）
│   │   ├── include/CPerf.h             # 性能监控接口（纯标量快照 + valid 位）
│   │   ├── cproc_config.c              # 运行时可配置 limits（偏好设置下发）
│   │   ├── cproc_internal.h            # C 层内部共享 g_cproc_limits
│   │   ├── proc_collect.c              # 全量进程快照 + 系统指标 + TTY
│   │   ├── proc_detail.c               # 单进程详情 + 无 task port 采集层（region / pipe / csops / tty）
│   │   ├── perf.c                      # 性能采样线程：IOReport / SMC / DVFS / 公开层计数器
│   │   ├── ioreg.c                     # IORegistry 树 / 属性 / driver bundle / client PID（纯 ASCII 输出）
│   │   ├── proc_arch.c                 # Mach-O FAT / thin 头解析 → 架构切片（带缓存）
│   │   ├── cproc_l10n_data.c           # 生成：C 层运行时文本的语义 key + 双语表
│   │   └── cproc_l10n_data.h           # 生成：查表接口（C 层私有头，不放 include/）
│   └── Vantage/
│       ├── main.swift / AppDelegate.swift / AppContext.swift
│       ├── Models.swift / ProcBridge.swift / ProcessStore.swift
│       ├── Preferences.swift / PreferencesWindowController.swift  # ⌘, 偏好设置
│       ├── PerfBridge.swift / PerformanceWindowController.swift  # 性能监控
│       ├── WindowLocator.swift / WindowPicker.swift              # CGWindow 枚举 + 准星选取
│       ├── WindowListWindowController.swift                      # 窗口列表 + AppActivate
│       ├── DetailLoadCache.swift       # 详情按页缓存 + 共享串行队列
│       ├── SearchMatcher.swift                  # 字面量 / 正则统一匹配器（含无效正则回退）
│       ├── GlobalSearchSnapshot.swift          # 固定快照 + 分批对所有 PID 取样
│       ├── GlobalSearchWindowController.swift  # ⌘⇧F 独立全局搜索窗口
│       ├── IORegistryBrowser.swift             # IORegistry 树 / 属性的 C 桥接与建模
│       ├── DeviceBrowserWindowController.swift # ⌘⌥B 设备树（树 + 属性表）
│       ├── ExtensionScanner.swift              # .kext/.dext/.systemextension/.appex 扫描
│       ├── ExtensionsWindowController.swift    # ⌘⌥E 系统扩展列表
│       ├── SigningReader.swift / Formatters.swift / UIHelpers.swift
│       ├── ProcessListViewController.swift      # NSOutlineView 树形列表 + 三态排序
│       ├── DetailViewControllers.swift         # 13 个详情 Tab（含 TTY / 窗口）
│       ├── StatsPanelViewController.swift / SparklineView.swift
│       ├── MainWindowController.swift          # 工具栏 + 嵌套分栏 + 检查器窗口
│       ├── Localization.swift                  # L() / 语言偏好 / C 层文本 / relocalize
│       ├── L10nTable.swift / L10nKeys.swift    # 生成：内嵌双语表 + key 常量
│       ├── AppColors.swift / SignalCatalog.swift / SignalMenuUpdater…
│       ├── ClipboardSupport.swift / ModifierClick.swift / RowTextCopying…
│       └── WindowActivator.swift / WindowListWindowController.swift …
├── Resources/
│   ├── zh-Hans.lproj/Localizable.strings       # "key" = "中文"
│   └── en.lproj/Localizable.strings            # "key" = "English"
├── Tools/
│   ├── l10n_master.py                         # Swift UI 唯一数据源：key → (zh, en)
│   ├── c_en_override.py                       # C 层字段英文译文（141 条手工 + 复用主表）
│   ├── build_l10n.py                          # 生成 .strings / L10nTable / L10nKeys（自动串起 C 生成器）
│   ├── build_c_l10n.py                        # 扫描 C 源码 → cproc_l10n_data.c/h
│   ├── swift_scan.py                          # Swift 字符串字面量状态机扫描器（迁移用）
│   ├── make_icon.py                           # App Icon 资源重建
│   └── make_dmg_bg.py                         # DMG 拖拽引导背景图生成（仅本地需要 Pillow）
├── Assets/                                    # Vantage.png / iconset / .icns
├── docs/                                      # 实现笔记 / 兼容性 / 发布清单 / 截图
├── .github/workflows/build.yml                # CI：编译 + DMG + Release
└── README.md                                 # 根目录只放文档、LICENSE 与 SwiftPM 必需文件
```

**分层思路**：C 层只负责把系统 API 结果拍平成值结构和「`\t` 分隔的字符串行」，
Swift 层不碰任何复杂 C 结构体（定长 `char[]` 全通过 `cproc_xxx()` accessor 读取），
因此 Swift 侧不必处理 C 定长数组被导入成 tuple 的问题，也不会因 SDK 结构体微调而崩。

---

## 编译与运行

需要 **macOS 12+ / Xcode 或 Command Line Tools**（Swift 5.9+）。

```bash
cd Vantage

# 调试运行（无 .app bundle，直接弹窗）
swift run

# 生成可双击的 App
chmod +x Scripts/build_app.sh
./Scripts/build_app.sh
open build/Vantage.app
```

`Scripts/build_app.sh` 会 `swift build -c release`，把可执行文件与 `Packaging/Info.plist` 组装成
`build/Vantage.app`，并做 ad-hoc 签名。

> 也可以用 `swift package generate-xcodeproj`（旧工具链）或直接在 Xcode 里
> `File → Open` 这个目录，用 SwiftPM 原生支持打开。

---

## 权限说明与 SIP 限制（重点）

### 为什么 root 也救不了 `task_for_pid`

SIP 开启时，`task_for_pid()` 对**受保护进程**（Apple 平台二进制、系统守护进程、带
restricted 标志的进程）必然失败，与运行身份无关：

- Apple《Runtime Protections》：内核在进程启动时判定「受保护」标志，之后任何
  `task_for_pid` / `processor_set_tasks` 尝试都返回 **EPERM**；文档里明确举例
  `sudo lldb -n Finder` 的 attach 依然失败。
- Apple《Debugging tool entitlement》：`com.apple.security.cs.debugger` 只能取得
  「未签名 / 第三方且带 `get-task-allow`」进程的 task port；对没有
  `get-task-allow`、因而受 SIP 保护的进程同样无效。
- `com.apple.system-task-ports`（旧名 `task_for_pid-allow`）能拿任意进程的 task
  port，但**只对 Apple 自身签发**，第三方拿不到。
- `taskgated` / TCC 还会额外要求授权，非 root 运行时弹管理员密码，授权仅 10 小时。

因此不能把「拿不到 task port 就提示需要 sudo」当作解法：`sudo` 解决不了 SIP。
本工程已把 task port 降级为**加分项**，所有主要信息都走不需要它的路径。

### 方案对照表

| 想采集的数据 | 原方案（依赖 task port） | 无 task port 替代 | 实现位置 |
|---|---|---|---|
| 已加载镜像 | `TASK_DYLD_INFO` + `mach_vm_read_overwrite` | **`proc_pidinfo(PROC_PIDREGIONINFO)` 迭代 + `proc_regionfilename`** | `dylibs_via_regions_noport()` |
| 完整内存映射 | `vm_region_recurse_64` | **`PROC_PIDREGIONINFO`（`pri_address + pri_size` 步进）** | `cproc_regions()` →「内存映射」页 |
| Audit / Security Token | `task_info(TASK_AUDIT_TOKEN)` on task port | **`task_name_for_pid()` + `task_info`**（task name port 只放行 `task_info`） | `cproc_mach_security()` |
| CS flags / Team ID | 容易误用的 `CS_OPS_*` 编号 | **`syscall(SYS_csops, CS_OPS_STATUS/CS_OPS_TEAMID)`** + Security.framework | `cproc_mach_security()` |
| 签名 / Entitlements / CDHash | — | `SecCodeCopyGuestWithAttributes` + `SecCodeCopySigningInformation` | `SigningReader.swift` |
| 控制终端 / 会话 / 作业控制 | — | `proc_bsdinfo.e_tdev` / `e_tpgid` / `pbi_pgid` + `devname_r` + `PROC_TTY_ONLY` | `cproc_tty()` →「TTY」页 |
| 命令行 / 环境变量 | — | `KERN_PROCARGS2` / `KERN_PROCARGS` | `proc_collect.c` / `proc_detail.c` |
| 打开文件 / socket / pipe | — | `PROC_PIDLISTFDS` + `PROC_PIDFDxxxINFO` | `cproc_open_files/sockets/monitoring` |
| pipe 对端进程 | — | **全系统 pipe 句柄索引**（`pipe_peerhandle` 反查） | `cproc_pipe_peers()` |
| 线程 / CPU / 内存 / BSD flags | — | `PROC_PIDTASKINFO` / `PROC_PIDTBSDINFO` / `PROC_PIDTHREADINFO` | `proc_collect.c` |
| **进程内存内容**（读字节） | `mach_vm_read_overwrite` | **无公开替代** | SIP 的设计目标就是不让你读；只能 ESF / 系统扩展 / 研究环境下关 SIP |
| 实时进程/网络事件 | — | Endpoint Security framework（需 `com.apple.developer.endpoint-security.client`） | 超出本工具范围 |

关键依据：`vmmap` 自己就是用 `proc_pidinfo` + `proc_regionfilename` 工作的，
`dtruss` 跟踪它只能看到 `proc_info` 系统调用、看不到任何 Mach VM 调用；
Apple DTS 也明确推荐用 `task_name_for_pid` 取得任意进程的 audit token。

### 仍然存在的边界

- **dyld 共享缓存**：region 枚举对共享缓存里的 system framework 只返回
  `dyld_shared_cache_*` 这一个路径，不会逐个展开成 `UIKit.framework` 等条目。
  要精确展开需解析 `dyld_shared_cache_*.map`，本工具不做。
- **Audit Token**：`task_name_for_pid` 是 Mach API，Apple 自己都提醒「兼容性冰很薄」，
  且对个别进程仍可能被拒；失败时界面会明确标注，不会假装成功。
- **CS flags**：`csops` 是稳定系统调用，但 `CS_*` 位值来自 xnu 常见定义，
  不同系统版本可能略有差异，界面已标注为参考值。
- **`com.apple.security.cs.debugger`** 仍保留在 entitlements 里：它对
  「自己编译、带 `get-task-allow` 的调试版 App」有效，能让这些进程显示精确镜像列表；
  但它**不能突破 SIP**，不要再把它当作 root 的替代品。

普通权限下即可使用全部 13 个 Tab；`sudo` 只对未受 SIP 保护的第三方进程额外解锁
精确 `TASK_DYLD_INFO` 镜像列表。

**参考来源**

- Apple《Runtime Protections》（SIP 下 `task_for_pid` / `processor_set_tasks` 返回 EPERM，`sudo lldb` 也失败）：<https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html>
- Apple《Debugging tool entitlement》（`com.apple.security.cs.debugger` 的适用边界）：<https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger>
- Apple DTS 论坛《Retrieve random process audit token》（`task_name_for_pid` 取得任意进程 audit token）：<https://developer.apple.com/forums/thread/652363>
- Apple DTS 论坛《Using libproc to get ports used by processes》（`PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO` 是官方路径）：<https://developer.apple.com/forums/thread/728731>
- xnu `bsd/sys/proc_info.h`（`struct proc_regioninfo` / `pipe_info` / `PROC_PID*INFO_SIZE`）与 `bsd/sys/codesign.h`（真实 `CS_OPS_*` 编号）：<https://github.com/apple-oss-distributions/xnu>
- Stack Overflow《filename of memory mapped libraries osx》（`PROC_PIDREGIONPATHINFO` 迭代示例）：<https://stackoverflow.com/questions/8240436/filename-of-memory-mapped-libraries-osx>
- Stack Overflow《Catching Mach system calls using dtruss》（`vmmap` 只用 `proc_info` 系统调用）：<https://stackoverflow.com/questions/35113541/catching-mach-system-calls-using-dtruss>
- xnu `bsd/sys/proc_info.h`（`struct proc_bsdinfo` 的 `e_tdev` / `e_tpgid` / `pbi_pgid` / `pbi_pjobc`）、`bsd/sys/ttycom.h`（`TIOCGWINSZ` / `TIOCGPGRP`）：<https://github.com/apple-oss-distributions/xnu>
- `ps(1)` man page（`-t` 按终端筛选、`-o tty` / `tt` 关键字）：<https://www.unix.com/man-page/osx/1/ps>

---

## 性能监控：参考 macmon，但不用 powermetrics / 不用 root

macmon 的核心价值不是界面，而是**绕过 `powermetrics` 的 root 门槛**：Apple Silicon 的
功耗、DVFS 频率、die 温度并不在 Mach task port 里，而是在 **IOReport 私有框架**和
**AppleSMC** 里，普通用户态进程就能读。本工程按同样的分层用 C 重写，做成原生 GUI。

### 数据源分层

| 层 | 接口 | 采集内容 | 权限 |
|---|---|---|---|
| **公开、始终可用** | `host_statistics(HOST_CPU_LOAD_INFO)` | CPU 用户/系统/空闲占比 | 无 |
| | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 每核 ticks，差分算分簇利用率 | 无 |
| | `host_statistics64(HOST_VM_INFO64)` + `vm.swapusage` | 内存已用 / Wired / 压缩 / Swap | 无 |
| | `IOBlockStorageDriver` 的 `Statistics` 字典 | 磁盘读/写字节、IOPS（差分得 B/s） | 无 |
| | `getifaddrs()` 的 `ifi_ibytes/obytes` | 网络上下行吞吐（差分，跳过 loopback） | 无 |
| | `notify(3)` 的 `com.apple.system.thermalpressurelevel` | 热压 0..3（NOMINAL/FAIR/SERIOUS/CRITICAL） | 无 |
| **私有、无 root、可选** | `libIOReport.dylib`（`dlopen` + `dlsym`） | CPU/GPU/ANE/DRAM 功耗、CPU/GPU P-state residency 与实时频率 | 无 |
| | `AppleSMC` IOKit user client | die 温度、`PSTR` 整机功率、风扇 | 无 |
| | `IOHIDEventSystem` 温度传感器 | CPU/GPU 温度兜底（SMC 键受限机型） | 无 |
| | IORegistry `AppleARMIODevice` → `pmgr` 的 `voltage-states*` | E/P/M/GPU 的**完整 DVFS 频率表**（不止上限） | 无 |
| | IORegistry `AGXAccelerator` → `gpu-core-count` | GPU 核心数 | 无 |

`powermetrics` 需要 root 且单次采样约 1 秒；macmon / 本工程直接读同源的内核计数器，
因此**既不弹 sudo，也不需要把慢速采样塞进 UI 刷新路径**。

### IOReport 调用链（`perf.c`）

1. `dlopen("/usr/lib/libIOReport.dylib")` 等三个候选路径 → `dlsym` 解析
   `IOReportCopyChannelsInGroup` / `MergeChannels` / `CreateSubscription` /
   `CreateSamples` / `CreateSamplesDelta` / `IOReportChannelGet*` /
   `IOReportSimpleGetIntegerValue` / `IOReportStateGet*`。
   任何必需符号缺失就整条链路降级，不崩溃。
2. 订阅**三组**：`Energy Model`（组件功耗）、`CPU Stats`、`GPU Stats`（后两者取 P-state）。
   解析阶段用 `ior_channel_allowed()` 逐条精确过滤，与 macmon 的
   `ioreport_channels_filter` 一致：
   - `Energy Model`：`GPU Energy` / `*CPU Energy` / `ANE*` / `DRAM*` / `GPU SRAM*`
   - `CPU Stats`：`subgroup == "CPU Core Performance States"`
   - `GPU Stats`：`subgroup == "GPU Performance States"`

   **不要整组订阅 `CLPC Stats` / `PMP`**：macmon 的 CLPC 能量通道是从 `AppleCLPC`
   IOKit service 按机型/系统版本查表**手工构造**并逐条注入的（group=`CLPC`、
   subgroup=`Energy Counters`、unit=`nJ`），不是订阅一个叫 `CLPC Stats` 的组。
   若整组订阅并用 `strstr(group,"Energy")` / `strstr(name,"CPU")` 宽泛匹配，
   会把上百个无关通道计入能量，CPU 功耗可虚高 2 倍以上。
3. 每次采样：`CreateSamples(s1)` → `usleep(window)` → `CreateSamples(s2)` →
   `CreateSamplesDelta(s1, s2)`。从 `s1` 建立 `index → (group, sub, name, unit)` 元数据，
   再按 index 解析 delta（避免 delta item 里元数据缺失导致错位）。
4. 功耗：`delta 值 / 单位 / 实际窗口秒数`，单位是 `mJ`→/1e3、`uJ`→/1e6、`nJ`→/1e9。
   只累加上面精确过滤后的 Energy Model 通道，按名分流
   （`GPU Energy`/`GPU SRAM*`→GPU、`*CPU Energy`→CPU、`ANE*`→ANE、`DRAM*`→DRAM）。
   状态栏的「逐通道诊断」会列出每个通道名、unit 和换算出的 W，可直接与 macmon 核对。
5. **P-state residency 的加权频率计算**：
   `residency = [IDLE/DOWN/OFF..., f0, f1, ...]`，先找第一个非前导状态的 `offset`，
   `usage = Σ residency[offset .. offset+len(freqs)]`（`take(freqs.len())`），
   `avg_freq = Σ (residency[offset+i] / usage) × freqs[i]`（**索引直接对应**），
   `active_ratio = usage / Σ全部 residency`。
   前提是「频率态数 ≥ 频率表档数」，且 Apple 的约定是**第一个 active state 对应
   最低频表项**。M5 的 state 名是 `V0P7/V1P6…`（ECPU）、`V0P18…`（PCPU）、
   `P1/P2…`（GPU），都不带 MHz，只能靠表按索引反查。
   若改成「取全部频率态 + 索引按比例拉伸」，GPU 频率会偏高（338 → 486 MHz）；
   按 `take(freqs.len())` 才能与参考口径一致。

   **pmgr 频率表有两个 M5 特有的坑**：
   - **单位变了**。M1–M3 的 CPU 表是 Hz（2064 MHz → `2_064_000_000`），
     M4+ 改成 **kHz**（4608 MHz → `4_608_000`），因为 u32 装不下 4.6 GHz 的 Hz 值。
     若一律 `freq/1e6`，kHz 表会被 `mhz<100` 过滤掉 → **E/P 表 0 档**。
     按 `freq>=1e8` 判 Hz、否则判 kHz（kHz 最大约 5e6，Hz 最小约 3e8，空档很大）。
   - **键名编号不固定**。`str_ends(kbuf,"-1-sram")` 匹配不上真实的
     `voltage-states1-sram`（结尾是 `s1-sram`），会导致一张 CPU 表都路由不到。
     正确做法是从键名解析 `voltage-states` 后的数字编号，把**所有表**存进表池；
     M5 起 Apple 用 `acc-clusters` 动态指定每簇对应哪张表
     （M5 Max 为 22/23/5，而非固定 1/5），因此运行时按
     「P-state 通道的频率态数量」选表：ECPU 恰好 8 个、PCPU 19 个，与表档数一一对应。
     GPU 表仍是编号 9。
   - **不去重**。同一频率可能对应不同电压档（或 OFF 与最低 P-state 同频），
     IOReport 的 state 是按索引对齐的；去重会少一档、把索引整体错位
     （M5 GPU 表 13 entries 会被压成 12 档）。
   状态栏「逐通道诊断」会列出表池每张表的编号 / 档数 / 频率范围 / 单位，
   以及每个 P-state 通道的 state 名与命中的表。
6. **按 CPU tier 分开**：通道名含 `ECPU` / `MCPU` / `SCPU` / `PCPU` 分别归入
   E / 中间 / P 簇，各自算实时频率与活跃占比；GPU 走 `GPU Stats`
   （频率表去掉最低一档，与参考口径一致）。每个通道先算自己的
   `avg_freq` 与 `active_ratio`，再**等权平均**：若把 `gpu_freq += avg`
   跨通道累加，有 N 个 GPU 通道频率就放大 N 倍。
   界面给出 `E-CPU 13% @ 1863 MHz` 这类分簇读数；频率为 0 时显示「— MHz」，
   不会拿 0 冒充读数。活跃占比用独立的 `CPERF_VALID_RESIDENCY` 位。

### AppleSMC 与 IOHID 温度（`perf.c`）

`IOServiceGetMatchingService("AppleSMC")` → `IOServiceOpen` →
`IOConnectCallStructMethod(conn, /*selector*/ 2, in80, 80, out80, &size)`。
参数块是 80 字节，用**固定字节偏移**读写（避开不同 SDK 里 `SMCParamStruct` 对齐差异）：

| 偏移 | 字段 |
|---|---|
| 0 | `key`（FourCC，大端字符序） |
| 28 / 32 | `keyInfo.dataSize` / `keyInfo.dataType` |
| 40 / 41 / 42 | `result` / `status` / `data8`（命令） |
| 44 | `data32`（`GetKeyFromIdx` 的索引） |
| 48 | `bytes[32]`（值） |

读键两跳：`data8=9(kSMCGetKeyInfo)` 拿到 size/type → 回填 keyInfo →
`data8=5(kSMCReadKey)` 读值。解码按 `dataType`：`flt ` = 小端 float（Apple Silicon 温度/功率
就是它）、`sp78` = 有符号 16 位 /256、`fpe2` = 16 位 >>2、`ui8/ui16/ui32/si8`。

**`#KEY` 单独处理**：它的 `dataType` 不保证是 `ui32`，走通用解码会失败，
因此直接读 `bytes[0..4]` 的大端 u32。传感器键按
`data8=8(kSMCGetKeyFromIdx)` 枚举一次后**缓存**
（每帧全量枚举会产生上千次 IOKit 调用），分类规则与参考口径一致：
`Tp/Te/Ts` 系列 → CPU，`Tg` 系列 → GPU，`F` 系列 → 风扇，`PSTR` → 整机功率。

> **`#KEY` 的值远大于 1024**。Apple Silicon 的 SMC 通常有 **3000+ 个键**
> （M4/M5 约 3246，其中约 320 个温度键）。若把上限写成 1024，
> `#KEY=3246` 会被判为失败 → T/F 开头的键枚举出 0 个 → 温度回退 IOHID
> → 而 M5 上没有 M1 世代的核心传感器 → 温度整栏显示「—」。
> 因此上限设为 65535，键缓存容 1024 个温度键 / 128 个风扇键，
> 诊断里会打印 `#KEY=...` 与枚举结果。

**SMC 拿不到温度时自动回退 IOHIDEventSystem**（macOS 14+ 主用 SMC）：
`IOHIDEventSystemClientCreate` + `SetMatching(PrimaryUsagePage=0xff00, PrimaryUsage=0x05)`
→ `CopyServices` → 每个 service 读 `IOHIDServiceClientCopyEvent(type=15)` 的
`IOHIDEventGetFloatValue(event, 15<<16)`，值已是摄氏度，过滤 `<=0 / >150`。

**传感器命名按芯片代际分两套**：
- M1/M2：`pACC/eACC MTR Temp Sensor` → CPU、`GPU MTR Temp Sensor` → GPU，
  这些是真正的核心热点传感器。
- M4/M5：只剩 `PMU tdie*` / `PMU2 tdie*`（供电 IC 自身 die 温度）、
  `PMU tcal`（校正参考值）、`PMU tdev*` / `NAND` / `battery`（周边）。
  `PMU tcal` 常见读数约 51.8°C，容易被误当成 CPU 温度。

  核心传感器与 PMU 值**分开累计**：只有核心传感器一个都没有时才用 PMU 平均值，
  并置 `CPERF_TEMP_PMU`，UI 显示「IOHID PMU（非核心热点）」。
  PMU 读数趋势对、绝对值比 SMC `Tp*` 低 15–20°C，这是物理位置差异，不是采集错误。
  `tdev`/`NAND`/`battery`/`tcal` 一律只写进诊断，不参与平均。

HID client 只创建一次，私有符号全部 `dlsym` 动态解析。
状态栏「逐通道诊断」列出 SMC 的 `#KEY` 总数、`T` 开头键读数与 IOHID 的全部
product 名+温度，可直接看出归类对不对。

### 关键口径与限制（务必看）

- **unavailable ≠ 0**。每个字段都有 `CPERF_VALID_*` 位，读不到时 UI 显示「—」、
  环形仪表画虚线，绝不显示 0 W / 0 °C 把「传感器不可用」伪装成「设备空闲」。
- **SoC 分项 vs 整机功率不能相加**。`cpu/gpu/ane/dram_power_w` 来自 IOReport
  `Energy Model` 的精确通道，`sys_power_w` 来自 SMC `PSTR`
  （含屏幕、Wi-Fi、SSD 等无独立计数器的部件）。卡片里明确标了两者口径，曲线也不叠加。
- **功耗数值与 macmon 不必逐秒相等**，但**量级必须一致**。两者采样窗口、负载时刻不同，
  正常情况下同量级浮动；若差 2 倍以上就是采集口径错了，不是采样时刻问题。
  状态栏的「逐通道诊断」列出每个 Energy Model 通道的 W 值、`P-state` 通道的
  state 名/档数/频率、匹配通道数，按此逐项核对即可定位。
- **容量单位用 1024 进制**。`hw.memsize` 是 16 GiB，用 `10^9` 会显示 17.18 GB，
  用 `2^30` 显示 16.00 GB；macmon / Activity Monitor 都是后者（界面标作 GB）。
  例如：同一时刻 Swap 用 `10^9` 显示 4.52 GB，用 `2^30` 显示 4.21 GB，
  参考工具显示 4.21。内存「已用」只算 `active + wired + compressed`，
  **不含可回收的 `inactive` 文件缓存**（计入时 16 GiB 机器会得出 94% 已用，
  正确口径约 81.5%）。
- **温度来源会变，且口径不同**。优先 SMC 的 `Tp/Te/Ts/Tg` 键（核心热点），
  其次 IOHID 核心传感器（M1/M2），最后才是 IOHID 的 PMU `tdie` 系列（M4/M5）。
  状态栏显示 `AppleSMC` / `IOHID 核心传感器` / `IOHID PMU（非核心热点）` / `不可用`。
  **PMU 值比核心温度低 15–20°C 是物理位置差异**，不能与 SMC 值直接比较。
  只认精确归类的传感器，拿不到就显示「—」，绝不用其它传感器的最大值凑数。
- **分簇利用率是启发式**。macOS 公开 `hw.nperflevels` / `hw.perflevelN.logicalcpu_max`
  （**N 越小性能越高**），但不公开 core-id → perflevel 映射。本工程按「E 核在前、P 核在后」
  把 `host_processor_info` 的核心序号分组，界面状态栏明确标注为启发式。
- **网络吞吐是近似值**。`getifaddrs` 的 `ifi_ibytes/obytes` 是 32 位，且 Apple 对第三方
  签名的程序按 1KiB 批量化上报以抗指纹。代码处理了一次 32 位回绕，但不追求与
  Activity Monitor（私有 `NetworkStatistics.framework`）逐字节一致。
- **仅 Apple Silicon 完整可用**。Intel Mac 没有 `Energy Model` / pmgr 电压表，
  IOReport/SMC/DVFS 相关字段会显示为「—」；公开层（CPU/内存/磁盘/网络）照常工作。
- **虚拟机 / 未来系统**可能不提供 IOReport 通道或 SMC 键；macmon 也明确对这些场景
  隐藏功耗与频率。本工程同样按 `valid` 位隐藏，不编造数值。
- IOReport 是**私有 API**，通过 `dlopen/dlsym` 运行时解析、不做链接期依赖，
  因此某个系统版本改了通道名最多是少几项数据，不会导致 App 启动失败。
  订阅句柄只在创建它的 pthread 上使用，且刻意不 `CFRelease`（私有不透明类型，
  当作 CF 对象处理反而会崩；进程生命周期内只创建一次）。

### 参考

- macmon 源码与架构：<https://github.com/vladkens/macmon> ·
  <https://docs.rs/macmon/latest/src/macmon/sources.rs.html> ·
  <https://deepwiki.com/vladkens/macmon/3.1-hardware-monitoring-apis>
- Apple《Determining system capabilities》（`hw.nperflevels` / `hw.perflevelN.*` 语义）：
  <https://developer.apple.com/documentation/kernel/1387446-sysctlbyname/determining_system_capabilities>
- Apple Developer《Using libproc to get ports used by processes》、Netdata macOS collector
  （IOReport / AppleSMC / IOHID / powermetrics 的分层实践）：
  <https://developer.apple.com/forums/thread/728731> ·
  <https://learn.netdata.cloud/docs/collecting-metrics/collectors/operating-systems/macos>
- `IOBlockStorageDriver` Statistics 键：
  <https://developer.apple.com/documentation/iokit/ioblockstoragedriver_h_user-space/defines>
- macOS `NET_RT_IFLIST2` / 1KiB 批量化说明：<https://iosfeeds.com/read/17645>

---

## TTY 解析：可以，而且完全不需要 task port

TTY 属于 **BSD 进程层**，不是 Mach 内存，因此 SIP / `task_for_pid` 那一整套限制跟它无关。
`ps` 的 `TT` 列、`lsof` 的 `TTY` 列本质上都来自同一个字段。

### 数据源

| 数据 | 来源 | 说明 |
|---|---|---|
| 控制终端 `dev_t` | `proc_bsdinfo.e_tdev`（或 `kinfo_proc.kp_eproc.e_tdev`） | `0` / `NODEV` 表示**没有**控制终端，显示 `??`（GUI 应用、守护进程大多如此） |
| 设备路径 | `devname_r(dev, S_IFCHR, ...)`；失败时扫描 `/dev` 比对 `stat().st_rdev`；再兜底按 minor 构造 `ttys%03d` | 结果带缓存，`/dev` 只扫一次。路径形如 `/dev/ttys001` |
| 主 / 次设备号 | Darwin `dev_t` 编码：major 高 12 位、minor 低 8 位 | 自己算，不依赖 SDK 里 `major()` / `minor()` 是宏还是函数 |
| 进程组 / 终端前台进程组 | `pbi_pgid` / `e_tpgid` | `pgid == tpgid` → **前台**；否则后台（`ps` 的 `STAT` 里 `+` 号同理） |
| `jobc` | `pbi_pjobc` | 该进程组里仍关联此终端的作业数 |
| 会话首进程 / CTTY 标志 | `pbi_flags & PROC_FLAG_SLEADER / PROC_FLAG_CTTY / PROC_FLAG_CONTROLT` | 位值见 `proc_info.h` |
| 同终端的所有进程 | `proc_listpids(PROC_TTY_ONLY, dev, ...)` | libproc 原生按 `e_tdev` 过滤；对每个 PID 再读 PGID/TPGID 标出前台进程 |
| FD 0/1/2 | `PROC_PIDFDVNODEPATHINFO` | 判断标准输入输出是否被重定向，以及是否仍指向该 tty |
| 窗口大小 / 前台组 / termios | 对 `/dev/ttysNNN` 只读 `open(O_RDONLY\|O_NOCTTY\|O_NONBLOCK)` + `ioctl(TIOCGWINSZ / TIOCGPGRP)` + `tcgetattr` | **尽力而为**：其他用户的 pty 可能因权限打不开，界面会标注原因，不影响其余数据；`O_NOCTTY` 保证不会把自己变成该终端的控制进程 |

### 落地形态

- **主表新增 `TTY` 列**：显示短设备名（`ttys001`）或 `??`，可点击表头排序，也纳入全文搜索。
- **概览页**：TTY 路径、TPGID、前台/后台、jobc 摘要；副标题也带上 `TTY xxx`。
- **新增「TTY」Tab**：上面表格里的全部字段逐条列出，外加同终端进程清单（含每个进程的 PGID/TPGID 与前台/后台状态）。
- 所有数据都来自 `proc_pidinfo(PROC_PIDTBSDINFO)` / `proc_listpids` / `proc_pidfdinfo` / 只读 ioctl，**没有一处调用 `task_for_pid`**。

### 一个 macOS 特有的坑：拿不到数字 SID

Linux 的 `/proc/PID/stat` 第 6 字段是数字 session ID，macOS 没有对应物：
`ps` 连 `sid` 关键字都没有，最接近的 `sess` 打印的是**内核 `struct session *` 指针**（十六进制地址），
不是 ID。所以「TTY」页会明确标注「会话 ID 不可用」，改用 PGID / TPGID / `SLEADER` 标志来推断
会话结构。这不是采集失败，是平台本身不提供。

---

## C 采集层的实现要点

C 采集层以 macOS SDK / xnu 公开头文件为准。以下列出这些接口上容易踩的坑，
以及本工程采用的写法，可作为改动采集代码时的检查清单：

1. **`<sys/user.h>`**：macOS 没有这个头，`kinfo_proc` 来自 `<sys/sysctl.h>`。
2. **`KERN_PROCARGS2` 缓冲区**：`sysctl` 返回的 `needed` 是字节数，写进固定
   栈数组会溢出；按 `needed` 动态分配并全程边界检查。
3. **命令行混入 envp**：不能把缓冲区里所有 NUL 结尾的串都拼进命令行，
   要严格按 `argc` 取 `argv[0..argc-1]`。
4. **`KERN_PROCARGS` 的 mib**：必须是 `{CTL_KERN, KERN_PROCARGS, pid}`；
   `{CTL_KERN, KERN_PROC, pid}` 取不到 argv+envp。用 `argc` 精确定位 envp 块，
   不靠「找双 NUL」猜边界。
5. **跨进程指针**：`imgs[i].imagePath` 是目标进程地址，不能当本机 `const char *`
   直接打印；对每个地址再做一次 `mach_vm_read_overwrite` 读取 C 字符串。
6. **`dyld_all_image_infos` 头部布局**：真实布局是
   `uint32 version; uint32 infoArrayCount; 指针 infoArray;`，把前两个字段当成
   `uint64_t` 会读出完全错误的镜像数。这里只读前 24 字节并用 `memcpy` 取值，
   不依赖完整结构定义，跨 dyld 版本更稳。
7. **`vm_region_recurse_64` 的参数**：要传 `struct vm_region_submap_info_64`
   的地址，不能把指针变量本身当 info 缓冲区。
8. **远端地址格式化**：按 `foreign` 选择 `insi_faddr` / `insi_laddr`，并用
   `memcpy` 取地址字节，兼容不同 SDK 中 `in_addr_4in6` 的字段命名。
9. **`CS_OPS_*` 编号**：`CS_OPS_AUDITTOKEN=1` / `CS_OPS_PID=2` /
   `CS_OPS_GET_CODESIGNING_INFORMATION=5` 不是 xnu 的定义；
   `bsd/sys/codesign.h` 的真实值是 `CS_OPS_STATUS=0` / `CS_OPS_CDHASH=5` /
   `CS_OPS_TEAMID=14` 等。签名详情优先用公开的 `Security.framework`；
   进程 CS flags 用 `syscall(SYS_csops, CS_OPS_STATUS)` 按真实编号读取。
10. **环境变量解析越界**：分配 `needed + 2` 并清零作双 NUL 哨兵，所有循环都带 `p < end`。
11. **父进程 PID**：统一用 `kp_eproc.e_ppid`，树形构建额外做了环 / 孤儿 / 深度防御。
12. **`task port` 泄漏**：每次 `task_for_pid` 成功后 `mach_port_deallocate`。
13. **`pbi_flags` 的公开位**：xnu `bsd/sys/proc_info.h` 只导出到
    `PROC_FLAG_EXEC (0x4000)`；Rosetta 位在 `#ifdef PRIVATE` 的
    `proc_info_private.h` 里，公开 SDK 不导出。曾经用 `0x00002000` 兜底
    `PROC_FLAG_TRANSLATED`，而 `0x2000` 是 `PROC_FLAG_PSUGID`（进程自 exec
    后提过权）—— `/usr/bin/sudo` 这类 setuid 的通用二进制因此被整批显示成
    `Intel (Rosetta 2)`。两个 C 文件的 `#ifndef` 兜底一律按 xnu 公开头真实值
    （`LP64=0x10`、`SLEADER=0x20`、`CTTY=0x40`、`CONTROLT=0x80`、
    `PSUGID=0x2000`、`EXEC=0x4000`），`flagdefs` 不再列任何私有位。
14. **架构识别**：`proc_arch.c` 读 Mach-O 文件头判断可执行文件含哪些 slice，
    而不是从 `pbi_flags` 猜运行时 ISA。FAT 头（`CA FE BA BE` / `CA FE BA BF`）
    字段一律大端，`fat_arch` 20 字节 / `fat_arch_64` 32 字节；thin Mach-O 由
    magic 判断后续字段的字节序（`CF FA ED FE` 为小端 64 位）。
    `cputype` 映射到 `CPROC_ARCH_*` 位掩码，`arm64e` 由 `cpusubtype & ~0xff000000 == 2`
    识别。按「路径 + dev/ino/mtime/size」缓存，TTL 60 秒内零系统调用，
    ⌘R /「立即刷新」调 `cproc_exec_archs_flush()` 强制重读。
    运行时 Rosetta 只在「Apple Silicon 主机 + 二进制不含 arm64 slice」这一确定
    条件下标注；通用二进制实际选了哪个 slice 属公开接口无法反查的信息，不猜测。
15. **argv[0] 单独保留**：`KERN_PROCARGS2` 缓冲区的最后一个字符串未必有 NUL
    结尾，不能当 C 字符串用 `strnlen`；按 `p - arg` 的已知长度复制，并在拼进
    空格分隔的 `cmdline` 之前先保存 `argv[0]`。Swift 侧因此能拿到完整的调用名，
    用于「与 bin 不同时」的名称标注、tooltip、概览页与搜索。

---

## 界面与交互设计要点

| 现象 | 根因 | 修正 |
|---|---|---|
| 顶部工具栏按钮被挡住，只剩一小段蓝色 segmented 露出来 | `styleMask` 含 `.fullSizeContentView`，内容视图延伸到标题栏下方，`bar` 的 top 约束贴在 `content.topAnchor`，整排控件被 traffic light + 标题栏压住；同时 9 个控件在约 1039pt 宽窗口里被 `NSStackView` 压缩 | 去掉 `.fullSizeContentView`；把状态文字移到底部独立状态条，顶部只留 8 个控件；搜索框设低 hugging 吸收余量，其余控件设高 compression resistance；`minSize` 不变 |
| 刷新会重置进程表滚动位置 | `reloadData()` 后同步遍历 `expandItem` 改变行数，且每次 `expanded` 为空就 `expandItem(nil, expandChildren: true)` 全展开，视口被拉走；`selectRowIndexes` 又触发详情重载 | 刷新前记录「视口顶部可见行的 PID」+ `clip.bounds.origin`，刷新后按锚点 PID 对齐垂直位置、保留水平位置，用 `NSClipView.scroll(to:)` + `reflectScrolledClipView` 恢复；展开状态改为只在首次（或切换树/列表时）全展开，之后按 PID 集合还原 |
| 刷新会重置数据列宽 | 详情表 `setRows()` 每次都 `removeTableColumn` + `addTableColumn` 重建列，用户拖过的宽度被默认值覆盖；主表虽不动列，但重载链路会连带触发详情刷新 | 详情表只在「列数或表头真的变化」时重建列；列宽按 tab 唯一 key 存 `UserDefaults`，`tableViewColumnDidResize` 落盘，重建时按序恢复；主表列宽同样按 column identifier 持久化；`setRows()` 也保存/恢复滚动位置 |
| 选中行刷新时反复触发详情重新采集 | `AppContext.selectedPID` 的 `didSet` 无条件发通知，`reloadData` 后恢复选中会把它重设一遍 | `oldValue == selectedPID` 时直接 return |
| 界面里 `kernel_task` 出现两行（都 PID 0） | `ppid == 0` 的进程既是 root，又被塞进 `byParent[0]`，于是变成自己的子节点 | 只有 `ppid > 0 && ppid != pid` 才挂到父节点；root 判定改为 `ppid <= 0` |
| **主窗口无法显示；⌘0 / 通过窗口定位进程时直接 SIGABRT 闪退**（`NSInternalInconsistencyException: A TabView managed by a TabViewController cannot have its delegate modified`） | **真正根因**：`DetailTabViewController.viewDidLoad()` 里执行了 `tabView.delegate = proxy`（用独立代理转发 `didSelect`）。`NSTabViewController` 本身就是它所管理 `NSTabView` 的 delegate，macOS 26 的 AppKit 在 `-[NSTabView setDelegate:]` 里直接抛异常。主窗口的嵌套 split 里包含这个 Tab VC → 内容视图加载失败 → 表现为「主窗口打不开」；`InspectorWindowController.init` 里 `setContentViewController:` 加载同一个类 → `NSPerformVisuallyAtomicChange` 把异常 rethrow → `abort()`。监控 / 偏好设置窗口不含这个 Tab VC，所以能正常打开，造成了「只有主窗口坏了」的假象 | **删掉所有 `tabView.delegate` 赋值**，改为 override `NSTabViewController.tabView(_:didSelect:)` 并调用 `super`（Apple 文档明确允许且要求调 super），另加 `NSTabViewDidSelectTabViewItemNotification`（字符串构造通知名）与 `viewDidLayout()` 双备用；三条路径汇到 `syncTabSelection()`，由 `selectTab` 去重、不递归。segmented control 与 index 的同步交回 AppKit 原生 delegate。另把检查器创建从通知派发栈挪到下一个 main queue 圈 |
| **「监控」页 FD 列也能被点击**（界面里 `9`/`10`/`17`/`18` 显示成蓝色链接色，双击会跳到 PID 9 这种不存在的进程） | 旧 `pidValue()` 用「同一行任意格含 PID 字样」放行**整行**：pipe 行的说明列写了「对端 PID 42826 (QQ) FD 10 — 同一进程」，于是同行的 FD 列 `9` 也被解析成 PID 9 | ① `pidValue()` 改成**列头白名单**：只有表头含 `pid` / `说明` / `对端` / `项目` / `值` 的列参与解析，FD / 类型 / 句柄 / 位置 / 窗口号 / 层 / 地址 / 路径等一律排除；② 新增 `pidLinksEnabled`，「监控」页设为 `false` —— 它只是 FD 类型汇总，对端进程请去专门的 Pipe 页看，整页不再有任何蓝色链接 |
| **进程列表点表头排序完全没反应** | `NSOutlineView` 的 delegate 是 `NSOutlineViewDelegate`，它为表头点击定义了**自己的** `outlineView(_:didClick:)`（ObjC `outlineView:didClickTableColumn:`）。AppKit 点表头只发这个消息，**不会**回退到 `NSTableViewDelegate` 的 `tableView(_:didClick:)`（`tableView:didClickTableColumn:`）。旧代码只实现了后者，回调从未被调用，`compare()` / 三态循环 / 三角全都没机会执行 | 实现 `outlineView(_:didClick:)`，并把 `tableView(_:didClick:)` 保留作兜底，两个入口都汇到 `handleHeaderClick(_:)`；同时把 `scrollToTopOnNextReload = true` 移到 `applySort` **之前**（`applySort` 内部同步 post 通知触发 `reload()`，事后设等于没设）。另注：`allowsColumnReordering = true` 必须保持开启，否则 AppKit 不派发表头点击 delegate |
| **选中文字后 ⌘C 无法复制，只能用右键菜单里的「复制」** | 手写 `NSApplication`（无故事板 / NSDocument）时 AppKit **不会自动创建标准「编辑」菜单**。旧主菜单「编辑」里只有「聚焦搜索 ⌘F」「复制 PID」「复制完整命令行」三个自定义项，且后两个都没有 keyEquivalent —— **没有任何菜单项带 ⌘C**，于是 `NSApplication.sendAction` 根本不会被触发，响应链再完整也没用。右键能复制是因为 `NSTextView` 自己的右键菜单里内置了 `copy:` | 编辑菜单补齐标准项：撤销 ⌘Z / 重做 ⇧⌘Z / 剪切 ⌘X / **复制 ⌘C** / 粘贴 ⌘V / 全选 ⌘A。`target=nil` 的标准项交给响应链（输入框、`NSTableView.selectAll:`）；「复制」走自定义 `Clipboard.copy` 分发：① 第一响应者（`NSTextView` / field editor）有选中文字 → 系统 `copy:`，只复制选区；② 只读文本视图无选中 → 复制全文；③ 表格无选中文字 → 沿响应链找 `RowTextCopying` 复制选中行（Tab 分隔）；④ 兜底复制选中 PID，都没有则 beep |
| **主表里同名进程分不清真实身份**（例如：PID 47521 显示 `WeChat`，点开检查器才发现可执行文件是 `WeChat.app/Contents/Frameworks/crashpad_handler`） | `bundlePath` 从 `exepath` 反向找 `.app/`，同一个 App 的 helper / XPC / Renderer 与主进程共享 Bundle，名称列于是全都显示应用名 | 新增「通用 → 进程名称显示」：`displayLabel` = 主名 + 可选 raw 名（可执行文件 basename），默认开、3 种格式；只在**有 Bundle 且 raw 与主名不同**时追加，避免 `Safari (Safari)`。可选读 Bundle 本地化显示名（带 `NSCache`）。搜索、排序、复制、右键菜单、信号确认框、检查器标题、概览页、tooltip 全部同步，详见专节 |
| **默认列宽过宽，首次启动要大幅横向滚动** | 主表 14 列合计 **1736pt**（仅「完整命令」一列就 420pt），而主窗口只有 1240pt；详情表若采用「除末列外一律 170、末列 420」这类固定规则，Pipe 对端 7 列合计 **1440pt**、网络连接 6 列 1270pt，都远超下部详情区约 860pt。而列宽是按 identifier 持久化的，**只改默认值对已保存过列宽的用户不生效** | ① 主表重定 14 列默认宽度，合计 **1218pt**，首屏基本看全（详见专节）；② 详情表按表头语义分配并归一化到 **820pt**，两列「项目 + 值」页保持原比例不动；③ 窗口列表 820 → **702pt**；④ 新增 `ColumnWidthDefaults` 的 schema 版本键，默认值方案不同时**一次性清掉旧的持久化宽度**，之后用户拖的宽度照常保留；⑤ 「视图 → 重置列宽为默认」随时可手动恢复，主表 / 详情表 / 窗口列表同步响应 |
| **Mach 页一堆「提示」行把数据挤到下面**（例如：`Audit token 由 task_name_for_pid 取得…`、`task_for_pid 失败：SIP 开启时…` 等 5 行，第一列全是「提示」） | `lb_hint()` 把说明性文字当普通数据行输出，没法单独隐藏；而且「提示」本地化后会变成 `Hint`，**不能拿显示文字当过滤依据** | C 层改用稳定 ASCII 标记 `CPROC_HINT_TAG = "__hint__"`；Swift `parse()` 先按中文 `titles` 剥表头，再按标记过滤，**默认隐藏**。偏好「通用 → 界面 → 在详情页显示提示行」可打开，勾选后立即重采。空状态占位（「未选择进程」「正在采集…」）是 Swift 侧 `setPairs` 生成的、无标记，照常显示，详见专节 |
| **只有中文界面** | 全部 UI 字符串是中文硬编码字面量 | 实现 i18n：语义 key + 双 `.lproj` + 内嵌兜底表，运行时切换「跟随系统 / 简体中文 / English」；菜单重建、静态控件就地转换、详情页重采，无需重启，详见专节 |
| **`swift build` 报 6 类语法错误**（`expected ',' separator` / `raw value for enum case must be a literal` / `conditional binding must have Optional type` 等） | 初版 i18n 用正则 `"(?:\\.\|[^"\\])*"` 机械地把源码里含中文的字符串包成 `L("…")`。这个正则**在 Swift 字符串插值内嵌双引号处截断**：`"# 可执行文件: \(snap?.exepath ?? "—")\n"` 被切成 `L("# 可执行文件: \(snap?.exepath ?? ")—")\n"`，源码直接语法崩坏；另外 `case control = L("终止 / 控制")` 违反「enum raw value 必须是编译期字面量」，`alternateTitle` 在 macOS 26 SDK 是非 Optional，`if let` 报错 | ① 按反馈重做为**语义 key**：中文是 `.strings` 的 value，源码只写 `L("detail.cmd.executable", arg)`，格式串用 `{0}` 占位 —— 插值表达式不再混进字符串字面量，从根上消除截断；② `SignalGroup.rawValue` 改稳定 ASCII key，显示名走 `title → L(rawValue)`；③ `alternateTitle` 改普通 `let`；④ 迁移改用**能正确处理 `\(` 插值嵌套引号的 Swift 字符串扫描器**（`Tools/` 外的一次性脚本），并验证全项目 0 个未闭合字符串、624 处 `L()` 参数与占位符一致；⑤ 保护区（`titles:` 中文协议数组、列宽关键词数组）显式还原，不被文案替换波及 |

排序（点表头）属于主动改变视图顺序，仍会回到顶部——这是刻意的，不算滚动状态丢失。

> 若排序后看起来「顺序没变」，先确认偏好设置里的「点击表头时自动切到扁平列表」是**开启**的（默认开）：树形模式下 `visibleTree()` 只按层级对各层 `roots` / `kids` 排序，全局顺序被父子层级打散，视觉上不明显；关掉该开关时是有意为之的树内排序。

### 复制（⌘C）行为

| 当前焦点 / 状态 | ⌘C 复制什么 |
|---|---|
| 搜索框、偏好设置输入框、`field editor` 里**有选中文字** | 只复制选区（走系统 `copy:`） |
| 「命令行」页 / 性能监控诊断栏 `NSTextView` **有选中文字** | 只复制选区 |
| 上述只读文本视图**没有选中文字** | 复制该视图全部文本（完整命令行 / 整段逐通道诊断） |
| 详情表 / 窗口列表 / 主表**有选中行** | 这些行的全部列，列间 `\t`、行间 `\n`；主表按用户拖动后的列顺序输出 |
| 详情表 / 窗口列表**没有选中行** | 当前过滤后的全部行，首行带表头 |
| 以上都不适用 | 当前选中进程的 PID；连选中进程都没有则 `beep()` |

剪切 / 粘贴 / 全选 / 撤销 / 重做是 `target=nil` 的标准响应链动作，输入框、`NSTextView`、`NSTableView.selectAll:` 原生处理，无需响应者时菜单项自动灰掉。详情表是 cell-based，单元格文字本身不可拖选，所以「选中文字」与「选中行」两条路径互不干扰：前者优先由 `NSTextView` 消费，后者才轮到 `RowTextCopying`。

### 默认列宽方案

**目标**：首次启动不横向滚动就能看全主表所有列；多列详情页不再动辄上千 pt。数值都不写死在 AppKit 调用点，而是集中在 `makeColumns()` / `defaultWidths()` / `WindowListViewController.defaultWidths`。

**主表（14 列，合计 1218pt，窗口 1240pt）**

| 列 | 旧 | 新 | 列 | 旧 | 新 |
|---|---|---|---|---|---|
| 进程名称 | 230 | **176** | 状态 | 90 | **72** |
| PID / PPID | 70 / 70 | **52 / 52** | 架构 | 130 | **100** |
| TTY | 96 | **72** | CPU 时间 | 100 | **80** |
| 用户 | 90 | **68** | 启动时间 | 130 | **96** |
| % CPU | 80 | **60** | 完整命令 / 路径 | **420** | **210** |
| 内存 | 100 | **80** | 线程 / FD | 70 / 60 | **52 / 48** |

`name` 列变窄后，组合名（`WeChat (crashpad_handler)`）可能被截断，但之前已加的 tooltip 会给出完整名称 + raw 名 + 可执行路径；需要常看长命令时把 `cmd` 列拖宽即可（`minWidth` 42，随便拖）。

**详情表**：两列「项目 + 值」页（概览 / 环境变量 / 签名等）**保持 170 + 420 不变**，值列要放完整命令行和长路径。三列及以上改为按表头语义分配后归一化到 **820pt**（下部详情区约 860pt）：

- 数字 / 短代码列（含 `FD`、`PID`、`窗口号`、`层`、`大小`、`状态`、`句柄`、`标志`）→ 权重 84
- 长文本列（含 `路径`、`命令`、`值`、`说明`、`标题`、`镜像`、`映射`、`地址`、`补充`、`变量`、`位置`、`进程`、`时间`）→ 权重 190
- 其余 → 120；按 `820 / Σ权重` 缩放，单列 clamp 到 `[60, 300]`

于是 Pipe 对端 7 列从 **1440pt → ~820pt**、网络连接 6 列从 **1270pt → ~820pt**、窗口 6 列从 **1270pt → ~820pt**，都正好铺满详情区右侧而不溢出。窗口列表独立 6 列从 820 → **702pt**（默认窗口 900pt 宽）。

**持久化与迁移**（`ColumnWidthDefaults.swift`）：列宽按 identifier 存 `UserDefaults`，用户拖过的宽度优先于默认值——所以只改默认值对老用户无效。用一个 schema 版本号解决：

```
App 启动 → migrateIfNeeded()
  └ 版本 != 2 → clearSavedWidths()（清 Vantage.processColumnWidth.* 与
                 Vantage.detail.*.col*.width）→ 写入版本 2
  └ 版本 == 2 → 什么都不做，用户拖过的宽度完整保留
```

`Preferences.reset()` 不动这个版本号（列宽独立于偏好）。「**视图 → 重置列宽为默认**」调用 `ColumnWidthDefaults.reset()`：清值 + 写回当前版本 + 发 `.columnWidthsShouldReset`，主表 / 所有详情 Tab / 窗口列表同步重排，不动数据、排序、选中与滚动位置。刻意**不调** `sizeLastColumnToFit()`，否则宽窗口下 `cmd` 列又会被撑到几百 pt，等于回到原问题。

### 提示行隐藏（默认隐藏）

详情页里 C 层会追加一批说明性「提示」行 —— 界面里的 Mach 页就有 5 行（`Audit token 由 task_name_for_pid 取得…`、`task_for_pid 失败：SIP 开启时…` 等）。它们对排错有用，但平时把有效数据挤到下面，且第一列一律叫「提示」。

**做法**：不靠文字匹配，给这类行一个稳定的结构标记。

| 层 | 改动 |
|---|---|
| C | `lb_hint()` 输出 `__hint__\t<msg>`（原来是 `提示\t<msg>`）；另外 3 处直接拼 `"提示\t-\t-\t…"` 的多列行也换成同一个宏 `CPROC_HINT_TAG`。标记是 ASCII，不受界面语言影响 |
| Swift | `parse()` 先按**中文** `titles` 剥掉 C 层表头行，再逐行判断 `f.first == L10n.hintTag`：默认丢弃；打开开关时把第一列换成 `L("detail.hint2")`（中文 `提示` / 英文 `Hint`，走语义 key 而非文字硬编码） |
| 偏好 | 「通用 → 界面 → 在详情页显示提示行」，默认 **关**（`Vantage.pref.showDetailHints`）。勾选后立刻发 `.procDetailForceRefresh` 清缓存重采，当前页马上出现提示行 |

**不受影响**：`showHint(_:)` 的空状态占位（「未选择进程」「正在采集…」）和窗口列表的占位行是 Swift 侧 `setPairs` 生成的，没有 C 层标记，照常显示 —— 隐藏提示行不会让详情页变成一片空白。

### 国际化（i18n）

**目标**：中文 / English / 跟随系统，运行时切换、不需要重启。入口在「通用 → 界面 → 语言」。

#### 语义 key：中文是 value，不是 key

源码里**只写点分命名的语义 key**，中文和英文都放在 `.lproj` 的 value 里：

```swift
L("list.processName")                      // "进程名称" / "Process Name"
L("inspector.title", name, pid)            // "检查器 — {0} · PID {1}"
L(L10nKey.detailCmdHeader)                 // 等价写法，IDE 可补全
```

格式串用 **`{0}` `{1}` 占位**（`L(_ key: String, _ args: Any...)` 按序 `String(describing:)` 替换），不用 `%@` / `%d` —— 不依赖参数类型匹配，`Int32` / `String` / 自定义对象都不会崩，也不会因为 Swift 桥接产生 `Optional(...)` 之外的意外。

> 当前实现采用语义 key，虽然中文环境零回归，但它把 UI 文案变成了隐式协议 —— 一旦文案改一个字，所有引用它的源码、缓存的反查表、`.strings` 全部失效；而且动态句子只能靠「插值后的整句」查表，参数一变就静默回退中文。现在 key 稳定、文案可独立编辑，这才是 Apple `NSLocalizedString` 的常规口径。

#### 唯一数据源与产物

```
Tools/
├── l10n_master.py          ← 唯一人工维护：MASTER = { key: (zh, en) } + PHRASES
└── build_l10n.py            ← 生成器（从任意工作目录可跑）
Resources/
├── zh-Hans.lproj/Localizable.strings   "key" = "中文";
└── en.lproj/Localizable.strings        "key" = "English";
Sources/Vantage/
├── Localization.swift       L() / 语言偏好 / C 层文本 / relocalize
├── L10nTable.swift          内嵌 zh / en / phrases（生成，Bundle 读不到时兜底）
└── L10nKeys.swift           L10nKey 常量表（生成，强类型入口）
```

改文案：Swift UI 改 `l10n_master.py`，C 层运行时文本改 `c_en_override.py`，然后跑一次 `python3 Tools/build_l10n.py`（它会串起 `build_c_l10n.py`）。生成器会做四项校验，任一失败直接退出：key 格式合法、英文零中文残留、`{N}` 占位符在 zh/en 编号一致、源码里所有 `L("key")` 都在主表里；C 生成器额外校验 printf 占位符与「C 源码每个含中文字面量都被表覆盖」。实测 **632 条 Swift 主表 / 618 个源码 key / 624 处 `L()` 调用参数与占位符 100% 一致 / 550 条 C 双语表 / C 源码文案覆盖率 100%**。

`L10n.zh` / `L10n.en` 优先读 `.app/Contents/Resources/<lang>.lproj/Localizable.strings`（`Scripts/build_app.sh` 用 `cp -R Resources/*.lproj` 拷进去），**只读对应语言子目录**，绝不退化到无 subdirectory 的那个（否则 en 会被 zh 覆盖）。读不到就用编译进二进制的 `L10nTable` —— 所以 `swift run`、手工组装的 `.app`、外部编辑 `.strings` 三种情况都能工作。

#### 切换后怎么生效

`L()` 每次调用时读当前语言，新建 / 刷新的文字立刻变；已经显示的静态控件由 `.languageDidChange` 补齐：

1. `AppDelegate` 重建整个主菜单；
2. 遍历 `NSApp.windows`，把窗口标题、`NSButton` / `NSTextField` / `NSPopUpButton` / `NSSegmentedControl` 的文字和 `NSTableColumn` 表头就地转换；
3. 发 `.procDetailForceRefresh` 让详情页按新语言重采（C 层文本在 `parse()` 时翻译），再发 `.preferencesDidChange` 刷新主表 / 性能窗口；
4. 偏好窗口每次 `showWindow` 都会 `relocalizeSelf()`，静态标签重开即更新。

`convertDisplayed(_:)` 用合并两张表得到的 **值 → key** 反查：中→英、英→中都能转；只对「完整等于某个表值」的字符串动手，动态数值文本不会命中。同一中文值对应多个 key 时取其一，`string(key)` 结果一样。

#### C 层运行时文本：也是语义 key，不再按中文文本匹配

> C 层运行时拼接文本的本地化采用语义 key + 双语值表 —— 短语表覆盖不全，就出现界面里 `From systcl 风格的 csops(CS_OPS_STATUS)，no…` 这种中英混杂，而且**每页底部的 `合计` 行全是中文**。中文文本匹配本质上还是把中文当隐式协议，不符合「专门 key string」的要求。

现在 C 层的中文只是**中文 value 模板**，唯一标识是生成的 `c.f.*` / `c.r.*` 语义 key：

| 层 | 做法 |
|---|---|
| 数据源 | `Tools/c_en_override.py` 手写 141 条英文 + 复用 `l10n_master.py` 里已有的精确译文；`Tools/build_c_l10n.py` 扫描 `proc_detail.c` / `perf.c` 的全部中文字符串字面量（含相邻拼接），按 `\t` 拆成**字段**翻译，再自动合成**整行英文格式串**（printf 占位符数量/顺序逐一校验） |
| 产物 | `Sources/CProc/cproc_l10n_data.c/h`：`kFmt`（整行格式串）、`kField`（字段）、`kInline`（短词内联）三张表，每条带稳定语义 key |
| C 输出 | `lb_add` / `lb_addf` / `diag_add` / `APPEND` 查表生成中、英两版，每个含中文的字段输出成 `\x1eL:<key>\x1f<中文>\x1f<English>\x1e`（控制字符不会出现在真实数据里）。**Zero 改动 C 层几百处调用点** |
| Swift | `parse()` 里 `L10n.resolveCField(_:)` 按当前语言取一份；表头行用 `L10n.cFieldZh(_:)` 取「标记里的中文原文」与 `titles:` 协议比较；性能窗口整段文本用 `L10n.resolveCText(_:)` 正则替换 |

优先级刻意设计成：**整字段精确译文 > 英文格式串 > 短词内联兜底**。否则 `无` → `No` 这类单字替换会把 `无控制终端（守护进程 / GUI 应用常见）` 切成 `No控制终端…`（第一次模拟测试真的抓到了这个）。短词内联只用于修 `%s` 参数传入的 `可用` / `不可用` 等状态词。

`L10nTable.phrases` 仍保留作**极少数未打标运行时文本**的兜底，但已不再是主路径。实测 **C 表 550 条、C 源码含中文字面量覆盖率 100%、英文零中文残留、printf 占位符零不一致**；真实链路编译运行测试覆盖 `合计` 行、带变量的汇总列、`(匿名映射)`、TTY 描述、作业控制状态、性能状态栏，中英切换后均零中文残留。

`python3 Tools/build_l10n.py` 现在会**自动串起** `build_c_l10n.py`，一次跑完生成 `.lproj`、`L10nTable`、`L10nKeys` 和 `cproc_l10n_data.c`，不会漏。

#### 边界

- 菜单、窗口标题、Tab 名、14 个主表列头、详情表头、按钮、偏好设置全部文字、信号名称与说明、配色名、C 层详情数据行与 `合计` 行、性能状态栏与逐通道诊断：**100% 走语义 key + 双语值**，两种语言都有值。
- `titles:` 数组（与 C 层表头比较）和 `suggestedWidth` 的关键词数组**故意不包 `L()`**：前者保持中文协议常量、后者同时内置中英两套关键词，英文下列宽分配不会退化。`cFieldZh` 让表头剥离不受语言影响。
- `SignalGroup` 的 `rawValue` 是稳定的 ASCII key（`signal.group.control` 等），显示名走 `title → L(rawValue)` —— Swift 强制 enum raw value 必须是编译期字面量，不能写 `L(...)`。

## socket / pipe 解析与 SIP 采集

| 现象 | 根因 | 修正 |
|---|---|---|
| 「网络连接」页只有 `结果 / 合计 ... 共 0 个 socket` | `proc_pidfdinfo` 传 `sizeof(struct socket_fdinfo)` 而非 `PROC_PIDFDSOCKETINFO_SIZE`，SDK 结构与内核期望的 buffer 大小不一致时直接返回 0；且失败 FD 被 `continue` 吞掉，把「读取失败」误报成「没有连接」 | 按 `PROC_PIDFDSOCKETINFO_SIZE` 分配堆 buffer，用 `memcpy` 取回结构；显式统计 `socket FD / 成功解析 / 失败`，全部失败时输出 errno 与 SIP 提示 |
| socket 信息太单薄 | 只处理 AF_INET/AF_INET6 的 TCP/UDP，其他 family 直接丢弃；未看 `soi_kind` | 按 `soi_kind`（IN / TCP / UN / NDRV / KERN_EVENT / KERN_CTL）分流，TCP 状态取 `pri_tcp.tcpsi_state`；补充列给出 kind、type、protocol、PCB 地址、`soi_state`、队列长度；AF_UNIX / 路由 / kern control 等也如实列出 |
| 「打开文件」页里 PIPE / KQUEUE / SOCKET 全是 `(非文件描述符)` | 非 vnode 行没有给出任何可操作信息 | 按类型标注「协议/地址见网络连接页」「对端进程见文件监控页」等 |
| 想知道 pipe 的另一端是谁 | 只打印了 `pipe_handle` / `pipe_peerhandle` 两个内核地址 | xnu `fill_pipeinfo()` 里 `pipe_peerhandle` 是**对端** `struct pipe` 的地址，与对端进程某 FD 的 `pipe_handle` 相同。用 `proc_listpids(PROC_ALL_PIDS)` 遍历全系统，对每个 PIPE FD 调 `PROC_PIDFDPIPEINFO` 建 `handle → (pid, comm, fd)` 索引（2 秒缓存），即可反查对端进程；新增「Pipe 对端」页，「文件监控」页每行也直接标注 |
| 「镜像」页在 SIP 开启时永远显示「需要 root」 | 拿不到 task port 就直接返回；而 `task_for_pid` 对受保护进程与 root 无关地必然失败 | 改为 task port 只是加分项：拿不到或快路径失败时，用 `proc_pidinfo(PROC_PIDREGIONINFO)` 迭代 `pri_address + pri_size` + `proc_regionfilename()` 枚举映射（与 `vmmap` 相同的 libproc 路径，不需要 Mach API）；新增「内存映射」页展示全部 region |
| 「Mach」页拿不到 Audit Token | 只走 `task_for_pid` → `task_info` | 增加 `task_name_for_pid()` + `task_info(TASK_AUDIT_TOKEN)`（Apple DTS 推荐的任意进程方案，用 `dlsym` 动态解析避免 SDK 差异），以及 `syscall(SYS_csops, CS_OPS_STATUS)` 读取 CS flags / Team ID；并输出 SIP 限制的明确说明 |
| Tab 变多后被挤 | 详情区宽度固定 760 / 检查器 880 | 检查器 1140pt，主窗口详情分隔 880pt、统计区最小宽 160pt，13 个标签统一压到 2 字 |
| 想看进程的控制终端与会话信息 | 原来完全没有 TTY 数据 | 新增主表 `TTY` 列 + 「TTY」Tab：`e_tdev` → `/dev/ttysNNN`、PGID/TPGID/jobc、前台/后台、`PROC_TTY_ONLY` 同终端进程、FD 0/1/2 重定向、窗口大小与 termios（详见「TTY 解析」章节） |
| 性能面板比 macmon 少 CPU/GPU 温度、分簇频率、活跃占比、RAM/SWAP 百分比 | ① P-state 名不带 MHz（M5 是 `P1`/`P5`）→ 频率解析为 0，且频率与活跃占比绑在同一 valid 位导致两页一起空白；② `#KEY` 的 dataType 不一定是 `ui32` → SMC 键枚举失败，温度显示「不可用」；③ 只累加 Energy Model、CLPC 通道未分部件 → CPU 功耗偏低 | 频率改为按 pmgr 频率表**索引反查**并分 E/P/M 簇；活跃占比拆出独立有效位；`#KEY` 直接读大端 4 字节 + SMC 键缓存；新增 IOHID 温度兜底；功耗逐部件优先 CLPC 并放宽通道匹配；UI 补温度角标、均值/峰值、分簇卡片、RAM/SWAP 百分比、动态诊断 |
| 与参考工具对照时，以下数值差异需要解释：CPU 功耗 3.06W vs 1.32W、峰值 23.3W vs 2.68W、CPU 温度 51.8°C vs 30°C、RAM 94% vs 81.5%、E-CPU 513MHz vs 1713MHz、GPU 972MHz vs 338MHz | ① 订阅放宽到 5 个组 + `strstr` 宽泛匹配 → 命中 101 个「能量通道」，重复计数；② `a->gpu_freq += avg` 跨通道**累加**频率而非平均；③ `calc_freq` 的 `used=len(freqs)` 截断高频态 + `strstr("1-sram")` 误并多张 pmgr 表 + `all_freqs` 兜底混入 GPU 低频档；④ `mem_used` 含 `inactive` 且容量用 `10^9`；⑤ HID 温度用宽泛子串分类，且 `cpu_n==0` 时拿所有传感器最大值当 CPU 温度 | 订阅收回 3 组并按 macmon `ioreport_channels_filter` **精确过滤**；功耗只累加 Energy Model；GPU 频率与各通道活跃占比改**等权平均**；`calc_freq` 取全部频率态并优先从 state 名解析 MHz、pmgr 键名改精确后缀、去掉合并表兜底；内存去掉 `inactive`、容量改 `2^30`；温度按精确传感器名分类、去掉最大值兜底；新增**逐通道诊断**输出原始通道/传感器明细 |
| M5 上的诊断：功耗/RAM/Swap **已对齐**，但 `E=0档 P=0档 M=0档 GPU=12档`、E/P 频率 `0 MHz`、GPU 486MHz vs 338MHz、温度「不可用」、`[SMC] 枚举到 T* 键=0`、HID 全是 `PMU tdie*` 归类 0 | ① M4+ 的 pmgr CPU 表单位是 **kHz**，一律 `freq/1e6` 被 `mhz<100` 全过滤；② `str_ends(kbuf,"-1-sram")` 匹配不上真实的 `voltage-states1-sram`（结尾 `s1-sram`）；③ M5 用 `acc-clusters` 动态指定簇→表编号，1/5 硬编码失效；④ `calc_freq` 擅自「取全部频率态 + 索引拉伸」，GPU 偏高；⑤ `#KEY` 上限误设 **1024**，而真机约 3246，判失败导致 T 开头键枚举 0 个；⑥ M4/M5 的 IOHID 传感器是 PMU 系列，不是 M1 的 `pACC MTR Temp Sensor` | 频率表单位 Hz/kHz 自适应 + 从键名解析编号把所有表存入**表池** + 运行时按 P-state 频率态数量选表（ECPU 8 / PCPU 19）+ 频率值**不去重** + 恢复 macmon 的 `take(freqs.len())` 索引直接对应；`#KEY` 上限放到 65535、键缓存扩到 1024；HID 增加 `PMU tdie` 系列兜底并单列 `CPERF_TEMP_PMU` 标注「非核心热点」；诊断输出整张表池与 `#KEY` 总数；频率为 0 显示「— MHz」 |
| 数值口径对齐后：频率曲线图例显示 `E 1.3kMHz / P 4.0kMHz`；副标题写 `CPU 3962 MHz / 2 簇` 但 E 簇只有 1345 MHz；SMC 诊断只列出 `TCHP/TCMb/TDBP...` 看不到参与平均的 `Tp*/Tg*` 键 | ① 图例对 MHz 也套用了速率的 `%.1fk` 缩写，`fmt(3962)="4.0k"` 再拼单位变成 `4.0kMHz`（冗余且像 GHz）；② 副标题取 `max(e,p,m)` 当「CPU 频率」，把最高簇冒充整体 CPU；③ 诊断按枚举顺序只打前 16 个有效读数，全是未归类键；④ 隐藏隐患：`smc_temp_ok` 对任何有效 T 开头键都置位，若某机型全是 `TCHP` 这类非归类键，会既不显示 SMC 温度又阻止 IOHID 回退 | MHz 图例改显示整数 `1345 / 3962`；副标题改 `E 1345 / P 3962 MHz · 2 簇`；SMC 诊断优先打印归类键并加 `[CPU]` / `[GPU]` 标记，其余只补 4 个样本；`smc_temp_ok` 只在真的归类到 CPU/GPU 时置位 |
| 「打开文件」页几十行 `OTHER`，FD 号 `2097291936` / `4464054`，打开标志全 `－`，路径全是「非 vnode 描述符」 | `read_fds()` 把 `proc_pidinfo` 的返回值（**字节数**）当成 **fd 个数**：第一次调用拿到的已是所需字节数却又乘了 `sizeof(proc_fdinfo)` 分配（多 8 倍），第二次调用后 `*out_cnt = r` 未除以 8。于是 buffer 后 7/8 是 `malloc` 未初始化的堆内存，被当成有效 FD 逐条显示——`2097291936 = 0x7D0222A0` 正是堆地址低 32 位，`fdtype` 是垃圾值 → 全落进 `OTHER` | `bytes = needed + 32 项余量`、`*out_cnt = r / sizeof(struct proc_fdinfo)`，改 `calloc` 并加净化（fd ∈ [0, 2²⁰]、fdtype ∈ [1, 64]）；补全 `PROX_FDTYPE` 映射到 `ATALK/FSEVENTS/NETPOLICY/CHANNEL/NEXUS`，未知类型显示 `UNKNOWN(n)`；非 vnode 行给出具体内核对象说明而非占位文案；vnode 路径读取失败也列行（之前整行被吞导致合计对不上）；「文件监控」页也逐行列出这些类型 |

## FD 类型里的 `OTHER` 到底是什么

**`OTHER` 不是一种真实的 FD 类型**，它只是 `fd_type_name()` 的 `default` 分支——所有不在映射表里的 `proc_fdtype` 都被笼统叫成 OTHER。内核实际给的是 xnu `bsd/sys/proc_info.h` 里的一串编号：

| 值 | 宏 | 含义 | 有 vnode 路径？ |
|---|---|---|---|
| 1 | `PROX_FDTYPE_ATALK` | AppleTalk 套接字 | 否 |
| 2 | `PROX_FDTYPE_VNODE` | 磁盘文件 / 目录 / 设备 | **是** |
| 3 | `PROX_FDTYPE_SOCKET` | 网络或 Unix 域套接字 | 否 |
| 4 | `PROX_FDTYPE_PSHM` | POSIX 共享内存对象 | 否 |
| 5 | `PROX_FDTYPE_PSEM` | POSIX 信号量 | 否 |
| 6 | `PROX_FDTYPE_KQUEUE` | kqueue 事件队列 | 否 |
| 7 | `PROX_FDTYPE_PIPE` | 管道 | 否 |
| 8 | `PROX_FDTYPE_FSEVENTS` | FSEvents 文件系统事件监听 | 否 |
| 9 | `PROX_FDTYPE_NETPOLICY` | 网络策略描述符 | 否 |
| 10 | `PROX_FDTYPE_CHANNEL` | channel 描述符 | 否 |
| 11 | `PROX_FDTYPE_NEXUS` | Skywalk nexus 描述符 | 否 |

所以「打开文件」页里出现少量 PSHM / KQUEUE / FSEVENTS **完全正常**：它们本来就没有路径，只有 VNODE 能填「路径」和「打开标志」两列。现在这些类型会直接显示名字与一句说明，不再是几十行一模一样的「非 vnode 描述符，详见文件监控页」。

但界面里那批 OTHER 是另一回事——**绝大多数是假的**。判断依据有三个：

1. **FD 号不可能那么大**。macOS 单进程 fd 上限由 `kern.maxfilesperproc` 决定，通常 10240～65536，绝不会出现 `2097291936`（`0x7D0222A0`）。这个形态是用户态堆地址的低 32 位。
2. **打开标志全 `－`、路径全是同一句占位文案**。真实的非 vnode FD 至少类型会分散在 SOCKET / PIPE / KQUEUE / PSHM 之间，不会几十行清一色 OTHER。
3. **FD 号重复且相邻**（`2097291864` 出现两次、`2097291960` 两次），正是按 8 字节步长扫同一块堆内存的特征。

根因是 `proc_pidinfo(PROC_PIDLISTFDS, 0, NULL, 0)` 返回的已经是**所需 buffer 字节数**，而 `read_fds()` 又乘了一次 `sizeof(struct proc_fdinfo)` 去分配，第二次调用的返回值（仍是字节数）直接赋给 `out_cnt`。`lsof` 类工具的标准写法是 `count = returned_bytes / sizeof(struct proc_fdinfo)`。修复后列表只剩真实 fd，且额外加了范围净化，即使内核返回异常数据也不会再把堆地址显示成 FD。

> 参考：`proc_pidinfo` 两段式调用与 `PROC_PIDLISTFD_SIZE` 换算见 Palomino Labs 的 `get_process_handles` 实现；`libsigar` 的 `proc_fd_get_count()` 同样用 `pinfo_size / PROC_PIDLISTFD_SIZE`。完整 `PROX_FDTYPE_*` 枚举可见公开的 Swift `PROC_PIDLISTFDS` 示例。

| 选中部分 app（浏览器 / IDE / Electron）后详情面板「取样极其缓慢」，切换进程要等好几秒 | ① **不管看哪个页签，每次选中都把 12 页全量采一遍**：11 次 `ProcBridge.detail` + `taskPort` + `SecCodeCopySigningInformation`，在一个串行队列里全部跑完才更新 UI；② 「镜像」和「映射」各自做一次**完整 vm_map region 枚举**（每个 region 2 次系统调用，重 app 轻易上万条）；③ 「Pipe」和「监控」各自触发一次**全系统 pipe FD 扫描**（遍历所有进程的所有 FD）；④ 400 个 FD 的 socket 页逐 FD 调 `proc_pidfdinfo`；⑤ 签名校验要读整个可执行文件；⑥ 无缓存、不可取消，快速点选 N 个进程就排队跑 N 套；⑦ 主窗口 + 每个检查器窗口各有独立队列，多窗口并发还会同时争抢 C 层全局 pipe 索引 | 改为**按页惰性加载**（12 项 → 通常 1 项，概览/命令零调用）；所有窗口共用一条串行队列；新增 **epoch 取消标记**，C 层长循环（region 枚举 / 全系统 pipe 扫描 / FD 循环）每 16~32 次迭代检查一次，切换进程立即中止旧批次；按 `(pid, 页)` 分级缓存；region 枚举加 20000 上限并提示截断；pipe 索引「空结果」也进 2 秒缓存（若只在 `n>0` 时缓存会导致无 pipe 时每次都全系统空转）；切换进程用不改变列宽的占位行清掉旧数据；⌘R /「刷新」强制失效重采 |

## 详情采集为什么慢（以及和「被取样的 app 重」有多大关系）

**两者都有，但主因是架构，不是目标进程。** 旧实现选中任意进程时，会把 12 个页签的数据
一次性全采完才允许 UI 更新：

| 采集项 | 成本来源 | 重 app 放大多少 |
|---|---|---|
| 镜像 | 拿不到 task port（SIP 下常态）→ `PROC_PIDREGIONINFO` 迭代整个 vm_map | 每个 region 2 次系统调用；VSS 1.89 TB 的进程常有数千~上万条映射 |
| **映射** | **再做一次**同样的完整 region 枚举 | 上面那份成本再付一遍 |
| Pipe | `proc_listpids(PROC_ALL_PIDS)` → 对全系统每个进程的每个 PIPE FD 调 `PROC_PIDFDPIPEINFO` | 与目标进程大小无关，但系统进程越多越慢 |
| **监控** | **再触发一次**同样的全系统 pipe 扫描（2 秒缓存内可复用，但首次/过期就是两次） | 同上 |
| 网络 / 文件 | 对 400 个 FD 逐个 `proc_pidfdinfo` | 界面里 FD=400，线性放大 |
| 签名 | `SecCodeCheckValidity` + `SecCodeCopySigningInformation` 读整个可执行文件 | 几百 MB 的 app 比小工具明显慢 |
| TTY / Mach / 环境 / 命令 | 几次 sysctl / libproc 调用 | 基本可忽略 |

这些调用**串行**跑完才 `apply`，而且**没有缓存、不能取消**：快速点选 5 个进程，就要排队跑
5 套完整采集；主窗口 + 每个检查器窗口还各有自己的队列，多窗口会并发重建同一个 C 层
全局 `g_pipe_index`（没有并发保护）。所以「重 app」只是把最贵的几项放大，真正让体感变成
「卡住」的是「一次选中 = 12 页全量 + 不可中断 + 无缓存」。

### 现在的做法

1. **按页惰性加载**。选中进程立刻显示概览 / 命令（只用主表快照，零系统调用），
   其他页在**第一次切到该页时**才采。默认打开几乎不花钱；只有主动看「映射」页才会
   枚举 vm_map，看「Pipe」页才会全系统扫描。
2. **共享串行队列**。所有详情窗口共用一条队列，既避免多窗口同时全系统扫描，也避免
   并发访问 C 层全局 pipe 索引。
3. **可取消（epoch）**。Swift 每次开始新批次取一个 epoch 并取消旧 epoch；C 层的
   `enumerate_regions` / `pipe_index_build` / 各 FD 循环每 16~32 次迭代检查
   `cproc_detail_aborted()`，快速切换进程时旧批次从万次系统调用里立刻退出。
   epoch 绑在线程上，不同窗口互不干扰；被取消的半截结果既不写缓存也不更新 UI。
4. **分级缓存**。按 `(pid, 页)` 存结果：FD / socket / pipe / 监控 2 秒，TTY 5 秒，
   环境 / 镜像 / 映射 / 签名 / Mach 60 秒。⌘R 与「刷新」按钮会 `invalidate(pid:)` 强制重采。
5. **上限与空结果兜底**。region 枚举最多 20000 条并在页面提示截断；pipe 索引即使
   扫出 0 项也缓存 2 秒（若只在 `n>0` 时缓存，「系统里没有 pipe」时每次都会全系统空转）。
6. **切换进程不留旧数据**。用 `showPlaceholder` 保持列数与列宽，只替换成一行
   「切换到本页时加载…」，不会用 `setPairs` 把 4 列的页重建为 2 列而丢掉用户调过的列宽。

### 仍然会慢的场合（这是数据本身的成本，不是 bug）

- **第一次**切到「映射」或「镜像」页：一次真实的完整 vm_map 枚举；SIP 下镜像页走
  region 回退，比有 task port 时的 `TASK_DYLD_INFO` 快路径慢得多。
- **第一次**切到「Pipe」页且 2 秒缓存已过期：一次全系统 pipe FD 扫描。
- 对超大二进制**第一次**打开「签名」页：Security.framework 要读盘校验。

这三处都会显示「正在…」占位而不是冻结界面，且第二次打开同一进程直接命中缓存。

| 希望自己调 limits / 选项；表头点了「排序」却看不出全局顺序，TTY 列完全点不动 | ① 所有 limits 都是 C 宏 / Swift 常量硬编码，没有配置入口；② 树形模式下 `visibleTree()` 先按 sortKey 排序、再重新挂父子层级，全局顺序被树结构吃掉；③ `compare()` 的文本分支漏了 `.tty`，掉进 `numeric()` 返回 0，整列按 PID 排；④ 旧实现只有「换列设方向 / 同列 toggle」两态，没有「恢复树形」 | 新增 **⌘, 偏好设置窗口**（4 组、24 项，即时下发 + 恢复默认），C 侧新增 `cproc_limits_t` / `cproc_get_limits` / `cproc_set_limits`；表头改**三态循环**并在排序时自动切扁平列表，`compare()` 补 `.tty`，14 列全部有 SortKey；表头三角自绘，不依赖系统图片名；三态行为（自动扁平 / 三击回树 / 显示三角）本身也可在偏好里关掉 |

## 偏好设置（⌘,）

窗口改为 **三个页签**：

- **通用**：可滚动表单（采集上限、缓存、刷新、排序与行为）
- **样式**：已退出进程高亮 + 全部可定制配色
- **信号**：勾选哪些信号出现在「发送信号」菜单里 + 发送前确认策略

改动均**即时生效、无需重启**，底部「恢复默认」同时清掉通用选项、配色与信号勾选。数值在 Swift 侧与 C 侧各 clamp 一次，填 0 或超大值都不会把采集拖进死循环或 OOM。

> **页签切换用 `NSSegmentedControl` + 三个常驻 `NSScrollView`（切 `isHidden`），不碰 `NSTabView` / `NSTabViewItem`。** 主窗口详情 Tab 确实在 macOS 26 踩过 `A TabView managed by a TabViewController cannot have its delegate modified`；但偏好窗口那次无消息的 `SIGTRAP` **与 Tab 实现无关**，真正原因是 `reloadValues()` 字典字面量重复 key（详见本文「兼容性排查」章节与 docs/COMPATIBILITY.md）。这里保留 segmented + `isHidden` 只是因为它更简单：没有 delegate、没有 item 插入、没有 `selectTabViewItem(at:)` 的 index 同步，三个 pane 从窗口创建起就铺满同一个容器，`selectSignalTab()` 只改 `selectedSegment` + `isHidden`。

### 通用页

| 分组 | 项 | 默认 | 作用 |
|---|---|---|---|
| 采集上限（下发 C 层） | region 枚举上限 | 20000 条 | 「镜像 / 映射」页单次 VM region 迭代上限；调小可加快重 app |
| | pipe 索引缓存 | 2000 ms | 全系统 pipe FD 扫描结果的缓存时长 |
| | 命令行缓冲区 | 1024 KiB | `KERN_PROCARGS2` 缓冲区上限 |
| | FD 列表缓冲区 | 64 MiB | `PROC_PIDLISTFDS` 缓冲区上限 |
| | SMC #KEY 上限 | 65535 键 | SMC 键枚举上限（低于真机键数会导致温度读不到） |
| 详情与缓存 | 进程树最大深度 | 32 层 | PPID 成环时的递归保护 |
| | 历史曲线点数 | 120 点 | 列表底部曲线与性能窗口的采样点数 |
| | 动态页 / TTY / 静态页缓存 | 2 / 5 / 60 秒 | 详情按 `(pid, 页)` 缓存的三档 TTL |
| | sample 时长 | 3 秒 | `/usr/bin/sample` 的持续时间 |
| 刷新与默认视图 | 列表刷新 / 性能采样间隔 | 1 秒 / 1000 ms | 启动时的默认值 |
| | 默认过滤 / 树内排序键 / 方向 | 所有 / %CPU / 降序 | 启动时套用到主窗口 |
| | 启动时树形视图 | 开 | 关则默认扁平列表 |
| 进程名称显示 | 同时显示原始进程名 (raw) | **开** | 有 Bundle 且 raw 名与主名不同的进程，名称列追加可执行短名 |
| | argv[0] 名与 bin 不同时同时显示 | **开** | 名称列追加 argv[0] 的文件名，例如 `bash (sh)` |
| | 主名称用 Bundle 本地化显示名 | 关 | 读 `CFBundleDisplayName` / `CFBundleName`（如「微信」）；关则用 `.app` 目录名 |
| | raw 名格式 | 括号 `(raw)` | 另有中点 `· raw`、方括号 `[raw]`；argv[0] 单独出现时沿用，与 raw 并列时改用「以 X 调用」避免两个同款括号 |
| | 实时预览 | — | 主进程 / helper / argv[0] 不同 / 三者互不相同四个案例，改选项立刻变 |
| 排序与行为 | 点击表头自动切扁平列表 | 开 | 关则保留树内排序（旧行为） |
| | 同一列三击恢复树形 | 开 | 关则退化为「升序 / 降序」二态循环 |
| | 表头显示升降序三角 | 开 | 自绘图片 |
| | 详情页按页惰性加载 | 开 | 关则回到「一次选中采全部 13 页」，供对比 / 排错 |
| | App 启动即开始性能采样 | 开 | 关则只在第一次打开性能窗口时启动 |
| | ⌘R 同时清空详情缓存 | 开 | 关则 ⌘R 只刷新进程列表 |
| | 发送前确认 / 危险信号始终确认 | 开 / 开 | 已移到「信号」页，见下文 |
| 搜索 / 全局搜索 | 搜索使用正则表达式 | 关 | 主表 / 详情页 / 全局搜索共用；无效正则自动回退到字面量 |
| | 全局搜索包含重量级页 | 关 | 开则额外采「镜像 / Pipe 对端 / 内存映射」，进程多时明显变慢 |
| | 全局搜索行数上限 | 50000 行 | 1000–500000，超出截断并标注 |

C 侧实现：`cproc_config.c` 持有 `cproc_limits_t g_cproc_limits`，`proc_detail.c` / `proc_collect.c` / `perf.c` 直接读（对齐 32 位读写，允许「下一次采集生效」的最终一致，不为每个系统调用加锁）。偏好设置里每次改动调用 `cproc_set_limits` 下发并发出 `.preferencesDidChange`，各模块运行时读 `Preferences.shared`。

### 进程名称显示：应用名 vs 真实身份

**问题**：一个 `.app` 里往往有一堆 helper / XPC / Renderer。`ProcessSnapshot.bundlePath` 是从 `exepath` 反向找 `.app/` 得到的，所以它们和主进程共享同一个 Bundle，若不做区分，主表里全都显示成「WeChat」。例如某 App 的 helper 名称显示为 `WeChat`，点开检查器「命令」页才发现可执行文件其实是 `WeChat.app/Contents/Frameworks/crashpad_handler`（崩溃上报 helper）——**不点进去无法判断真实身份**。

**方案**：名称列在显示应用名的同时追加 **raw 名**（可执行文件的 basename），开关在「通用 → 进程名称显示」，默认**开**。另有独立开关把 **argv[0] 名**在它与 bin 不同时也追加进来（默认开）。

需要区分的是**四个可以互不相同的值**：`.app` 目录名、`Info.plist` 的
`CFBundleExecutable`、`proc_pidpath` 给的实际可执行文件 basename、以及
`KERN_PROCARGS2` 里的 `argv[0]`。典型叠加案例：`Visual Studio Code.app` 的目录名是
`Visual Studio Code`，声明与实际 exe 都是 `Electron`，而通过 symlink 调用时
`argv[0]` 可以是 `Code` —— **bundle 与 exe 不同名、exe 与 argv[0] 也不同名**。

```
WeChat                                ← 主进程，raw 与主名相同，不重复标注
WeChat (crashpad_handler)             ← helper，格式「括号」，默认
WeChat · crashpad_handler             ← 格式「中点」
WeChat [crashpad_handler]             ← 格式「方括号」
微信 (crashpad_handler)                ← 再打开「主名称用 Bundle 本地化显示名」
bash (sh)                              ← argv[0] 与 bin 不同，只有一段追加
Visual Studio Code (Electron) 以 Code 调用   ← 两段追加并列，第二个改用文字标签
```

两段追加并列时**不能共用同一种括号**：`Visual Studio Code (Electron) (Code)`
分不出哪个括注是真实文件、哪个只是调用名。所以 argv[0] 单独出现时沿用
`rawNameStyle`，与 raw 段同时出现时改成 `L("model.argv0Alias", …)`
（中文「以 X 调用」/ 英文「as X」）。偏好设置的实时预览里有四种组合可直接对照。

| 层 | 取值 | 说明 |
|---|---|---|
| `displayName` | `.app` 目录名 / BSD 短名 | 原有语义，图标缓存、树内排序仍用它 |
| `primaryDisplayName` | 可选本地化名 | 开启后读 `Info.plist` 的 `CFBundleDisplayName` → `CFBundleName`，失败回退 `displayName` |
| `bundleExecutableName` | `Info.plist` 的 `CFBundleExecutable` | bundle **声明**的主可执行文件名，独立 `NSCache` 缓存 |
| `isBundleMainExecutable` / `bundleRoleText` | `exepath` 是否落在 `<bundle>/Contents/MacOS/<declared>` | 区分主程序与 helper / 子组件；概览页显示 |
| `executableName` / `rawName` | `exepath` basename → `name` → `comm` | 优先可执行文件文件名，不受 `p_comm` 16 字符截断影响 |
| `argv0` / `argv0Name` | `KERN_PROCARGS2` 里原始 argv[0] / 其 basename | 由 C 层单独保留，不从已用空格拼接的 `cmdline` 反推 |
| `identitySummary` | 四个名字分行列出 | 名称列 tooltip，不靠括号猜身份 |
| `displayLabel` | 主名 + 可选 raw + 可选 argv[0] | 主表名称列、名称列复制、右键菜单标题、信号确认框、检查器窗口标题、概览页统一使用 |

**raw 只在满足全部条件时追加**：有 Bundle（`bundlePath != nil`）、开关开启、`rawName` 非空、raw 与主名 `localizedCaseInsensitiveCompare` 不同。所以 Safari 主进程仍是「Safari」，不会变成「Safari (Safari)」；没有 Bundle 的命令行进程也不受影响。

**argv[0] 段**与 Bundle 无关，判断依据是 `argv0Name` 是否等于真实可执行文件的 basename；同时排除与主名、raw 名重复。常见触发场景：`/bin/sh` 是 `/bin/bash` 的硬链接（`proc_pidpath` 给 `/bin/bash`，argv[0] 给 `/bin/sh`）、登录 shell 的 `-bash`、以及 `exec -a` 自定义调用名。因为 `cmdline` 是空格拼接后的字符串（参数含空格时无法还原），argv[0] 由 C 层在解析 `KERN_PROCARGS2` 时按已知长度单独复制进快照，用 accessor 传给 Swift。读不到 `KERN_PROCARGS2` 的进程（受保护 / 已退出）`argv0` 为空，这一段自然不显示。

```
bash (sh)                                    ← argv[0]=/bin/sh，规范 exe=/bin/bash
Visual Studio Code (Electron) 以 Code 调用     ← 三者互不相同：两段追加并列，第二改文字标签
Visual Studio Code (Electron) as Code         ← 英文界面同一行
```

**配套行为**：

- **搜索**：无论开关是否打开，过滤都覆盖应用名、本地化名、raw 名、argv[0]、
  `CFBundleExecutable`、实际 exe basename、BSD 短名与命令行 —— 直接搜
  `crashpad_handler`、`Electron` 或 `/bin/sh` 都能找到相关进程；全局搜索快照同样覆盖。
- **排序**：「进程名称」列按 `primaryDisplayName`（主名称）排，不算追加后缀，同 Bundle 的进程仍聚在一起；切换显示开关不会让顺序跳动。
- **截断**：列宽有限时名称列的 tooltip 始终给出完整组合名、四个身份字段、argv[0] 与可执行路径。
- **概览页**新增「原始进程名 (raw)」「argv[0]（调用名）」「Bundle」「Bundle 声明的可执行文件」
  「Bundle 内角色」五行，便于和主表对照。
- **本地化名解析** `AppNameResolver` 用两张 `NSCache` 按 bundle 路径分别缓存显示名与
  `CFBundleExecutable`（同一个 .app 下几十个 helper 只读一次 plist）；超长 plist 值截断，
  切换开关或「恢复默认」会清空两张缓存。

### 样式页：已退出进程高亮

| 项 | 默认 | 说明 |
|---|---|---|
| 高亮已退出的进程 | 开 | 关闭后进程退出即从列表移除，不进入宽限期 |
| 保留刷新次数 | **3** 次（0–20） | 按**刷新次数**而非秒数计数；1 秒刷新约可见 3 秒。填 0 等价于关闭保留 |

**语义**：`x = exitedKeepRefreshes`。进程从系统进程表消失的那一帧加入宽限期记录，`remaining = x`；之后每帧递减，减到 0 时移除 —— 从发现退出算起共显示 **x 帧**。所以调整刷新间隔时，可见时长会同比变化；改次数只影响之后新退出的进程，已经在宽限期里的记录不追溯延长。

实现刻意把两类数据分开：

- `ProcessStore.processes` **只含真正存活的进程** —— CPU 差分、系统统计、状态栏「N 个进程」、`process(withPID:)` 都只看它；
- `exiting: [pid: (snapshot, remaining)]` 单独保存退出瞬间的快照，仅在生成可见数据源时追加，并置 `isExited = true` / `cpuPercent = 0`。

这样退出行不会被当成活进程参与 CPU 时间差分或 PID 复用后的误算；若退出进程的父进程还活着，树形视图会自然把它挂回原父链，父也没了则成为根节点。PID 被立即复用时（同一 pid 又出现在新快照里）会直接从宽限期表移除。

**视觉标记**：名称前加 `✕`、状态列显示 `已退出·N`（N 是剩余刷新次数）、整行背景用 `exitedBackground`、文字用 `exitedText`。整行背景通过 `NSOutlineViewDelegate.outlineView(_:rowViewForItem:)` 返回自定义 `NSTableRowView`（`ExitedRowView`），其余行返回 nil 交给 AppKit，alternating row 与选中态保持系统行为。状态栏会追加「N 个已退出（高亮保留中）」。

### 样式页：配色定制

11 个可定制色，分三组，每项都能用系统取色器（`NSColorWell`）或直接输入 `#RRGGBB` / `#RRGGBBAA`：

| 组 | 键 | 应用位置 | 默认（系统动态色） |
|---|---|---|---|
| 状态与指标 | `cpuHigh` / `cpuMedium` | 主表 %CPU ≥80% / ≥40% | `systemRed` / `systemOrange` |
| | `stateRunning` / `stateStopped` / `stateZombie` | 主表「状态」列 | `systemGreen` / `systemOrange` / `secondaryLabelColor` |
| | `pidLink` | 详情表、窗口列表里可双击跳转的 PID 数值 | `linkColor` |
| 已退出进程 | `exitedText` / `exitedBackground` | 宽限期行的文字与整行背景 | `systemRed` / `systemRed @ 14%` |
| 系统曲线 | `chartUser` / `chartSystem` / `chartMemory` | 主窗口底部 CPU 用户 / CPU 系统 / 内存曲线 | `systemBlue` / `systemOrange` / `systemPurple` |

设计要点：

- **未自定义时返回系统动态色**，自动适配浅色 / 深色模式与「增加对比度」；用户一改就以 sRGB hex 存 `UserDefaults`，变成固定色。点单项 `↺` 或「恢复配色默认」可回到动态色。
- **5 个预设**：系统默认 / 高对比 / 暖色 / 冷色 / 单色蓝；逐项改色后自动切到「自定义」。预设本质是一次性写入整组 hex。
- 样式页底部有**实时预览条**，用当前 `exitedText` / `exitedBackground` 渲染一行「✕ 已退出进程示例」。
- 颜色改动发 `.appColorsDidChange`：主表 reload（保留滚动与列宽）、详情表 / 窗口列表 reload、底部曲线重绘；通用页数值/开关改动走 `.preferencesDidChange`。

> 性能监控窗口的图表色（IOReport 曲线、仪表盘角标）暂未纳入定制，样式页只覆盖上表所列位置。

## 进程右键菜单与信号

### 右键菜单

主表右键菜单改为**每次弹出前动态构建**（`NSMenuDelegate.menuNeedsUpdate`）：

```
<进程名> · PID 1234            （灰色标题行）
─────────
打开检查器…
通过窗口定位此进程…
─────────
退出进程 (SIGTERM)            ← 快捷项，保留原有行为
强制退出 (SIGKILL)
暂停 / 继续
发送信号 ▸                    ← 按下面偏好勾选，分组显示
─────────
在 Finder 中显示
采样 N 秒…（N 取偏好里的 sample 时长）
─────────
复制 PID / 复制完整命令行 / 复制可执行文件路径
─────────
配置菜单信号…                  ← 直接跳到偏好设置「信号」页
```

关键实现：`ProcOutlineView.rightMouseDown` 会记录**右键那一行**的 PID / 名称 / 是否已退出，菜单项通过 `SignalMenuPayload` 直接携带它，不依赖「当前选中行」——避免刷新、多选或键盘呼出菜单时把信号发错进程。快捷项仍走 `AppContext.selectedProcess()`（右键会同步选中该行）。目标不存在或处于退出宽限期时，所有会发信号的项自动禁用。标题行也显示 PID，方便确认目标。

主菜单「进程」里也加了同样的 **发送信号 ▸** 子菜单（`SignalMenuUpdater` 在每次展开时按最新偏好重建），pid 传 0 表示取当前选中进程。

### 信号目录

`SignalCatalog.swift` 收录 **31 个** Darwin 信号，编号直接写固定数值（不引用 `SIGEMT` / `SIGINFO` 这类在不同 SDK 里时有时无的常量名），分 4 组：

| 组 | 代表信号 |
|---|---|
| 终止 / 控制 | SIGHUP / SIGINT / SIGQUIT / SIGKILL / SIGTERM / SIGSTOP / SIGTSTP / SIGCONT / SIGTTIN / SIGTTOU |
| 通知 / 自定义 | SIGWINCH / SIGINFO / SIGUSR1 / SIGUSR2 |
| 故障 / 崩溃 | SIGILL / SIGTRAP / SIGABRT / SIGEMT / SIGFPE / SIGBUS / SIGSEGV / SIGSYS |
| 其它 | SIGPIPE / SIGALRM / SIGURG / SIGCHLD / SIGIO / SIGXCPU / SIGXFSZ / SIGVTALRM / SIGPROF |

每项带中文说明、分组与严重度（`.destructive` / `.control` / `.harmless`），带 ⚠ 的是默认动作会终止或崩溃进程的信号。

### 偏好设置「信号」页

- 31 行 checkbox，按分组列出「名称 (编号) + 说明 + 严重度标注」
- 批量按钮：**全选 / 仅常用（默认）/ 全不选**，实时显示「已选 N / 31」
- **默认勾选 12 个**：`SIGHUP, SIGINT, SIGQUIT, SIGKILL, SIGTERM, SIGSTOP, SIGTSTP, SIGCONT, SIGWINCH, SIGINFO, SIGUSR1, SIGUSR2`
- 勾选结果存 `visibleSignals`（信号编号数组）；**空数组是合法值**（全部不显示），用 `array(forKey:) == nil` 区分「没设过」与「清空」，所以「全不选」不会被当默认值恢复
- 菜单是**惰性读取**偏好的，勾选后下次展开立即生效，不需要重启，也不会触发进程列表刷新

### 发送与确认

所有信号统一走 `AppContext.sendSignal(_:to:processName:)` → `ProcBridge.signal` → C 层 `kill(2)`，成功后立即刷新进程列表；失败显示 `strerror(errno)`（ESRCH / EPERM 等）。

| 开关 | 默认 | 行为 |
|---|---|---|
| 发送任何信号前确认 | 开 | 所有信号都弹确认，含 SIGUSR1 / SIGINFO 这类通知信号 |
| 危险信号始终确认 | 开 | 即使关掉上面的总开关，带 ⚠ 的终止 / 崩溃类信号仍强制确认，避免误点杀死进程 |

确认框按严重度用 `.critical` / `.warning` 样式，并写清目标 PID、信号含义和后果（不可捕获 / 数据可能来不及保存 / 改变运行状态 / 通知类通常被忽略）。`terminate(force:)` 与 `toggleSuspend()` 也复用同一个入口，行为保持一致。

## 表头排序：三态循环

```
单击某列         → 按该列排序 + 自动切扁平列表 + 表头三角（数值列默认降序、文本列默认升序）
再单击同一列     → 反序
再单击同一列     → 恢复树形视图、清掉三角、排序键复位为偏好里的默认树内排序
点击另一列       → 从第一态重新开始
```

**为什么以前「点了没反应」**（两层原因，都已修）：

1. **回调根本没被调用**（决定性）：`NSOutlineView` 的 delegate 是 `NSOutlineViewDelegate`，它为表头点击定义了自己的 `outlineView(_:didClick:)`（ObjC `outlineView:didClickTableColumn:`）。AppKit 只发这个消息，不回退到 `NSTableViewDelegate` 的 `tableView(_:didClick:)`。旧代码只实现了后者，等于没写。[citation:2] 现在两个入口都汇到 `handleHeaderClick(_:)`；`allowsColumnReordering` 也保持开启，否则 AppKit 不派发表头点击 delegate。[citation:3]
2. **树形模式看不出全局顺序**：`visibleTree()` 先按 `sortKey` 排序，再按 PPID 挂父子层级，排序只作用在根节点和同层子节点上。现在点表头自动切到扁平列表（偏好里可关）。另外 `compare()` 文本分支漏了 `.tty`，导致 TTY 列掉进 `numeric()` 恒返回 0、整列按 PID 排——已补上，14 列现在全部有对应的 `SortKey` 且都能生效。

`scrollToTopOnNextReload = true` 必须在 `applySort` **之前**设置：`applySort` 内部同步 post `.procStoreDidUpdate` → `reload()` 当场消费标记，事后设不生效。

`applySort` 把 `sortKey / ascending / sortPhase / sortIndicatorKey / treeMode` 一次性提交，抑制期间只发一次通知 → 一次 `reloadData`，不会因多个 `didSet` 重复刷新、打断列宽与滚动。手动点「树形 / 列表」按钮或菜单时 `treeMode` 的 `didSet` 会自动重置排序循环并清掉表头三角。

## 通过窗口定位进程（参考 Windows SystemInformer）

对应 SystemInformer 的 *Find window's process* / *Window list*。两种入口都在「进程」和「窗口」菜单里：

| 入口 | 快捷键 / 位置 | 行为 |
|---|---|---|
| **通过窗口定位进程…** | ⌘⌥L，进程菜单 | 直接进**准星模式**：隐藏本 App 窗口 → 鼠标移动时把指针下最前面的普通窗口用蓝色边框高亮，左上角浮层实时显示 owner 进程名与 PID → 单击选定 → 定位到该进程 |
| **窗口列表…** | 进程 / 窗口菜单 | 列出所有屏幕窗口（标题、进程名、PID、层、位置尺寸、窗口号），支持过滤、双击行或点「定位到进程」；窗口里也有「准星选取…」按钮 |
| **主窗口** | ⌘0，窗口菜单 | 把主窗口找回并激活（同时校正跑到屏幕外的 frame） |

### 数据源与权限

`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` 返回的数组**顺序就是 z-order（前 → 后）**，每项带 `kCGWindowOwnerPID` / `kCGWindowOwnerName` / `kCGWindowBounds` / `kCGWindowLayer` / `kCGWindowNumber`。取第一个 `layer == 0` 且 bounds 包含鼠标点的窗口即可。

- **ownerPID / ownerName / bounds / layer 不需要任何授权**——即使完全没给权限，准星选取与 PID 定位照样工作。
- `kCGWindowName`（窗口标题）在 macOS 10.15+ 需要「屏幕录制」授权。未授权时标题显示「（标题需屏幕录制授权）」，窗口列表里提供「授权窗口标题…」按钮调 `CGRequestScreenCaptureAccess()`。
- 坐标转换：`NSEvent.mouseLocation` 是 NS 全局坐标（主屏左下原点，y 向上），CG 窗口坐标原点在主屏左上（y 向下），用 `CGDisplayBounds(CGMainDisplayID()).height - nsY` 互转。
- 准星用 `NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown])` + local monitor，Esc 或浮层「取消」退出；鼠标移动高频调用做了 0.4 秒窗口列表缓存。若某些系统限制全局事件监听，**窗口列表**这条路径完全不依赖事件监听，仍可定位。

### 定位动作做了什么

`AppContext.locateProcess(pid)`：清掉搜索与非 `.all` 的过滤条件 → 恢复并激活主窗口 → `ProcessListViewController.selectPID(pid)` 在树里找从根到目标的**整条父链并逐级展开**（否则深层子节点的行根本不存在），选中并 `scrollRowToVisible` → 打开 / 激活该 PID 的检查器。若进程不在当前快照（例如刚启动），会注册一次性 `.procStoreDidUpdate` 观察等下次刷新后重试，带 6 秒超时兜底。

### 详情「窗口（Windows）」Tab：列出当前进程的窗口

准星 / 窗口列表是「**从窗口反查进程**」；这个 Tab 反过来，是「**从进程看它有哪些窗口**」，对应 SystemInformer 的进程属性里窗口列表的概念。

| 列 | 数据来源 | 是否需授权 |
|---|---|---|
| 窗口号 | `kCGWindowNumber` | 否 |
| 标题 | `kCGWindowName` | **需要「屏幕录制」**；未授权显示「（标题需屏幕录制授权）· 进程名」 |
| 层 | `kCGWindowLayer`（0 = 普通窗口，也列出状态栏 / 弹出层等非零层） | 否 |
| 位置 / 尺寸 | `kCGWindowBounds`（CG 全局坐标，主屏左上原点） | 否 |
| 屏幕状态 | `kCGWindowIsOnscreen` + 与 `optionOnScreenOnly` 结果交叉验证，附 Z 序（返回顺序即前 → 后） | 否 |
| 共享 / Alpha | `kCGWindowSharingState`（不共享 / 只读 / 可读写）、`kCGWindowAlpha` | 否 |

实现要点：

- 用 **`.optionAll`** 而不是 `optionOnScreenOnly`：这样最小化、其他 Space、隐藏的窗口也会列出，并标注「不在屏幕」。一次 `optionOnScreenOnly` 枚举只用来拿"屏幕上的窗口号集合"做交叉验证（`kCGWindowIsOnscreen` 字段在部分系统版本缺失）。
- 按 `kCGWindowOwnerPID == pid` 过滤，**保留 `CGWindowListCopyWindowInfo` 的原始顺序**（z-order 前 → 后），所以「屏幕上（Z 序 N）」能直接反映叠放次序。
- 纯 CG API，**可以跑在 `DetailLoadQueue` 后台串行队列里**：不访问 `WindowLocator.onScreenWindows` 的缓存（准星在主线程高频刷新它，缓存已用 `NSLock` 保护），也不调 `CGPreflightScreenCaptureAccess` / `NSScreen` / `NSEvent` 这类主线程 API。
- 走与其它页相同的惰性加载链路：`items(for: 9)` → `.lines([String])` → `parse()` 按 `\t` 拆列 → `setRows()`。缓存归**动态档**（`dynamicTTL`，默认 2 秒），因为窗口会随时开关；`⌘R` 强制失效。
- 末尾几行摘要：`Owner PID <pid>`（双击数值可定位到本进程，检查器单实例会激活自身）、权限提示与操作提示。窗口号 / 层 / 位置等数字**不会**被 PID 跳转误命中——表头不含 `PID`，且解析要求数字开头。
- 无窗口时显示「该进程当前没有可枚举的窗口（纯后台 / 命令行进程，或窗口尚未创建）」，而不是空表。
- **双击窗口条目（或 ⌘ / ⌥ + 单击）→ 把那一个具体窗口前置激活**，见下节。

Tab 顺序变为 13 个，`items(for:)` / `applyLines` 的 case 编号、`(0...11)` 全量采集范围、`clearStalePages` / `showEmpty` / `showLoading` 的 VC 列表同步调整；检查器窗口加宽到 1140pt、主窗口详情分隔调到 880pt，避免 segmented control 截掉末尾标签。授权入口复用「窗口列表」窗口里的「授权窗口标题…」按钮。

## 激活指定窗口 & 修饰键单击

### 三条交互规则

| 位置 | 双击 | **⌘ / ⌥ + 单击** |
|---|---|---|
| 检查器「窗口」页的窗口条目 | 激活该窗口 | 激活该窗口（**相同**） |
| 全局「窗口列表」的一行 | **定位到拥有该窗口的进程**（原有行为，不变） | **激活该窗口**（唯一「两者不同」的地方） |
| 其它所有支持双击的表格（主表、详情各页、文件页跨页跳转等） | 原动作 | **与双击完全相同** |

也就是说：**除「窗口列表」外，凡是双击能做的事，⌘ / ⌥ + 单击都能做**。表格 tooltip 与状态栏都写明了规则。修饰键取 `⌘` 或 `⌥` 任一，不用 Control / Shift，避免与右键菜单和范围选择冲突。

### 实现方式

`ModifierClick.swift` 提供 `ActionTableView`（NSTableView）与主表 `ProcOutlineView`（NSOutlineView）共用的 `ModifierClickGate`：在 `mouseDown(with:)` 里检测 `clickCount == 1` + 修饰键 + 命中行，先 `super.mouseDown` 保持 AppKit 选择行为，再显式 `selectRowIndexes` 并调 `onModifierClick(row, col)`。`clickGate.consumeRecent()` 在 `doubleAction` 开头吞掉「⌘+快速点两下」产生的重复执行（0.5 秒窗口）。

各 VC 把双击逻辑抽成 `performDoubleAction` / `performRowAction`，由 `doubleAction` 与 `onModifierClick` 共用同一入口，保证两者效果严格一致。「窗口列表」是唯一把两者绑到不同方法的地方：`doubleClicked()` → `locateProcess(pid)`，`onModifierClick` → `activateWindow(at:)`。另外补了「激活窗口」按钮作为可发现入口。

### 怎么把「某一个」窗口激活

`CGWindowListCopyWindowInfo` 只给 `kCGWindowNumber` 和 owner PID，没有激活接口。`WindowActivator.swift` 走 Accessibility：

1. `AXIsProcessTrusted()` 检查**辅助功能**授权；未授权弹提示，可直接跳转「系统设置 → 隐私与安全性 → 辅助功能」。这与窗口标题所需的**屏幕录制**是两项独立授权，互不影响。
2. `AXUIElementCreateApplication(pid)` → `kAXWindowsAttribute` 拿到该 App 的 AX 窗口数组。
3. `CGWindowID ↔ AXUIElement` 用 `_AXUIElementGetWindow`（HIServices 私有 SPI）精确匹配；符号全部 `dlopen` + `dlsym` 运行时解析，**不做链接期依赖**。拿不到时退回按 `kAXPositionAttribute` / `kAXSizeAttribute`（+ 标题，若已授权）匹配 `CGWindowBounds`。
4. 最小化窗口先写 `kAXMinimizedAttribute = false`；然后 `NSRunningApplication.activate(options: [])` + `kAXFrontmostAttribute` 把 App 前置，再对**这一个**窗口 `kAXRaiseAction`、写 `kAXMainAttribute` / 应用的 `kAXFocusedWindowAttribute`。

`WindowLocator.windowInfo(number:)` 新增按窗口号从 `.optionAll` 反查 bounds/title，供第 3 步兜底。失败分成 `needsAccessibility` / `windowNotFound` / `failed` 三类，各自给出明确提示（窗口已关闭、系统 UI 窗口、App 未向 AX 暴露窗口等），不会静默无反应。

> `Packaging/Info.plist` 加了 `NSAccessibilityUsageDescription`，`Package.swift` 显式链接 `ApplicationServices`。

## 双击 PID 数值 & 检查器单实例

**双击 PID 值**：详情表里凡是能解析出 PID 的单元格都会显示成蓝色（链接色）并带 tooltip，双击即 `locateProcess(pid)`。覆盖：

- Pipe 页的「对端 PID」列（列头含 `PID`）
- 概览 / TTY / Mach 页里「项目 = PID，值 = 1234」或 `PID: 1234` 形式的行
- 主表的 PID / PPID 列（双击数值格打开那个 PID，双击其他列仍是打开当前选中进程）

**「监控」页整页禁用 PID 链接**（`pidLinksEnabled = false`）：它只是 FD 类型汇总，对端进程请去专门的 Pipe 页看。此外 `pidValue()` 改成**列头白名单**——只有表头含 `pid` / `说明` / `对端` / `项目` / `值` 的列参与解析，FD / 类型 / 句柄 / 位置 / 窗口号 / 层 / 地址 / 路径等一律排除。这样 pipe 行的说明列写了「对端 PID 42826」，同行的 FD `9` 也不会再被染成蓝色、双击跳到 PID 9。解析本身也只认**数字开头**的连续 ASCII 数字且 `0 < pid ≤ 999999`。列被重排时按 `NSTableColumn.identifier`（`dcolN`）反查真实列号。

**一个 PID 只有一个检查器窗口**：`AppContext.showInspector(for:)` 先按 `pid` 查 `inspectors`，命中就走 `activateInspector(_:)` 激活而不是新建。激活链路比单纯 `showWindow` 更完整：`deminiaturize` → `showWindow` → `makeKeyAndOrderFront` → `orderFrontRegardless` → `AppActivate.front()`，能处理最小化、被遮挡、在其他 Space 的情况。窗口关闭时 `windowWillClose` 调 `closeInspector` 从数组移除，之后同一 PID 才会重新创建。顺手统一了 App 激活：macOS 14+ 用 `NSApp.activate()`，更早系统用 `activate(ignoringOtherApps:)`，避免 deprecated 警告。

## NSTabView delegate 约束

这是崩溃报告（`EXC_CRASH (SIGABRT)` / `NSInternalInconsistencyException`）里的那条异常，也是「主窗口打不开 + ⌘0 闪退」的真正根因。

### 为什么

`NSTabViewController` 在 `loadView` 时把自己设为内部 `NSTabView` 的 delegate，负责 segmented control、`selectedTabViewItemIndex`、选中 item 与 child view controller 之间的同步。macOS 26 的 AppKit 在 `-[NSTabView setDelegate:]` 里加了一致性检查：**只要这个 tabView 归某个 TabViewController 管，任何 `setDelegate:` 调用都直接抛异常**，连设成同一个对象也不行。

旧代码为了在切页签时触发「按页惰性加载」，塞了一个独立的 `TabSelectProxy` 进去：

```swift
tabView.delegate = proxy   // ← 抛 NSInternalInconsistencyException
```

它在 `DetailTabViewController.viewDidLoad()` 里，而这个类被两处使用：

1. **主窗口**：`innerSplit` 里的「详情 Tab」→ 窗口显示时加载内容视图 → 异常 → 内容加载失败，表现为「主窗口打不开」；
2. **检查器窗口**：`InspectorWindowController.init` 的 `window.contentViewController = t` → `NSWindow setContentViewController:` 包在 `NSPerformVisuallyAtomicChange` 里，异常被 `objc_exception_rethrow` 重新抛出 → `abort()`。崩溃栈里 `locateProcess → showInspector` 只是触发点，不是原因。

「性能监控」「偏好设置」窗口不含这个 Tab VC，所以能正常打开——这正是最容易误导判断的地方。

### 改法：只观察，不改 delegate

delegate 完全交回 AppKit 原生实现。Apple 文档明确 `NSTabViewController` 自己就是 tabView 的 delegate，「你不得直接修改标签页视图的项或更改其委托」；同时 `NSTabViewController.tabView(_:didSelect:)` 是**可以 override 的**，文档要求「若 override，实现中必须调用 `super`」。[citation:2][citation:8] 自 10.13 起，改由 controller 管理的 `NSWindow` / `NSTabView` / `NSSplitView` 的 delegate 都会 assert。[citation:3]

| 路径 | 作用 |
|---|---|
| `override func tabView(_:didSelect:)` → `super.tabView(...)` → `syncTabSelection(item)` | 主路径，官方推荐。先用传入的 `NSTabViewItem` 直接算 index，最准 |
| `NSTabViewDidSelectTabViewItemNotification`（`object: nil`） | 备用。通知名用 `Notification.Name("...")` 字符串构造，不依赖 `NSTabView.didSelectTabViewItemNotification` 这个 Swift 常量在不同 SDK 的拼写；sender 类型差异也不会漏掉 |
| `override func viewDidLayout()` | 兜底：AppKit 内部若直接改 ivar 绕过通知 / setter，布局时仍能读到最新的 `selectedTabViewItemIndex` |

三条都汇到 `syncTabSelection()` → 算 index → `selectTab(idx)`。`selectTab` 里 `index != selectedTabIndex` 去重，所以多次触发不会重复 `reload()`，也不会递归。通知用 block-based observer，`deinit` 里按 token 移除。

> 通用结论：**不要给 `NSTabViewController` 管理的 `NSTabView` 设 delegate**。需要感知切换，正确做法是 override `tabView(_:didSelect:)` 并调用 `super`，而不是塞一个第三方代理进去。

顺带把 `AppContext.locateProcess` 里「通知回调中同步创建检查器窗口」改成 `showInspectorDeferred`，下一个 main queue 圈再建窗口：`setContentViewController:` 会一次性加载 13 个 Tab 的 view，放在通知派发栈里既重，又容易被 AppKit 的 visually-atomic 事务放大成崩溃。

## 「文件」页双击跨页跳转并定位到该 FD

「文件」页列出的是 `PROC_PIDLISTFDS` 的全部 FD，但它只给路径；要看 PIPE 的对端、socket 的连接、TTY 的属性、kqueue 的状态，得切到别的页再手工找同一个 FD。现在**双击任意一行**直接跳到对应页并选中该 FD 那一行：

| 该行类型（「类型」列 / 路径） | 目标页 | 定位键 |
|---|---|---|
| `SOCKET` | **网络** | 第一列 FD 精确匹配 |
| `PIPE` | **Pipe** | 第一列 FD 精确匹配 |
| 路径含 `/dev/tty*` / `ttys*` / `pty*` | **TTY** | 设备名（如 `ttys001`），备选 `FD N` 匹配「标准输入 FD 0」这类行 |
| `KQUEUE` / `PSHM` / `FSEVENTS` / `NETPOLICY` / `VNODE` / 其它 | **监控** | 第一列 FD 精确匹配 |

实现要点：

- `DetailTableViewController` 新增 `doubleClickHandler`，返回 `true` 即消费双击、不再走默认 PID 跳转；「文件」页由 `DetailTabViewController.jumpFromFiles(_:)` 接管。
- 目标页是**惰性加载**的，双击时它可能还停在占位行，所以不立即定位：先把 `PendingLocate(tab, fd, keys)` 存起来，同步更新 `selectedTabIndex` + `selectedTabViewItemIndex` 触发切页与 `reload()`，等 `apply()` 把数据填完再 `flushPendingLocate()`。定位再延迟一个 main queue 圈，等 AppKit 完成页签切换与布局，否则 `scrollRowToVisible` 会被忽略。
- `clearFilterAndLocate(fd:textKeys:)` 会**先清空目标页的过滤框**（旧过滤可能把目标行藏起来），再按第一列 FD 精确匹配 → 备选关键字模糊匹配 → `selectRowIndexes` + `scrollRowToVisible` + `makeFirstResponder`。实在找不到（例如 socket 刚关闭）就把过滤框设成 FD 号兜底。
- 换进程时清掉 `pendingLocate`，避免上一个进程的定位落到新进程的数据上。
- **C 层配套**：`cproc_monitoring` 原来对 `PROX_FDTYPE_VNODE` 只计数不列行，导致「文件」页双击一个普通文件 FD 跳到「监控」页后找不到条目。现在补一行 `FD / VNODE / - / 普通文件 / 目录（完整路径见「文件」页）`，只给 FD 号与类型、不额外读路径，避免为几百个文件 FD 再做几百次 `proc_pidfdinfo`。`SOCKET` 仍不列（网络页已有），`PIPE` 两边都有。

表格 tooltip 写明了映射规则；Pipe 页的「对端 PID」列仍保留蓝色链接，可继续双击跳到对端进程。