// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 系统扩展 / 驱动 bundle 列表（⌘⌥E）
//
// 列出 .kext / .dext / .systemextension / .appex 四类 bundle，字段全部来自
// 各 bundle 自带的 Info.plist；状态来自 kmutil showloaded 与
// systemextensionsctl list。双击 Bundle ID 到设备树里找使用该驱动的设备，
// 双击路径在 Finder 显示，签名 Team ID 选中时才按需校验。
// ---------------------------------------------------------------------

final class ExtensionsWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, RowTextCopying {

    static let shared = ExtensionsWindowController()

    private let table = ActionTableView(frame: .zero)
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchField = NSSearchField(frame: .zero)
    private let regexButton = NSButton(frame: .zero)
    private let refreshButton = NSButton(frame: .zero)
    private let scanAppsCheck = NSButton(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    private var visible: [ExtensionBundle] = []
    private var signingCache: [String: (String, String)] = [:]
    private var forceLiteralSearch = false
    private var scanning = false

    private static let columnIDs = ["extKind", "extName", "extBundleID",
                                    "extVersion", "extPoint", "extStatus",
                                    "extIOClasses", "extPath"]
    private static let columnWidths: [CGFloat] =
        [76, 165, 230, 96, 150, 80, 70, 380]

    private var mode: SearchMatchMode {
        forceLiteralSearch ? .literal
            : (Preferences.shared.searchUseRegex ? .regex : .literal)
    }

    // -----------------------------------------------------------------
    // 初始化
    // -----------------------------------------------------------------

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = L("ext.windowTitle")
        w.minSize = NSSize(width: 860, height: 460)
        w.center()
        w.setFrameAutosaveName("VantageExtensionsWindow")
        super.init(window: w)
        setupUI()
        observe()
    }

    required init?(coder: NSCoder) { return nil }

    override func showWindow(_ sender: Any?) {
        window?.ensureVisibleOnScreens(autosaveName: "VantageExtensionsWindow")
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        AppActivate.front()
        if ExtensionScanner.shared.bundles.isEmpty && !scanning { rescan() }
    }

    // -----------------------------------------------------------------
    // 界面
    // -----------------------------------------------------------------

    private func setupUI() {
        guard let window = self.window else { return }
        let root = NSView()
        window.contentView = root

        rebuildKindPopup()
        kindPopup.font = NSFont.systemFont(ofSize: 12)
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))

        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        regexButton.title = ".*"
        regexButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        regexButton.bezelStyle = .rounded
        regexButton.setButtonType(.pushOnPushOff)
        regexButton.target = self
        regexButton.action = #selector(regexToggled(_:))
        regexButton.toolTip = L("window.regexModeTooltip")

        refreshButton.title = L("ext.refresh")
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))

        scanAppsCheck.setButtonType(.switch)
        scanAppsCheck.title = L("ext.scanApps")
        scanAppsCheck.font = NSFont.systemFont(ofSize: 11)
        scanAppsCheck.target = self
        scanAppsCheck.action = #selector(scanAppsToggled(_:))
        scanAppsCheck.state = Preferences.shared.scanAppExtensions ? .on : .off

        let toolbar = NSStackView(views: [kindPopup, searchField, regexButton,
                                          scanAppsCheck, refreshButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.distribution = .fill
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [kindPopup, regexButton, scanAppsCheck, refreshButton] {
            v.setContentCompressionResistancePriority(.defaultHigh,
                                                      for: .horizontal)
        }

        setupTable()
        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.cell?.wraps = true
        detailLabel.cell?.isScrollable = false
        detailLabel.maximumNumberOfLines = 2
        detailLabel.heightAnchor.constraint(equalToConstant: 34).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        for v in [toolbar, scroll, detailLabel, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            toolbar.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -6),

            detailLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            detailLabel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
        syncControls()
        updateStatus()
        updateDetail()
    }

    private func rebuildKindPopup() {
        kindPopup.removeAllItems()
        kindPopup.addItem(withTitle: L("ext.kind.all"))
        for k in ExtensionKind.allCases { kindPopup.addItem(withTitle: k.title) }
    }

    private func setupTable() {
        for (i, id) in Self.columnIDs.enumerated() {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = Self.columnTitle(id)
            c.width = Self.columnWidths[i]
            c.minWidth = 44
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .small
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.onModifierClick = { [weak self] row, col in
            self?.performRowAction(row: row, col: col)
        }
    }

    private static func columnTitle(_ id: String) -> String {
        switch id {
        case "extKind":       return L("ext.col.kind")
        case "extName":       return L("ext.col.name")
        case "extBundleID":   return L("ext.col.bundleID")
        case "extVersion":    return L("ext.col.version")
        case "extPoint":      return L("ext.col.point")
        case "extStatus":     return L("ext.col.status")
        case "extIOClasses":  return L("ext.col.ioClasses")
        default:              return L("ext.col.path")
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
            self, selector: #selector(columnWidthsShouldReset),
            name: .columnWidthsShouldReset, object: nil)
    }

    @objc private func languageChanged() {
        window?.title = L("ext.windowTitle")
        for c in table.tableColumns { c.title = Self.columnTitle(c.identifier.rawValue) }
        let sel = kindPopup.indexOfSelectedItem
        rebuildKindPopup()
        kindPopup.selectItem(at: max(0, min(sel, kindPopup.numberOfItems - 1)))
        refreshButton.title = L("ext.refresh")
        scanAppsCheck.title = L("ext.scanApps")
        regexButton.toolTip = L("window.regexModeTooltip")
        syncControls()
        applyFilter()
        updateStatus()
        updateDetail()
    }

    @objc private func searchModeChanged() { syncControls(); applyFilter() }

    @objc private func columnWidthsShouldReset() {
        for (i, c) in table.tableColumns.enumerated() {
            if i < Self.columnWidths.count { c.width = Self.columnWidths[i] }
        }
    }

    private func modePlaceholder() -> String {
        mode == .regex ? L("ext.searchRegexPlaceholder") : L("ext.searchPlaceholder")
    }

    private func syncControls() {
        regexButton.state = (mode == .regex) ? .on : .off
        regexButton.isEnabled = !forceLiteralSearch
        if !forceLiteralSearch { searchField.placeholderString = modePlaceholder() }
    }

    // -----------------------------------------------------------------
    // 扫描
    // -----------------------------------------------------------------

    @objc private func refreshClicked(_ sender: Any?) { rescan() }
    @objc private func kindChanged(_ sender: Any?) { applyFilter() }
    @objc private func searchChanged(_ sender: Any?) { applyFilter() }
    @objc private func regexToggled(_ sender: Any?) {
        Preferences.shared.searchUseRegex = (regexButton.state == .on)
        Preferences.shared.applyToRuntime()
        NotificationCenter.default.post(name: .searchModeDidChange, object: nil)
    }
    @objc private func scanAppsToggled(_ sender: Any?) {
        Preferences.shared.scanAppExtensions = (scanAppsCheck.state == .on)
        Preferences.shared.applyToRuntime()
        rescan()
    }

    private func rescan() {
        guard !scanning else { return }
        scanning = true
        statusLabel.stringValue = L("ext.status.scanning")
        let include = Preferences.shared.scanAppExtensions
        ExtensionScanner.shared.scan(includeApps: include) { [weak self] _ in
            guard let self = self else { return }
            self.scanning = false
            self.applyFilter()
            self.updateStatus()
            self.updateDetail()
        }
    }

    // -----------------------------------------------------------------
    // 过滤
    // -----------------------------------------------------------------

    private func applyFilter() {
        let all = ExtensionScanner.shared.bundles
        let m = SearchMatcher(query: searchField.stringValue, mode: mode)
        let kindIndex = kindPopup.indexOfSelectedItem
        let chosen: ExtensionKind? = kindIndex > 0
            ? ExtensionKind.allCases[safe: kindIndex - 1] : nil
        visible = all.filter { b in
            if let k = chosen, b.kind != k { return false }
            if m.isEmpty { return true }
            return m.matches(anyOf: [
                b.kind.title, b.name, b.bundleID, b.displayVersion,
                b.extensionPoint, b.executable, b.path, b.statusTitle,
                b.ioClasses.joined(separator: " "),
            ])
        }
        table.reloadData()
        updateStatus()
    }

    private func updateStatus() {
        let total = ExtensionScanner.shared.bundles.count
        var s = L("ext.status.count", visible.count, total)
        if ExtensionScanner.shared.truncated { s += L("ext.status.truncated") }
        if !ExtensionScanner.shared.statusCLIsAvailable {
            s += L("ext.status.noCLI")
        }
        if let err = SearchMatcher(query: searchField.stringValue,
                                   mode: mode).errorText,
           !err.isEmpty, !forceLiteralSearch {
            s += L("window.invalidRegexFallback", err)
        }
        if ExtensionScanner.shared.scannedAt == nil { s = L("ext.status.notScanned") }
        statusLabel.stringValue = s
    }

    // -----------------------------------------------------------------
    // 详情（签名按需）
    // -----------------------------------------------------------------

    private func selectedBundle() -> ExtensionBundle? {
        let r = table.selectedRow
        guard r >= 0, r < visible.count else { return nil }
        return visible[r]
    }

    private func updateDetail() {
        guard let b = selectedBundle() else {
            detailLabel.stringValue = L("ext.detailHint")
            return
        }
        let line1 = b.kind.title + "  ·  " + b.name
            + "  ·  " + b.displayVersion
            + "  ·  " + b.statusTitle
        var line2 = b.path
        if !b.ioClasses.isEmpty {
            line2 += "  ·  " + L("ext.detail.ioClasses",
                                 b.ioClasses.count,
                                 b.ioClasses.prefix(6).joined(separator: ", "))
        }
        if let c = signingCache[b.path] {
            if !c.0.isEmpty { line2 += "  ·  " + L("ext.detail.team", c.0) }
            if !c.1.isEmpty { line2 += "  ·  " + c.1 }
        } else {
            let path = b.path
            DispatchQueue.global(qos: .userInitiated).async {
                let c = ExtensionScanner.signing(path: path)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.signingCache[path] = c
                    if self.selectedBundle()?.path == path { self.updateDetail() }
                }
            }
        }
        detailLabel.stringValue = line1 + "\n" + line2
    }

    // -----------------------------------------------------------------
    // 交互
    // -----------------------------------------------------------------

    @objc private func rowDoubleClicked(_ sender: Any?) {
        if table.clickGate.consumeRecent() { return }
        performRowAction(row: table.clickedRow >= 0
                            ? table.clickedRow : table.selectedRow,
                         col: table.clickedColumn)
    }

    private func performRowAction(row: Int, col: Int) {
        guard row >= 0, row < visible.count else { return }
        let b = visible[row]
        let id = (col >= 0 && col < table.tableColumns.count)
            ? table.tableColumns[col].identifier.rawValue : ""
        if id == "extPath" {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: b.path)])
            return
        }
        if !b.bundleID.isEmpty {
            DeviceBrowserWindowController.shared.focusOn(bundleID: b.bundleID)
        } else {
            Clipboard.setString(b.path)
        }
    }

    /// 从设备树双击驱动 Bundle 跳过来
    func focusOn(bundleID: String) {
        forceLiteralSearch = true
        searchField.stringValue = bundleID
        syncControls()
        let had = !ExtensionScanner.shared.bundles.isEmpty
        showWindow(nil)
        if had { applyFilter() }
    }

    // -----------------------------------------------------------------
    // 数据源 / 代理
    // -----------------------------------------------------------------

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let c = tableColumn, row < visible.count else { return nil }
        let b = visible[row]
        let cellID = NSUserInterfaceItemIdentifier("ExtCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self)
            as? NSTextField ?? NSTextField(labelWithString: "")
        cell.identifier = cellID
        cell.font = NSFont.systemFont(ofSize: 11)
        cell.lineBreakMode = .byTruncatingTail
        cell.textColor = .labelColor
        switch c.identifier.rawValue {
        case "extKind":      cell.stringValue = b.kind.title
        case "extName":      cell.stringValue = b.name
        case "extBundleID":
            cell.stringValue = b.bundleID.isEmpty ? "—" : b.bundleID
            if !b.bundleID.isEmpty { cell.textColor = .linkColor }
        case "extVersion":   cell.stringValue = b.displayVersion
        case "extPoint":     cell.stringValue = b.extensionPoint
        case "extStatus":    cell.stringValue = b.statusTitle
        case "extIOClasses": cell.stringValue = b.ioClasses.isEmpty
                                ? "—" : "\(b.ioClasses.count)"
        default:
            cell.stringValue = b.path
            cell.toolTip = b.path
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    // -----------------------------------------------------------------
    // ⌘C
    // -----------------------------------------------------------------

    func copySelectedRowsToPasteboard() -> Bool {
        let rows = table.selectedRowIndexes.compactMap { i -> [String]? in
            guard i < visible.count else { return nil }
            let b = visible[i]
            return [b.kind.title, b.name, b.bundleID, b.displayVersion,
                    b.extensionPoint, b.statusTitle,
                    "\(b.ioClasses.count)", b.path]
        }
        guard !rows.isEmpty else { return false }
        Clipboard.setString(Clipboard.joined(
            rows: rows,
            columns: Self.columnIDs.map { Self.columnTitle($0) }))
        return true
    }
}
