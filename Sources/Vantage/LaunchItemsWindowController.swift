// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 启动项 / 后台任务窗口（⌘⌥J）
//
// 只读展示 + 右键做加载 / 卸载 / 启用 / 禁用。表格复用
// DetailTableViewController，过滤、列宽记忆、复制行都是现成的。
// ---------------------------------------------------------------------

final class LaunchItemsWindowController: NSWindowController {

    static let shared = LaunchItemsWindowController()

    private static let frameName = "VantageLaunchItemsWindow"

    private let table = DetailTableViewController()
    /// 下半部分：选中条目的 plist 详情（判断「它是干什么的」必须靠这个）
    private let detail = DetailTableViewController()
    /// 详情面板容器（表头 + 表格）
    private let detailContainer = NSViewController()
    /// 上列表 / 下详情
    private let splitVC = NSSplitViewController()
    /// 窗口根控制器（工具栏 + split）
    private let contentVC = NSViewController()
    private let detailTitle = UI.label("", size: 11, weight: .semibold)
    private let detailHint = UI.label("", size: 10, color: .secondaryLabelColor)
    private let refreshButton = NSButton(frame: .zero)
    private let hideAppleCheck = NSButton(frame: .zero)
    private let hintLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let countLabel = UI.label("", size: 11, color: .secondaryLabelColor)

    private var items: [LaunchItem] = []

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = L("launch.windowTitle")
        w.minSize = NSSize(width: 820, height: 420)
        w.center()
        w.setFrameAutosaveName(Self.frameName)
        super.init(window: w)

        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChanged),
            name: .languageDidChange, object: nil)
        // 提权状态变化后作用域会变（多出其他用户），有窗口就重扫一次
        NotificationCenter.default.addObserver(
            self, selector: #selector(privilegeChanged),
            name: .vantagePrivilegeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError(L("window.initCoderNotImplemented")) }

    override func showWindow(_ sender: Any?) {
        window?.ensureVisibleOnScreens(autosaveName: Self.frameName)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        reload()
        AppActivate.front()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: 界面

    private func setupUI() {
        guard let window = self.window else { return }

        refreshButton.title = L("launch.refresh")
        refreshButton.bezelStyle = .rounded
        refreshButton.font = NSFont.systemFont(ofSize: 12)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))

        hideAppleCheck.setButtonType(.switch)
        hideAppleCheck.title = L("launch.hideApple")
        hideAppleCheck.font = NSFont.systemFont(ofSize: 11)
        hideAppleCheck.state = .on
        hideAppleCheck.target = self
        hideAppleCheck.action = #selector(filterToggled(_:))

        hintLabel.stringValue = L("launch.hint")
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow,
                                                          for: .horizontal)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let bar = NSStackView(views: [refreshButton, hideAppleCheck,
                                      hintLabel, countLabel])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false

        table.storageKey = "Vantage.launchitems"
        table.widthTarget = 1140
        table.columnWeights = [95, 245, 90, 195, 172, 145, 290]
        table.doubleClickHandler = { [weak self] _, _, row in
            self?.reveal(path: row.last ?? "") ?? false
        }
        table.extraMenuItems = { [weak self] row in
            self?.menuItems(for: row) ?? []
        }
        let tableView = table.view
        tableView.translatesAutoresizingMaskIntoConstraints = false

        // 详情面板：两列（项目 / 值），值列吃掉剩余宽度
        detail.storageKey = "Vantage.launchitems.detail"
        detail.widthTarget = 1140
        detail.setPairs([], headers: [L("launch.detItem"), L("launch.detValue")])
        detail.showPlaceholder(L("launch.detHint"))
        detailTitle.stringValue = L("launch.detTitle")
        detailTitle.translatesAutoresizingMaskIntoConstraints = false
        detailHint.stringValue = L("launch.detHint")
        detailHint.lineBreakMode = .byTruncatingTail
        detailHint.setContentCompressionResistancePriority(.defaultLow,
                                                           for: .horizontal)

        let detailHeader = NSStackView(views: [detailTitle, detailHint])
        detailHeader.orientation = .horizontal
        detailHeader.spacing = 8
        detailHeader.alignment = .centerY
        detailHeader.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        detailHeader.translatesAutoresizingMaskIntoConstraints = false

        let detailPane = NSView()
        detailPane.addSubview(detailHeader)
        detailPane.addSubview(detail.view)
        detail.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailHeader.topAnchor.constraint(equalTo: detailPane.topAnchor),
            detailHeader.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            detailHeader.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            detailHeader.heightAnchor.constraint(equalToConstant: 24),
            detail.view.topAnchor.constraint(equalTo: detailHeader.bottomAnchor),
            detail.view.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            detail.view.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            detail.view.bottomAnchor.constraint(equalTo: detailPane.bottomAnchor),
        ])
        detailContainer.addChild(detail)
        detailContainer.view = detailPane

        table.selectionHandler = { [weak self] row in
            self?.showDetails(for: row)
        }

        // 用 NSSplitViewController 而不是裸 NSSplitView：后者在自动布局下
        // 用「加入时的 frame」算初始分割位置，两个子视图都还没布局时会算出
        // 0 高度，列表整块消失（踩过）。NSSplitViewController 带最小厚度。
        splitVC.splitView.isVertical = false
        let topItem = NSSplitViewItem(viewController: table)
        topItem.minimumThickness = 160
        let bottomItem = NSSplitViewItem(viewController: detailContainer)
        bottomItem.minimumThickness = 120
        bottomItem.canCollapse = true
        // 窗口变高变矮时让详情面板吸收变化，列表保持稳定
        bottomItem.holdingPriority = .init(250)
        splitVC.addSplitViewItem(topItem)
        splitVC.addSplitViewItem(bottomItem)

        let rootVC = NSViewController()
        let root = NSView()
        rootVC.view = root
        root.addSubview(bar)
        contentVC.addChild(splitVC)
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitVC.view)
        window.contentViewController = rootVC
        // contentViewController 会按 fittingSize 反向收窗口（偏好窗口踩过），
        // 这里显式还原默认尺寸并居中。
        window.setContentSize(NSSize(width: 1180, height: 700))
        window.center()

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),

            splitVC.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // 首次显示给 6:4；之后用户拖动的位置由 NSSplitView 自己记住
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.splitVC.splitView.frame.height > 240,
                  self.splitVC.splitViewItems.count >= 2,
                  self.splitVC.splitViewItems[1].viewController.view.frame.height < 80
            else { return }
            self.splitVC.splitView.setPosition(
                self.splitVC.splitView.frame.height * 0.62, ofDividerAt: 0)
        }
    }

    @objc private func refreshClicked(_ sender: Any?) { reload() }

    @objc private func filterToggled(_ sender: Any?) { applyFilter() }

    @objc private func languageChanged() {
        window?.title = L("launch.windowTitle")
        refreshButton.title = L("launch.refresh")
        hideAppleCheck.title = L("launch.hideApple")
        hintLabel.stringValue = L("launch.hint")
        table.reapplyFilter()
        reload()
    }

    @objc private func privilegeChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.privilegeChanged() }
            return
        }
        guard isWindowLoaded, window?.isVisible == true else { return }
        reload()
    }

    // MARK: 详情

    /// 选中某行 → 把该条目的 plist 摊平成两列表格
    private func showDetails(for row: [String]) {
        guard let path = row.last,
              let item = items.first(where: {
                  $0.path == path && $0.label == row[safe: 1]
              }) else {
            detail.showPlaceholder(L("launch.detHint"))
            detailHint.stringValue = L("launch.detHint")
            return
        }
        let pairs = item.detailRows()
        detail.setPairs(pairs, headers: [L("launch.detItem"),
                                        L("launch.detValue")])
        detailHint.stringValue = item.label
    }

    // MARK: 数据

    private func reload() {
        // 扫描包含目录枚举 + 每个 launchd 域一次 `launchctl print`，
        // 放到后台避免窗口打开时卡一下（系统域 400+ 服务）。
        let hideApple = hideAppleCheck.state == .on
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let all = LaunchItemsReader.scan()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.items = all
                self.applyFilter(hideApple: hideApple)
            }
        }
    }

    private func applyFilter(hideApple: Bool? = nil) {
        let hide = hideApple ?? (hideAppleCheck.state == .on)
        let visible = items.filter { !hide || !$0.isApple }
        // 刷新会重建行，选中项按 plist 路径找回，详情面板不至于闪成占位
        let selectedPath = table.selectedRowValues?.last
        table.setRows(visible.map { $0.row },
                      headers: [L("launch.colScope"), L("launch.colLabel"),
                                L("launch.colKind"), L("launch.colProgram"),
                                L("launch.colTrigger"), L("launch.colState"),
                                L("launch.colPath")])
        countLabel.stringValue = L("launch.count", visible.count, items.count)

        if let path = selectedPath,
           let idx = visible.firstIndex(where: { $0.path == path }) {
            table.selectVisibleRow(idx)
        } else {
            detail.showPlaceholder(L("launch.detHint"))
            detailHint.stringValue = L("launch.detHint")
        }
    }

    // MARK: 右键

    private func item(for row: [String]) -> LaunchItem? {
        guard let path = row.last else { return nil }
        return items.first { $0.path == path && $0.label == row[1] }
    }

    private func menuItems(for row: [String]) -> [NSMenuItem] {
        guard let it = item(for: row) else { return [] }
        var out: [NSMenuItem] = []

        let reveal = NSMenuItem(title: L("launch.menuReveal"),
                                action: #selector(revealClicked(_:)),
                                keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = it.path
        out.append(reveal)

        let copyLabel = NSMenuItem(title: L("launch.menuCopyLabel"),
                                   action: #selector(copyLabelClicked(_:)),
                                   keyEquivalent: "")
        copyLabel.target = self
        copyLabel.representedObject = it.label
        out.append(copyLabel)

        let copyPath = NSMenuItem(title: L("launch.menuCopyPath"),
                                  action: #selector(copyLabelClicked(_:)),
                                  keyEquivalent: "")
        copyPath.target = self
        copyPath.representedObject = it.path
        out.append(copyPath)

        // 写操作：Apple 自带的 / SIP 保护的一律不给入口，避免把系统搞坏
        guard it.isEditable, !it.isApple else { return out }
        out.append(.separator())

        for (action, enabled) in [(LaunchItemsReader.Action.load, !it.loaded),
                                  (.unload, it.loaded),
                                  (.enable, it.disabled),
                                  (.disable, !it.disabled)] {
            let mi = NSMenuItem(title: action.title,
                                action: #selector(actionClicked(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.isEnabled = enabled
            mi.representedObject = LaunchActionBox(action: action, item: it)
            out.append(mi)
        }
        return out
    }

    @objc private func revealClicked(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: path)])
    }

    @objc private func copyLabelClicked(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func actionClicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? LaunchActionBox else {
            return
        }
        let it = box.item

        let alert = NSAlert()
        alert.messageText = L("launch.confirmTitle", box.action.title, it.label)
        alert.informativeText = L("launch.confirmBody", it.domain)
        alert.alertStyle = .warning
        alert.addButton(withTitle: box.action.title)
        alert.addButton(withTitle: L("app.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = LaunchItemsReader.perform(box.action, on: it)
        if result.rc != 0 {
            let fail = NSAlert()
            fail.messageText = L("launch.failed", box.action.title)
            fail.informativeText = result.output.isEmpty
                ? "rc=\(result.rc)" : result.output
            fail.addButton(withTitle: L("app.ok"))
            fail.runModal()
        }
        reload()
    }

    @discardableResult
    private func reveal(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: path)])
        return true
    }
}

/// 右键项的载荷（NSMenuItem.representedObject 只收 AnyObject）
private final class LaunchActionBox {
    let action: LaunchItemsReader.Action
    let item: LaunchItem

    init(action: LaunchItemsReader.Action, item: LaunchItem) {
        self.action = action
        self.item = item
    }
}
