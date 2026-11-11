# 第三方说明与致谢

Vantage 使用 Apple 系统 SDK 与 SwiftPM 构建，没有外部 Package 依赖。本文件记录
设计参考、接口依据与素材来源。

## 设计参考

| 项目 | 参考内容 |
|---|---|
| [Activity Monitor](https://support.apple.com/guide/activity-monitor/welcome/mac)（Apple） | 进程列表布局、统计口径与检查器式详情页 |
| [System Informer](https://github.com/winsiderss/systeminformer)（[MIT](https://github.com/winsiderss/systeminformer/blob/master/LICENSE.txt)） | 「通过窗口定位进程」的准星选取交互 |
| [macmon](https://github.com/vladkens/macmon) | 无 root 读取 Apple Silicon 功耗 / 频率的采集分层，以及若干数值口径 |

以上均为思路与交互层面的参考；性能采集用 C 实现，界面用 AppKit 实现。
各项目许可证归其权利人所有。

## 接口依据

采集与界面实现依据 Apple 公开文档及 Darwin 开源头文件核对系统调用语义：

- `libproc` / `sysctl` / Mach / IOKit / CoreGraphics / Security.framework /
  Accessibility 的 Apple Developer Documentation
- xnu 开源源码中的 `bsd/sys/proc_info.h`、`bsd/sys/codesign.h`、
  `osfmk/mach/task_info.h` 等头文件
- `ps(1)`、`lsof(1)`、`vmmap(1)`、`sample(1)`、`kmutil(8)`、
  `systemextensionsctl(8)` 的输出作为行为对照

## 私有接口

下列接口在运行时通过 `dlopen` / `dlsym` 动态解析，**没有链接期依赖**，
Apple 未公开其稳定性：

- `libIOReport.dylib` 的 `IOReportCreateSubscription` / `CreateSamples` /
  `CreateSamplesDelta` 等符号
- `AppleSMC` IOKit user client 的 key 读取
- IOHIDEventSystem 的温度传感器事件
- `_AXUIElementGetWindow`（HIServices SPI）
- `syscall(SYS_csops, …)`（`csops` 没有公开包装函数）

缺少任一符号时，对应字段显示 `—`，不会让 App 启动失败。详见
[SECURITY.md](SECURITY.md) 与 [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)。

## 素材

`Assets/Vantage.png` / `.icns` / `.iconset` 是本项目原创图形（深蓝→青绿渐变 +
脉冲波形），随本项目 [MIT](LICENSE) 许可一同发布。替换主图后可运行
`python3 Tools/make_icon.py` 重建全套尺寸。

README 的界面截图位于 `docs/screenshots/`，共 5 张，均为本项目的实机截图
（主窗口、性能监控、设备树、全局搜索、窗口列表）。原始 Retina PNG 随
[MIT](LICENSE) 许可一同发布。

## 商标

Apple、macOS、Activity Monitor、App Store 等为 Apple Inc. 的商标；
System Informer、macmon 等名称归各自权利人所有。本文件与 README 中的提及
仅作说明与致谢用途，不构成背书或关联。
