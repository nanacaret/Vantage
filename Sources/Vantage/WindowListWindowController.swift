// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 「窗口列表」窗口：列出所有屏幕窗口及其 owner PID，双击定位到进程。
// 准星模式的补充 —— 准星失败（例如没有全局事件权限）时，列表仍可定位。
// ---------------------------------------------------------------------

// 不标 private：让它能自然满足 internal 协议 RowTextCopying 的见证可见性要求
final class WindowListViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, RowTextCopying {

    private let table = ActionTableView(frame: .zero)
    private let search = NSSearchField(frame: .zero)
    private let status = UI.label("", size: 10, color: .secondaryLabelColor)
    private var all: [WindowInfo] = []
    private var shown: [WindowInfo] = []
    private var query = ""

    private let headers = [L("window.window"), L("window.process"), "PID", L("window.layer"), L("window.positionSize"), L("window.windowId")]

    /// 6 列合计 702pt，窗口默认 900pt 宽 —— 820pt 方案里「窗口」单列占 300，
    /// 把进程名、PID、位置挤得只能靠横滚才能看全。
    private static let defaultWidths: [CGFloat] = [220, 132, 60, 48, 158, 84]

    override func loadView() {
        view = NSView()

        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.toolTip =
            L("window.doubleClickLocateTheOwning")
        // 唯一「双击 ≠ 修饰键单击」的地方：双击定位进程，修饰键单击激活窗口
        table.onModifierClick = { [weak self] row, _ in
            self?.activateWindow(at: row)
        }

        for (i, title) in headers.enumerated() {
            let col = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("wcol\(i)"))
            col.title = title
            col.width = Self.defaultWidths[i]
            col.minWidth = 44
            col.isEditable = false
            table.addTableColumn(col)
        }

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder

        search.placeholderString = L("window.filterWindowTitleProcessPid")
        search.target = self
        search.action = #selector(searchChanged(_:))

        let pickBtn = UI.button(L("window.pickWithCrosshair"), target: self,
                                action: #selector(pickClicked))
        let locateBtn = UI.button(L("window.locateProcess"), target: self,
                                  action: #selector(locateClicked))
        let activateBtn = UI.button(L("window.activateWindow"), target: self,
                                    action: #selector(activateClicked))
        let refreshBtn = UI.button(L("window.refresh2"), target: self,
                                   action: #selector(refreshClicked))
        let authBtn = UI.button(L("window.authorizeWindowTitles"), target: self,
                                action: #selector(authClicked))

        let bar = NSStackView(views: [search, pickBtn, locateBtn,
                                      activateBtn, refreshBtn, authBtn])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.distribution = .fill
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for b in [pickBtn, locateBtn, activateBtn, refreshBtn, authBtn] {
            b.setContentCompressionResistancePriority(.defaultHigh,
                                                       for: .horizontal)
        }

        let bottom = NSView()
        status.translatesAutoresizingMaskIntoConstraints = false
        bottom.addSubview(status)

        for v in [bar, scroll, bottom] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 42),

            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 24),

            status.leadingAnchor.constraint(equalTo: bottom.leadingAnchor,
                                            constant: 10),
            status.trailingAnchor.constraint(equalTo: bottom.trailingAnchor,
                                             constant: -10),
            status.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(colorsChanged),
            name: .appColorsDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resetColumnWidths),
            name: .columnWidthsShouldReset, object: nil)
        reload()
    }

    @objc private func colorsChanged(_ n: Notification) {
        guard isViewLoaded else { return }
        table.reloadData()
    }

    /// 窗口列表的列宽不持久化，重置只需按默认数组写回。
    @objc private func resetColumnWidths(_ n: Notification) {
        guard isViewLoaded else { return }
        for (i, col) in table.tableColumns.enumerated()
            where i < Self.defaultWidths.count {
            col.width = Self.defaultWidths[i]
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func reload() {
        all = WindowLocator.onScreenWindows(force: true)
            .filter { $0.layer == 0 && $0.bounds.width >= 1 && $0.bounds.height >= 1 }
        applyFilter()
        let granted = WindowLocator.hasScreenCaptureAccess
        let ax = WindowActivator.accessibilityTrusted
        status.stringValue =
            L("window.totalWindowsDoubleClickLocate", all.count)
            + (granted ? L("window.titlesAuthorized") : L("window.titlesNeedScreenRecording"))
            + (ax ? L("window.accessibilityAuthorized") : L("window.activatingWindowsNeedsAccessibility"))
    }

    private func applyFilter() {
        if query.isEmpty {
            shown = all
        } else {
            shown = all.filter {
                "\($0.displayTitle) \($0.ownerName) \($0.ownerPID) \($0.number)"
                    .lowercased().contains(query)
            }
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < shown.count else { return nil }
        let idx = Int(col.identifier.rawValue.replacingOccurrences(of: "wcol",
                                                                  with: "")) ?? 0
        let w = shown[row]
        let text: String
        switch idx {
        case 0:  text = w.displayTitle
        case 1:  text = w.ownerName
        case 2:  text = "\(w.ownerPID)"
        case 3:  text = "\(w.layer)"
        case 4:  text = w.boundsText
        default: text = "\(w.number)"
        }
        let cell = (tableView.makeView(withIdentifier: col.identifier, owner: self)
                    as? TextCell) ?? TextCell(frame: .zero)
        cell.identifier = col.identifier
        cell.configure(text,
                       color: idx == 2 ? AppColors.shared.color(.pidLink) : .labelColor,
                       alignment: (idx == 2 || idx == 3 || idx == 5) ? .right : .left)
        return cell
    }

    // MARK: RowTextCopying —— ⌘C 复制选中窗口行

    func copySelectedRowsToPasteboard() -> Bool {
        guard !shown.isEmpty else { return false }
        func cells(_ w: WindowInfo) -> [String] {
            [w.displayTitle, w.ownerName, "\(w.ownerPID)", "\(w.layer)",
             w.boundsText, "\(w.number)"]
        }
        let row = table.selectedRow
        let picked: [[String]]
        if row >= 0, row < shown.count {
            picked = [cells(shown[row])]
            Clipboard.setString(Clipboard.joined(rows: picked))
        } else {
            picked = shown.map(cells)
            Clipboard.setString(Clipboard.joined(rows: picked, columns: headers))
        }
        return true
    }

    private func pidForAction() -> Int32? {
        let row = table.selectedRow >= 0 ? table.selectedRow : table.clickedRow
        guard row >= 0, row < shown.count else { return nil }
        return shown[row].ownerPID
    }

    /// 双击保持原语义：定位到拥有该窗口的进程（并打开检查器）
    @objc private func doubleClicked() {
        guard !table.clickGate.consumeRecent() else { return }
        guard let pid = pidForAction() else { return }
        AppContext.shared.locateProcess(pid)
    }

    /// ⌘ / ⌥ + 单击（或「激活窗口」按钮）：把**这一个**窗口前置激活
    private func activateWindow(at row: Int) {
        guard row >= 0, row < shown.count else { return }
        let w = shown[row]
        if WindowActivator.activateAndReport(windowNumber: w.number,
                                             ownerPID: w.ownerPID) {
            status.stringValue =
                L("window.activatedWindowPid", w.number, w.ownerName, w.ownerPID)
        }
    }

    @objc private func activateClicked() {
        let row = table.selectedRow >= 0 ? table.selectedRow : table.clickedRow
        guard row >= 0 else {
            AppContext.shared.showError(L("window.selectAWindowRowFirst"))
            return
        }
        activateWindow(at: row)
    }

    @objc private func locateClicked() {
        guard let pid = pidForAction() else {
            AppContext.shared.showError(L("window.selectAWindowRowFirst2"))
            return
        }
        AppContext.shared.locateProcess(pid)
    }

    @objc private func pickClicked() {
        var hide: [NSWindow] = []
        if let w = view.window { hide.append(w) }
        if let mw = AppContext.shared.mainWindow?.window, mw !== view.window {
            hide.append(mw)
        }
        WindowPicker.shared.begin(
            hiding: hide,
            onPick: { [weak self] pid in
                AppContext.shared.locateProcess(pid)
                self?.reload()
            },
            onCancel: { [weak self] in
                self?.view.window?.makeKeyAndOrderFront(nil)
            })
    }

    @objc private func refreshClicked() { reload() }

    @objc private func authClicked() {
        WindowLocator.requestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = L("window.screenRecordingPermissionRequested")
        alert.informativeText =
            L("window.afterAllowingThisAppIn")
        alert.addButton(withTitle: L("window.ok"))
        alert.runModal()
        reload()
    }

    @objc private func searchChanged(_ sender: Any?) {
        query = search.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        applyFilter()
    }
}

final class WindowListWindowController: NSWindowController {

    static let shared = WindowListWindowController()
    private let listVC = WindowListViewController()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("window.windowListLocateProcess")
        w.minSize = NSSize(width: 620, height: 320)
        w.center()
        super.init(window: w)
        w.contentViewController = listVC
    }

    required init?(coder: NSCoder) { fatalError(L("window.initCoderNotImplemented3")) }

    override func showWindow(_ sender: Any?) {
        _ = listVC.view            // 触发 loadView，确保首次显示就有数据
        listVC.reload()
        super.showWindow(sender)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        AppActivate.front()
    }
}

// ---------------------------------------------------------------------
// 统一的 App 激活：activate(ignoringOtherApps:) 在 macOS 14 起废弃
// ---------------------------------------------------------------------

enum AppActivate {
    static func front() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
