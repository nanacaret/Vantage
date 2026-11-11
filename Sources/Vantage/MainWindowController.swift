// SPDX-License-Identifier: MIT
import AppKit

// ---------------------------------------------------------------------
// 独立检查器窗口（Activity Monitor 风格）
// ---------------------------------------------------------------------

final class InspectorWindowController: NSWindowController, NSWindowDelegate {
    let pid: Int32
    private let tabs: DetailTabViewController

    init(pid: Int32) {
        self.pid = pid
        let t = DetailTabViewController()
        t.fixedPID = pid
        self.tabs = t

        // 13 个 2 字页签（新增「窗口」），比 12 个时略宽一点避免 segmented
        // control 把末尾标签截掉；窗口页有 6 列，也需要横向空间。
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        // 标题也带名称：主表能看到 raw，检查器里同样不用猜是哪个进程
        let label = AppContext.shared.store.process(withPID: pid)?.displayLabel
        w.title = label.map { L("window.inspectorPid", $0, pid) }
            ?? L("window.inspectorPid2", pid)
        w.minSize = NSSize(width: 660, height: 420)
        w.center()
        super.init(window: w)

        w.contentViewController = t
        w.delegate = self
    }

    required init?(coder: NSCoder) { fatalError(L("window.initCoderNotImplemented")) }

    /// 全局搜索命中行：切到目标页签并定位到那一行
    func focus(tab: Int, textKeys: [String]) {
        tabs.focus(tab: tab, textKeys: textKeys)
    }

    func windowWillClose(_ notification: Notification) {
        AppContext.shared.closeInspector(self)
    }
}

// ---------------------------------------------------------------------
// 主窗口
// ---------------------------------------------------------------------

final class MainWindowController: NSWindowController {

    /// frame autosave 的名字用纯 String 存一份：NSWindow.FrameAutosaveName
    /// 在不同 SDK 里可能是 Optional、String 别名或 RawRepresentable struct，
    /// 校正可见性时不要去读 window.frameAutosaveName（`.rawValue` / `if let`
    /// 都会因版本差异编译失败），直接用这个我们传进去的字符串即可。
    private static let mainFrameAutosaveName = "VantageMainWindow"

    private let listVC = ProcessListViewController()
    private let detailTabs = DetailTabViewController()
    private let statsVC = StatsPanelViewController()

    private var outerSplit: NSSplitViewController!
    private var innerSplit: NSSplitViewController!

    private lazy var refreshButton: NSButton =
        UI.button(L("window.refresh"), target: self, action: #selector(refreshClicked(_:)))

    private lazy var viewSegment: NSSegmentedControl = {
        let s = NSSegmentedControl(labels: [L("window.tree"), L("window.list")],
                                   trackingMode: .selectOne,
                                   target: self,
                                   action: #selector(viewChanged(_:)))
        return s
    }()

    private lazy var filterPopup: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: ProcessFilter.allCases.map { $0.title })
        p.target = self
        p.action = #selector(filterChanged(_:))
        return p
    }()

    private lazy var intervalPopup: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: [L("window.s"), L("window.s2"), L("window.s3"), L("window.s4")])
        p.selectItem(at: 1)
        p.target = self
        p.action = #selector(intervalChanged(_:))
        return p
    }()

    private lazy var searchField: NSSearchField = {
        let f = NSSearchField(frame: .zero)
        f.placeholderString = L("window.searchNamePidCommandLine")
        f.target = self
        f.action = #selector(searchChanged(_:))
        return f
    }()

    /// 搜索框旁的「.*」开关：切换字面量 / 正则模式，与偏好设置、全局搜索共享。
    private lazy var regexButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.title = ".*"
        b.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        b.bezelStyle = .rounded
        b.setButtonType(.pushOnPushOff)
        b.target = self
        b.action = #selector(regexToggled(_:))
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.setContentCompressionResistancePriority(.defaultHigh,
                                                  for: .horizontal)
        return b
    }()

    private lazy var statusLabel = UI.label("", size: 11,
                                            color: .secondaryLabelColor)

    private lazy var terminateButton: NSButton =
        UI.button(L("window.quit"), target: self, action: #selector(terminateClicked(_:)))

    private lazy var forceButton: NSButton =
        UI.button(L("window.forceQuit"), target: self, action: #selector(forceClicked(_:)))

    private lazy var inspectorButton: NSButton =
        UI.button(L("window.inspector"), target: self, action: #selector(inspectorClicked(_:)))

    init() {
        // 不要用 .fullSizeContentView：内容视图会延伸到标题栏下方，
        // 顶部工具栏会被 traffic light + 标题栏压住（只露出一点 segmented 蓝条）。
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "Vantage"
        w.minSize = NSSize(width: 960, height: 600)
        w.center()
        // 当前 SDK 里 FrameAutosaveName 就是 String 别名，直接传常量即可；
        // 不写 NSWindow.FrameAutosaveName(...) 是为了少一层类型构造假设。
        w.setFrameAutosaveName(Self.mainFrameAutosaveName)
        super.init(window: w)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError(L("window.initCoderNotImplemented2")) }

    // -----------------------------------------------------------------
    // 窗口可见性
    // -----------------------------------------------------------------

    /// setFrameAutosaveName 会恢复上次保存的 frame。若显示器配置变了
    /// （拔掉副屏 / 改分辨率）或 UserDefaults 里存过异常值，窗口会整个
    /// 跑到屏幕外：isVisible 仍是 true（所以 App 也不会退出），但用户
    /// 完全看不到 —— 这正是「主窗口无法显示」的典型表现。
    ///
    /// 显示前检查与所有屏幕可见区域是否还有足够交集，否则重置为默认
    /// 尺寸并清掉那条脏的 autosave 记录。
    func ensureWindowVisible() {
        guard let w = window else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        var bestArea: CGFloat = 0
        for s in screens {
            let inter = w.frame.intersection(s.visibleFrame)
            if !inter.isNull && !inter.isEmpty {
                bestArea = max(bestArea, inter.width * inter.height)
            }
        }
        // 至少要露出 200×120，否则视为「看不见」
        if bestArea < 200 * 120 {
            w.setFrame(NSRect(x: 0, y: 0, width: 1240, height: 800),
                       display: false)
            w.center()
            // AppKit 存 frame 的 key 格式自 NeXT 时代起就是
            // "NSWindow Frame <autosaveName>"。直接删掉脏记录；autosave name
            // 仍挂在窗口上，之后窗口移动会把校正后的 frame 重新写回去。
            UserDefaults.standard.removeObject(
                forKey: "NSWindow Frame \(Self.mainFrameAutosaveName)")
        }
    }

    /// 供「通过窗口定位进程」调用：转发给列表控制器
    @discardableResult
    func selectProcess(_ pid: Int32) -> Bool {
        listVC.selectPID(pid)
    }

    // -----------------------------------------------------------------
    // 布局
    // -----------------------------------------------------------------

    private func setupUI() {
        guard let window = self.window else { return }

        let root = NSViewController()
        root.view = NSView()
        window.contentViewController = root
        let content = root.view

        // 状态文字放底部独立状态条，不挤占顶部工具栏宽度；
        // 否则窄窗口下 NSStackView 会把按钮/弹框压缩到几乎不可见。
        let bar = NSStackView(views: [
            refreshButton, viewSegment, filterPopup, intervalPopup,
            regexButton, searchField,
            terminateButton, forceButton, inspectorButton,
        ])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.distribution = .fill
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 38),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        // 让搜索框吸收多余宽度，其余控件保持固有尺寸不被压缩
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls: [NSView] = [refreshButton, viewSegment, filterPopup,
                                  intervalPopup, regexButton,
                                  terminateButton, forceButton,
                                  inspectorButton]
        for control in controls {
            control.setContentCompressionResistancePriority(.defaultHigh,
                                                            for: .horizontal)
        }

        // 底部状态条
        let bottomBar = NSView()
        bottomBar.wantsLayer = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bottomBar)

        let divider = NSBox(frame: .zero)
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(divider)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(statusLabel)

        let hintLabel = UI.label(L("window.doubleClickAPidTo"),
                                 size: 10, color: .secondaryLabelColor)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(hintLabel)
        statusLabel.setContentCompressionResistancePriority(.defaultLow,
                                                            for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.defaultHigh,
                                                          for: .horizontal)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 24),

            divider.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            divider.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor,
                                                 constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo:
                hintLabel.leadingAnchor, constant: -10),

            hintLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor,
                                                constant: -10),
            hintLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])

        // 外层：上 = 进程列表，下 = 详情 + 统计
        outerSplit = NSSplitViewController()
        _ = outerSplit.view
        outerSplit.splitView.isVertical = false
        outerSplit.addSplitViewItem(NSSplitViewItem(viewController: listVC))

        // 内层：左 = 详情 Tab，右 = 系统统计曲线
        innerSplit = NSSplitViewController()
        _ = innerSplit.view
        innerSplit.splitView.isVertical = true
        innerSplit.addSplitViewItem(NSSplitViewItem(viewController: detailTabs))
        innerSplit.addSplitViewItem(NSSplitViewItem(viewController: statsVC))

        let bottomVC = NSViewController()
        bottomVC.view = NSView()
        bottomVC.addChild(innerSplit)
        innerSplit.view.translatesAutoresizingMaskIntoConstraints = false
        bottomVC.view.addSubview(innerSplit.view)
        UI.pin(innerSplit.view, in: bottomVC.view,
               top: 0, left: 0, bottom: 0, right: 0)

        outerSplit.addSplitViewItem(NSSplitViewItem(viewController: bottomVC))
        root.addChild(outerSplit)
        outerSplit.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outerSplit.view)
        NSLayoutConstraint.activate([
            outerSplit.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            outerSplit.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outerSplit.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outerSplit.view.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
        ])

        listVC.view.heightAnchor
            .constraint(greaterThanOrEqualToConstant: 220).isActive = true
        detailTabs.view.widthAnchor
            .constraint(greaterThanOrEqualToConstant: 360).isActive = true
        statsVC.view.widthAnchor
            .constraint(greaterThanOrEqualToConstant: 160).isActive = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.outerSplit.splitView.setPosition(420, ofDividerAt: 0)
            // 详情 Tab 增至 13 个（标签已压到 2 字），给左侧更多宽度避免截断
            self.innerSplit.splitView.setPosition(880, ofDividerAt: 0)
        }

        syncToolbar()
        syncSearchMode()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeUpdated),
            name: .procStoreDidUpdate, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchModeChanged),
            name: .searchModeDidChange, object: nil)
    }

    // -----------------------------------------------------------------
    // 工具栏
    // -----------------------------------------------------------------

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    func syncToolbar() {
        let store = AppContext.shared.store
        viewSegment.selectedSegment = store.treeMode ? 0 : 1
        filterPopup.selectItem(at: ProcessFilter.allCases
            .firstIndex(of: store.filter) ?? 0)
        let intervals: [TimeInterval] = [0.5, 1.0, 2.0, 5.0]
        let idx = intervals.firstIndex {
            abs($0 - store.refreshInterval) < 0.01
        } ?? 1
        intervalPopup.selectItem(at: idx)
        updateStatus()
    }

    private func updateStatus() {
        let s = AppContext.shared.store
        let base = String(
            format: L("window.dProcessesThreadsRefreshEvery"),
            s.processes.count, Fmt.number(s.system.threadsTotal),
            s.refreshInterval)
        // 退出宽限期内仍显示的行单独标注，方便核对「保留刷新次数」是否生效
        let n = s.exitedVisibleCount
        var text = n > 0
            ? base + L("window.exitedGraceHighlight", n)
            : base
        // 正则敲到一半（例如 "["）编译失败时明确告知已回退，而不是静默
        // 把整个列表清空让人以为「没有匹配进程」。
        if let err = s.searchRegexError {
            text += L("window.invalidRegexFallback", err)
        }
        statusLabel.stringValue = text
    }

    private func syncSearchMode() {
        let on = Preferences.shared.searchUseRegex
        let want: NSControl.StateValue = on ? .on : .off
        if regexButton.state != want { regexButton.state = want }
        regexButton.contentTintColor = on ? .controlAccentColor : nil
        regexButton.toolTip = L("window.regexModeTooltip")
        searchField.placeholderString = on
            ? L("window.searchRegexPlaceholder")
            : L("window.searchLiteralPlaceholder")
    }

    @objc private func searchModeChanged(_ note: Notification) {
        syncSearchMode()
        // search 值没变，didSet 不会触发，显式重新过滤一次
        AppContext.shared.store.reapplySearch()
        updateStatus()
    }

    @objc private func regexToggled(_ sender: NSButton) {
        Preferences.shared.searchUseRegex = (sender.state == .on)
        NotificationCenter.default.post(name: .searchModeDidChange, object: self)
    }

    @objc private func storeUpdated() { updateStatus() }

    @objc private func refreshClicked(_ sender: Any?) {
        AppContext.shared.store.refresh()
        if Preferences.shared.refreshInvalidatesDetail {
            NotificationCenter.default.post(name: .procDetailForceRefresh, object: nil)
        }
    }

    @objc private func viewChanged(_ sender: Any?) {
        AppContext.shared.store.treeMode = (viewSegment.selectedSegment == 0)
    }

    @objc private func filterChanged(_ sender: Any?) {
        AppContext.shared.store.filter =
            ProcessFilter(rawValue: filterPopup.indexOfSelectedItem) ?? .all
    }

    @objc private func intervalChanged(_ sender: Any?) {
        let intervals: [TimeInterval] = [0.5, 1.0, 2.0, 5.0]
        let i = intervalPopup.indexOfSelectedItem
        if i >= 0 && i < intervals.count {
            AppContext.shared.store.refreshInterval = intervals[i]
            updateStatus()
        }
    }

    @objc private func searchChanged(_ sender: Any?) {
        AppContext.shared.store.search = searchField.stringValue
    }

    @objc private func terminateClicked(_ sender: Any?) {
        AppContext.shared.terminate(force: false)
    }

    @objc private func forceClicked(_ sender: Any?) {
        AppContext.shared.terminate(force: true)
    }

    @objc private func inspectorClicked(_ sender: Any?) {
        guard let pid = AppContext.shared.selectedPID else {
            AppContext.shared.showError(L("window.selectAProcessFirst"))
            return
        }
        AppContext.shared.showInspector(for: pid)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
