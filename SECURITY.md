# Security Policy

> 也可阅读[中文说明](README.zh-Hans.md)。本文说明本项目的安全边界与报告方式。

## 这个工具做什么 / 不做什么

Vantage 是**本机只读诊断工具**：采集进程、内存、文件描述符、socket、TTY、IORegistry、
系统扩展与性能计数器，展示在 GUI 里。它不监听网络端口、不上传遥测、不写入用户文档、
不安装守护进程或系统扩展、不请求 root。

唯一会改变系统状态的操作是**你主动发起**的：

- 发送信号（`kill(2)`）：退出 / 强制退出 / 暂停 / 继续 / 自定义信号
- 激活某个窗口（AXUIElement）
- `sample` 采样（生成临时文件）

这些操作都在菜单里显式触发，且危险信号默认要求二次确认。

## 私有 API 与分发边界

项目使用了未公开的 macOS 接口（IOReport 通道、AppleSMC 键、
`_AXUIElementGetWindow`、`syscall(SYS_csops, …)`）。它们全部在运行时动态解析，
但会带来以下事实，请在部署前知悉：

- **不适用于 Mac App Store**，也未做 Apple 公证（notarization）；
- GitHub Actions 会为每次构建产出 DMG（ad-hoc 签名、**未公证**），随 `nightly`
  预发布或 `v*` tag 的正式 Release 分发，并附 SHA-256 校验文件；也可完全从源码本地构建。
  下载后请先 `shasum -a 256 -c Vantage-*.dmg.sha256`，首次打开见 README「预构建 DMG」；
- macOS 更新可能让某个私有符号失效，届时对应指标显示 `—`，不影响其余功能；
- `Packaging/Vantage.entitlements` 含 `com.apple.security.cs.debugger`，仅对未签名或带
  `get-task-allow` 的第三方进程有效；SIP 开启时对受保护进程无效，root 也一样。

## 权限

部分功能需要用户在「系统设置 → 隐私与安全性」中授权：

| 权限 | 用途 |
|---|---|
| 辅助功能 | 激活指定窗口 |
| 屏幕录制 | 读取窗口标题 |

两项授权相互独立，且**都不会**让 Vantage 获得读取其他进程内存的能力——
SIP 下没有公开替代方案，工程也没有实现该能力。

## 报告问题

- **一般性 bug / 崩溃 / 编译问题**：请在仓库开 GitHub Issue（Issues 页），附上 macOS 版本、
  SDK 版本、芯片架构与完整日志或崩溃报告。
- **可能造成实际危害的安全问题**（例如越权读取、权限提升、意外修改系统状态）：
  请不要在公开 Issue 里贴细节，改用仓库的 **Security Advisories → Report privately**
  （GitHub 私有报告通道）；若尚未启用，可在 Issue 里只写「需要私下沟通」而不附细节。

本项目由社区维护，不提供 SLA、安全审计或商业支持。在敏感环境使用前请自行审阅源码，
并从源码构建而不是信任第三方分发的二进制。
