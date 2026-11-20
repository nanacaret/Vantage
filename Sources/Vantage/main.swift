// SPDX-License-Identifier: MIT
import AppKit

// NSApplication.delegate 是弱引用，必须用全局变量强持有 AppDelegate。
private var strongAppDelegate: AppDelegate?

// 记录提权重启时带来的原始 uid（供「降权为用户」使用）
Privilege.noteLaunchArguments()

// 隐藏模式：Touch ID 提权的特权辅助工具（由 LaunchDaemon 以 root 启动）。
// 常驻，只服务白名单内的特权操作。
if CommandLine.arguments.contains("--touchid-helper") {
    TouchIDHelperServer.run()
}

// 隐藏模式：以 root 写 TCC 数据库。
// 由 PermissionReader.writeTCC 经 Authorization Services 启动
// （TCCStore.runHelper）。必须在创建 NSApplication 之前结束，否则会多开一个
// Dock 图标 / 窗口，也会把一次命令行操作变成常驻进程。
if let i = CommandLine.arguments.firstIndex(of: "--tcc-write") {
    exit(TCCStore.runHelper(Array(CommandLine.arguments.dropFirst(i + 1))))
}

// 隐藏模式：安装 / 卸载 Touch ID 特权辅助工具（以 root 经
// Authorization Services 启动本二进制）。所有文件操作都在子模式里
// 进程内完成（mkdir/copy/chmod/chown/unlink），不经 /bin/sh，也不再依赖
// cat / rm / install(1) 这类外部命令 —— launchctl 是唯一保留的（它没有
// 公开 API 替代）。同样必须在 NSApplication 之前结束。
if let i = CommandLine.arguments.firstIndex(of: "--helper-install") {
    let raw = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
    exit(TouchIDHelper.performInstall(installerUID: uid_t(raw) ?? 0))
}
if CommandLine.arguments.contains("--helper-uninstall") {
    exit(TouchIDHelper.performUninstall())
}

autoreleasepool {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()
    strongAppDelegate = delegate
    app.delegate = delegate

    app.run()
}
