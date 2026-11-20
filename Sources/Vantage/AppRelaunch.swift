// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 语言切换后重启自己
//
// 为什么必须重启：界面上的文字分两类 ——
//   1. 渲染时现取 `L(key)` 的（每秒刷新的统计数字、表格数据）
//   2. 建视图时取一次、存在控件里的（工具栏按钮、页签标题、列头、
//      自定义绘制的表头、各个独立窗口的静态标签）
// 第 2 类分布在十几个控制器里，`L10n.relocalize` 只能按「显示值 → key」
// 反查着改，改不到的地方（自定义绘制、缓存的字符串数组、NSTabView
// 未加载的页、私有视图内部的控件）就会留着旧语言 —— 表现就是中英混排。
//
// 与其在二十多个视图里逐个补「刷新」路径（每加一个控件就多一个漏点），
// 不如把语言切换做成「写偏好 → 重启」：一次进程重启就能保证 100% 一致，
// 这也是系统里很多工具的做法。
// ---------------------------------------------------------------------

enum AppRelaunch {

    /// 重启本 App。成功返回 true（调用方随后会被 exit 掉）。
    ///
    /// 以 root 运行时不重启：`open` 会以 root 身份在错误的会话里拉起新实例。
    /// 那种情况由调用方退回「就地刷新 + 提示下次启动生效」。
    @discardableResult
    static func restart() -> Bool {
        guard !Privilege.isRoot else { return false }
        guard let exe = Bundle.main.executablePath else { return false }

        let task = Process()
        if Bundle.main.bundleURL.pathExtension == "app" {
            // 走 LaunchServices：新实例才会被当成「用户打开的应用」拿到焦点、
            // 菜单栏与 Dock 归属，而不是一个从终端继承来的孤儿进程。
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", Bundle.main.bundleURL.path]
        } else {
            // 开发时可能直接跑 .build 里的可执行文件（没有 bundle）
            task.executableURL = URL(fileURLWithPath: exe)
            task.arguments = Array(CommandLine.arguments.dropFirst())
        }

        do {
            try task.run()
        } catch {
            return false
        }
        // 给 open 一点时间把新实例注册进 LaunchServices，再退出自己，
        // 否则可能出现「旧的没了、新的还没起来」的空窗。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            exit(0)
        }
        return true
    }
}
