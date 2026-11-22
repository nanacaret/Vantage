// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import UniformTypeIdentifiers

// ---------------------------------------------------------------------
// 全局搜索窗口（⌘⇧F）
//
// 独立入口：打开时立即拍一份进程快照，并对快照里所有 PID 逐页取样；
// 之后输入关键字 / 正则只在这份固定数据上过滤，绝不随主表刷新漂移。
// 双击（或 ⌘/⌥ + 单击）命中行 → 激活该 PID 的检查器、切到对应页签并
// 定位到那一行；右键可「在主表中定位」。
// ---------------------------------------------------------------------

private enum GlobalSearchRow {
    case hit(GlobalSearchEntry)
    case failure(GlobalSearchFailure)
    /// 快照对比模式下的 +/− 行
    case diff(GlobalSearchDiff.Row)
}

final class GlobalSearchWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, RowTextCopying {

    static let shared = GlobalSearchWindowController()

    private let table = ActionTableView(frame: .zero)
    private let searchField = NSSearchField(frame: .zero)
    private let regexButton = NSButton(frame: .zero)
    private let recaptureButton = NSButton(frame: .zero)
    private let exportButton = NSButton(frame: .zero)
    private let importButton = NSButton(frame: .zero)
    private let diffButton = NSButton(frame: .zero)
    private let clearDiffButton = NSButton(frame: .zero)
    private let progressLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let failuresCheck = NSButton(frame: .zero)

    private var session: GlobalSearchSession?
    private var visibleRows: [GlobalSearchRow] = []
    private var refreshScheduled = false
    private var regexError: String?
    private var resultTruncated = false
    /// 导出成功之类的瞬时提示，显示在状态行末尾
    private var statusNote: String?

    // 快照对比状态：非 nil 时表格显示 diff，而不是搜索结果
    private var diffResult: GlobalSearchDiff.Summary?
    private var diffBaselineName: String?
    private var diffBaselineDate: Date?

    private static let resultCap = 5000
    private static let columnIDs = ["gsPid", "gsProcess", "gsSource", "gsContent"]
    private static let columnDefaults: [CGFloat] = [64, 170, 110, 640]

    private var mode: SearchMatchMode {
        Preferences.shared.searchUseRegex ? .regex : .literal
    }

    // -----------------------------------------------------------------
    // 初始化
    // -----------------------------------------------------------------

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("gs.windowTitle")
        w.minSize = NSSize(width: 720, height: 420)
        w.center()
        w.setFrameAutosaveName("VantageGlobalSearchWindow")
        super.init(window: w)
        setupUI()
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError(L("window.initCoderNotImplemented2"))
    }

    override func showWindow(_ sender: Any?) {
        // 先校正 frame 再显示，避免「窗口先出现在屏幕外、再跳回来」的闪动
        window?.ensureVisibleOnScreens(autosaveName: "VantageGlobalSearchWindow")
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        AppActivate.front()
        // 偏好里关掉「自动取样」时不再一打开就采：沿用上次结果，空着就等用户点
        // 「重新取样」。这样只是回来看看旧数据的人不会白白触发几十秒的全量采集。
        if session == nil && Preferences.shared.globalSearchAutoCapture {
            startNewSession()
        }
        syncProgress()
        window?.makeFirstResponder(searchField)
    }

    // -----------------------------------------------------------------
    // 界面
    // -----------------------------------------------------------------

    private func setupUI() {
        guard let window = self.window else { return }
        let root = NSView()

        regexButton.title = ".*"
        regexButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        regexButton.bezelStyle = .rounded
        regexButton.setButtonType(.pushOnPushOff)
        regexButton.target = self
        regexButton.action = #selector(regexToggled(_:))
        regexButton.toolTip = L("gs.regexTooltip")
        regexButton.translatesAutoresizingMaskIntoConstraints = false
        regexButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        searchField.placeholderString = L("gs.searchPlaceholder")
        searchField.target = self
        searchField.action = #selector(queryChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        recaptureButton.title = L("gs.recapture")
        recaptureButton.bezelStyle = .rounded
        recaptureButton.target = self
        recaptureButton.action = #selector(recaptureClicked(_:))
        recaptureButton.toolTip = L("gs.recaptureTooltip")
        recaptureButton.setContentCompressionResistancePriority(.defaultHigh,
                                                                for: .horizontal)

        // 快照三件套：导出 / 导入 / 与文件对比。用 controlSize .small 挤进顶栏，
        // 窗口拉到最小宽度（720）时搜索框还有地方。
        styleBarButton(exportButton, title: L("gs.export"),
                       tooltip: L("gs.exportTooltip"),
                       action: #selector(exportClicked(_:)))
        styleBarButton(importButton, title: L("gs.import"),
                       tooltip: L("gs.importTooltip"),
                       action: #selector(importClicked(_:)))
        styleBarButton(diffButton, title: L("gs.diff"),
                       tooltip: L("gs.diffTooltip"),
                       action: #selector(diffClicked(_:)))

        let bar = NSStackView(views: [regexButton, searchField,
                                      recaptureButton, exportButton,
                                      importButton, diffButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.distribution = .fill
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)

        table.rowHeight = 19
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.toolTip = L("gs.hintDoubleClick")
        table.onModifierClick = { [weak self] row, _ in
            self?.performRowAction(row: row)
        }
        table.menu = makeContextMenu()
        buildColumns()

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        failuresCheck.title = L("gs.showFailures")
        failuresCheck.setButtonType(.switch)
        failuresCheck.target = self
        failuresCheck.action = #selector(failuresToggled(_:))
        failuresCheck.font = NSFont.systemFont(ofSize: 10)

        // 只在对比模式下出现：退出 diff、回到当前快照的结果列表
        clearDiffButton.title = L("gs.clearDiff")
        clearDiffButton.bezelStyle = .inline
        clearDiffButton.controlSize = .small
        clearDiffButton.font = NSFont.systemFont(ofSize: 10)
        clearDiffButton.target = self
        clearDiffButton.action = #selector(clearDiffClicked(_:))
        clearDiffButton.toolTip = L("gs.clearDiffTooltip")
        clearDiffButton.isHidden = true

        for v in [progressLabel, statusLabel] {
            v.font = NSFont.systemFont(ofSize: 10)
            v.textColor = .secondaryLabelColor
            v.lineBreakMode = .byTruncatingTail
        }
        progressLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [clearDiffButton, failuresCheck,
                                         progressLabel, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.distribution = .fill
        footer.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 7, right: 10)
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28),
        ])

        let vc = NSViewController()
        vc.view = root
        window.contentViewController = vc
        syncModeUI()
    }

    private func styleBarButton(_ button: NSButton, title: String,
                                tooltip: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.setContentCompressionResistancePriority(.defaultHigh,
                                                       for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildColumns() {
        let titles = [L("gs.colPid"), L("gs.colProcess"),
                      L("gs.colSource"), L("gs.colContent")]
        for (i, id) in Self.columnIDs.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = titles[i]
            col.width = savedWidth(id, default: Self.columnDefaults[i])
            col.minWidth = 44
            col.maxWidth = 1400
            table.addTableColumn(col)
        }
    }

    private func savedWidth(_ id: String, default d: CGFloat) -> CGFloat {
        let v = UserDefaults.standard.double(forKey: "Vantage.globalSearch.col.\(id)")
        return v > 0 ? CGFloat(v) : d
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        // 不读 userInfo["NSTableColumn"]：不同 SDK 里该键名/类型不稳定。
        // 和主表一样直接遍历当前所有列保存实际宽度。
        for col in table.tableColumns {
            UserDefaults.standard.set(
                Double(col.width),
                forKey: "Vantage.globalSearch.col.\(col.identifier.rawValue)")
        }
    }

    private func makeContextMenu() -> NSMenu {
        let m = NSMenu()
        let items = [
            (L("gs.menuOpenInspector"), #selector(menuOpenInspector(_:))),
            (L("gs.menuLocateInMain"), #selector(menuLocateInMain(_:))),
            (L("gs.menuCopyRow"), #selector(menuCopyRow(_:))),
        ]
        for (title, sel) in items {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            m.addItem(mi)
        }
        return m
    }

    // -----------------------------------------------------------------
    // 快照 / 采集
    // -----------------------------------------------------------------

    private func startNewSession() {
        session?.cancel()
        // 拍快照：ProcessSnapshot 是值类型，复制后与实时刷新完全隔离。
        let snap = AppContext.shared.store.processes
        let s = GlobalSearchSession(snapshot: snap, processCount: snap.count)
        s.onProgress = { [weak self] _, _ in
            self?.scheduleRefresh()
        }
        s.onFinish = { [weak self] in
            self?.refreshScheduled = false
            self?.updateResults()
        }
        installSession(s)
        s.start()
        syncProgress()
    }

    /// 换上一个新会话（现场采集或从文件导入），并把 diff 之类的临时视图清掉。
    private func installSession(_ s: GlobalSearchSession) {
        session = s
        diffResult = nil
        diffBaselineName = nil
        diffBaselineDate = nil
        statusNote = nil
        visibleRows = []
        regexError = nil
        resultTruncated = false
        table.reloadData()
        syncProgress()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshScheduled = false
            self?.updateResults()
        }
    }

    // -----------------------------------------------------------------
    // 过滤
    // -----------------------------------------------------------------

    private func updateResults() {
        guard let s = session else {
            visibleRows = []
            table.reloadData()
            syncProgress()
            return
        }
        let m = SearchMatcher(query: searchField.stringValue, mode: mode)
        regexError = m.errorText

        var rows: [GlobalSearchRow] = []
        rows.reserveCapacity(min(Self.resultCap, 512))
        resultTruncated = false

        // 对比模式：行来自 diff 结果，搜索照样生效（匹配显示文本、进程名、pid）
        if let diff = diffResult {
            for r in diff.rows {
                if m.matches(diffText(r)) || m.matches(r.processName)
                    || m.matches(String(r.pid)) {
                    rows.append(.diff(r))
                    if rows.count >= Self.resultCap { resultTruncated = true; break }
                }
            }
            visibleRows = rows
            table.reloadData()
            syncProgress()
            return
        }

        for e in s.entries {
            if m.matches(e.displayLine) || m.matches(e.processName)
                || m.matches(String(e.pid)) {
                rows.append(.hit(e))
                if rows.count >= Self.resultCap { resultTruncated = true; break }
            }
        }
        if failuresCheck.state == .on {
            for f in s.failures where rows.count < Self.resultCap {
                rows.append(.failure(f))
            }
        }
        visibleRows = rows
        table.reloadData()
        syncProgress()
    }

    private func syncProgress() {
        guard let s = session else {
            progressLabel.stringValue = L("gs.statusIdle")
            // 没会话且自动取样关着：告诉用户为什么没数据、该按哪
            statusLabel.stringValue = Preferences.shared.globalSearchAutoCapture
                ? "" : L("gs.autoCaptureOff")
            clearDiffButton.isHidden = true
            return
        }
        let stamp = DateFormatter.localizedString(from: s.capturedAt,
                                                  dateStyle: .none, timeStyle: .medium)
        clearDiffButton.isHidden = (diffResult == nil)
        failuresCheck.isEnabled = (diffResult == nil)

        if let diff = diffResult {
            let baseStamp = diffBaselineDate.map {
                DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium)
            } ?? stamp
            let baseline = diffBaselineName ?? ""
            let current = s.importedFrom.map { L("gs.sourceFile", $0) } ?? L("gs.sourceLive")
            progressLabel.stringValue = L("gs.diffVersus", baseline, baseStamp,
                                          current, stamp)
            var text = diff.isEmpty
                ? L("gs.diffEmpty")
                : L("gs.diffCounts", diff.added, diff.removed,
                    diff.appeared, diff.gone)
            if diff.truncated || resultTruncated { text += L("gs.truncated") }
            if s.truncated { text += L("gs.diffBaselineTruncated") }
            if let note = statusNote { text += " · " + note }
            statusLabel.stringValue = text
            recaptureButton.isEnabled = true
            return
        }

        if let from = s.importedFrom {
            progressLabel.stringValue = L("gs.statusImported", from, stamp,
                                          s.entries.count, s.failures.count)
        } else if s.finished {
            progressLabel.stringValue = L("gs.statusDone", s.processCount, stamp,
                                          s.entries.count, s.failures.count)
        } else {
            progressLabel.stringValue = L("gs.statusCollecting",
                                          s.processed, s.processCount, stamp)
        }
        var text = L("gs.resultCount", visibleRows.count)
        if let err = regexError {
            text += L("gs.invalidRegex", err)
        }
        if s.truncated || resultTruncated { text += L("gs.truncated") }
        if s.cancelledByUser { text += L("gs.cancelledBadge") }
        if let note = statusNote { text += " · " + note }
        statusLabel.stringValue = text
        recaptureButton.isEnabled = true
    }

    private func syncModeUI() {
        let on = mode == .regex
        regexButton.state = on ? .on : .off
        regexButton.contentTintColor = on ? .controlAccentColor : nil
        searchField.placeholderString = on
            ? L("gs.searchRegexPlaceholder") : L("gs.searchPlaceholder")
        regexButton.toolTip = L("gs.regexTooltip")
    }

    // -----------------------------------------------------------------
    // 通知
    // -----------------------------------------------------------------

    private func observe() {
        let names: [(Notification.Name, Selector)] = [
            (.searchModeDidChange, #selector(searchModeChanged(_:))),
            (.languageDidChange, #selector(languageChanged(_:))),
        ]
        for (n, sel) in names {
            NotificationCenter.default.addObserver(self, selector: sel, name: n, object: nil)
        }
    }

    @objc private func searchModeChanged(_ note: Notification) {
        syncModeUI()
        updateResults()
    }

    @objc private func languageChanged(_ note: Notification) {
        window?.title = L("gs.windowTitle")
        regexButton.toolTip = L("gs.regexTooltip")
        recaptureButton.title = L("gs.recapture")
        recaptureButton.toolTip = L("gs.recaptureTooltip")
        failuresCheck.title = L("gs.showFailures")
        table.toolTip = L("gs.hintDoubleClick")
        let colKeys = ["gs.colPid", "gs.colProcess", "gs.colSource", "gs.colContent"]
        for (i, col) in table.tableColumns.enumerated() where i < colKeys.count {
            col.title = L(colKeys[i])
        }
        exportButton.title = L("gs.export")
        exportButton.toolTip = L("gs.exportTooltip")
        importButton.title = L("gs.import")
        importButton.toolTip = L("gs.importTooltip")
        diffButton.title = L("gs.diff")
        diffButton.toolTip = L("gs.diffTooltip")
        clearDiffButton.title = L("gs.clearDiff")
        clearDiffButton.toolTip = L("gs.clearDiffTooltip")
        table.menu = makeContextMenu()
        session?.reparseForLanguage()
        syncModeUI()
        updateResults()
    }

    // -----------------------------------------------------------------
    // 动作
    // -----------------------------------------------------------------

    @objc private func queryChanged(_ sender: Any?) { updateResults() }

    @objc private func failuresToggled(_ sender: Any?) { updateResults() }

    @objc private func regexToggled(_ sender: NSButton) {
        Preferences.shared.searchUseRegex = (sender.state == .on)
        NotificationCenter.default.post(name: .searchModeDidChange, object: self)
    }

    @objc private func recaptureClicked(_ sender: Any?) { startNewSession() }

    // -----------------------------------------------------------------
    // 快照：导出 / 导入 / 与文件对比
    // -----------------------------------------------------------------

    private static var appVersionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Vantage " + (v ?? "?")
    }

    private func currentSnapshotFile(_ s: GlobalSearchSession) -> GlobalSearchSnapshotFile {
        s.snapshotFile(appVersion: Self.appVersionText,
                       host: ProcessInfo.processInfo.hostName,
                       os: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    @objc private func exportClicked(_ sender: Any?) {
        guard let s = session, let window = self.window else { return }
        let panel = NSSavePanel()
        panel.title = L("gs.exportPanelTitle")
        panel.prompt = L("gs.exportPrompt")
        let format = Preferences.shared.snapshotSaveFormat
        panel.nameFieldStringValue = GlobalSearchSnapshotIO
            .defaultFileName(capturedAt: s.capturedAt, format: format)
        // 偏好里的格式排第一：用户不手动改扩展名时，保存面板补的就是它
        panel.allowedContentTypes = format == .json ? [.json, .gzip] : [.gzip, .json]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            guard let s = self.session else { return }
            do {
                try GlobalSearchSnapshotIO.write(self.currentSnapshotFile(s), to: url)
                self.statusNote = L("gs.exported", url.lastPathComponent)
                self.syncProgress()
            } catch {
                self.presentSnapshotError(error, titleKey: "gs.exportFailed")
            }
        }
    }

    @objc private func importClicked(_ sender: Any?) {
        pickSnapshot(titleKey: "gs.importPanelTitle", promptKey: "gs.importPrompt",
                     failureKey: "gs.importFailed") { [weak self] file, name in
            guard let self = self else { return }
            // 导入 = 用文件里的行替换当前会话；重新拍摄可以回到现场数据
            self.session?.cancel()
            let s = GlobalSearchSession(imported: file, name: name)
            self.installSession(s)
            self.updateResults()
            self.statusNote = L("gs.imported", name)
            self.syncProgress()
        }
    }

    @objc private func diffClicked(_ sender: Any?) {
        pickSnapshot(titleKey: "gs.comparePanelTitle", promptKey: "gs.comparePrompt",
                     failureKey: "gs.compareFailed") { [weak self] file, name in
            guard let self = self, let s = self.session else { return }
            // 方向：选中的文件是「基线（旧）」，屏幕上这份是「当前（新）」
            let summary = GlobalSearchDiff.compute(
                baseline: file, current: self.currentSnapshotFile(s),
                maxRows: Self.resultCap)
            self.diffResult = summary
            self.diffBaselineName = name
            self.diffBaselineDate = file.capturedAt
            self.statusNote = nil
            self.updateResults()
        }
    }

    @objc private func clearDiffClicked(_ sender: Any?) {
        diffResult = nil
        diffBaselineName = nil
        diffBaselineDate = nil
        statusNote = nil
        updateResults()
    }

    /// 打开面板选一个快照文件，解析成功才交给 apply（失败弹 alert，不动当前视图）。
    private func pickSnapshot(titleKey: String, promptKey: String,
                              failureKey: String,
                              then apply: @escaping (GlobalSearchSnapshotFile, String) -> Void) {
        guard let window = self.window else { return }
        let panel = NSOpenPanel()
        panel.title = L(titleKey)
        panel.prompt = L(promptKey)
        panel.allowedContentTypes = [.gzip, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            do {
                apply(try GlobalSearchSnapshotIO.load(from: url), url.lastPathComponent)
            } catch {
                self.presentSnapshotError(error, titleKey: failureKey)
            }
        }
    }

    private func presentSnapshotError(_ error: Error, titleKey: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L(titleKey)
        alert.informativeText = snapshotErrorText(error)
        if let w = window {
            alert.beginSheetModal(for: w)
        } else {
            alert.runModal()
        }
    }

    private func snapshotErrorText(_ error: Error) -> String {
        guard let e = error as? GlobalSearchSnapshotIO.LoadError else {
            return error.localizedDescription
        }
        switch e {
        case .notSnapshot:
            return L("gs.snapshotNotSnapshot")
        case .tooNew(let v):
            return L("gs.snapshotTooNew", v, GlobalSearchSnapshotFile.currentVersion)
        case .unreadable(let why):
            return L("gs.snapshotUnreadable", why)
        }
    }

    /// diff 行的显示文本：进程出现/消失用本地化文案，其余带 +/− 前缀。
    private func diffText(_ r: GlobalSearchDiff.Row) -> String {
        switch r.kind {
        case .appeared:
            return L("gs.diffProcessAppeared")
        case .gone:
            return L("gs.diffProcessGone")
        case .added:
            return "+ " + L10n.resolveCText(r.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .removed:
            return "− " + L10n.resolveCText(r.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        // ActionTableView 的修饰键单击会 mark 它自己的 gate；⌘+快速点两下
        // 时这里吞掉重复的那一次 doubleAction，避免同一行执行两遍。
        if table.clickGate.consumeRecent() { return }
        performRowAction(row: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow)
    }

    private func performRowAction(row: Int) {
        guard row >= 0, row < visibleRows.count else { return }
        if case .hit(let e) = visibleRows[row] { openHit(e) }
    }

    private func openHit(_ h: GlobalSearchEntry) {
        guard h.pid > 0 else { return }
        let wc = AppContext.shared.showInspector(for: h.pid)
        let tab = h.tabIndex ?? 0
        wc.focus(tab: tab, textKeys: locateKeys(for: h))
        // 主表也顺手选中，但**不改搜索 / 过滤条件**，避免破坏用户当前的视图
        _ = AppContext.shared.mainWindow?.selectProcess(h.pid)
    }

    /// 目标页定位用的关键字：优先第一列（FD / 窗口号 / 项目名），再补几个短字段。
    private func locateKeys(for h: GlobalSearchEntry) -> [String] {
        var keys: [String] = []
        for f in h.fields {
            let t = f.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == "-" || t == "—" { continue }
            if t.count > 80 { continue }
            keys.append(t)
            if keys.count >= 4 { break }
        }
        return keys
    }

    @objc private func menuOpenInspector(_ sender: Any?) {
        guard let r = rowAtMenu(), case .hit(let e) = r, e.pid > 0 else { return }
        _ = AppContext.shared.showInspector(for: e.pid)
    }

    @objc private func menuLocateInMain(_ sender: Any?) {
        guard let r = rowAtMenu(), case .hit(let e) = r, e.pid > 0 else { return }
        AppContext.shared.locateProcess(e.pid)
    }

    @objc private func menuCopyRow(_ sender: Any?) {
        guard let r = rowAtMenu() else { return }
        Clipboard.setString(rowText(r))
    }

    private func rowAtMenu() -> GlobalSearchRow? {
        let i = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard i >= 0, i < visibleRows.count else { return nil }
        return visibleRows[i]
    }

    private func rowText(_ r: GlobalSearchRow) -> String {
        switch r {
        case .hit(let e):
            return "\(e.pid)\t\(e.processName)\t"
                + GlobalSearchSession.sourceTitle(e.sourceKey)
                + "\t" + e.displayLine
        case .failure(let f):
            return "\(f.pid)\t\(f.processName)\t"
                + GlobalSearchSession.sourceTitle(f.sourceKey)
                + "\t" + L("gs.fail.\(f.reasonKey)")
        case .diff(let d):
            return "\(d.pid)\t\(d.processName)\t"
                + GlobalSearchSession.sourceTitle(d.sourceKey)
                + "\t" + diffText(d)
        }
    }

    // -----------------------------------------------------------------
    // 数据源
    // -----------------------------------------------------------------

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row >= 0, row < visibleRows.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell." + col.identifier.rawValue)
        let cell: NSTextField
        if let v = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            cell = v
        } else {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.font = NSFont.systemFont(ofSize: 11)
            f.lineBreakMode = .byTruncatingTail
            f.textColor = .labelColor
            cell = f
        }
        let r = visibleRows[row]
        // 复用单元格：每次都重置字体与颜色，否则上一行的样式会残留
        cell.font = NSFont.systemFont(ofSize: 11)
        cell.textColor = .labelColor
        switch col.identifier.rawValue {
        case "gsPid":
            cell.stringValue = "\(pid(of: r))"
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        case "gsProcess":
            cell.stringValue = processName(of: r)
        case "gsSource":
            cell.stringValue = sourceTitle(of: r)
            cell.textColor = .secondaryLabelColor
        default:
            cell.stringValue = content(of: r)
            switch r {
            case .failure:
                cell.textColor = .tertiaryLabelColor
            case .diff(let d):
                switch d.kind {
                case .added, .appeared: cell.textColor = .systemGreen
                case .removed, .gone:   cell.textColor = .systemRed
                }
            case .hit:
                cell.textColor = .labelColor
            }
        }
        return cell
    }

    private func pid(of r: GlobalSearchRow) -> Int32 {
        switch r {
        case .hit(let e):     return e.pid
        case .failure(let f): return f.pid
        case .diff(let d):    return d.pid
        }
    }
    private func processName(of r: GlobalSearchRow) -> String {
        switch r {
        case .hit(let e):     return e.processName
        case .failure(let f): return f.processName
        case .diff(let d):    return d.processName
        }
    }
    private func sourceTitle(of r: GlobalSearchRow) -> String {
        switch r {
        case .hit(let e):     return GlobalSearchSession.sourceTitle(e.sourceKey)
        case .failure(let f): return GlobalSearchSession.sourceTitle(f.sourceKey)
        case .diff(let d):    return GlobalSearchSession.sourceTitle(d.sourceKey)
        }
    }
    private func content(of r: GlobalSearchRow) -> String {
        switch r {
        case .hit(let e):     return e.displayLine
        case .failure(let f): return L("gs.fail.\(f.reasonKey)")
        case .diff(let d):    return diffText(d)
        }
    }

    // -----------------------------------------------------------------
    // ⌘C
    // -----------------------------------------------------------------

    func copySelectedRowsToPasteboard() -> Bool {
        let idx = table.selectedRowIndexes
        guard !idx.isEmpty else { return false }
        let text = idx.compactMap { i -> String? in
            guard i < visibleRows.count else { return nil }
            return rowText(visibleRows[i])
        }.joined(separator: "\n")
        Clipboard.setString(text)
        return !text.isEmpty
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

