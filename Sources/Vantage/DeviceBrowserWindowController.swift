// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 设备树浏览器（⌘⌥D）
//
// 左边是 ioreg 风格的 NSOutlineView 树，可按 plane 切换；选中节点后下栏
// 列出该节点的全部 IORegistry 属性，并额外解析出：
//   · driver bundle：节点属性 CFBundleIdentifier / IOPersonality，再用
//     扩展列表的 IOKitPersonalities 索引按 IOClass 反查 bundle 路径 / 版本；
//   · client PID：IOUserClientCreator（CFString / CFNumber / CFData
//     audit_token / CFArray / CFDictionary 五种形态都解析）。
//
// 双击 Client PID 定位进程，双击驱动 Bundle 跳到扩展列表；修饰键单击 ≡
// 双击。搜索复用全局的正则 / 字面量模式与偏好设置。
// ---------------------------------------------------------------------

private final class DeviceOutlineView: NSOutlineView {
    var onModifierClick: ((Int, Int) -> Void)?
    let clickGate = ModifierClickGate()

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let row = self.row(at: loc)
        let col = self.column(at: loc)
        if event.clickCount == 1, row >= 0, ModifierClick.isModifier(event) {
            clickGate.mark()
            super.mouseDown(with: event)
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            onModifierClick?(row, col)
            return
        }
        super.mouseDown(with: event)
    }
}

private enum DeviceFilter: Int, CaseIterable {
    case all = 0, withDriver = 1, withClient = 2

    var title: String {
        switch self {
        case .all:        return L("dev.filter.all")
        case .withDriver: return L("dev.filter.withDriver")
        case .withClient: return L("dev.filter.withClient")
        }
    }
}

private struct DeviceTableRow {
    let key: String
    let type: String
    let value: String
}

final class DeviceBrowserWindowController: NSWindowController,
    NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSTableViewDataSource, NSTableViewDelegate, RowTextCopying {

    static let shared = DeviceBrowserWindowController()

    private let outline = DeviceOutlineView(frame: .zero)
    private let propTable = ActionTableView(frame: .zero)
    private let planePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchField = NSSearchField(frame: .zero)
    private let regexButton = NSButton(frame: .zero)
    private let refreshButton = NSButton(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let driverLabel = NSTextField(labelWithString: "")

    private var tree = IORegTree()
    private var visible: Set<Int> = []
    private var propRows: [DeviceTableRow] = []
    private var selectedPath: String = ""
    private var epoch: UInt64 = 0
    private var forceLiteralSearch = false
    private var scannedOnce = false

    private static let columnIDs = ["devName", "devClass", "devBundle",
                                    "devClient", "devEntry", "devPath"]
    private static let columnWidths: [CGFloat] = [210, 170, 200, 84, 92, 360]

    private var mode: SearchMatchMode {
        forceLiteralSearch ? .literal
            : (Preferences.shared.searchUseRegex ? .regex : .literal)
    }

    // -----------------------------------------------------------------
    // 初始化
    // -----------------------------------------------------------------

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = L("dev.windowTitle")
        w.minSize = NSSize(width: 820, height: 500)
        w.center()
        // FrameAutosaveName 在新 SDK 就是 String，直接传字符串，不读属性
        w.setFrameAutosaveName("VantageDeviceBrowserWindow")
        super.init(window: w)
        setupUI()
        observe()
    }

    required init?(coder: NSCoder) { return nil }

    override func showWindow(_ sender: Any?) {
        window?.ensureVisibleOnScreens(autosaveName: "VantageDeviceBrowserWindow")
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        AppActivate.front()
        if tree.nodes.isEmpty { reload() }
    }

    // -----------------------------------------------------------------
    // 界面
    // -----------------------------------------------------------------

    private func setupUI() {
        guard let window = self.window else { return }
        let root = NSView()
        window.contentView = root

        for p in IORegistryBrowser.planes { planePopup.addItem(withTitle: p) }
        planePopup.selectItem(at: 0)
        planePopup.target = self
        planePopup.action = #selector(planeChanged(_:))
        planePopup.font = NSFont.systemFont(ofSize: 12)

        for f in DeviceFilter.allCases { filterPopup.addItem(withTitle: f.title) }
        filterPopup.selectItem(at: 0)
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged(_:))
        filterPopup.font = NSFont.systemFont(ofSize: 12)

        searchField.placeholderString = L("dev.searchPlaceholder")
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.font = NSFont.systemFont(ofSize: 12)

        regexButton.title = ".*"
        regexButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        regexButton.bezelStyle = .rounded
        regexButton.setButtonType(.pushOnPushOff)
        regexButton.target = self
        regexButton.action = #selector(regexToggled(_:))
        regexButton.toolTip = L("window.regexModeTooltip")

        refreshButton.title = L("dev.refresh")
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))

        let toolbar = NSStackView(views: [planePopup, filterPopup, searchField,
                                          regexButton, refreshButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.distribution = .fill
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [planePopup, filterPopup, regexButton, refreshButton] {
            v.setContentCompressionResistancePriority(.defaultHigh,
                                                      for: .horizontal)
        }

        setupOutline()
        setupPropTable()
        let outlineScroll = NSScrollView(frame: .zero)
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.borderType = .bezelBorder

        let propScroll = NSScrollView(frame: .zero)
        propScroll.documentView = propTable
        propScroll.hasVerticalScroller = true
        propScroll.hasHorizontalScroller = true
        propScroll.autohidesScrollers = true
        propScroll.borderType = .bezelBorder
        // 列宽随窗口自适应（Value 列吃掉剩余宽度）后正常情况下不再需要横滚；
        // 保留自动隐藏的横滚条，用户手动拖宽某列时仍能看全内容。
        propScroll.postsFrameChangedNotifications = true

        driverLabel.font = NSFont.systemFont(ofSize: 11)
        driverLabel.textColor = .secondaryLabelColor
        driverLabel.lineBreakMode = .byTruncatingTail
        driverLabel.cell?.wraps = true
        driverLabel.cell?.isScrollable = false
        driverLabel.maximumNumberOfLines = 2

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        // 这里刻意**不用嵌套 NSStackView**：垂直 stack 默认按 arrangedSubview
        // 的 intrinsic width 摆放，propPane 的宽度会被 driverLabel 那行文字
        // 限制成约 310pt 并整体居中，于是属性表被挤成下半区中间一小条，
        // 三列总宽 1020pt 远超容器 → 被迫左右横滚。改成把每个视图的
        // leading/trailing 直接钉在 root 上，宽度 100% 跟随窗口。
        for v in [toolbar, outlineScroll, driverLabel, propScroll, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            toolbar.heightAnchor.constraint(equalToConstant: 28),

            outlineScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            outlineScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            outlineScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            driverLabel.topAnchor.constraint(equalTo: outlineScroll.bottomAnchor, constant: 6),
            driverLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            driverLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            driverLabel.heightAnchor.constraint(equalToConstant: 34),

            propScroll.topAnchor.constraint(equalTo: driverLabel.bottomAnchor, constant: 4),
            propScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            propScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            // 上下两块内容区近似等高：下半区额外放了 34pt label + 10pt 间距
            propScroll.heightAnchor.constraint(equalTo: outlineScroll.heightAnchor,
                                               constant: -44),

            statusLabel.topAnchor.constraint(equalTo: propScroll.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        // 窗口 / 分栏尺寸变化时，让 Value 列始终吃掉剩余宽度。
        // 用 target-action 而非 block-based observer，deinit 里一句
        // removeObserver(self) 就能清干净，不会留下僵尸 token。
        NotificationCenter.default.addObserver(
            self, selector: #selector(propScrollFrameChanged(_:)),
            name: Notification.Name("NSViewFrameDidChangeNotification"),
            object: propScroll)
        DispatchQueue.main.async { [weak self] in
            self?.fitPropColumns()
        }
        syncControls()
    }

    @objc private func propScrollFrameChanged(_ note: Notification) {
        fitPropColumns()
    }

    /// 把 documentView 宽度同步到 clipView 可见宽度，再让最后一列吃掉剩余空间。
    /// 只调 `sizeLastColumnToFit()` 不够：propTable 初始 frame 是 .zero，
    /// tableView 宽度为 0 时它会把 Value 列压到 minWidth，而不是撑满。
    private func fitPropColumns() {
        let w = max(propTable.superview?.bounds.width ?? 900, 320)
        if abs(propTable.frame.width - w) > 0.5 {
            propTable.setFrameSize(NSSize(width: w, height: propTable.frame.height))
        }
        propTable.sizeLastColumnToFit()
    }

    private func setupOutline() {
        for (i, id) in Self.columnIDs.enumerated() {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = Self.columnTitle(id)
            c.width = Self.columnWidths[i]
            c.minWidth = 44
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.allowsMultipleSelection = false
        outline.rowSizeStyle = .small
        outline.doubleAction = #selector(outlineDoubleClicked(_:))
        outline.onModifierClick = { [weak self] row, col in
            self?.performRowAction(row: row, col: col)
        }
    }

    private func setupPropTable() {
        let ids = ["propKey", "propType", "propValue"]
        // Value 列的初始值只是下限参考：columnAutoresizingStyle 会在布局时把
        // 它撑到「表格可见宽度 - Key - Type」，既铺满也不触发横向滚动。
        let widths: [CGFloat] = [190, 76, 420]
        for (i, id) in ids.enumerated() {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = Self.propColumnTitle(id)
            c.width = widths[i]
            c.minWidth = 44
            propTable.addTableColumn(c)
        }
        propTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        propTable.dataSource = self
        propTable.delegate = self
        propTable.usesAlternatingRowBackgroundColors = true
        propTable.allowsColumnReordering = true
        propTable.allowsColumnResizing = true
        propTable.rowSizeStyle = .small
        propTable.doubleAction = #selector(propDoubleClicked(_:))
        propTable.onModifierClick = { [weak self] row, col in
            self?.performPropAction(row: row, col: col)
        }
    }

    private static func columnTitle(_ id: String) -> String {
        switch id {
        case "devName":   return L("dev.col.name")
        case "devClass":  return L("dev.col.class")
        case "devBundle": return L("dev.col.bundle")
        case "devClient": return L("dev.col.client")
        case "devEntry":  return L("dev.col.entry")
        default:          return L("dev.col.path")
        }
    }

    private static func propColumnTitle(_ id: String) -> String {
        switch id {
        case "propKey":   return L("dev.prop.key")
        case "propType":  return L("dev.prop.type")
        default:          return L("dev.prop.value")
        }
    }

    // -----------------------------------------------------------------
    // 通知
    // -----------------------------------------------------------------

    private func observe() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChanged),
            name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchModeChanged),
            name: .searchModeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .preferencesDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnWidthsShouldReset),
            name: .columnWidthsShouldReset, object: nil)
    }

    @objc private func languageChanged() {
        window?.title = L("dev.windowTitle")
        for c in outline.tableColumns { c.title = Self.columnTitle(c.identifier.rawValue) }
        for c in propTable.tableColumns { c.title = Self.propColumnTitle(c.identifier.rawValue) }
        for (i, f) in DeviceFilter.allCases.enumerated() {
            if i < filterPopup.numberOfItems { filterPopup.item(at: i)?.title = f.title }
        }
        searchField.placeholderString = forceLiteralSearch
            ? L("dev.searchPlaceholder") : modePlaceholder()
        refreshButton.title = L("dev.refresh")
        regexButton.toolTip = L("window.regexModeTooltip")
        applyFilterAndSearch()
        updateStatus()
        updateDriverLabel()
    }

    @objc private func searchModeChanged() { syncControls(); applyFilterAndSearch() }
    @objc private func preferencesChanged() { syncControls(); applyFilterAndSearch() }
    @objc private func columnWidthsShouldReset() {
        for (i, c) in outline.tableColumns.enumerated() {
            if i < Self.columnWidths.count { c.width = Self.columnWidths[i] }
        }
        let w: [CGFloat] = [190, 76, 420]
        for (i, c) in propTable.tableColumns.enumerated() {
            if i < w.count { c.width = w[i] }
        }
        DispatchQueue.main.async { [weak self] in
            self?.fitPropColumns()
        }
    }

    private func modePlaceholder() -> String {
        mode == .regex ? L("dev.searchRegexPlaceholder") : L("dev.searchPlaceholder")
    }

    private func syncControls() {
        regexButton.state = (mode == .regex) ? .on : .off
        regexButton.isEnabled = !forceLiteralSearch
        if !forceLiteralSearch { searchField.placeholderString = modePlaceholder() }
    }

    // -----------------------------------------------------------------
    // 采集与刷新
    // -----------------------------------------------------------------

    @objc private func planeChanged(_ sender: Any?) { reload() }
    @objc private func filterChanged(_ sender: Any?) { applyFilterAndSearch() }
    @objc private func refreshClicked(_ sender: Any?) { reload() }
    @objc private func searchChanged(_ sender: Any?) { applyFilterAndSearch() }

    @objc private func regexToggled(_ sender: Any?) {
        Preferences.shared.searchUseRegex = (regexButton.state == .on)
        Preferences.shared.applyToRuntime()
        NotificationCenter.default.post(name: .searchModeDidChange, object: nil)
    }

    private var currentPlane: String {
        IORegistryBrowser.planes[safe: planePopup.indexOfSelectedItem] ?? "IOService"
    }

    private func reload() {
        // 取消上一轮，避免连续切换 plane 时旧枚举继续跑
        if epoch != 0 { IORegistryBrowser.cancelEpoch(epoch) }
        let e = IORegistryBrowser.beginEpoch()
        epoch = e
        statusLabel.stringValue = L("dev.status.collecting")
        let plane = currentPlane
        IORegistryBrowser.queue.async {
            IORegistryBrowser.markEpoch(e)
            let t = IORegistryBrowser.tree(plane: plane)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.tree = t
                self.scannedOnce = true
                self.applyFilterAndSearch()
                self.updateStatus()
                self.restoreSelection()
            }
        }
    }

    private func restoreSelection() {
        guard !selectedPath.isEmpty else { return }
        if let n = tree.nodes.first(where: { $0.path == selectedPath }) {
            let row = outline.row(forItem: NSNumber(value: n.index))
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row),
                                         byExtendingSelection: false)
            }
            loadProperties(n)
        }
    }

    // -----------------------------------------------------------------
    // 搜索 / 过滤：保留匹配节点 + 其整条祖先链，树不会断
    // -----------------------------------------------------------------

    private func applyFilterAndSearch() {
        let nodes = tree.nodes
        let matcher = SearchMatcher(query: searchField.stringValue, mode: mode)
        let df = DeviceFilter(rawValue: filterPopup.indexOfSelectedItem) ?? .all

        var candidates: Set<Int> = []
        for n in nodes {
            switch df {
            case .all:        candidates.insert(n.index)
            case .withDriver: if !n.driverBundleID.isEmpty { candidates.insert(n.index) }
            case .withClient: if n.hasClient { candidates.insert(n.index) }
            }
        }

        var matched = Set<Int>()
        for n in nodes where candidates.contains(n.index) {
            if matcher.isEmpty || matches(matcher, n) { matched.insert(n.index) }
        }
        var v = matched
        // 补祖先链（不受筛选条件限制）
        for idx in matched {
            var p = nodes[safe: idx]?.parent ?? -1
            var guardCount = 0
            while p >= 0, p < nodes.count, guardCount < 128 {
                v.insert(p)
                p = nodes[p].parent
                guardCount += 1
            }
        }
        visible = v
        outline.reloadData()
        // 展开前三层 + 所有匹配节点的直接父项，保证命中行可见
        for n in nodes where v.contains(n.index) && n.depth <= 2 {
            outline.expandItem(NSNumber(value: n.index))
        }
        for idx in matched {
            if let p = nodes[safe: idx]?.parent, p >= 0 {
                outline.expandItem(NSNumber(value: p))
            }
        }
        updateStatus()
    }

    private func matches(_ m: SearchMatcher, _ n: IORegNode) -> Bool {
        let fields = [n.name, n.className, n.bundleID, n.personalityBundleID,
                      n.ioClass, n.providerClass, n.clientName, n.path,
                      String(format: "0x%llx", n.entryID),
                      n.clientPID.map(String.init) ?? ""]
        return m.matches(anyOf: fields)
    }

    private func updateStatus() {
        let total = tree.nodes.count
        let shown = visible.count
        var s = L("dev.status.nodes", total, shown)
        if scannedOnce && total == 0 && !tree.truncated {
            s += L("dev.status.emptyPlane")
        }
        if tree.truncated { s += L("dev.status.truncated") }
        if let err = SearchMatcher(query: searchField.stringValue, mode: mode).errorText,
           !err.isEmpty, !forceLiteralSearch {
            s += L("window.invalidRegexFallback", err)
        }
        statusLabel.stringValue = s
    }

    // -----------------------------------------------------------------
    // 属性与驱动详情
    // -----------------------------------------------------------------

    private func loadProperties(_ n: IORegNode) {
        selectedPath = n.path
        propRows = [DeviceTableRow(key: L("dev.loading"), type: "", value: "")]
        propTable.reloadData()
        updateDriverLabel(n)
        let path = n.path
        IORegistryBrowser.queue.async {
            let p = IORegistryBrowser.properties(path: path)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.selectedPath == path else { return }
                var rows: [DeviceTableRow] = []
                rows.append(DeviceTableRow(key: L("dev.info.node"), type: "string",
                                           value: n.name))
                rows.append(DeviceTableRow(key: L("dev.info.class"), type: "string",
                                           value: n.className))
                rows.append(DeviceTableRow(key: L("dev.info.entryID"), type: "hex",
                                           value: String(format: "0x%llx", n.entryID)))
                rows.append(DeviceTableRow(key: L("dev.info.path"), type: "path",
                                           value: n.path))
                if !n.driverBundleID.isEmpty {
                    rows.append(DeviceTableRow(key: L("dev.info.driverBundle"),
                                               type: "bundle",
                                               value: n.driverBundleID))
                }
                if !n.driverClass.isEmpty {
                    rows.append(DeviceTableRow(key: L("dev.info.ioClass"),
                                               type: "string", value: n.driverClass))
                }
                if !n.provider.isEmpty {
                    rows.append(DeviceTableRow(key: L("dev.info.provider"),
                                               type: "string", value: n.provider))
                }
                if let pid = n.clientPID, pid > 0 {
                    rows.append(DeviceTableRow(key: L("dev.info.clientPID"),
                                               type: "pid", value: "\(pid)"))
                    rows.append(DeviceTableRow(key: L("dev.info.clientSource"),
                                               type: "string",
                                               value: Self.clientSourceTitle(n.clientSource)))
                }
                for r in p.rows {
                    rows.append(DeviceTableRow(key: r.key, type: r.type, value: r.value))
                }
                if p.truncated {
                    rows.append(DeviceTableRow(key: L("dev.info.more"), type: "",
                                               value: L("dev.info.truncated")))
                }
                if let e = p.error {
                    rows.append(DeviceTableRow(key: L("dev.info.error"),
                                               type: "", value: e))
                }
                self.propRows = rows
                self.propTable.reloadData()
            }
        }
    }

    private func updateDriverLabel(_ n: IORegNode? = nil) {
        guard let n = n ?? selectedNode() else {
            driverLabel.stringValue = L("dev.driverHint")
            return
        }
        let b = ExtensionScanner.shared.lookup(bundleID: n.driverBundleID,
                                               ioClass: n.driverClass)
        var line1 = L("dev.driver.title")
        if !n.driverBundleID.isEmpty { line1 += "  " + n.driverBundleID }
        var line2 = ""
        if let b = b {
            line1 += "  ·  " + b.kind.title + " " + b.displayVersion
                + "  ·  " + b.statusTitle
            line2 = b.path
        } else {
            line1 += "  ·  " + L("dev.driver.notInList")
            if !n.driverClass.isEmpty {
                line1 += " (" + n.driverClass + ")"
                line2 = n.driverClass
            }
        }
        if let pid = n.clientPID, pid > 0 {
            line2 += (line2.isEmpty ? "" : "  ·  ")
                + L("dev.driver.client", pid, n.clientName,
                    Self.clientSourceTitle(n.clientSource))
        }
        driverLabel.stringValue = line1
            + (line2.isEmpty ? "" : "\n" + line2)
    }

    private static func clientSourceTitle(_ s: String) -> String {
        switch s {
        case "string": return L("dev.clientSource.string")
        case "number": return L("dev.clientSource.number")
        case "audit":  return L("dev.clientSource.audit")
        default:       return L("dev.clientSource.none")
        }
    }

    private func selectedNode() -> IORegNode? {
        let row = outline.selectedRow
        guard row >= 0, let item = outline.item(atRow: row) as? NSNumber else { return nil }
        return node(at: item.intValue)
    }

    private func node(at index: Int) -> IORegNode? {
        guard index >= 0, index < tree.nodes.count else { return nil }
        return tree.nodes[index]
    }

    // -----------------------------------------------------------------
    // 交互
    // -----------------------------------------------------------------

    @objc private func outlineDoubleClicked(_ sender: Any?) {
        if outline.clickGate.consumeRecent() { return }
        performRowAction(row: outline.clickedRow >= 0
                            ? outline.clickedRow : outline.selectedRow,
                         col: outline.clickedColumn)
    }

    private func performRowAction(row: Int, col: Int) {
        guard row >= 0, let item = outline.item(atRow: row) as? NSNumber,
              let n = node(at: item.intValue) else { return }
        let id = (col >= 0 && col < outline.tableColumns.count)
            ? outline.tableColumns[col].identifier.rawValue : ""
        if id == "devClient", let pid = n.clientPID, pid > 0 {
            AppContext.shared.locateProcess(pid)
            return
        }
        if id == "devBundle", !n.driverBundleID.isEmpty {
            ExtensionsWindowController.shared.focusOn(bundleID: n.driverBundleID)
            return
        }
        if outline.isItemExpanded(item) { outline.collapseItem(item) }
        else { outline.expandItem(item) }
    }

    @objc private func propDoubleClicked(_ sender: Any?) {
        if propTable.clickGate.consumeRecent() { return }
        performPropAction(row: propTable.clickedRow >= 0
                            ? propTable.clickedRow : propTable.selectedRow,
                          col: propTable.clickedColumn)
    }

    private func performPropAction(row: Int, col: Int) {
        guard row >= 0, row < propRows.count else { return }
        let r = propRows[row]
        if r.type == "pid", let pid = Int32(r.value), pid > 0 {
            AppContext.shared.locateProcess(pid)
            return
        }
        if r.type == "bundle" {
            ExtensionsWindowController.shared.focusOn(bundleID: r.value)
            return
        }
        if r.value.hasPrefix("/System") || r.value.hasPrefix("/Library") {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: r.value)])
            return
        }
        Clipboard.setString("\(r.key)\t\(r.type)\t\(r.value)")
    }

    /// 从扩展列表反向跳过来：按 bundle id 过滤本树
    func focusOn(bundleID: String) {
        forceLiteralSearch = true
        searchField.stringValue = bundleID
        syncControls()
        let hadTree = !tree.nodes.isEmpty
        showWindow(nil)          // 首次打开时 showWindow 会触发 reload()
        if hadTree { applyFilterAndSearch() }
    }

    // -----------------------------------------------------------------
    // NSOutlineView 数据源 / 代理
    // -----------------------------------------------------------------

    private func childrenFor(_ parent: Int) -> [Int] {
        (tree.children[parent] ?? []).filter { visible.contains($0) }
    }

    func outlineView(_ outlineView: NSOutlineView,
                     numberOfChildrenOfItem item: Any?) -> Int {
        let p = (item as? NSNumber)?.intValue ?? -1
        return childrenFor(p).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int,
                     ofItem item: Any?) -> Any {
        let p = (item as? NSNumber)?.intValue ?? -1
        let kids = childrenFor(p)
        return NSNumber(value: kids[safe: index] ?? -1)
    }

    func outlineView(_ outlineView: NSOutlineView,
                     isItemExpandable item: Any) -> Bool {
        let p = (item as? NSNumber)?.intValue ?? -1
        return !childrenFor(p).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let c = tableColumn, let num = item as? NSNumber,
              let n = node(at: num.intValue) else { return nil }
        let cellID = NSUserInterfaceItemIdentifier("DeviceCell")
        let cell = outlineView.makeView(withIdentifier: cellID, owner: self)
            as? NSTextField ?? NSTextField(labelWithString: "")
        cell.identifier = cellID
        cell.font = NSFont.systemFont(ofSize: 11)
        cell.lineBreakMode = .byTruncatingTail
        cell.textColor = .labelColor
        let id = c.identifier.rawValue
        switch id {
        case "devName":   cell.stringValue = n.name
        case "devClass":  cell.stringValue = n.className
        case "devBundle": cell.stringValue = n.driverBundleID.isEmpty
                            ? "—" : n.driverBundleID
        case "devClient":
            if let pid = n.clientPID, pid > 0 {
                cell.stringValue = "\(pid)"
                cell.textColor = .linkColor
                cell.toolTip = L("dev.clientTooltip", pid, n.clientName)
            } else { cell.stringValue = "—" }
        case "devEntry":  cell.stringValue = String(format: "0x%llx", n.entryID)
        default:          cell.stringValue = n.path
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = selectedNode() else {
            selectedPath = ""
            propRows = []
            propTable.reloadData()
            updateDriverLabel()
            return
        }
        loadProperties(n)
    }

    // -----------------------------------------------------------------
    // 属性表数据源 / 代理
    // -----------------------------------------------------------------

    func numberOfRows(in tableView: NSTableView) -> Int {
        // NSOutlineView 是 NSTableView 子类，但它有自己的数据源方法
        // （numberOfChildrenOfItem），不会走这里。返回 0 而不是查询
        // tableView.numberOfRows —— 后者会再次回调本方法造成无限递归。
        guard tableView === propTable else { return 0 }
        return propRows.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === propTable,
              let c = tableColumn, row < propRows.count else { return nil }
        let r = propRows[row]
        let cellID = NSUserInterfaceItemIdentifier("DevicePropCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self)
            as? NSTextField ?? NSTextField(labelWithString: "")
        cell.identifier = cellID
        cell.font = NSFont.systemFont(ofSize: 11)
        cell.lineBreakMode = .byTruncatingTail
        cell.textColor = .labelColor
        var fullText = ""
        switch c.identifier.rawValue {
        case "propKey":   fullText = r.key;   cell.stringValue = r.key
        case "propType":  fullText = r.type;  cell.stringValue = r.type
        default:
            fullText = r.value
            cell.stringValue = r.value
            if r.type == "pid" || r.type == "bundle" { cell.textColor = .linkColor }
        }
        // cell 会被复用，每行都必须重设，否则悬停提示会残留上一行的内容
        cell.toolTip = fullText.isEmpty ? nil : fullText
        return cell
    }

    // -----------------------------------------------------------------
    // ⌘C：优先复制树选中行，其次属性表选中行
    // -----------------------------------------------------------------

    func copySelectedRowsToPasteboard() -> Bool {
        if outline.selectedRow >= 0, let n = selectedNode() {
            Clipboard.setString(Clipboard.joined(rows: [[
                n.name, n.className, n.driverBundleID,
                n.clientPID.map(String.init) ?? "—",
                String(format: "0x%llx", n.entryID), n.path,
            ]], columns: Self.columnIDs.map { Self.columnTitle($0) }))
            return true
        }
        let rows = propTable.selectedRowIndexes.compactMap { i -> [String]? in
            guard i < propRows.count else { return nil }
            let r = propRows[i]
            return [r.key, r.type, r.value]
        }
        guard !rows.isEmpty else { return false }
        Clipboard.setString(Clipboard.joined(rows: rows))
        return true
    }
}
