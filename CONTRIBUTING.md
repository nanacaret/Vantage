# 贡献指南

感谢你愿意改进 Vantage。本项目是纯 macOS 原生工程，改动前请先读完这一页——尤其是
「不要手工编辑生成文件」和「私有 API 的使用原则」两条。

## 开发环境

- macOS 12+（推荐 Apple Silicon，能验到 IOReport / SMC / DVFS 数据）
- Xcode Command Line Tools（Swift 5.9+）
- Python 3（可选，仅用于重跑 `Tools/` 下的生成器）
- 无需 root、无需 `powermetrics`、无需额外依赖

```bash
swift build -c release
swift run
./Scripts/build_app.sh
```

## 代码风格

- **注释与文档用简体中文**，与现有代码保持一致；标识符、日志 key、commit message 用英文。
- 每个源文件首行带 `SPDX-License-Identifier: MIT`。新建文件请沿用现有文件的写法；
  `Package.swift` 例外——`// swift-tools-version:5.9` 必须是第一行，SPDX 放第二行。
- C 层对外只暴露**扁平标量结构与 `\t` 分隔文本行**，不要把 `char[]` 数组或复杂结构体
  塞进公开头（Swift 会把定长 `char[]` 导入成 tuple，后续极难维护）。
- 每次 `proc_pidfdinfo` 一类调用都按 `PROC_PID*INFO_SIZE` 分配缓冲区，用 `memcpy`
  取字段，避免不同 SDK 的结构体字段名/布局差异。
- 读不到的传感器/权限数据显示 `—` 并标注 valid 位，**绝不用 0 冒充「不可用」**。

## 不要手工编辑这些文件

它们由生成器输出，改了会在下次生成时被覆盖：

| 生成文件 | 来源 |
|---|---|
| `Resources/*.lproj/Localizable.strings` | `Tools/l10n_master.py` |
| `Sources/Vantage/L10nTable.swift` | 同上 |
| `Sources/Vantage/L10nKeys.swift` | 同上 |
| `Sources/CProc/cproc_l10n_data.c/.h` | `Tools/l10n_master.py` + `Tools/c_en_override.py` |
| `Assets/Vantage.iconset/`、`Assets/Vantage.icns` | `Tools/make_icon.py` |

改文案 / 加文案的正确流程：

```bash
# 1. 编辑唯一数据源
$EDITOR Tools/l10n_master.py          # key -> (简体中文, English)
# 2. 若改的是 C 层运行时拼接文本，编辑手工译文
$EDITOR Tools/c_en_override.py
# 3. 一次重建全部资源
python3 Tools/build_l10n.py
```

界面文案一律写 `L("semantic.key")`，**中文不是 key**。新增 key 后必须重跑生成器，
否则编译时 `src_keys - MASTER` 校验会失败。

C 层新增中文输出时，`build_c_l10n.py` 会扫描 `proc_detail.c` / `perf.c` 并生成
`c.*` 语义 key + 双语表；`ioreg.c` 刻意只输出 ASCII 结构行，UI 文案全在 Swift 侧，
不要在里面写中文字符串字面量。

## 新增 / 修改 C 接口

1. 在 `Sources/CProc/include/CProc.h` 或 `CPerf.h` 声明；
2. 在对应 `.c` 实现；
3. 若 Swift 侧要调用，确认该文件有 `import CProc`；
4. 内部共用的头放在 `Sources/CProc/` 私有目录，**不要放进 `include/`**——
   `publicHeadersPath` 下每个 `.h` 都会被当公开头，`CProc.h` 作为 umbrella 没包含它
   会触发 `umbrella header ... does not include header` 警告。

## 提交前检查清单

```bash
# 1) 编译必须零 error、零 warning
swift build -c release

# 2) 生成器幂等：两次运行之间不应产生 diff
python3 Tools/build_l10n.py && git diff --exit-code

# 3) 资源一致性（任选其一）
grep -c 'SPDX-License-Identifier' Sources/Vantage/*.swift   # 每个文件都应命中
```

另外请确认：

- 字典字面量没有重复 key、switch 没有重复 case（Swift 对前者是**运行时** trap，
  且不带任何错误信息，曾在偏好设置窗口踩过）；
- 没有 `Selector("字面量:")` 构造（会触发 `use #selector` / `no method declared` 警告，
  统一用 `NSSelectorFromString`）；
- 没有对 CF 类型用 `as?`（新版 SDK 会报 "always succeeds"，先 `CFGetTypeID` 校验）；
- 新窗口如果调用 `ensureVisibleOnScreens(autosaveName:)`，传自己的 frame autosave 名常量；
- 涉及 `NSTabViewController` 时不要改它所管理 `NSTabView` 的 delegate（AppKit 会直接抛
  `NSInternalInconsistencyException`）。

## 私有 API 的使用原则

`libIOReport`、`AppleSMC`、`_AXUIElementGetWindow`、`syscall(SYS_csops, …)` 都是
未公开接口，允许使用，但必须满足：

- **运行时 `dlopen` / `dlsym` 解析，不做链接期依赖**；
- 拿不到时功能降级并给出明确状态，不能让 App 起不来；
- 在 `README` / `THIRD_PARTY_NOTICES.md` 的免责说明里如实列出；
- 不要为了拿数据关 SIP 或要求 root——SIP 下 root 也拿不到受保护进程的 task port。

## 提交 Issue

请附上：macOS 版本、Xcode / SDK 版本、芯片（Apple Silicon / Intel）、复现步骤、
完整编译日志或崩溃报告（`~/Library/Logs/DiagnosticReports/`）。性能数据对不上时，
把性能窗口状态栏的**逐通道诊断**文字一并贴上来——它直接给出计入的通道、
pmgr 频率表与温度来源，比截图有用得多。

## 提交 PR

- 一个 PR 聚焦一件事，说明改动动机与验证方式；
- 不要提交 `build/`、`*.app`、`.build/`、签名私钥或 `Tools/c_l10n_generated.json`；
- 不要顺手重排无关文件的格式；
- 确认 `swift build -c release` 零警告、`Scripts/build_app.sh` 能生成 `.app`。

## 许可证

提交贡献即表示你同意以 [MIT](LICENSE) 许可发布你的改动，并确认你有权这样做。
