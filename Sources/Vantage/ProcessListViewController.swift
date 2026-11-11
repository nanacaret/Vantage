// SPDX-License-Identifier: MIT
import AppKit

// ---------------------------------------------------------------------
// 自定义单元格
// ---------------------------------------------------------------------

final class NameCell: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let iv = NSImageView(frame: .zero)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        addSubview(iv)
        imageView = iv

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = NSFont.systemFont(ofSize: 12)
        tf.lineBreakMode = .byTruncatingTail
        addSubview(tf)
        textField = tf

        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError(L("list.initCoderNotImplemented")) }

    func configure(_ p: ProcessSnapshot) {
        imageView?.image = IconCache.shared.icon(for: p)
        textField?.stringValue = p.isExited ? "✕ \(p.displayLabel)" : p.displayLabel
        textField?.textColor = p.isExited
            ? AppColors.shared.color(.exitedText)
            : (p.stateName == "ZOMBIE" ? .secondaryLabelColor : .labelColor)
        // 列宽有限时组合名可能被截断，tooltip 始终给出完整身份
        toolTip = L("list.nameTooltip", p.displayLabel,
                    p.rawName.isEmpty ? "—" : p.rawName)
            + (p.exepath.isEmpty ? "" : "\n\(p.exepath)")
    }
}

/// 已退出进程（宽限期内）的整行背景高亮。
/// 用 NSOutlineViewDelegate 的 `outlineView(_:rowViewForItem:)` 返回自定义行视图，
/// 其余行返回 nil 交给 AppKit，这样 alternating row 与选中态都由系统负责。
final class ExitedRowView: NSTableRowView {
    var tint: NSColor?
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let c = tint else { return }
        c.setFill()
        dirtyRect.fill()
    }
}

final class TextCell: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.lineBreakMode = .byTruncatingTail
        addSubview(tf)
        textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError(L("list.initCoderNotImplemented2")) }

    func configure(_ text: String, color: NSColor = .labelColor,
                   alignment: NSTextAlignment = .left) {
        textField?.stringValue = text
        textField?.textColor = color
        textField?.alignment = alignment
    }
}

final class ProcOutlineView: NSOutlineView {
    /// ⌘ / ⌥ + 单击 → 与双击效果相同（PID/PPID 跳转或打开检查器）
    var onModifierClick: ((Int, Int) -> Void)?
    let clickGate = ModifierClickGate()

    /// 右键那一行的进程信息。菜单动作直接用它，不依赖「当前选中行」——
    /// 避免刷新 / 多选 / 键盘呼出菜单时把信号发到别的进程。
    private(set) var contextPID: Int32 = 0
    private(set) var contextName = ""
    private(set) var contextExited = false

    /// 右键时先选中该行，再弹出菜单
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        if r >= 0, let n = item(atRow: r) as? ProcessNode {
            contextPID = n.proc.pid
            contextName = n.proc.displayLabel
            contextExited = n.proc.isExited
            selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        } else {
            contextPID = 0
            contextName = ""
            contextExited = false
        }
        super.rightMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        let col = self.column(at: p)
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

// ---------------------------------------------------------------------
// 列表控制器
// ---------------------------------------------------------------------

private struct ColumnDef {
    let id: String
    let title: String
    let width: CGFloat
    let key: SortKey
    let numeric: Bool
    let value: (ProcessSnapshot) -> String
}

final class ProcessListViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDelegate,
    NSMenuDelegate, RowTextCopying {

    private let outline = ProcOutlineView(frame: .zero)
    private var columns: [ColumnDef] = []
    private var roots: [ProcessNode] = []
    private var contextMenu: NSMenu!
    private let signalSubmenu = NSMenu(title: L("list.sendSignal"))
    private var didInitialExpand = false
    private var lastTreeMode: Bool?
    private var scrollToTopOnNextReload = false
    private let columnWidthKey = "Vantage.processColumnWidth"

    override func loadView() {
        columns = Self.makeColumns()
        self.view = NSView()
        configureOutline()

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        UI.pin(scroll, in: view, top: 0, left: 0, bottom: 0, right: 0)

        buildContextMenu()
        outline.menu = contextMenu
        // 菜单每次弹出前重建：信号子菜单按偏好里勾选的项实时变化，
        // 并把右键那一行的 PID 写进每个菜单项。
        contextMenu.delegate = self
        // ⌘ / ⌥ + 单击 ≡ 双击（主表：PID/PPID 跳转 / 打开检查器）
        outline.onModifierClick = { [weak self] row, col in
            self?.performDoubleAction(col: col, row: row)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: .procStoreDidUpdate, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .preferencesDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(colorsChanged),
            name: .appColorsDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resetColumnWidths),
            name: .columnWidthsShouldReset, object: nil)
        reload()
        updateSortIndicator()
    }

    @objc private func preferencesChanged(_ note: Notification) {
        updateSortIndicator()
        // 树深度 / 过滤等由 store 在下次 notify 时重新读取；这里立即刷一次
        performReload(preserveScroll: true)
    }

    @objc private func colorsChanged(_ note: Notification) {
        // 配色是绘制期读取的，reloadData 一次即可全部生效（保留滚动与列宽）
        performReload(preserveScroll: true)
    }

    /// 默认列宽：14 列合计 **1218pt**，略小于主窗口 1240pt 的可视宽度，
    /// 首次启动不用横向滚动就能看全所有列。若合计 1736pt（cmd 单列就 420），
    /// 需要大幅横滚。用户仍可自由拖宽，拖过的宽度按 identifier 持久化。
    private static func makeColumns() -> [ColumnDef] {
        [
            ColumnDef(id: "name",    title: L("list.processName"), width: 176, key: .name,     numeric: false, value: { $0.displayLabel }),
            ColumnDef(id: "pid",     title: "PID",      width: 52,  key: .pid,      numeric: true,  value: { "\($0.pid)" }),
            ColumnDef(id: "ppid",    title: "PPID",     width: 52,  key: .ppid,     numeric: true,  value: { "\($0.ppid)" }),
            ColumnDef(id: "tty",     title: "TTY",       width: 72,  key: .tty,      numeric: false, value: { $0.ttyShortName }),
            ColumnDef(id: "user",    title: L("list.user"),     width: 68,  key: .user,     numeric: false, value: { $0.userName }),
            ColumnDef(id: "cpu",     title: "% CPU",    width: 60,  key: .cpu,      numeric: true,  value: { Fmt.percent($0.cpuPercent) }),
            ColumnDef(id: "mem",     title: L("list.memory"),     width: 80,  key: .mem,      numeric: true,  value: { Fmt.bytes($0.rss) }),
            ColumnDef(id: "threads", title: L("list.threads"),     width: 52,  key: .threads,  numeric: true,  value: { "\($0.threads)" }),
            ColumnDef(id: "ports",   title: "FD",       width: 48,  key: .ports,    numeric: true,  value: { "\($0.nfiles)" }),
            ColumnDef(id: "state",   title: L("list.status"),     width: 72,  key: .state,    numeric: false, value: { $0.stateName }),
            ColumnDef(id: "arch",    title: L("list.architecture"),     width: 100, key: .arch,     numeric: false, value: { $0.archName }),
            ColumnDef(id: "cputime", title: L("list.cpuTime"), width: 80,  key: .cpuTime, numeric: true,  value: { Fmt.cpuTime($0.cpuTimeNS) }),
            ColumnDef(id: "start",   title: L("list.startTime"), width: 96,  key: .start,   numeric: false, value: { Fmt.startDate($0) }),
            ColumnDef(id: "cmd",     title: L("list.fullCommandPath"), width: 210, key: .cmd, numeric: false,
                      value: { $0.cmdline.isEmpty ? $0.exepath : $0.cmdline }),
        ]
    }

    private func configureOutline() {
        outline.frame = NSRect(x: 0, y: 0, width: 1400, height: 400)
        outline.rowHeight = 20
        outline.indentationPerLevel = 14
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsColumnResizing = true
        outline.allowsColumnReordering = true
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.allowsColumnSelection = false
        outline.delegate = self
        outline.dataSource = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.toolTip =
            L("list.doubleClickOrClickThe")

        for def in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(def.id))
            col.title = def.title
            col.width = def.width
            col.minWidth = 42
            col.isEditable = false
            outline.addTableColumn(col)
        }
        if let first = outline.tableColumns.first {
            outline.outlineTableColumn = first
        }

        // 列宽按 identifier 持久化；刷新 reloadData 完全不动列对象，
        // 用户拖过的宽度不会被重置，重启应用也能保留。
        for col in outline.tableColumns {
            let key = "\(columnWidthKey).\(col.identifier.rawValue)"
            let saved = UserDefaults.standard.double(forKey: key)
            if saved > 0 { col.width = CGFloat(saved) }
        }
    }

    private func saveColumnWidths() {
        for col in outline.tableColumns {
            UserDefaults.standard.set(
                Double(col.width),
                forKey: "\(columnWidthKey).\(col.identifier.rawValue)")
        }
    }

    /// 「视图 → 重置列宽为默认」：按 identifier 找到默认值（用户可能拖过列顺序，
    /// 所以不能按数组下标），不动数据、不动排序、不动滚动位置。
    @objc private func resetColumnWidths(_ note: Notification) {
        var byID: [String: CGFloat] = [:]
        for def in columns { byID[def.id] = def.width }
        for col in outline.tableColumns {
            if let w = byID[col.identifier.rawValue] { col.width = w }
        }
        // 刻意不调 sizeLastColumnToFit()：那会在宽窗口里把「完整命令」列
        // 撑到几百 pt，正好又变回「默认过宽」。右侧留白比横向滚动好。
        // 也不调 saveColumnWidths：让 UserDefaults 保持空的，下次启动仍读默认值。
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        saveColumnWidths()
    }

    // -----------------------------------------------------------------
    // 刷新
    // -----------------------------------------------------------------

    /// 通知 / 菜单触发的刷新入口。避免同名重载：#selector(reload) 一旦存在
    /// 带参版本就会ambiguous，所以实际干活的函数另起名字。
    @objc private func reload() {
        let toTop = scrollToTopOnNextReload
        scrollToTopOnNextReload = false
        performReload(preserveScroll: !toTop)
    }

    /// 刷新时保留：滚动位置（按顶部锚点 PID 对齐）、展开状态、选中行、列宽。
    /// - Parameter preserveScroll: 排序 / 切换视图时传 false，回到顶部。
    private func performReload(preserveScroll: Bool) {
        let store = AppContext.shared.store
        let hadRows = !roots.isEmpty

        // ---- 1. 快照刷新前的视口 ----
        let clip = outline.enclosingScrollView?.contentView
        let savedOrigin = clip?.bounds.origin
        let anchorPID = hadRows ? topVisiblePID() : nil
        let selected = AppContext.shared.selectedPID

        // 节点对象每次重建，展开状态按 PID 还原
        var expanded = Set<Int32>()
        for i in 0..<outline.numberOfRows {
            if let item = outline.item(atRow: i), outline.isItemExpanded(item),
               let n = item as? ProcessNode {
                expanded.insert(n.proc.pid)
            }
        }

        // 树形/列表切换时重置「首次全展开」
        if lastTreeMode != store.treeMode {
            didInitialExpand = false
            lastTreeMode = store.treeMode
        }

        // ---- 2. 重建数据（列对象不动，列宽不会被重置） ----
        roots = store.visibleTree()
        outline.reloadData()

        if store.treeMode {
            if !didInitialExpand {
                outline.expandItem(nil, expandChildren: true)
                didInitialExpand = true
            } else {
                restoreExpansion(roots, expanded)
            }
        }

        // ---- 3. 恢复选中行 ----
        if let pid = selected, let row = rowForPID(pid) {
            outline.selectRowIndexes(IndexSet(integer: row),
                                     byExtendingSelection: false)
        }

        // ---- 4. 恢复滚动 ----
        // preserveScroll == false（排序）时回到左上角，不能沿用当前 bounds.origin
        restoreScroll(anchorPID: preserveScroll ? anchorPID : nil,
                      savedOrigin: preserveScroll ? savedOrigin : NSPoint.zero)
        updateSortIndicator()
    }

    /// 视口最上方可见行的 PID，用作滚动锚点（进程增减时比像素坐标更稳）
    private func topVisiblePID() -> Int32? {
        guard let clip = outline.enclosingScrollView?.contentView else { return nil }
        let r = clip.documentVisibleRect
        let row = outline.row(at: NSPoint(x: r.minX + 2, y: r.minY + 2))
        guard row >= 0, let n = outline.item(atRow: row) as? ProcessNode else {
            return nil
        }
        return n.proc.pid
    }

    private func rowForPID(_ pid: Int32) -> Int? {
        for i in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: i) as? ProcessNode,
               n.proc.pid == pid { return i }
        }
        return nil
    }

    /// 供「通过窗口定位进程」/「双击 PID 值」调用。
    /// 树形模式下目标常是深层子节点，必须先展开整条父链，否则
    /// rowForPID 永远返回 nil（进程在树里，但行还没被展开）。
    @discardableResult
    func selectPID(_ pid: Int32) -> Bool {
        func path(_ nodes: [ProcessNode], _ acc: [ProcessNode]) -> [ProcessNode]? {
            for n in nodes {
                var next = acc
                next.append(n)
                if n.proc.pid == pid { return next }
                if let found = path(n.children, next) { return found }
            }
            return nil
        }
        guard let chain = path(roots, []) else { return false }

        for node in chain.dropLast() where !node.children.isEmpty {
            outline.expandItem(node)
        }
        // 扁平模式 / 刚展开后都重新查一次行号
        if let row = rowForPID(pid) {
            outline.selectRowIndexes(IndexSet(integer: row),
                                     byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            AppContext.shared.selectedPID = pid
            return true
        }
        return false
    }

    private func restoreScroll(anchorPID: Int32?, savedOrigin: NSPoint?) {
        // 新版 SDK 里 NSScrollView.contentView 是非 Optional 的 NSClipView，
        // 不能再用 guard let 解包；只有 enclosingScrollView 需要解包。
        guard let scroll = outline.enclosingScrollView else { return }
        let clip = scroll.contentView
        outline.layoutSubtreeIfNeeded()

        var target = savedOrigin ?? clip.bounds.origin
        if let pid = anchorPID, let row = rowForPID(pid) {
            // 水平位置保持原样，只把垂直位置对齐到锚点行
            target.y = outline.rect(ofRow: row).minY
        }
        // NSClipView 内部会 clamp 到有效范围，无需手工限幅
        clip.scroll(to: target)
        scroll.reflectScrolledClipView(clip)
    }

    private func restoreExpansion(_ nodes: [ProcessNode], _ expanded: Set<Int32>) {
        for n in nodes {
            if !n.children.isEmpty && expanded.contains(n.proc.pid) {
                outline.expandItem(n)
            }
            restoreExpansion(n.children, expanded)
        }
    }

    // -----------------------------------------------------------------
    // DataSource / Delegate
    // -----------------------------------------------------------------

    func outlineView(_ outlineView: NSOutlineView,
                     numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return roots.count }
        return (item as? ProcessNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView,
                     child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return roots[index] }
        guard let n = item as? ProcessNode, index < n.children.count else {
            return NSObject()
        }
        return n.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView,
                     isItemExpandable item: Any) -> Bool {
        guard AppContext.shared.store.treeMode else { return false }
        guard let n = item as? ProcessNode else { return false }
        return !n.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let col = tableColumn,
              let node = item as? ProcessNode,
              let def = columns.first(where: { $0.id == col.identifier.rawValue })
        else { return nil }

        let ident = NSUserInterfaceItemIdentifier(def.id)
        let proc = node.proc

        if def.id == "name" {
            let cell = (outlineView.makeView(withIdentifier: ident, owner: self)
                        as? NameCell) ?? NameCell(frame: .zero)
            cell.identifier = ident
            cell.configure(proc)
            return cell
        }

        let cell = (outlineView.makeView(withIdentifier: ident, owner: self)
                    as? TextCell) ?? TextCell(frame: .zero)
        cell.identifier = ident

        let C = AppColors.shared
        var color: NSColor = .labelColor
        if proc.isExited {
            color = C.color(.exitedText)
        } else {
            switch def.id {
            case "cpu":
                if proc.cpuPercent >= 80 { color = C.color(.cpuHigh) }
                else if proc.cpuPercent >= 40 { color = C.color(.cpuMedium) }
            case "state":
                if proc.stateName == "ZOMBIE" { color = C.color(.stateZombie) }
                else if proc.stateName == "STOPPED" { color = C.color(.stateStopped) }
                else if proc.stateName == "RUNNING" { color = C.color(.stateRunning) }
            default:
                break
            }
        }

        var text = def.value(proc)
        if proc.isExited && def.id == "state" {
            text = L("list.exited", proc.exitRemaining)
        }
        cell.configure(text, color: color,
                       alignment: def.numeric ? .right : .left)
        return cell
    }

    /// 退出宽限期内的行整行染色；其它行返回 nil 用系统默认行视图。
    func outlineView(_ outlineView: NSOutlineView,
                     rowViewForItem item: Any) -> NSTableRowView? {
        guard let n = item as? ProcessNode, n.proc.isExited else { return nil }
        let v = ExitedRowView(frame: .zero)
        v.tint = AppColors.shared.color(.exitedBackground)
        return v
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        if row >= 0, let n = outline.item(atRow: row) as? ProcessNode {
            AppContext.shared.selectedPID = n.proc.pid
        } else {
            AppContext.shared.selectedPID = nil
        }
    }

    // MARK: RowTextCopying —— ⌘C 复制选中进程的整行（按当前列顺序）

    /// 用 ColumnDef.value 取实际显示的字符串（含「已退出·N」这类状态改写），
    /// 并按用户拖动后的列顺序输出，而不是按固定列定义顺序。
    func copySelectedRowsToPasteboard() -> Bool {
        let idx = outline.selectedRowIndexes
        guard !idx.isEmpty else { return false }
        // 用逐项赋值而不是 uniqueKeysWithValues：后者遇到重复 key 会运行时
        // trap（本项目刚踩过字典重复 key 的无消息 SIGTRAP），这里重复只覆盖。
        var byID: [String: ColumnDef] = [:]
        for c in columns { byID[c.id] = c }
        var lines: [String] = []
        for r in idx {
            guard let n = outline.item(atRow: r) as? ProcessNode else { continue }
            let cells = outline.tableColumns.map { col -> String in
                let id = col.identifier.rawValue
                guard let def = byID[id] else { return "" }
                var v = def.value(n.proc)
                if n.proc.isExited, id == "state" {
                    v = L("list.exited2", n.proc.exitRemaining)
                }
                return v
            }
            lines.append(cells.joined(separator: "\t"))
        }
        guard !lines.isEmpty else { return false }
        Clipboard.setString(lines.joined(separator: "\n"))
        return true
    }

    func outlineView(_ outlineView: NSOutlineView,
                     heightOfRowByItem item: Any) -> CGFloat { 20 }

    /// 表头三态循环：
    ///   单击该列 → 按该列排序；再单击 → 反序；再单击 → 恢复树形。
    /// 换一列则重新从第一态开始。所有列都有 SortKey，不存在「点不动」的列。
    ///
    /// **关键修复**：NSOutlineView 的 delegate 是 NSOutlineViewDelegate，它
    /// 为表头点击定义了**自己的** `outlineView(_:didClick:)`（ObjC selector
    /// `outlineView:didClickTableColumn:`）。AppKit 点表头时只发这个消息，
    /// **不会**回退到 NSTableViewDelegate 的 `tableView(_:didClick:)`
    /// （`tableView:didClickTableColumn:`）。旧代码只实现了后者，于是点表头
    /// 完全没反应 —— 这就是「排序没有生效」的根因，跟 compare() 无关。
    /// 现在两个入口都汇到 handleHeaderClick，兼容不同 SDK 版本的转发行为。
    func outlineView(_ outlineView: NSOutlineView,
                     didClick tableColumn: NSTableColumn) {
        handleHeaderClick(tableColumn)
    }

    /// 兜底：少数 SDK 版本 / 自定义 NSOutlineView 仍会走父类回调
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        handleHeaderClick(tableColumn)
    }

    private func handleHeaderClick(_ tableColumn: NSTableColumn) {
        guard let def = columns.first(where: { $0.id == tableColumn.identifier.rawValue })
        else { return }
        let store = AppContext.shared.store
        let prefs = Preferences.shared
        let activeKey = store.sortIndicatorKey
        let isSameColumn = store.sortPhase != 0 && activeKey == def.key

        // 必须在 applySort **之前**设置：applySort 内部会同步 post 通知，
        // reload() 当场就会消费这个标记，事后设等于没设。
        scrollToTopOnNextReload = true

        if !isSameColumn {
            // 第一态：按新列排序（数值列默认降序，文本列默认升序）
            let asc = Self.defaultAscending(for: def.key)
            store.applySort(key: def.key, ascending: asc, phase: 1,
                            treeMode: prefs.sortAutoFlat ? false : store.treeMode,
                            indicator: def.key)
        } else if store.sortPhase == 1 {
            // 第二态：反序
            store.applySort(key: def.key, ascending: !store.ascending, phase: 2,
                            treeMode: prefs.sortAutoFlat ? false : store.treeMode,
                            indicator: def.key)
        } else if prefs.sortCycleToTree {
            // 第三态：恢复树形，排序键复位为偏好设置里的默认树内排序
            store.applySort(key: prefs.defaultSortKey,
                            ascending: prefs.defaultAscending, phase: 0,
                            treeMode: true, indicator: nil)
        } else {
            // 关闭三态时退化为常见二态正反序循环
            store.applySort(key: def.key, ascending: !store.ascending, phase: 1,
                            treeMode: prefs.sortAutoFlat ? false : store.treeMode,
                            indicator: def.key)
        }

        // applySort 只发一次通知 → 一次 reload
        updateSortIndicator()
    }

    private static func defaultAscending(for key: SortKey) -> Bool {
        switch key {
        case .name, .tty, .user, .state, .arch, .cmd: return true
        default: return false
        }
    }

    /// 自绘三角，不依赖 NSAscendingSortIndicator 这类系统图片资源名
    private static func indicatorImage(ascending: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 9, height: 6), flipped: false) { _ in
            let p = NSBezierPath()
            if ascending {
                p.move(to: NSPoint(x: 0.5, y: 5.2))
                p.line(to: NSPoint(x: 8.5, y: 5.2))
                p.line(to: NSPoint(x: 4.5, y: 0.8))
            } else {
                p.move(to: NSPoint(x: 0.5, y: 0.8))
                p.line(to: NSPoint(x: 8.5, y: 0.8))
                p.line(to: NSPoint(x: 4.5, y: 5.2))
            }
            p.close()
            NSColor.secondaryLabelColor.setFill()
            p.fill()
            return true
        }
        return img
    }

    func updateSortIndicator() {
        for col in outline.tableColumns { outline.setIndicatorImage(nil, in: col) }
        guard Preferences.shared.showSortIndicator else { return }
        let store = AppContext.shared.store
        guard let key = store.sortIndicatorKey,
              let def = columns.first(where: { $0.key == key }),
              let col = outline.tableColumn(
                withIdentifier: NSUserInterfaceItemIdentifier(def.id))
        else { return }
        outline.setIndicatorImage(Self.indicatorImage(ascending: store.ascending),
                                  in: col)
    }

    // -----------------------------------------------------------------
    // 交互
    // -----------------------------------------------------------------

    @objc private func doubleClicked() {
        // 刚发生过 ⌘/⌥+单击时别再重复执行一次
        guard !outline.clickGate.consumeRecent() else { return }
        performDoubleAction(col: outline.clickedColumn, row: outline.clickedRow)
    }

    /// 双击与修饰键单击共用的动作：
    /// PID / PPID 列 → 定位到那个 PID；其它列 → 打开当前选中进程的检查器。
    private func performDoubleAction(col: Int, row: Int) {
        if col >= 0, col < outline.tableColumns.count, row >= 0,
           let n = outline.item(atRow: row) as? ProcessNode {
            let id = outline.tableColumns[col].identifier.rawValue
            if id == "pid" || id == "ppid" {
                let target = id == "pid" ? n.proc.pid : n.proc.ppid
                if target > 0 {
                    AppContext.shared.locateProcess(target)
                    return
                }
            }
        }
        guard let pid = AppContext.shared.selectedPID else { return }
        AppContext.shared.showInspector(for: pid)
    }

    private func buildContextMenu() {
        contextMenu = NSMenu(title: L("list.processActions"))
        // 先填一份，避免某些路径下 delegate 尚未触发就弹出空菜单；
        // 每次真正弹出时 menuNeedsUpdate 会按右键行重建。
        menuNeedsUpdate(contextMenu)
    }

    /// NSMenuDelegate：每次弹出前重建。这样偏好里勾选的信号随手改随手生效，
    /// 且菜单项携带的是「右键那一行」的 PID，不会误发给别的进程。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else { return }

        let pid = outline.contextPID > 0
            ? outline.contextPID : (AppContext.shared.selectedPID ?? 0)
        let name = outline.contextPID > 0 ? outline.contextName
            : (AppContext.shared.selectedProcess()?.displayLabel ?? "")
        let exited = outline.contextPID > 0
            ? outline.contextExited
            : (AppContext.shared.selectedProcess()?.isExited ?? false)
        let hasTarget = pid > 0 && !exited

        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector,
                 enabled: Bool = true, separator: Bool = false) {
            if separator { menu.addItem(.separator()) }
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.isEnabled = enabled
            menu.addItem(i)
        }

        let header = NSMenuItem(title: pid > 0
                                ? "\(name) · PID \(pid)\(exited ? "（已退出）" : "")"
                                : L("list.noProcessSelected"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        add(L("list.openInspector"), #selector(menuInspector), enabled: hasTarget)
        add(L("list.locateThisProcessByWindow"), #selector(menuLocateInMain),
            enabled: hasTarget)

        menu.addItem(.separator())
        add(L("list.quitProcessSigterm"), #selector(menuTerminate), enabled: hasTarget)
        add(L("list.forceQuitSigkill"), #selector(menuForceTerminate),
            enabled: hasTarget)
        add(L("list.pauseResume"), #selector(menuSuspend), enabled: hasTarget)

        // 「发送信号」子菜单：内容由偏好的勾选决定
        let signalItem = NSMenuItem(title: L("list.sendSignal2"), action: nil,
                                    keyEquivalent: "")
        signalItem.submenu = signalSubmenu
        signalItem.isEnabled = hasTarget
        menu.addItem(signalItem)
        SignalMenuBuilder.fill(signalSubmenu, pid: pid, name: name)
        if !hasTarget {
            for i in signalSubmenu.items { i.isEnabled = false }
        }

        menu.addItem(.separator())
        add(L("list.revealInFinder"), #selector(menuReveal), enabled: hasTarget)
        add(L("list.samplingS", Preferences.shared.sampleSeconds),
            #selector(menuSample), enabled: hasTarget)

        menu.addItem(.separator())
        add(L("list.copyPid"), #selector(menuCopyPID), enabled: pid > 0)
        add(L("list.copyFullCommandLine"), #selector(menuCopyCmd), enabled: hasTarget)
        add(L("list.copyExecutablePath"), #selector(menuCopyExe), enabled: hasTarget)

        menu.addItem(.separator())
        let prefItem = NSMenuItem(title: L("list.configureMenuSignals"),
                                  action: #selector(SignalActions.openSignalPreferences(_:)),
                                  keyEquivalent: "")
        prefItem.target = SignalActions.shared
        menu.addItem(prefItem)
    }

    @objc private func menuInspector()       {
        let pid = outline.contextPID > 0
            ? outline.contextPID : (AppContext.shared.selectedPID ?? 0)
        guard pid > 0 else { return }
        AppContext.shared.showInspector(for: pid)
    }
    @objc private func menuLocateInMain()    {
        let pid = outline.contextPID > 0
            ? outline.contextPID : (AppContext.shared.selectedPID ?? 0)
        guard pid > 0 else { return }
        AppContext.shared.locateProcess(pid)
    }
    @objc private func menuTerminate()       { AppContext.shared.terminate(force: false) }
    @objc private func menuForceTerminate()  { AppContext.shared.terminate(force: true) }
    @objc private func menuSuspend()         { AppContext.shared.toggleSuspend() }
    @objc private func menuReveal()          { AppContext.shared.revealInFinder() }
    @objc private func menuSample()          { AppContext.shared.sampleProcess() }
    @objc private func menuCopyPID()         { AppContext.shared.copyPID() }
    @objc private func menuCopyCmd()         { AppContext.shared.copyCommandLine() }
    @objc private func menuCopyExe()         { AppContext.shared.copyExecutablePath() }

    deinit { NotificationCenter.default.removeObserver(self) }
}
