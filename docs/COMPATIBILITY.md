# Vantage — SDK 兼容性与已知限制

> 本文按**主题**整理在 macOS 26.5 SDK / Xcode 26 上需要注意的接口差异、约束与
> 运行时限制，供在本机 SDK 上构建或改动代码时查阅。
>
> 功能与实现原理见 [IMPLEMENTATION.md](IMPLEMENTATION.md)；面向用户的说明见
> [README](../README.md)。

---

## C 层构建约束

| 约束 | 做法 |
|---|---|
| `PROC_FLAG_TRANSLATED` 等宏并非所有 SDK 都导出 | `proc_collect.c` / `proc_detail.c` 各有一套 `#ifndef PROC_FLAG_*` 兜底；`flagdefs` 显式声明为 `flagdefs[CPROC_NFLAGS]`，循环用常量而非 `sizeof` 推断 |
| `kill(2)` 需要显式声明 | 相关文件包含 `<signal.h>`；C99 起不允许隐式函数声明 |
| `syscall(SYS_csops, …)` 的弃用警告 | `csops` 没有公开包装函数，Apple 也未给 `CS_OPS_*` 替代 API（警告建议的 `kdebug_signpost()` 只对应 `SYS_kdebug_trace`）。在 `#ifdef SYS_csops` 块内用 `clang diagnostic push / pop` 局部关掉 `-Wdeprecated-declarations`，不扩大到文件其它部分 |
| `PROC_PID*INFO` 缓冲区 | 一律按 `PROC_PID*INFO_SIZE` 宏分配并用 `memcpy` 取字段，规避不同 SDK 的结构体字段名 / 布局差异 |
| IPv4 地址 | 位于 `in_addr_4in6` 的**末 4 字节**，用 `memcpy` 取字节，不能取前 4 字节 |
| IOKit 的两个独立变化 | ① `kIOMainPortDefault` 是 macOS 12 引入的 `const mach_port_t` **变量**，不是宏，`#ifndef` 探测会恒成立并退回已弃用的 `kIOMasterPortDefault`，因此用 `__MAC_OS_X_VERSION_MAX_ALLOWED < 120000` 分支。② `IORegistryEntryCopyFromPath` 的 path 形参**自 10.11 引入起就是 `CFStringRef`**，与 12.0 无关；接受 `io_string_t` 的老函数是 `IORegistryEntryFromPath`（无 `Copy`，返回值同样需 `IOObjectRelease`）。`ioreg.c` 统一造 `CFString` 并 `CFRelease`，不保留 `io_string_t` 分支 |
| 公开头 | `Sources/CProc/include/` 只放 `CProc.h`（umbrella，已显式包含 `CPerf.h`）与 `CPerf.h`。内部头（如 `cproc_l10n_data.h`）放在 `Sources/CProc/` 私有目录，否则 SwiftPM 会报 `umbrella header ... does not include header` |
| Swift 调用 C 符号 | 凡直接用到 `cproc_*` 或 C 结构体的 Swift 文件都必须 `import CProc`——SwiftPM 的 C target 是独立 module |
| C 层双语诊断缓冲 | 每行带 `\x1eL:key\x1f中文\x1fEnglish\x1e` 标记后会膨胀 2~3 倍，容量要按行数与两种语言总量估算。空间不足时**整行丢弃**，不能留下缺结尾 `\x1e` 的半标记：Swift 侧正则匹配不上会把控制字符和中文原样显示出来 |

`Package.swift` 用 `.executableTarget`（SwiftPM 5.4+ 规范），并显式链接
`IOKit` / `CoreFoundation`（C target）与 `CoreGraphics` / `ApplicationServices`（Swift target）。

## Swift / AppKit 约束

| 约束 | 做法 |
|---|---|
| C 结构的 `uint32_t` 字段 | Swift 侧保持 `UInt32`。给 `static let` 常量显式标注类型，否则会被推断成 `Int`，用作 `switch` 的 expression pattern 时报 `expression pattern of type 'Int' cannot match values of type 'UInt32'`。`case 0/1/2` 这类整数字面量本身合法，出问题的是具名常量 |
| `NSScrollView.contentView` | 新版 SDK 是非 Optional 的 `NSClipView`，不能 `guard let` 解包；只解包 `enclosingScrollView`，再 `let clip = scroll.contentView`。`?.contentView` 的 optional chaining 不受影响 |
| `NSWindow.FrameAutosaveName` | 在不同 SDK 可能是 `RawRepresentable struct`，也可能只是 `typealias = String`，且 `frameAutosaveName` 的 Optional 性会变。**不读属性**：自己存一份字符串常量用于 `setFrameAutosaveName`，拼 `NSWindow Frame <name>` 清脏记录。AppKit 的 key 格式固定 |
| `NSTabViewController` | 它本身是所管理 `NSTabView` 的 delegate，**不得改该 delegate**，否则 AppKit 抛 `A TabView managed by a TabViewController cannot have its delegate modified`。页签切换走 `override tabView(_:didSelect:)`（必须调 `super`）+ 通知 + `viewDidLayout` 三条路径 |
| 偏好窗口的页签 | 用 `NSSegmentedControl` + 常驻 pane（`isHidden` 切换），不碰 `NSTabView` / `NSTabViewItem`：没有 delegate、没有 item 插入、没有 index 同步 |
| `#selector` | 不要写 `Selector("字面量:")` 构造：会触发 ObjC 方法存在性检查（`undo:` / `redo:` 在非 NSDocument 应用里无声明）和 `use '#selector'` 警告。统一用 `NSSelectorFromString(...)` 运行时构造，标准编辑动作沿响应链分发 |
| CF 类型转换 | 目标为 CF 类型（`CFArray` / `CFDictionary` / `AXValue` / `SecIdentity` …）时不要用 `as?`，新版 SDK 会报 "always succeeds"。先 `CFGetTypeID(x) == XxxGetTypeID()` 校验，再 `unsafeBitCast`。目标是 Swift / Foundation 类型的 `as?` 不受影响 |
| `RTLD_DEFAULT` / `RTLD_NEXT` 等负指针宏 | Swift 不导入，用 `UnsafeMutableRawPointer(bitPattern: -2)` 构造等价句柄传给 `dlsym` |
| 字典字面量 | **不要**用 `[K: V]` 字面量写「一组枚举 tag → 一组控件值」：重复 key 编译期不报错，运行时 `Swift runtime failure: Dictionary literal contains duplicate keys` → 无消息 `SIGTRAP`。用 `[(K, V)]` 元组数组，从结构上免疫 |
| 无消息 `EXC_BREAKPOINT` | 头号嫌疑是 Swift 运行时检查（重复字典 key、数组越界、IUO 隐式解包、算术溢出），不是 AppKit 内部断言。先看 `~/Library/Logs/DiagnosticReports/` 里 `.crash` 的 Thread 0 第 0 帧 symbol |
| 批量改写源码字符串 | 不要用正则匹配 Swift 字符串字面量：`\(...)` 插值里可以再出现双引号、括号、三元。用 `Tools/swift_scan.py` 的状态机按括号深度扫描 |
| 私有 SPI | `_AXUIElementGetWindow` 等符号全部 `dlopen` / `dlsym` 运行时解析，不做链接期依赖 |

## 界面布局约束

- **嵌套垂直 `NSStackView` 会按 arrangedSubview 的 intrinsic width 水平摆放**。若把设备树下半区放进嵌套 stack，它会被 `driverLabel` 的文字宽度限制成约 310pt、居中，属性表被迫横滚。所有视图的 `leading` / `trailing` 都直接钉在 `root` 上，宽度跟随窗口。
- `propTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle` 让 `Value` 列吃掉剩余宽度；`fitPropColumns()` 先按 clipView 可见宽度同步 `documentView.frame.width` 再 `sizeLastColumnToFit()`——tableView 初始 frame 宽 0 时只调后者会把末列压到 `minWidth`。
- 列宽按 identifier 持久化在 `UserDefaults`，用 schema 版本号在默认值方案变化时清一次已存宽度；用户拖过的宽度始终优先。
- `ensureVisibleOnScreens(autosaveName:)` 是 `UIHelpers.swift` 里的 internal `NSWindow` 扩展，定义在文件作用域的 `private extension` 会变成 `fileprivate`，其它窗口无法调用。
- **工具栏控件不要写死宽度**：本地化标题长短不一，按钮状态切换（暂停 / 继续）也会改标题，固定宽度会把文字截断成 `Pause Refr...`。按所有可能标题的 `intrinsicContentSize` 取最大值，用 `greaterThanOrEqualToConstant` + 高 content hugging 固定；程序化遍历 `NSPopUpButton` 选项测宽度时临时把 `target` 置空，避免触发 action。

## 构建时间

`swift build -c release` 全新目录约 **20s**，属于正常区间：Swift 类型检查 + `-O` 优化 / codegen、
C 采集层编译、以及链接 AppKit / CoreFoundation / IOKit / ApplicationServices / Security /
CoreGraphics。没有发现拖后腿的巨型表达式或重复编译单元。

在**全新目录**里每次都是全量构建，20s 是预期开销，不是缓存异常。固定目录时增量编译
通常 1–3s：`swift run` 用于日常调试，`./Scripts/build_app.sh` 只在需要 `.app` 时跑。
`Scripts/build_app.sh` 里第二次 `swift build -c release --show-bin-path` 只解析 manifest、不触发编译。

不建议为省这 20s 改 `-Osize` / WMO / `--scratch-path` 之类的开关：有取舍、可能改变产物、
收益不确定。

## 已知限制

- `struct proc_regioninfo` 用 `pri_address` / `pri_size` / `pri_protection`（xnu 公开头与
  `proc_regionwithpathinfo` 示例中均存在）。不同 macOS SDK 若报字段名差异，按报错处
  对照本机 `sys/proc_info.h` 微调。
- `PROC_PIDFDSOCKETINFO` / `PROC_PIDFDPIPEINFO` 对**受 SIP 保护或属于其他用户**的进程
  可能被内核拒绝；界面把「没有 socket」与「读取失败」分开显示，不静默误报。这是
  macOS 的权限模型。
- 「内存映射」页对 dyld 共享缓存只显示 `dyld_shared_cache_*` 一个路径，不逐个展开
  system framework（需解析 `dyld_shared_cache_*.map`）。
- macOS 不提供数字 session ID（`ps -o sess` 打印的是内核指针），「TTY」页用
  PGID / TPGID / `SLEADER` 推断会话结构，不伪造 SID。
- 对 `/dev/ttysNNN` 的只读 ioctl 只对当前用户有权访问的 pty 成功；其他用户的终端
  显示「不可读」并给出 errno，不影响 `e_tdev` 等进程层数据。
- 设备名反查的最后一级兜底按 minor 构造 `ttys%03d`；非标准 pty 命名下可能不符，
  正常 macOS 上 `devname_r` / `/dev` 扫描会先命中。
- 性能面板在 Intel Mac / macOS 虚拟机里拿不到 IOReport Energy Model 与 pmgr DVFS 表，
  功耗、实时频率、P/E 上限显示「—」；公开层指标仍可用。
- 分簇（P/E）利用率按核心序号启发式分组，不是 macOS 私有调度器的精确映射；
  `hw.perflevelN` 只给核心数量，不给 core-id 列表。
- `getifaddrs` 网络字节计数为 32 位且 Apple 对第三方签名做 1KiB 批量化，吞吐是近似值。
- 内存「已用」采用 `active + wired + compressed`（不含可回收的 `inactive` 文件缓存），
  与 macmon / Activity Monitor 口径一致；显示单位用 `2^30`。
- `CS_*` 标志位表为 xnu 常见值，不同系统版本可能略有差异，界面中标注为参考值。
- Rosetta 2 判定基于 `PROC_FLAG_TRANSLATED`（启发式），个别系统进程可能显示为未知。
- 进程退出 / 新建极快时，选中项可能短暂丢失，下一次刷新自动恢复。
- **激活窗口**依赖「辅助功能」授权与 `_AXUIElementGetWindow` 私有 SPI；SPI 不可用时
  退回按 bounds / 标题匹配，系统 UI 窗口、已关闭窗口或未向 AX 暴露的窗口返回
  `windowNotFound`，此时只能定位进程、不能激活窗口。
- 屏幕录制（窗口标题）与辅助功能（激活窗口）是**两项独立授权**，给其中一个不会
  自动获得另一个。

---

## 可定制点

- 列集合：`ProcessListViewController.makeColumns()`
- 过滤口径：`ProcessStore.filtered()`
- 刷新间隔：`ProcessStore.refreshInterval`
- 曲线配色 / 历史长度：`SparklineView`、`ProcessStore.trim`
- 详情 Tab：`DetailTabViewController.viewDidLoad()` 中的 `tabs` 数组
- 性能采样间隔 / 历史长度：`PerformanceStore.start()`、`maxPoints`；UI 布局见
  `PerformanceWindowController.configureTitles()` / `render()`
- 性能数据源与降级策略：`Sources/CProc/perf.c` 的 `ior_init()` / `smc_open()` /
  `read_dvfs_table()` / `fill_public_metrics()`，有效位见 `CPerf.h`
- 需要更精确的内存口径：改 `proc_collect.c` 的 `collect_system()`
