// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import Darwin

extension Notification.Name {
    static let procStoreDidUpdate =
        Notification.Name("com.vantage.storeDidUpdate")
    static let procSelectionDidChange =
        Notification.Name("com.vantage.selectionDidChange")
    /// 「立即刷新」时让详情丢弃缓存、重采当前页
    static let procDetailForceRefresh =
        Notification.Name("com.vantage.detailForceRefresh")
    /// 搜索模式（字面量 / 正则）切换：主表重新过滤、各窗口同步 .* 按钮状态
    static let searchModeDidChange =
        Notification.Name("com.vantage.searchModeDidChange")
}

final class AppContext {
    static let shared = AppContext()

    let store = ProcessStore()
    var mainWindow: MainWindowController?
    private var inspectors: [InspectorWindowController] = []

    var selectedPID: Int32? {
        didSet {
            // reloadData 后会重新 selectRowIndexes，若 PID 没变就不要重发通知：
            // 否则每次刷新都会让所有详情页重新采集 + setRows，列宽/滚动被打断。
            if oldValue == selectedPID { return }
            var info: [AnyHashable: Any] = [:]
            if let p = selectedPID { info["pid"] = p }
            NotificationCenter.default.post(name: .procSelectionDidChange,
                                            object: self, userInfo: info)
        }
    }

    func start() {
        // 先把偏好设置里的 C 层 limits 与默认视图下发，再启动采集
        Preferences.shared.applyToRuntime()
        store.applyDefaults()
        mainWindow?.syncToolbar()
        store.start()
        // 性能采样是独立 pthread；默认随 App 启动以便打开窗口时已有历史曲线
        if Preferences.shared.startPerfSampler {
            PerformanceStore.shared.start(
                intervalMs: UInt32(Preferences.shared.perfIntervalMs))
        }
    }

    func selectedProcess() -> ProcessSnapshot? {
        guard let pid = selectedPID else { return nil }
        return store.process(withPID: pid)
    }

    // ---------------------------------------------------------------
    // 主窗口：随时可找回（窗口 frame 跑到屏幕外时从菜单恢复）
    // ---------------------------------------------------------------

    func revealMainWindow() {
        guard let wc = mainWindow else { return }
        wc.ensureWindowVisible()
        wc.window?.deminiaturize(nil)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        wc.window?.orderFrontRegardless()
        AppActivate.front()
    }

    // ---------------------------------------------------------------
    // 通过窗口 / PID 值定位进程
    // ---------------------------------------------------------------

    /// 在主表中选中该 PID（必要时展开父链）并打开 / 激活它的检查器。
    /// 被过滤掉的进程会先清掉搜索与过滤条件。
    func locateProcess(_ pid: Int32) {
        guard pid > 0 else { return }
        let store = self.store

        if !store.search.isEmpty { store.search = "" }
        if store.filter != .all { store.filter = .all }
        revealMainWindow()

        // 先立即试一次：绝大多数情况下进程已在当前快照里。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.mainWindow?.selectProcess(pid) == true {
                self.showInspectorDeferred(pid)
                return
            }
            // 不在快照（例如刚启动的进程）：刷新后重试一次，带超时防悬挂。
            var token: NSObjectProtocol? = nil
            token = NotificationCenter.default.addObserver(
                forName: .procStoreDidUpdate, object: nil, queue: .main) { [weak self] _ in
                    guard let self = self else { return }
                    if let t = token { NotificationCenter.default.removeObserver(t) }
                    token = nil
                    _ = self.mainWindow?.selectProcess(pid)
                    // 不在通知派发栈里同步建窗口：setContentViewController 会
                    // 触发 13 个 Tab 的 view 加载，放在通知回调里既重又容易
                    // 被 AppKit 的 visually-atomic 事务放大成崩溃。
                    self.showInspectorDeferred(pid)
            }
            store.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if let t = token { NotificationCenter.default.removeObserver(t) }
            }
        }
    }

    // ---------------------------------------------------------------
    // 检查器窗口：同一个 PID 只保留一个窗口；已存在则激活而不是新建
    // ---------------------------------------------------------------

    func inspector(for pid: Int32) -> InspectorWindowController? {
        inspectors.first { $0.pid == pid }
    }

    /// 把「创建 + 激活检查器」挪出通知派发栈，下一个 main queue 圈再执行
    private func showInspectorDeferred(_ pid: Int32) {
        DispatchQueue.main.async { [weak self] in
            self?.showInspector(for: pid)
        }
    }

    @discardableResult
    func showInspector(for pid: Int32) -> InspectorWindowController {
        if let existing = inspector(for: pid) {
            activateInspector(existing)
            return existing
        }
        let wc = InspectorWindowController(pid: pid)
        inspectors.append(wc)
        activateInspector(wc)
        return wc
    }

    private func activateInspector(_ wc: InspectorWindowController) {
        // 最小化 / 被其他窗口盖住 / 在别的 Space 时都要能唤回；
        // 只调 showWindow 对已最小化或已 orderOut 的窗口不一定生效。
        wc.window?.deminiaturize(nil)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        wc.window?.orderFrontRegardless()
        AppActivate.front()
    }

    func closeInspector(_ wc: InspectorWindowController) {
        inspectors.removeAll { $0 === wc }
    }

    // ---------------------------------------------------------------
    // 进程操作
    // ---------------------------------------------------------------

    /// 统一的信号发送入口：右键「发送信号」子菜单、主菜单、快捷项都走这里。
    /// - pid / processName 由调用方给定，不强依赖 selectedProcess()（右键行
    ///   可能不是当前选中行，也可能是宽限期内的已退出进程）。
    func sendSignal(_ def: SignalDef, to pid: Int32,
                    processName name: String) {
        guard pid > 0 else {
            showError(L("app.noTargetProcessAvailable"))
            return
        }
        let pref = Preferences.shared
        // 危险信号（默认动作会终止 / 崩溃进程）即使总开关关了也强制确认，
        // 避免误点一下就把进程杀掉。无害通知类信号则完全按总开关。
        let needConfirm = pref.confirmBeforeSignal
            || (pref.alwaysConfirmDestructive
                && def.severity == .destructive)
        if needConfirm {
            let alert = NSAlert()
            alert.alertStyle = def.severity == .destructive
                ? .critical : .warning
            alert.messageText = L("app.sendTheSignal", name, def.name)
            var info = L("app.targetPid", pid, def.summary)
            switch def.severity {
            case .destructive:
                info += L("app.theDefaultActionOfThis")
            case .control:
                info += L("app.thisSignalChangesTheProcess")
            case .harmless:
                info += L("app.notificationSignalsUsuallyIgnoredOr")
            }
            alert.informativeText = info
            alert.addButton(withTitle: L("app.send", def.name))
            alert.addButton(withTitle: L("app.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let rc = ProcBridge.signal(pid, def.number)
        if rc != 0 {
            showError(L("app.couldNotSendToPid", def.name, pid, String(cString: strerror(errno))))
        } else {
            store.refresh()
        }
    }

    func terminate(force: Bool) {
        guard let p = selectedProcess(),
              let def = SignalCatalog.def(number: force ? SIGKILL : SIGTERM)
        else { return }
        sendSignal(def, to: p.pid, processName: p.displayLabel)
    }

    func toggleSuspend() {
        guard let p = selectedProcess(),
              let def = SignalCatalog.def(number: p.isStopped ? SIGCONT : SIGSTOP)
        else { return }
        sendSignal(def, to: p.pid, processName: p.displayLabel)
    }

    func copyExecutablePath() {
        guard let p = selectedProcess(), !p.exepath.isEmpty else {
            showError(L("app.thisProcessHasNoUsable"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p.exepath, forType: .string)
    }

    func revealInFinder() {
        guard let p = selectedProcess(), !p.exepath.isEmpty else {
            showError(L("app.thisProcessHasNoUsable2"))
            return
        }
        let target = p.bundlePath ?? p.exepath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    func copyPID() {
        guard let p = selectedProcess() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(p.pid)", forType: .string)
    }

    func copyCommandLine() {
        guard let p = selectedProcess() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            p.cmdline.isEmpty ? p.exepath : p.cmdline, forType: .string)
    }

    /// 调用系统 /usr/bin/sample 采样（时长可在偏好设置里改）并打开结果
    func sampleProcess() {
        guard let p = selectedProcess() else { return }
        let file = NSTemporaryDirectory() +
            "Vantage-\(p.pid)-\(Int(Date().timeIntervalSince1970)).sample.txt"
        let task = Process()
        task.launchPath = "/usr/bin/sample"
        let seconds = Preferences.shared.sampleSeconds
        task.arguments = ["\(p.pid)", "\(seconds)", "-file", file]
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            showError(L("app.couldNotStartSampling", error.localizedDescription))
            return
        }
        task.terminationHandler = { _ in
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: file) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: file))
                } else {
                    self.showError(L("app.sampleProducedNoOutputFile"))
                }
            }
        }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("app.actionIncomplete")
        alert.informativeText = message
        alert.addButton(withTitle: L("app.ok"))
        alert.runModal()
    }
}
