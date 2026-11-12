// SPDX-License-Identifier: MIT
import AppKit
import Darwin
import Foundation

// ---------------------------------------------------------------------
// 进程信号目录 / 菜单
//
// 信号编号直接写 Darwin 的固定数值，不引用 SIGHUP 这类常量名 —— 部分信号
// （SIGEMT / SIGINFO）在不同 SDK 的 Swift 导入里时有时无，数值从 4.4BSD
// 起就没变过，写数值最稳。
// ---------------------------------------------------------------------

enum SignalGroup: String, CaseIterable {
    // rawValue 必须是编译期字面量（Swift 强制），所以用**稳定的 ASCII key**
    // 而不是中文，也不是 L() 调用；显示名统一走 title → L(rawValue)。
    case control = "signal.group.control"
    case user    = "signal.group.user"
    case fault   = "signal.group.fault"
    case other   = "signal.group.other"

    var title: String { L(rawValue) }
}

enum SignalSeverity {
    case destructive   // 默认动作会终止 / 崩溃进程，且多数不可捕获
    case control       // 暂停 / 继续 / 终端控制
    case harmless      // 通知类，默认动作通常被忽略或可捕获
}

struct SignalDef {
    let number: Int32
    let name: String
    let summary: String
    let group: SignalGroup
    let severity: SignalSeverity

    var menuTitle: String {
        let mark = severity == .destructive ? "⚠ " : ""
        return "\(mark)\(name) (\(number)) — \(summary)"
    }

    var prefTitle: String {
        let mark = severity == .destructive ? "⚠ " : ""
        return "\(mark)\(name) (\(number))"
    }
}

enum SignalCatalog {
    /// macOS / Darwin 上可发送给进程的全部常用信号
    static let all: [SignalDef] = [
        // 终止 / 控制
        .init(number: 1,  name: "SIGHUP",  summary: L("signal.hangupManyDaemonsUseIt"),
              group: .control, severity: .destructive),
        .init(number: 2,  name: "SIGINT",  summary: L("signal.interruptTerminalCtrlC"),
              group: .control, severity: .destructive),
        .init(number: 3,  name: "SIGQUIT", summary: L("signal.quitAndDumpCore"),
              group: .control, severity: .destructive),
        .init(number: 9,  name: "SIGKILL", summary: L("signal.killImmediatelyCannotBeCaught"),
              group: .control, severity: .destructive),
        .init(number: 15, name: "SIGTERM", summary: L("signal.requestGracefulExitCatchableCleanup"),
              group: .control, severity: .destructive),
        .init(number: 17, name: "SIGSTOP", summary: L("signal.freezeProcessCannotBeCaught"),
              group: .control, severity: .control),
        .init(number: 18, name: "SIGTSTP", summary: L("signal.terminalSuspendCtrlZCatchable"),
              group: .control, severity: .control),
        .init(number: 19, name: "SIGCONT", summary: L("signal.continueResumeAStoppedProcess"),
              group: .control, severity: .control),
        .init(number: 21, name: "SIGTTIN", summary: L("signal.backgroundProcessReadingFromTerminal"),
              group: .control, severity: .control),
        .init(number: 22, name: "SIGTTOU", summary: L("signal.backgroundProcessWritingToTerminal"),
              group: .control, severity: .control),

        // 通知 / 自定义
        .init(number: 28, name: "SIGWINCH", summary: L("signal.terminalWindowSizeChanged"),
              group: .user, severity: .harmless),
        .init(number: 29, name: "SIGINFO",  summary: L("signal.requestStatusInfoTerminalCtrl"),
              group: .user, severity: .harmless),
        .init(number: 30, name: "SIGUSR1",  summary: L("signal.userDefinedSignal"),
              group: .user, severity: .harmless),
        .init(number: 31, name: "SIGUSR2",  summary: L("signal.userDefinedSignal2"),
              group: .user, severity: .harmless),

        // 故障 / 崩溃
        .init(number: 4,  name: "SIGILL",  summary: L("signal.illegalInstruction"),
              group: .fault, severity: .destructive),
        .init(number: 5,  name: "SIGTRAP", summary: L("signal.traceBreakpointTrap"),
              group: .fault, severity: .destructive),
        .init(number: 6,  name: "SIGABRT", summary: L("signal.abnormalTerminationAbort"),
              group: .fault, severity: .destructive),
        .init(number: 7,  name: "SIGEMT",  summary: L("signal.emtInstruction"),
              group: .fault, severity: .destructive),
        .init(number: 8,  name: "SIGFPE",  summary: L("signal.floatingPointArithmeticException"),
              group: .fault, severity: .destructive),
        .init(number: 10, name: "SIGBUS",  summary: L("signal.busErrorAlignmentFault"),
              group: .fault, severity: .destructive),
        .init(number: 11, name: "SIGSEGV", summary: L("signal.invalidMemoryReferenceSegfault"),
              group: .fault, severity: .destructive),
        .init(number: 12, name: "SIGSYS",  summary: L("signal.invalidSystemCall"),
              group: .fault, severity: .destructive),

        // 其它
        .init(number: 13, name: "SIGPIPE",  summary: L("signal.writeToPipeWithNo"),
              group: .other, severity: .harmless),
        .init(number: 14, name: "SIGALRM",  summary: L("signal.realTimeTimerExpired"),
              group: .other, severity: .harmless),
        .init(number: 16, name: "SIGURG",   summary: L("signal.socketUrgentData"),
              group: .other, severity: .harmless),
        .init(number: 20, name: "SIGCHLD",  summary: L("signal.childProcessStatusChanged"),
              group: .other, severity: .harmless),
        .init(number: 23, name: "SIGIO",    summary: L("signal.asyncIOAvailable"),
              group: .other, severity: .harmless),
        .init(number: 24, name: "SIGXCPU",  summary: L("signal.cpuTimeLimitExceeded"),
              group: .other, severity: .destructive),
        .init(number: 25, name: "SIGXFSZ",  summary: L("signal.fileSizeLimitExceeded"),
              group: .other, severity: .destructive),
        .init(number: 26, name: "SIGVTALRM", summary: L("signal.virtualTimerExpired"),
              group: .other, severity: .harmless),
        .init(number: 27, name: "SIGPROF",  summary: L("signal.profilingTimerExpired"),
              group: .other, severity: .harmless),
    ]

    /// 默认在菜单里显示的信号：常用 + 安全，其余可在偏好设置里打开
    static let defaultNumbers: Set<Int32> =
        [1, 2, 3, 9, 15, 17, 18, 19, 28, 29, 30, 31]

    static func def(number: Int32) -> SignalDef? {
        all.first { $0.number == number }
    }

    /// 按偏好里勾选的顺序保留目录顺序，过滤出可见信号
    static func visible() -> [SignalDef] {
        let set = Preferences.shared.visibleSignalNumbers
        return all.filter { set.contains($0.number) }
    }
}

// MARK: - 菜单 payload

/// 菜单项携带的目标：主菜单没有右键行，pid 用 0 表示「取当前选中进程」。
final class SignalMenuPayload: NSObject {
    let pid: Int32
    let name: String
    let number: Int32

    init(pid: Int32, name: String, number: Int32) {
        self.pid = pid
        self.name = name
        self.number = number
    }
}

// MARK: - 统一的发送动作（右键菜单与主菜单共用）

final class SignalActions: NSObject {
    static let shared = SignalActions()

    @objc func sendSignalFromMenu(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? SignalMenuPayload,
              let def = SignalCatalog.def(number: p.number) else { return }
        let pid = p.pid > 0 ? p.pid : (AppContext.shared.selectedPID ?? 0)
        let name = p.name.isEmpty
            ? (AppContext.shared.selectedProcess()?.displayLabel ?? "PID \(pid)")
            : p.name
        AppContext.shared.sendSignal(def, to: pid, processName: name)
    }

    @objc func openSignalPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.showWindow(nil)
        PreferencesWindowController.shared.selectSignalTab()
    }
}

// MARK: - 菜单构建

enum SignalMenuBuilder {
    /// 清空并按「当前偏好里勾选的信号」重建子菜单内容。
    /// - pid: 右键行传实际 PID；主菜单传 0 → 运行时取当前选中进程。
    static func fill(_ menu: NSMenu, pid: Int32, name: String) {
        menu.removeAllItems()
        let visible = SignalCatalog.visible()
        if visible.isEmpty {
            let i = NSMenuItem(title: L("signal.noSignalsSelectedPreferencesSignals"),
                               action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
            let p = NSMenuItem(title: L("signal.openPreferences"),
                               action: #selector(SignalActions.openSignalPreferences(_:)),
                               keyEquivalent: "")
            p.target = SignalActions.shared
            menu.addItem(p)
            return
        }
        for group in SignalGroup.allCases {
            let items = visible.filter { $0.group == group }
            guard !items.isEmpty else { continue }
            if menu.items.count > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem(title: "— \(group.title) —",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for def in items {
                let mi = NSMenuItem(
                    title: def.menuTitle,
                    action: #selector(SignalActions.sendSignalFromMenu(_:)),
                    keyEquivalent: "")
                mi.target = SignalActions.shared
                mi.representedObject = SignalMenuPayload(
                    pid: pid, name: name, number: def.number)
                mi.toolTip = def.summary
                menu.addItem(mi)
            }
        }
    }
}

/// 主菜单「发送信号」子菜单的 delegate：每次展开时按最新偏好重建。
final class SignalMenuUpdater: NSObject, NSMenuDelegate {
    static let shared = SignalMenuUpdater()

    func menuNeedsUpdate(_ menu: NSMenu) {
        let name = AppContext.shared.selectedProcess()?.displayLabel ?? ""
        SignalMenuBuilder.fill(menu, pid: 0, name: name)
    }
}
