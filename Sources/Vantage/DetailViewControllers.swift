// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 通用「带搜索的多列表格」：打开文件 / 环境变量 / 镜像 / 网络连接 / 签名
// ---------------------------------------------------------------------

final class DetailTableViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate, RowTextCopying {

    private let table = ActionTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    private let searchField = NSSearchField(frame: .zero)
    private var allRows: [[String]] = []
    private var headers: [String] = [L("detail.item"), L("detail.value")]
    private var columnCount = 2
    private var query = ""
    /// 与主表共用同一套匹配语义（字面量 / 正则 + 无效正则回退）
    private var matcher = SearchMatcher(query: "", mode: .literal)

    // 右键菜单：命中的行 / 列与解析出的路径，在菜单弹出前算好
    private let contextMenu = NSMenu()
    private var contextRow = -1
    private var contextColumn = -1
    private var contextPath: String?

    /// 过滤框默认隐藏（检查器窗口用它省出纵向空间，⌘F 唤出）。
    /// 主窗口的详情区保持常显。视图已建好时改这个值会立刻生效。
    var filterStartsHidden = false {
        didSet {
            guard isViewLoaded else { return }
            setFilterVisible(!filterStartsHidden)
        }
    }

    /// 过滤框当前是否显示。隐藏不改变过滤内容：⌘F 唤回后文字与筛选结果都还在。
    private(set) var isFilterVisible = true
    private var filterTop: NSLayoutConstraint!
    private var tableWithFilter: NSLayoutConstraint!
    private var tableWithoutFilter: NSLayoutConstraint!

    /// 每个详情 Tab 唯一的列宽存储键（由 DetailTabViewController 赋值）
    var storageKey: String? {
        didSet {
            if isViewLoaded { applySavedWidths() }
        }
    }
    private var previousWidths: [CGFloat] = []
    /// 重建列期间禁止落盘：程序化设置 col.width 同样会触发
    /// tableViewColumnDidResize，把占位表的 170/420 写进偏好就再也洗不掉了。
    private var suppressWidthSave = false

    /// 该页是否允许「双击 PID 数值格跳转进程」。
    /// 「监控」页设为 false：它只是 FD 类型汇总，对端 PID 应去专门的 Pipe 页看，
    /// 避免整行数字（尤其 FD 列）被染成链接色、双击跳到 PID 9 这类假进程。
    var pidLinksEnabled = true

    /// 自定义双击处理；返回 true 表示已消费，不再走默认的 PID 跳转。
    /// 参数：(可见行号, 真实列号, 该行全部列值)
    var doubleClickHandler: ((Int, Int, [String]) -> Bool)?

    /// 追加自定义右键菜单项（「权限」页用它放 TCC 授予 / 撤销）。
    /// 入参是右键命中的整行；返回空数组表示不加任何项。
    var extraMenuItems: (([String]) -> [NSMenuItem])?

    /// 列宽归一化的目标总宽。详情页默认 820（下部详情区约 860pt）；
    /// 独立窗口（启动项 1180pt）可以调大，否则右侧会留一大片空白。
    var widthTarget: CGFloat = 820

    /// 该页专用的列宽权重；nil 时按表头语义自动推断。
    /// 「权限」页的表头（类别 / 权限 / 状态 / 详情 / 来源）在通用推断里
    /// 都落到默认权重，状态列会被压到放不下 "未请求 (not requested)"。
    var columnWeights: [CGFloat]?

    /// 选中行变化（该行全部列值）。「启动项」窗口用它刷新详情面板。
    var selectionHandler: (([String]) -> Void)?

    /// 由宿主设置表格 tooltip（例如「文件」页说明双击跳转规则）
    func setToolTip(_ text: String) { table.toolTip = text }

    /// 当前选中行（无选中时 nil）
    var selectedRowValues: [String]? {
        let i = table.selectedRow
        guard i >= 0, i < visibleRows.count else { return nil }
        return visibleRows[i]
    }

    /// 以代码选中第 n 个可见行（用于刷新后恢复选中）
    func selectVisibleRow(_ index: Int) {
        guard index >= 0, index < visibleRows.count else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let handler = selectionHandler, let row = selectedRowValues else {
            return
        }
        handler(row)
    }

    /// 以代码方式设置过滤框内容（供跨页定位时清空 / 兜底过滤）
    func applyFilter(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = t.lowercased()
        matcher = SearchMatcher(
            query: t,
            mode: Preferences.shared.searchUseRegex ? .regex : .literal)
        if searchField.stringValue != text { searchField.stringValue = text }
        table.reloadData()
        // 代码设进来的非空过滤（跨页定位兜底 / 全局搜索跳转）必须让过滤框可见，
        // 否则「行莫名其妙变少」查不到原因 —— 检查器里它默认是收起的。
        if !t.isEmpty, !isFilterVisible { setFilterVisible(true) }
    }

    /// 搜索模式切换后按新语义重算当前页（不重采数据）。
    func reapplyFilter() { applyFilter(searchField.stringValue) }

    // -----------------------------------------------------------------
    // 过滤框显隐（检查器里默认收起，⌘F 唤出）
    //
    // 过滤框占掉一行高度，而检查器窗口本来就矮；默认收起后 13 个页的表格
    // 都能多显示两行。隐藏只改布局，不清过滤内容：⌘F 唤回后文字与结果都还在。
    // -----------------------------------------------------------------

    /// 显示 / 隐藏过滤框；`focus` 为真时把键盘焦点交给它（已有文字全选）。
    func setFilterVisible(_ visible: Bool, focus: Bool = false) {
        guard isViewLoaded else {
            filterStartsHidden = !visible     // view 尚未建立：记成初始状态
            return
        }
        isFilterVisible = visible
        searchField.isHidden = !visible
        tableWithFilter.isActive = visible
        tableWithoutFilter.isActive = !visible

        if !visible, let w = view.window,
           let editor = searchField.currentEditor(), w.firstResponder === editor {
            // 焦点若留在已隐藏的 field editor 上，下一次输入会打进看不见的框
            w.makeFirstResponder(table)
        }
        if visible, focus {
            // 刚解除 isHidden 的视图当轮还没完成布局，下一圈再抢焦点更稳
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isFilterVisible else { return }
                self.view.window?.makeFirstResponder(self.searchField)
                self.searchField.currentEditor()?.selectAll(nil)
            }
        }
    }

    /// ⌘F：切换过滤框显隐，唤出时自动聚焦。
    func toggleFilter() {
        guard isViewLoaded else { return }
        setFilterVisible(!isFilterVisible, focus: !isFilterVisible)
    }

    /// 清空当前过滤 → 找到目标行 → 选中并滚动到可见。
    /// - fd: 目标行的第一列（FD 号）精确匹配，适用于 网络 / 监控 / Pipe 页
    /// - textKeys: 备选关键字（TTY 页没有 FD 列，用 tty 名 / "FD N" 匹配任意列）
    @discardableResult
    func clearFilterAndLocate(fd: String?, textKeys: [String]) -> Bool {
        applyFilter("")     // 旧过滤可能把目标行藏起来，先清掉
        var idx: Int?
        if let fd = fd, !fd.isEmpty {
            idx = visibleRows.firstIndex { row in
                row.first?.trimmingCharacters(in: .whitespacesAndNewlines) == fd
            }
        }
        if idx == nil {
            for key in textKeys where !key.isEmpty {
                idx = visibleRows.firstIndex { row in
                    row.contains { $0.localizedCaseInsensitiveContains(key) }
                }
                if idx != nil { break }
            }
        }
        guard let i = idx else { return false }
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
        table.window?.makeFirstResponder(table)
        return true
    }

    private var visibleRows: [[String]] {
        if matcher.isEmpty { return allRows }
        return allRows.filter { matcher.matches($0.joined(separator: " ")) }
    }

    override func loadView() {
        view = NSView()

        table.rowHeight = 19
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.toolTip = L("detail.doubleClickOrClickAct")
        // 除「窗口列表」外，所有表格的修饰键单击与双击效果完全相同
        table.onModifierClick = { [weak self] row, col in
            self?.performRowAction(row: row, displayColumn: col)
        }

        // 右键：在 Finder 中显示 / 复制路径（File Path、Image Path、Mapped Path…）
        table.onContextMenu = { [weak self] row, column in
            self?.prepareContextMenu(row: row, column: column)
        }
        table.menu = contextMenu
        contextMenu.delegate = self

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder

        searchField.placeholderString = L("detail.filterCurrentTab")
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchField)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        // 过滤框显隐两套约束：隐藏时表格直接顶到 view 顶部。
        // 只切 scroll 的 top 约束，搜索框自身的 leading/trailing/top 保持不变，
        // isHidden 已经让它不参与绘制，不会留白。
        filterTop = searchField.topAnchor.constraint(equalTo: view.topAnchor,
                                                    constant: 6)
        tableWithFilter = scroll.topAnchor.constraint(
            equalTo: searchField.bottomAnchor, constant: 6)
        tableWithoutFilter = scroll.topAnchor.constraint(
            equalTo: view.topAnchor, constant: 6)
        NSLayoutConstraint.activate([
            filterTop,
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                                 constant: 8),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                  constant: -8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        setFilterVisible(!filterStartsHidden)

        // NSTabViewController 懒加载：setRows 可能先于 loadView 执行并已建好列，
        // 这时不要重建，否则用户调整过的宽度会被默认值覆盖。
        if table.tableColumns.isEmpty { rebuildColumns() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(colorsChanged),
            name: .appColorsDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchModeChanged),
            name: .searchModeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resetColumnWidths),
            name: .columnWidthsShouldReset, object: nil)
    }

    @objc private func colorsChanged(_ n: Notification) {
        guard isViewLoaded else { return }
        table.reloadData()      // PID 链接色在 viewFor 里读取
    }

    /// 主表 / 偏好 / 全局搜索任一处切换「正则模式」时，当前页按新语义重算，
    /// 但**不重采数据**（过滤只作用于已有的 allRows）。
    @objc private func searchModeChanged(_ n: Notification) {
        guard isViewLoaded else { return }
        reapplyFilter()
    }

    /// 「视图 → 重置列宽为默认」：清掉刷新前的旧宽度，按当前页表头重建列。
    /// UserDefaults 里的保存值已由 ColumnWidthDefaults.clearSavedWidths 清掉。
    @objc private func resetColumnWidths(_ n: Notification) {
        previousWidths = []
        guard isViewLoaded else { return }
        rebuildColumns()
        table.reloadData()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: RowTextCopying —— ⌘C 且没有选中文字时复制表格行

    /// 表格是 cell-based，单元格文字本身不可拖选。所以 ⌘C 的语义定为：
    /// · 有选中行 → 复制这些行（列间 Tab、行间换行），适合贴到表格软件
    /// · 无选中行 → 复制当前过滤后的全部行，并带一行表头
    /// 选中文字的场合由 Clipboard.copy 在第 1 步就交给 NSTextView，不会走到这里。
    func copySelectedRowsToPasteboard() -> Bool {
        let rows = visibleRows
        guard !rows.isEmpty, isViewLoaded else { return false }
        let picked: [[String]]
        let idx = table.selectedRowIndexes.filter { $0 >= 0 && $0 < rows.count }
        if idx.isEmpty {
            picked = rows
            Clipboard.setString(Clipboard.joined(rows: picked, columns: headers))
        } else {
            picked = idx.map { rows[$0] }
            Clipboard.setString(Clipboard.joined(rows: picked))
        }
        return true
    }

    // -----------------------------------------------------------------
    // 右键菜单：在 Finder 中显示 / 复制路径
    //
    // 详情表的路径列散落在各页：文件「路径」、镜像「镜像路径」、映射
    // 「映射文件」、概览「可执行文件路径 / Bundle」……列头各不相同，而
    // 同一行里往往只有一格是路径。所以解析顺序是：
    //   ① 右键命中的那一格（用户指哪打哪）
    //   ② 该行「路径类」列（列头含 path/file/路径/镜像/映射）
    //   ③ 从右往左第一格认得出的路径（各页都把路径放在最右）
    // 全部认不出就只留「复制行」，Finder 项自动置灰，不会点了没反应。
    // -----------------------------------------------------------------

    /// 菜单项的路径来自「右键那一刻」的行与列，不用 selectedRow：
    /// 键盘呼出菜单、刷新后行号变化时都不会指到别的文件。
    private func prepareContextMenu(row: Int, column: Int) {
        contextRow = row
        contextColumn = column >= 0 ? columnIndex(column) : -1
        rebuildContextMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        rebuildContextMenu()
    }

    private func rebuildContextMenu() {
        contextMenu.removeAllItems()
        contextPath = nil
        guard contextRow >= 0, contextRow < visibleRows.count else { return }

        let row = visibleRows[contextRow]
        let path = resolvedPath(in: row)
        contextPath = path

        func add(_ title: String, _ sel: Selector, needsPath: Bool = false) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.isEnabled = needsPath ? (path != nil) : true
            contextMenu.addItem(item)
        }

        if let p = path {
            let header = NSMenuItem(title: PathReveal.abbreviated(p),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            contextMenu.addItem(header)
            contextMenu.addItem(.separator())
        }

        add(L("list.revealInFinder"), #selector(menuRevealInFinder), needsPath: true)
        add(L("detail.menuCopyPath"), #selector(menuCopyPath), needsPath: true)

        contextMenu.addItem(.separator())
        add(L("gs.menuCopyRow"), #selector(menuCopyRow))

        if let extra = extraMenuItems {
            let items = extra(row)
            if !items.isEmpty {
                contextMenu.addItem(.separator())
                for item in items { contextMenu.addItem(item) }
            }
        }
    }

    /// 从这一行里挑出最可信的路径，见上面的三步顺序。
    private func resolvedPath(in row: [String]) -> String? {
        if contextColumn >= 0, contextColumn < row.count,
           let p = PathReveal.resolve(row[contextColumn]) {
            return p
        }
        for i in row.indices where i != contextColumn && isPathColumn(i) {
            if let p = PathReveal.resolve(row[i]) { return p }
        }
        return row.reversed().lazy.compactMap { PathReveal.resolve($0) }.first
    }

    /// 列头是否描述「路径」。表头已被 L() 翻译，中英两套关键词都要认。
    private func isPathColumn(_ idx: Int) -> Bool {
        guard idx < headers.count else { return false }
        let h = headers[idx].lowercased()
        if h.contains("path") || h.contains("file") || h.contains("image") {
            return true
        }
        return h.contains("路径") || h.contains("镜像")
            || h.contains("映射") || h.contains("文件")
    }

    @objc private func menuRevealInFinder() {
        guard let p = contextPath else { return }
        PathReveal.reveal(p)
    }

    @objc private func menuCopyPath() {
        guard let p = contextPath else { return }
        Clipboard.setString(p)
    }

    @objc private func menuCopyRow() {
        guard contextRow >= 0, contextRow < visibleRows.count else { return }
        Clipboard.setString(Clipboard.joined(rows: [visibleRows[contextRow]]))
    }

    func setRows(_ rows: [[String]], headers: [String]) {
        // 刷新前先记录列宽与滚动位置
        let clip = table.enclosingScrollView?.contentView
        let savedOrigin = clip?.bounds.origin
        previousWidths = table.tableColumns.map { $0.width }

        allRows = rows
        let widest = rows.map { $0.count }.max() ?? 0
        // 上限放宽到 8：「Pipe 对端」有 7 列，之前上限 6 会把状态列截掉
        let newCount = max(1, min(8, max(headers.count, widest)))

        // 只有列数或表头真的变了才重建列；否则保留用户调整过的宽度
        if newCount != columnCount || headers != self.headers {
            self.headers = headers
            columnCount = newCount
            rebuildColumns()
        }
        table.reloadData()

        // 恢复滚动位置（NSTableView 行数变化时也不跳）
        if let clip = clip, let o = savedOrigin {
            clip.scroll(to: o)
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    func setPairs(_ pairs: [(String, String)], headers: [String] = [L("detail.item2"), L("detail.value2")]) {
        setRows(pairs.map { [$0.0, $0.1] }, headers: headers)
    }

    func showHint(_ text: String) {
        setPairs([(L("detail.hint"), text)])
    }

    /// 占位提示但**保持列数与列宽**：切换进程时不能让用户看到上一个进程的数据，
    /// 又不能用 setPairs 把 4 列的页重建为 2 列（会丢掉用户调过的列宽）。
    func showPlaceholder(_ text: String) {
        var row = [String](repeating: "", count: max(1, columnCount))
        row[0] = text
        allRows = [row]
        table.reloadData()
    }

    /// 下部详情区的可用宽度约 860pt（主窗口 1240 − 右侧统计 360），
    /// 检查器窗口 1140pt 只会更宽。多列页统一归一化到 820pt，正好铺满。
    private static let detailWidthTarget: CGFloat = 820

    /// 按表头语义给默认宽度，再整体归一化到 detailWidthTarget。
    /// 旧实现是「除末列外一律 170、末列 420」：Pipe 对端 7 列合计
    /// 1440pt、网络连接 6 列 1270pt，都要大幅横向滚动才能看到后半列。
    private func defaultWidths() -> [CGFloat] {
        // 「项目 + 值」这类两列页：值列要放完整命令行 / 长路径，所以按目标
        // 总宽给出 1:4 —— 独立窗口把 widthTarget 调大后能铺满，不再留白。
        if columnCount <= 2 {
            if columnCount == 1 { return [widthTarget] }
            let first = max(120, (widthTarget * 0.2).rounded())
            return [first, widthTarget - first]
        }
        let raw: [CGFloat] = (0..<columnCount).map { i in
            if let w = columnWeights, w.count == columnCount { return w[i] }
            let title = i < headers.count ? headers[i] : ""
            return Self.suggestedWidth(forHeader: title)
        }
        let total = max(raw.reduce(0, +), 1)
        let k = widthTarget / total
        var out = raw.map { min(300, max(60, $0 * k)) }
        let sum = out.reduce(0, +)
        if sum > widthTarget {
            let k2 = widthTarget / sum
            out = out.map { max(55, $0 * k2) }
        }
        return out
    }

    private static func suggestedWidth(forHeader title: String) -> CGFloat {
        // 数字 / 短代码列优先判断（「对端 PID」「屏幕状态」也落这里）
        // 表头在英文模式下会被 L() 翻译，关键词必须两套都认，
        // 否则所有列都落到默认权重 120，列宽分配会退化。
        let short = ["FD", "PID", "PPID", "TID", "CPU", "窗口号", "层", "大小",
                     "线程", "类型", "状态", "保护", "句柄", "标志",
                     "Window ID", "Layer", "Size", "Threads", "Type",
                     "Status", "Protection", "Handle", "Flags", "Value"]
        // 长文本列：路径 / 地址 / 说明 / 标题 / 值 …
        // 先判断 long：`Position / Size` 这类组合表头里，长文本关键词更具体，
        // 先命中 short 的 "Size" 会把整列压到 84pt。
        let long = ["路径", "命令", "值", "说明", "标题", "镜像", "映射",
                    "地址", "补充", "变量", "位置", "尺寸", "共享",
                    "Alpha", "进程", "时间", "权限", "详情",
                    "Path", "Command", "Value", "Description", "Title",
                    "Images", "Mapping", "Address", "Extra", "Variable",
                    "Position", "Sharing", "Process", "Time", "Start",
                    "Permission", "Details"]
        if long.contains(where: { title.contains($0) }) { return 190 }
        if short.contains(where: { title.contains($0) }) { return 84 }
        return 120
    }

    private func rebuildColumns() {
        let widths = defaultWidths()
        suppressWidthSave = true
        for col in table.tableColumns { table.removeTableColumn(col) }
        for i in 0..<columnCount {
            let col = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("dcol\(i)"))
            col.title = i < headers.count ? headers[i] : ""
            col.width = widths[i]
            col.minWidth = 55
            col.isEditable = false
            table.addTableColumn(col)
        }
        applySavedWidths()
        // 程序化设宽引发的 didResize 通知可能在本轮或下一轮 runloop 到达，
        // 等到下一轮再放开保存
        DispatchQueue.main.async { [weak self] in self?.suppressWidthSave = false }
    }

    /// 优先用 UserDefaults 里用户拖过的宽度，其次用本次刷新前的宽度
    private func applySavedWidths() {
        let d = UserDefaults.standard
        for (i, col) in table.tableColumns.enumerated() {
            if let key = storageKey {
                let saved = d.double(forKey: "\(key).col\(i).width")
                if saved > 0 { col.width = CGFloat(saved); continue }
            }
            // 这里不再套用 previousWidths：能走到 rebuildColumns 说明列数
            // 或表头已经变了，上一帧的列宽属于另一套列，套过来只会让第一列
            // 继承占位表的 170pt（并且被写进偏好，之后永远偏宽）。
        }
    }

    private func saveColumnWidths() {
        guard let key = storageKey else { return }
        for (i, col) in table.tableColumns.enumerated() {
            UserDefaults.standard.set(Double(col.width),
                                      forKey: "\(key).col\(i).width")
        }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !suppressWidthSave else { return }
        saveColumnWidths()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < visibleRows.count else { return nil }
        let raw = col.identifier.rawValue.replacingOccurrences(of: "dcol", with: "")
        let idx = Int(raw) ?? 0
        let cell = (tableView.makeView(withIdentifier: col.identifier, owner: self)
                    as? TextCell) ?? TextCell(frame: .zero)
        cell.identifier = col.identifier
        let r = visibleRows[row]
        let value = idx < r.count ? r[idx] : ""
        let header = idx < headers.count ? headers[idx] : ""
        let linked = pidValue(value, header: header, row: r) != nil
        cell.configure(value,
                       color: linked ? AppColors.shared.color(.pidLink)
                            : (idx == 0 ? .secondaryLabelColor : .labelColor))
        // 列宽有限时长文本会被截断（「权限」页的详情列尤其明显）；
        // 悬停显示完整内容，双击跳转的提示优先。
        cell.toolTip = linked ? L("detail.doubleClickToOpenThe")
                              : (value.isEmpty ? nil : value)
        return cell
    }

    // -----------------------------------------------------------------
    // 双击 PID 数值格 → 打开 / 激活对应 PID 的检查器
    // -----------------------------------------------------------------

    /// 从「对端 PID」列、内嵌 "PID 1234" 文本、或 TTY / 概览里
    /// 「项目=PID, 值=1234」这类行中解析出 PID。
    ///
    /// **列头白名单**：只有列头含 `pid` / `说明` / `对端` / `项目` / `值`
    /// 的列才参与解析。旧实现用「同一行任意格含 PID 字样」放行整行，
    /// 于是「监控」页 pipe 行的说明列写了「对端 PID 42826」，同行的
    /// **FD 列 `9` / `10` / `17` / `18` 也被染成链接色**，双击会跳到
    /// PID 9 这种根本不存在的进程 —— 这正是本次要修的 bug。
    /// FD / 类型 / 句柄 / 位置 / 窗口号 / 层 / 地址 / 路径等列一律排除。
    private func pidValue(_ text: String, header: String,
                          row: [String]) -> Int32? {
        guard pidLinksEnabled else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "—" || t == "-" || t == "?" { return nil }

        func valid(_ v: Int) -> Int32? {
            (v > 0 && v <= 999_999) ? Int32(v) : nil
        }

        let h = header.lowercased()
        // 「窗口」页的摘要行是 `Owner PID / 1234 / …`，数值落在「标题」列下，
        // 列头本身不含白名单词。给一个精确例外：只有**行首标签**含 PID 时
        // 才放行。FD 行的第一格是纯数字（不含 pid），所以不会回到「整行放行」
        // 的老问题。
        let rowLabelIsPID = (row.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().contains("pid")) ?? false
        let columnAllowed = h.contains("pid") || h.contains(L("detail.description2"))
            || h.contains(L("detail.peer")) || h.contains(L("detail.item3")) || h.contains(L("detail.value4"))
            || rowLabelIsPID
        guard columnAllowed else { return nil }

        if h.contains("pid") {
            // Pipe 页的「对端 PID」列：值可能是 "1234" / "1234 (进程名)" / "—"
            if let v = Self.firstInteger(in: t) { return valid(v) }
            return nil
        }

        if h.contains(L("detail.description3")) || h.contains(L("detail.peer2")) {
            // "对端 PID 1234 (xxx) FD 5 — 已连接"
            if let v = Self.embeddedPID(in: t) { return valid(v) }
            return nil
        }

        // 概览 / TTY / Mach 的键值表：要求同一行确实有 "PID" 字样，
        // 且本格以数字开头（"0x..." 句柄、OSStatus 错误码不会命中）
        let rowHasPID = row.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().contains("pid")
        }
        if rowHasPID, let v = Self.firstInteger(in: t) { return valid(v) }
        return nil
    }

    /// 只取「开头」的连续 ASCII 数字；不跳过前导非数字，避免把说明文字
    /// 里的版本号、OSStatus 错误码、十六进制句柄误当成 PID。
    /// "1234 (Safari)" → 1234，"123 / 1" → 123，"—" / "0x7f..." → nil。
    private static func firstInteger(in s: String) -> Int? {
        var digits = ""
        for ch in s {
            if let a = ch.asciiValue, a >= 48, a <= 57 {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            } else {
                return nil
            }
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 从 "对端 PID 1234 (xxx)" / "pid=1234" / "PID: 1234" 中取数字。
    /// 要求分隔符之后立刻是数字，防止 "PID 校验失败 OSStatus -67054" 误命中。
    private static func embeddedPID(in s: String) -> Int? {
        // 直接在原字符串上查找：lowercased() 会生成新 String，它的 Index
        // 不能安全地拿回原字符串里用（非 ASCII 时甚至会越界）。
        guard let r = s.range(of: "pid", options: .caseInsensitive) else {
            return nil
        }
        let tail = String(s[r.upperBound...])
        let skip = CharacterSet(charactersIn: ":=# \t()[]（）")
        var i = tail.startIndex
        while i < tail.endIndex,
              tail[i].unicodeScalars.count == 1,
              let u = tail[i].unicodeScalars.first,
              skip.contains(u) {
            i = tail.index(after: i)
        }
        guard i < tail.endIndex,
              let a = tail[i].asciiValue, a >= 48, a <= 57 else { return nil }
        return firstInteger(in: String(tail[i...]))
    }

    private func columnIndex(_ displayColumn: Int) -> Int {
        guard displayColumn >= 0,
              displayColumn < table.tableColumns.count else { return displayColumn }
        let raw = table.tableColumns[displayColumn].identifier.rawValue
            .replacingOccurrences(of: "dcol", with: "")
        return Int(raw) ?? displayColumn
    }

    @objc private func rowDoubleClicked() {
        guard !table.clickGate.consumeRecent() else { return }
        performRowAction(row: table.clickedRow, displayColumn: table.clickedColumn)
    }

    /// 双击与 ⌘/⌥+单击 共用的动作入口。
    private func performRowAction(row: Int, displayColumn: Int) {
        guard row >= 0, displayColumn >= 0, row < visibleRows.count else { return }
        let idx = columnIndex(displayColumn)
        let r = visibleRows[row]
        guard idx < r.count else { return }

        // 自定义语义：文件页跨页跳转、窗口页激活窗口等；返回 true 即消费
        if let h = doubleClickHandler, h(row, idx, r) { return }

        let header = idx < headers.count ? headers[idx] : ""
        guard let pid = pidValue(r[idx], header: header, row: r) else { return }
        AppContext.shared.locateProcess(pid)
    }

    @objc private func searchChanged(_ sender: Any?) {
        applyFilter(searchField.stringValue)
    }

    /// 过滤框里按 Esc：清空过滤。检查器这种「过滤框默认收起」的场合顺带收起，
    /// 一次 Esc 就回到「无过滤 + 全屏表格」的初始状态。
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField,
              commandSelector == NSSelectorFromString("cancelOperation:")
        else { return false }
        searchField.stringValue = ""
        applyFilter("")
        if filterStartsHidden { setFilterVisible(false) }
        return true
    }
}

// ---------------------------------------------------------------------
// 概览页：图标 + 名称 + 关键指标表
// ---------------------------------------------------------------------

final class OverviewViewController: NSViewController {

    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = UI.label(L("detail.noProcessSelected"), size: 16, weight: .semibold)
    private let subLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let header = NSView(frame: .zero)
    private let tableVC = DetailTableViewController()

    /// 概览页的过滤框归内嵌表格管：⌘F / 「默认收起」都要能找到它。
    var filterHost: DetailTableViewController { tableVC }
    var filterStartsHidden: Bool {
        get { tableVC.filterStartsHidden }
        set { tableVC.filterStartsHidden = newValue }
    }

    override func loadView() {
        view = NSView()
        tableVC.storageKey = "Vantage.detail.overview"

        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        header.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(subLabel)

        addChild(tableVC)
        tableVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableVC.view)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 52),

            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),

            subLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),

            tableVC.view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            tableVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func setLoading(_ pid: Int32) {
        titleLabel.stringValue = "PID \(pid)"
        subLabel.stringValue = L("detail.readingProcessDetails")
        iconView.image = IconCache.genericIcon()
        tableVC.showHint(L("detail.collectingData"))
    }

    func setSnapshot(_ p: ProcessSnapshot?, port: UInt32?) {
        guard let p = p else {
            titleLabel.stringValue = L("detail.noProcessSelected2")
            subLabel.stringValue = L("detail.selectAProcessAboveOr")
            iconView.image = IconCache.genericIcon()
            tableVC.showHint(L("detail.noProcessSelected3"))
            return
        }

        titleLabel.stringValue = p.displayLabel
        subLabel.stringValue =
            "PID \(p.pid)  ·  PPID \(p.ppid)  ·  \(p.userName)  ·  \(p.stateName)  ·  \(p.archName)  ·  TTY \(p.ttyShortName)"
        iconView.image = IconCache.shared.icon(for: p, size: 32)

        let rows: [(String, String)] = [
            (L("detail.processName"), p.displayLabel),
            (L("detail.rawProcessName"), p.rawName.isEmpty ? "—" : p.rawName),
            (L("detail.argv0"), p.argv0.isEmpty ? "—" : p.argv0),
            ("Bundle", p.bundlePath ?? "—"),
            (L("detail.bundleExecutable"),
             p.bundleExecutableName.isEmpty ? "—" : p.bundleExecutableName),
            (L("detail.bundleRole"), p.bundleRoleText ?? "—"),
            ("PID / PPID", "\(p.pid) / \(p.ppid)"),
            (L("detail.userUidGid"), "\(p.userName) (\(p.uid) / \(p.gid))"),
            (L("detail.status2"), p.stateName),
            (L("detail.architecture"), p.archName),
            (L("detail.archSlices"), p.archSlices),
            ("% CPU", Fmt.percent(p.cpuPercent) + " %"),
            (L("detail.memoryRss"), Fmt.bytes(p.rss)),
            (L("detail.virtualMemoryVss"), Fmt.bytes(p.vss)),
            (L("detail.threads"), "\(p.threads)"),
            (L("detail.openFilesFd"), "\(p.nfiles)"),
            (L("detail.cumulativeCpuTime"), Fmt.cpuTime(p.cpuTimeNS)),
            (L("detail.startTime"), Fmt.startDate(p)),
            (L("detail.nicePriority"), "\(p.nice) / \(p.priority)"),
            (L("detail.processGroupPgid"), "\(p.pgid)"),
            (L("detail.controllingTerminalTty"), p.hasTTY ? p.ttyName : L("detail.noControllingTerminal")),
            (L("detail.foregroundPgidTpgid"), "\(p.ttyTpgid)"),
            (L("detail.jobControlState"), p.ttyJobState),
            ("jobc", "\(p.ttyJobc)"),
            ("BSD flags", Fmt.flags(p.flags)),
            (L("detail.faultsPageInCow"), "\(p.faults) / \(p.pageins) / \(p.cowFaults)"),
            (L("detail.contextSwitches"), "\(p.csw)"),
            (L("detail.machUnixSyscalls"), "\(p.sysMach) / \(p.sysUnix)"),
            (L("detail.machMessagesSentReceived"), "\(p.msgRecv) / \(p.msgSent)"),
            ("task port", port.map { "\($0)" } ?? L("detail.unavailableSipProtectionPermissionsRoot")),
            (L("detail.executablePath"), p.exepath.isEmpty ? "—" : p.exepath),
            ("Bundle", p.bundlePath ?? "—"),
            (L("detail.commandLine"), p.cmdline.isEmpty ? "—" : p.cmdline),
        ]
        tableVC.setPairs(rows)
    }
}

// ---------------------------------------------------------------------
// 命令行页
// ---------------------------------------------------------------------

/// 只读文本视图，右键菜单顶部多一条「在 Finder 中显示」。
/// 命令行页里同时出现可执行文件路径与 Bundle 路径，但它们混在整段文字里
/// 不可选格，所以取「选中文字」；没有选中就取右键落点所在的那个词。
/// 认不出路径时原样返回系统菜单，不加多余项。
final class PathTextView: NSTextView {

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let base = super.menu(for: event) else { return nil }
        guard let path = contextPath(at: event) else { return base }
        // 复制一份再插入：系统菜单是共享实例，直接改会在下次弹出时累积重复项
        guard let menu = base.copy() as? NSMenu else { return base }
        let item = NSMenuItem(title: L("list.revealInFinder"),
                              action: #selector(revealFromMenu(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = path
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    private func contextPath(at event: NSEvent) -> String? {
        // 有选区就只看选区：用户已经明确指了范围
        let sel = selectedRange()
        if sel.length > 0,
           let p = PathReveal.resolve((string as NSString).substring(with: sel)) {
            return p
        }
        guard let token = token(at: convert(event.locationInWindow, from: nil))
        else { return nil }
        return PathReveal.resolve(token)
    }

    /// 从落点向两侧扩到空白 / 引号，得到一个候选 token
    private func token(at point: NSPoint) -> String? {
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        var i = characterIndexForInsertion(at: point)
        if i >= ns.length { i = ns.length - 1 }
        if isBreak(ns.character(at: i)), i > 0,
           !isBreak(ns.character(at: i - 1)) { i -= 1 }
        guard !isBreak(ns.character(at: i)) else { return nil }
        var start = i, end = i
        while start > 0, !isBreak(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, !isBreak(ns.character(at: end)) { end += 1 }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private func isBreak(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        return CharacterSet(charactersIn: "\"'`()<>[]：:，,。")
            .contains(scalar)
    }

    @objc private func revealFromMenu(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        PathReveal.reveal(p)
    }
}

final class CommandLineViewController: NSViewController {
    private let textView = PathTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))

    override func loadView() {
        view = NSView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        UI.pin(scroll, in: view, top: 8, left: 8, bottom: 8, right: 8)
    }

    func set(text: String) { textView.string = text }

    /// 第一响应者不是 textView（例如刚切到本页）时，⌘C 仍复制完整命令行。
    /// 若 textView 本身是第一响应者且选中了文字，Clipboard.copy 会优先走
    /// 系统 copy:，只复制选区，不会走到这里。
    func copySelectedRowsToPasteboard() -> Bool {
        guard !textView.string.isEmpty else { return false }
        Clipboard.setString(textView.string)
        return true
    }
}

extension CommandLineViewController: RowTextCopying {}

// ---------------------------------------------------------------------
// Tab 容器
// ---------------------------------------------------------------------

/// 检查器页签的顺序 —— 单一事实来源。
///
/// 之前 `tabs` 数组、`items(for:)`、`tableVC(for:)`、`DetailTab` 枚举和全局
/// 搜索各自抄了一份数字下标，插一个页签要改五处，漏一处就是「点文件页跳到
/// 窗口页」这种错位。顺序只在这里定义，其余地方一律用 `DetailTab(rawValue:)`。
enum DetailTab: Int, CaseIterable {
    case overview, files, env, dylibs, sockets, monitoring, pipePeers, regions
    case tty, threads, windows, signing, permissions, audit, mach, command

    /// 需要独立采集的页（概览用主表快照、命令页是纯文本）
    static var collectable: [DetailTab] {
        allCases.filter { $0 != .overview && $0 != .command }
    }
}

/// 页签标题：普通项按 l10n key 取当前语言译文；"=Pipe" 这类
/// 前缀表示字面量（技术名词不翻译）。
fileprivate func detailTabTitle(_ key: String) -> String {
    key.hasPrefix("=") ? String(key.dropFirst()) : L(key)
}

/// 详情页签容器：页签条 + NSTabViewController 的内容。
///
/// 必须包一层：NSTabViewController 的 `view` 就是它管理的 NSTabView，
/// 不能直接往里塞自定义页签条。这里让它以 `.unspecified` 样式运行
/// （不画系统页签），由外面的 `TabStripView` 驱动
/// `selectedTabViewItemIndex`，选中变化仍走原来的 didSelect /
/// syncTabSelection 路径，惰性加载逻辑不受影响。
///
/// 页签条的位置由偏好决定（见 `TabBarStyle`）：横向时在内容上方折行，
/// 纵向时在内容左侧、可滚动；两种布局用两套约束切换。
final class DetailTabPaneController: NSViewController {
    let tabs: DetailTabViewController
    private let bar = TabStripView()
    private let divider = NSBox()
    private var observers: [NSObjectProtocol] = []
    private var horizontalConstraints: [NSLayoutConstraint] = []
    private var verticalConstraints: [NSLayoutConstraint] = []
    private var barWidth: NSLayoutConstraint?
    /// 上一次实际套用的「标题 + 排布」，用于跳过无意义的重建：
    /// `.preferencesDidChange` 会随每个复选框触发，重建 15 个分段控件
    /// 纯属浪费，还会把键盘焦点从页签条上挪走。
    private var appliedTitles: [String] = []
    private var appliedMode: TabStripView.Mode?

    init(tabs: DetailTabViewController) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        let root = NSView()
        // 页签条本身没有内在高度（横向靠 heightConstraint，纵向靠容器），
        // 内容视图也没有：不给下限时，窗口按 fittingSize 会缩成
        //「标题栏 + 一行页签」那么高（Left 布局实测只剩 52pt）。
        root.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(tabs)
        let content = tabs.view
        content.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isHidden = true

        view.addSubview(bar)
        view.addSubview(divider)
        view.addSubview(content)

        bar.onSelect = { [weak self] index in
            self?.tabs.select(tab: index)
        }
        tabs.onTabSelected = { [weak self] index in
            self?.bar.select(index)
        }

        applyLayout()

        // 排布样式 / 每行个数改动、语言切换后都要重排（标题宽度会变）
        observers.append(NotificationCenter.default.addObserver(
            forName: .preferencesDidChange, object: nil, queue: .main) {
                [weak self] _ in self?.applyLayout()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .languageDidChange, object: nil, queue: .main) {
                [weak self] _ in self?.applyLayout()
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// 页签标题始终从 l10n key 现取：`tabViewItems` 的 label 是建页时
    /// 按当时语言写死的，语言切换后就地转换容易和实际译文不一致。
    private func tabTitles() -> [String] {
        let keys = tabs.tabTitleKeys
        if keys.count == tabs.tabViewItems.count {
            return keys.map { detailTabTitle($0) }
        }
        return tabs.tabViewItems.map { $0.label }
    }

    /// 在「横向多行」与「左侧竖排」两套约束之间切换。
    ///
    /// 两套约束不能同时存在：横向时内容在页签条下面，纵向时内容在右边。
    /// 每次切换先把旧的整组 deactivate，再激活新的，避免约束互相打架。
    private func applyLayout() {
        guard isViewLoaded else { return }
        let mode = Preferences.shared.tabStripMode
        let titles = tabTitles()
        if mode == appliedMode, titles == appliedTitles {
            bar.select(tabs.selectedTabViewItemIndex)
            return
        }
        appliedMode = mode
        appliedTitles = titles
        NSLayoutConstraint.deactivate(horizontalConstraints)
        NSLayoutConstraint.deactivate(verticalConstraints)
        barWidth?.isActive = false
        barWidth = nil

        bar.configure(titles: titles, mode: mode)
        bar.select(tabs.selectedTabViewItemIndex)
        let content = tabs.view

        switch mode {
        case .vertical:
            divider.isHidden = false
            let w = bar.widthAnchor.constraint(equalToConstant: bar.columnWidth)
            barWidth = w
            verticalConstraints = [
                bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                             constant: 8),
                bar.bottomAnchor.constraint(equalTo: view.bottomAnchor,
                                            constant: -6),
                w,

                divider.leadingAnchor.constraint(equalTo: bar.trailingAnchor,
                                                 constant: 4),
                divider.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
                divider.bottomAnchor.constraint(equalTo: view.bottomAnchor,
                                                constant: -8),
                divider.widthAnchor.constraint(equalToConstant: 1),

                content.topAnchor.constraint(equalTo: view.topAnchor),
                content.leadingAnchor.constraint(equalTo: divider.trailingAnchor,
                                                 constant: 4),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
            NSLayoutConstraint.activate(verticalConstraints)

        case .horizontal:
            divider.isHidden = true
            horizontalConstraints = [
                bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                             constant: 8),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                              constant: -8),

                content.topAnchor.constraint(equalTo: bar.bottomAnchor,
                                             constant: 6),
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
            NSLayoutConstraint.activate(horizontalConstraints)
        }
    }
}

final class DetailTabViewController: NSTabViewController {

    /// 检查器窗口可锁定某个 PID；nil 时跟随全局选中项
    var fixedPID: Int32?

    /// 过滤框默认收起（检查器用它省出纵向空间，⌘F 唤出）。
    /// 必须在内容视图加载之前设置；主窗口保持 false，详情区过滤框常显。
    var hidesFilterByDefault = false

    private let overview = OverviewViewController()
    private let files = DetailTableViewController()
    private let env = DetailTableViewController()
    private let dylibs = DetailTableViewController()
    private let sockets = DetailTableViewController()
    private let monitoring = DetailTableViewController()
    private let signing = DetailTableViewController()
    private let permissions = DetailTableViewController()
    private let audit = DetailTableViewController()
    private let mach = DetailTableViewController()
    private let command = CommandLineViewController()
    private let regions = DetailTableViewController()
    private let pipePeers = DetailTableViewController()
    private let tty = DetailTableViewController()
    private let threads = DetailTableViewController()
    private let windows = DetailTableViewController()

    private var generation: UInt64 = 0
    private var activeEpoch: UInt64 = 0
    private var selectedTabIndex: Int = 0
    private var tabSelectionObserver: NSObjectProtocol?
    /// 各页签标题的 l10n key（"=Pipe" / "=Mach" 这类 "=" 前缀是字面量）。
    /// 语言切换时按 key 重新取译文，不能对已显示的文案做 value→key 反查：
    /// 不同 key 的中文值可能撞车（例如「环境」与「环境变量」），
    /// 反查会把页签标题改成别的条目的译文。
    fileprivate(set) var tabTitleKeys: [String] = []
    /// 当前页签变化（多行页签条据此高亮）。任何路径改了选中页都会回调：
    /// 用户点系统页签、点自定义页签条、⌘F 跳转、全局搜索定位。
    var onTabSelected: ((Int) -> Void)?
    private var loadedKeys: Set<String> = []
    private var lastPID: Int32?
    /// 最后一次拿到的快照（含已退出进程），用于宽限期结束后继续冻结展示
    private var lastSnapshot: ProcessSnapshot?

    /// 文件页双击后要跳到的页与目标行。目标页是惰性加载的，必须等
    /// apply() 把数据填完再定位，所以先存起来。
    private struct PendingLocate {
        let tab: Int
        let fd: String
        let keys: [String]
    }
    private var pendingLocate: PendingLocate?
    /// 全局搜索命中行跳转：切到目标页后按关键字定位那一行。
    private var pendingFocus: (tab: Int, keys: [String])?

    private var currentPID: Int32? { fixedPID ?? AppContext.shared.selectedPID }

    // -----------------------------------------------------------------
    // 页签切换：只「观察」，绝不改 tabView.delegate
    //
    // NSTabViewController 本身就是它所管理的 NSTabView 的 delegate。
    // macOS 26 的 AppKit 在 -[NSTabView setDelegate:] 里直接抛
    //   NSInternalInconsistencyException:
    //   "A TabView managed by a TabViewController cannot have its delegate modified"
    // 旧实现用独立代理 TabSelectProxy 转发 didSelect，于是 viewDidLoad 一执行
    // 就抛异常 → NSWindow setContentViewController 在 NSPerformVisuallyAtomicChange
    // 里 rethrow → SIGABRT。主窗口（嵌套 split 里的详情 Tab）和检查器窗口
    // 都加载同一个类，所以「主窗口打不开」「⌘0 / 定位进程时闪退」是同一个根因。
    //
    // 现在 delegate 完全交回 AppKit 原生实现（segmented control 与
    // selectedTabViewItemIndex 的同步由系统负责），我们只读地感知变化：
    //   ① override tabView(_:didSelect:) 并调 super —— Apple 文档明确
    //      NSTabViewController 的该方法可 override，且「必须调用 super」
    //   ② NSTabViewDidSelectTabViewItemNotification 备用（通知名用字符串
    //      构造，避免不同 SDK 下 Swift 常量名差异导致编译失败）
    //   ③ viewDidLayout 兜底（AppKit 内部直接改 ivar、绕过通知/setter 时）
    // 三条路径都汇到 syncTabSelection()，由 selectTab 里的 index 去重保证
    // 不重复 reload、不递归。
    // -----------------------------------------------------------------

    /// Apple 文档：NSTabViewController.tabView(_:didSelect:) 允许 override，
    /// 但实现里必须调用 super，否则 segmented control / selectedTabViewItemIndex
    /// 的原生同步会丢。我们不替换 delegate，只是在系统同步之后读一次结果。
    override func tabView(_ tabView: NSTabView,
                          didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        syncTabSelection(tabViewItem)
    }

    private func syncTabSelection(_ item: NSTabViewItem? = nil) {
        guard isViewLoaded else { return }
        let idx: Int
        if let item = item {
            let i = tabView.indexOfTabViewItem(item)
            idx = i >= 0 ? i : selectedTabViewItemIndex
        } else {
            idx = selectedTabViewItemIndex
        }
        guard idx >= 0, idx < tabViewItems.count else { return }
        selectTab(idx)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncTabSelection()
    }

    /// 一个页签需要的一项采集
    private struct Item {
        let key: String
        let load: () -> DetailLoadCache.Payload?
    }

    override func loadView() {
        // 不画系统页签：页签条由外层 DetailTabPaneController 提供（支持多行）。
        tabStyle = .unspecified
        super.loadView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 16 个页签，全部对应「不需要 task port」或已有降级的采集能力。
        // 标签统一压到 2 个字，避免 segmented control 在窄窗口下把文字截没。
        // 注意：顺序与 items(for:) / applyLines 的 index 一一对应，插入新页时
        // 必须同步改这两处的 case 编号。
        let tabs: [(String, String, NSViewController)] = [
            ("detail.overview",   "overview",   overview),
            ("detail.file",   "files",      files),
            ("detail.environment",   "env",        env),
            ("detail.images",   "dylibs",     dylibs),
            ("detail.network",   "sockets",    sockets),
            ("detail.monitoring",   "monitoring", monitoring),
            ("=Pipe",   "pipepeers",  pipePeers),
            ("detail.mapping",   "regions",    regions),
            ("=TTY",    "tty",        tty),
            ("detail.threadsTab", "threads",  threads),
            ("detail.window",   "windows",    windows),
            ("detail.signing",   "signing",    signing),
            ("detail.permissions", "permissions", permissions),
            ("detail.audit", "audit", audit),
            ("=Mach",   "mach",       mach),
            ("detail.command",   "command",    command),
        ]
        tabTitleKeys = tabs.map { $0.0 }
        for (titleKey, key, vc) in tabs {
            if let t = vc as? DetailTableViewController {
                t.storageKey = "Vantage.detail.\(key)"
                // 检查器里过滤框默认收起（⌘F 唤出）；主窗口保持常显
                t.filterStartsHidden = hidesFilterByDefault
            } else if let o = vc as? OverviewViewController {
                o.filterStartsHidden = hidesFilterByDefault
            }
            let item = NSTabViewItem(viewController: vc)
            item.label = detailTabTitle(titleKey)
            addTabViewItem(item)
        }

        // 「监控」页不做任何 PID 跳转：它是 FD 类型汇总，对端进程应去专门的
        // Pipe 页看。否则说明列写了「对端 PID 42826」会把同行的 FD 9/10/17/18
        // 也染成链接色，双击跳到 PID 9 这种不存在的进程。
        monitoring.pidLinksEnabled = false

        // 「文件」页双击 / 修饰键单击 → 按 FD 类型跳到 网络 / Pipe / 监控 / TTY 并定位该行
        files.setToolTip(L("detail.doubleClickOrClickAny"))
        files.doubleClickHandler = { [weak self] _, _, row in
            self?.jumpFromFiles(row) ?? false
        }

        // 「窗口」页双击 / 修饰键单击 → 激活（前置）对应的具体窗口
        windows.setToolTip(
            L("detail.doubleClickAWindowRow"))
        windows.doubleClickHandler = { [weak self] _, _, row in
            self?.activateWindowFromDetail(row) ?? false
        }

        // 「权限」页：TCC 行右键可授予 / 撤销（仅在 SIP 文件系统保护关闭时）
        permissions.setToolTip(L("perm.tooltip"))
        permissions.columnWeights = [80, 170, 160, 225, 175]
        permissions.extraMenuItems = { [weak self] row in
            self?.permissionMenuItems(for: row) ?? []
        }

        // 只观察 NSTabView 自己发出的选中通知，不碰 tabView.delegate
        // （AppKit 禁止修改 TabViewController 管理的 TabView 的 delegate）。
        // object 传 nil：不同系统版本该通知的 sender 可能是 tabView 也可能是
        // tabViewItem，按名字过滤即可。syncTabSelection 读的是自己的
        // selectedTabViewItemIndex，别的窗口发通知也不会误触发 reload（有去重）。
        tabSelectionObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSTabViewDidSelectTabViewItemNotification"),
            object: nil, queue: .main) { [weak self] _ in
                self?.syncTabSelection()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged),
            name: .procSelectionDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(forceRefresh),
            name: .procDetailForceRefresh, object: nil)
        reload()
    }

    @objc private func selectionChanged(_ notification: Notification) {
        reload()
    }

    @objc private func forceRefresh(_ notification: Notification) {
        if let pid = currentPID { DetailLoadCache.shared.invalidate(pid: pid) }
        loadedKeys.removeAll()
        reload(force: true)
    }

    /// 只加载当前页签。概览 / 命令页用主表快照，完全不做系统调用；
    /// 其余每页只采自己那一项。这样选中一个重 app 不再是「14 页全量扫一遍」。
    private func selectTab(_ index: Int) {
        guard index >= 0, index < tabViewItems.count else { return }
        // 先通知页签条（即使 index 没变，也要保证高亮与真实选中一致）
        onTabSelected?(index)
        guard index != selectedTabIndex else { return }
        selectedTabIndex = index
        reload()
    }

    /// 供外层多行页签条切换页面。
    func select(tab index: Int) {
        guard index >= 0, index < tabViewItems.count else { return }
        selectedTabViewItemIndex = index
        selectTab(index)
    }

    // -----------------------------------------------------------------
    // 「文件」页双击 → 按 FD 类型跳到对应页并定位到该 FD 那一行
    // -----------------------------------------------------------------

    /// 「窗口」页：双击或修饰键单击窗口条目 → 激活（前置）那个具体窗口。
    /// 第一列是窗口号；摘要行（Owner PID / 提示）与无窗口占位行不命中，
    /// 返回 false 让默认逻辑处理（Owner PID 行仍可跳到本进程）。
    private func activateWindowFromDetail(_ row: [String]) -> Bool {
        guard let first = row.first?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let number = Int(first), number > 0,
              let pid = currentPID, pid > 0 else { return false }
        WindowActivator.activateAndReport(windowNumber: number, ownerPID: pid)
        return true
    }

    /// 返回 true 表示已消费双击（不再走默认 PID 跳转）
    private func jumpFromFiles(_ row: [String]) -> Bool {
        guard let fd = row.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fd.isEmpty, Int(fd) != nil else { return false }

        let type = (row.count > 1 ? row[1] : "").uppercased()
        let path = row.last ?? ""
        let p = path.lowercased()

        let tab: DetailTab
        var keys: [String] = []
        if type.contains("SOCKET") {
            tab = .sockets                       // 网络页第一列就是 FD
        } else if type.contains("PIPE") {
            tab = .pipePeers                     // Pipe 页第一列就是 FD
        } else if p.contains("/dev/tty") || p.contains("/dev/pty")
                    || p.contains("ttys") || p.contains("ptys") {
            tab = .tty                           // TTY 页没有 FD 列，用设备名匹配
            keys.append((path as NSString).lastPathComponent)
            keys.append("FD \(fd)")             // 「标准输入 FD 0」这类行
            keys.append(path)
        } else {
            tab = .monitoring                    // KQUEUE / PSHM / VNODE / 其它
        }
        keys.append("FD \(fd)")

        pendingLocate = PendingLocate(tab: tab.rawValue, fd: fd, keys: keys)

        // 同步更新内部 index（不能只靠 AppKit 的 didSelect 通知，它可能是异步的），
        // 再让 segmented control 跟上。reload() 会采目标页 → apply() → flush。
        selectedTabIndex = tab.rawValue
        selectedTabViewItemIndex = tab.rawValue
        onTabSelected?(tab.rawValue)
        reload()
        return true
    }

    /// 只在 apply() 数据落表之后执行：目标页是惰性加载的，提前选中会选到占位行。
    private func flushPendingLocate() {
        guard let p = pendingLocate, p.tab == selectedTabIndex else { return }
        pendingLocate = nil
        // 再等一个 main queue 圈：apply() 里刚设好 selectedTabViewItemIndex，
        // AppKit 可能还没完成页签切换与布局，此时 scrollRowToVisible 会被忽略。
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.selectedTabIndex == p.tab else { return }
            let target: DetailTableViewController
            switch p.tab {
            case DetailTab.sockets.rawValue:    target = self.sockets
            case DetailTab.monitoring.rawValue: target = self.monitoring
            case DetailTab.pipePeers.rawValue:  target = self.pipePeers
            case DetailTab.tty.rawValue:        target = self.tty
            default: return
            }
            if target.clearFilterAndLocate(fd: p.fd, textKeys: p.keys) { return }
            // 兜底：把过滤框设成 FD 号，至少把相关行筛出来（例如进程刚退出、
            // socket 已关闭，目标页确实没有这一条）
            target.applyFilter(p.fd)
        }
    }

    // -----------------------------------------------------------------
    // 全局搜索命中 → 切到对应页签并定位到该行
    // -----------------------------------------------------------------

    /// 由 InspectorWindowController 转发。目标页是惰性加载的，所以先记下
    /// 待办，等 apply() 把数据填完再由 flushPendingFocus() 执行定位。
    func focus(tab: Int, textKeys: [String]) {
        guard DetailTab(rawValue: tab) != nil else { return }
        pendingFocus = (tab: tab, keys: textKeys.filter { !$0.isEmpty })
        if selectedTabIndex != tab {
            selectedTabIndex = tab
            selectedTabViewItemIndex = tab
        }
        onTabSelected?(tab)
        reload()
        // 数据已全部命中缓存时 apply() 会同步走完，pendingFocus 当场清掉；
        // 否则等后台采集完成后的 apply() 再处理。
    }

    private func tableVC(for tab: Int) -> DetailTableViewController? {
        switch DetailTab(rawValue: tab) {
        case .files:        return files
        case .env:          return env
        case .dylibs:       return dylibs
        case .sockets:      return sockets
        case .monitoring:   return monitoring
        case .pipePeers:    return pipePeers
        case .regions:      return regions
        case .tty:          return tty
        case .threads:      return threads
        case .windows:      return windows
        case .signing:      return signing
        case .permissions:  return permissions
        case .audit:        return audit
        case .mach:         return mach
        case .overview, .command, .none: return nil   // 文本视图，没有行可选
        }
    }

    /// ⌘F：切换当前页过滤框的显隐（唤出时自动聚焦）。
    /// 「命令」页是整段文本、没有过滤框，直接忽略。
    func toggleFilter() {
        let host: DetailTableViewController?
        if selectedTabIndex == 0 {
            host = overview.filterHost      // 概览页的过滤框在内嵌表格里
        } else {
            host = tableVC(for: selectedTabIndex)
        }
        guard let target = host else { return }
        _ = target.view                     // 惰性页：先让视图（与默认收起状态）生效
        target.toggleFilter()
    }

    private func flushPendingFocus() {
        guard let f = pendingFocus, f.tab == selectedTabIndex else { return }
        pendingFocus = nil
        let keys = f.keys
        // 再等一个 main queue 圈：页签切换 / 布局完成后 scrollRowToVisible
        // 才会生效（与 flushPendingLocate 同样的处理）。
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.selectedTabIndex == f.tab else { return }
            guard let target = self.tableVC(for: f.tab) else { return }
            if !keys.isEmpty, target.clearFilterAndLocate(fd: nil, textKeys: keys) {
                return
            }
            // 找不到（例如该行来自另一个进程、数据刚变化）：至少按首关键字过滤
            target.applyFilter(keys.first ?? "")
        }
    }

    private func lineItem(_ key: String, _ kind: ProcBridge.DetailKind,
                          pid: Int32) -> Item {
        Item(key: key) { .lines(ProcBridge.detail(kind, pid: pid)) }
    }

    /// 页签 index 与 viewDidLoad 里 addTabViewItem 的顺序一一对应
    private func items(for tab: Int, pid: Int32, path: String) -> [Item] {
        switch DetailTab(rawValue: tab) {
        case .overview:
            return [Item(key: "port") { .port(ProcBridge.taskPort(pid) ?? 0) }]
        case .files:
            return [lineItem("files",      .openFiles,    pid: pid)]
        case .env:
            return [lineItem("env",        .environment,  pid: pid)]
        case .dylibs:
            return [lineItem("dylibs",     .dylibs,       pid: pid)]
        case .sockets:
            return [lineItem("sockets",    .sockets,      pid: pid)]
        case .monitoring:
            return [lineItem("monitoring", .monitoring,   pid: pid)]
        case .pipePeers:
            return [lineItem("pipePeers",  .pipePeers,    pid: pid)]
        case .regions:
            return [lineItem("regions",    .regions,      pid: pid)]
        case .tty:
            return [lineItem("tty",        .tty,          pid: pid)]
        case .threads:
            return [lineItem("threads",    .threads,      pid: pid)]
        case .windows:
            return [Item(key: "windows") {
                // CGWindowListCopyWindowInfo 是纯 CG API，可跑在后台采集队列；
                // 窗口号 / 层 / bounds / 共享状态都不需要屏幕录制授权。
                .lines(WindowLocator.detailLines(for: pid))
            }]
        case .signing:
            return [Item(key: "signing") {
                .pairs(SigningReader.read(pid: pid, path: path).rows)
            }]
        case .permissions:
            return [Item(key: "permissions") {
                // entitlements / TCC.db / SIP / task port 全部在 Swift 侧采集，
                // 中文文案直接走 L()，不需要 C 层的双语标记表。
                .lines(PermissionReader.lines(
                    PermissionReader.report(pid: pid, path: path)))
            }]
        case .audit:
            return [lineItem("audit",      .audit,        pid: pid)]
        case .mach:
            return [lineItem("mach",       .machSecurity, pid: pid)]
        case .command, .none:
            return []                       // 命令页：只用快照
        }
    }

    func reload(force: Bool = false) {
        guard let pid = currentPID, pid > 0 else {
            showEmpty()
            return
        }

        generation &+= 1
        let g = generation
        // 取消上一批：C 层的 region 枚举 / 全系统 pipe 扫描会在长循环里检查
        if activeEpoch != 0 { ProcBridge.cancelDetailEpoch(activeEpoch) }
        let epoch = ProcBridge.beginDetailEpoch()
        activeEpoch = epoch

        // 换进程时清掉所有页，绝不在「文件」页上留下上一个进程的 FD 列表。
        // **必须在取快照之前**清 lastSnapshot：否则本帧刚取到的「已退出快照」
        // 会被这里一并清掉，下一次 reload 就退回按活进程采集 → 一屏 sysctl 报错。
        if lastPID != pid {
            lastPID = pid
            lastSnapshot = nil
            loadedKeys.removeAll()
            pendingLocate = nil      // 跨页定位只属于双击时的那个进程
            clearStalePages()
        }

        // 已退出进程的快照只存在于宽限期里；检查器开得比它久时不能再退回
        // 「按活进程采集」，所以记住最后一次见到的快照继续渲染。
        if let found = AppContext.shared.store.snapshotIncludingExited(for: pid) {
            lastSnapshot = found
        }
        let snap = lastSnapshot
        // 已退出（宽限期快照）：只用主表里已采到的值 + 缓存里已采过的页，
        // 不再对死掉的 PID 发任何系统调用 —— 那些调用只会返回 ESRCH，
        // 让用户看到一堆「读取失败」，没有任何信息量。
        let exited = snap?.isExited == true
        let path = snap?.exepath ?? ""
        let tab = selectedTabIndex
        let cache = DetailLoadCache.shared

        // 轻量页立即出内容，不等后台队列
        overview.setSnapshot(snap, port: exited ? nil : cachedPort(pid: pid, force: force))
        command.set(text: commandText(pid: pid, snap: snap))

        if exited {
            // 退出前采过的页照原样回放；没采过的页直接留空（不显示「正在采集…」）
            loadedKeys.removeAll()
            applyFrozen(cache, pid: pid, snap: snap, tab: tab)
            return
        }

        // 偏好设置里关掉「按页惰性加载」时回到全量采集（供性能对比 / 排错）。
        // 默认只采当前页，选中重 app 不再付 14 页的成本。
        let wanted: [Item] = Preferences.shared.lazyDetailLoading
            ? items(for: tab, pid: pid, path: path)
            : DetailTab.collectable.flatMap {
                items(for: $0.rawValue, pid: pid, path: path)
            }
        var ready: [String: DetailLoadCache.Payload] = [:]
        var pending: [Item] = []
        for it in wanted {
            if let hit = cache.get(it.key, pid: pid, force: force) {
                ready[it.key] = hit
                loadedKeys.insert(it.key)
            } else {
                pending.append(it)
                if it.key != "port", !loadedKeys.contains(it.key) {
                    showLoading(it.key)
                }
            }
        }

        if pending.isEmpty {
            apply(ready, pid: pid, snap: snap)
            return
        }

        DetailLoadQueue.queue.async { [weak self] in
            ProcBridge.markDetailEpoch(epoch)
            var results = ready
            for it in pending {
                if ProcBridge.detailAborted() { break }
                guard let payload = it.load(), !ProcBridge.detailAborted() else { break }
                results[it.key] = payload
                // 被取消产生的半截结果不写入缓存；采集失败（C 层首行是「错误」）
                // 的也不写 —— 否则进程退出后检查器读到这条缓存，会一直显示
                // 一屏「sysctl 失败」，把「退出前没采过」这个事实盖掉。
                if !Self.payloadIsCollectionError(payload) {
                    cache.put(payload, key: it.key, pid: pid)
                }
            }
            guard !ProcBridge.detailAborted() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == g else { return }
                for k in results.keys { self.loadedKeys.insert(k) }
                self.apply(results, pid: pid, snap: snap)
            }
        }
    }

    /// 已退出进程的页签内容：只从缓存回放，不发起采集。
    /// 当前页一页都没有缓存时，明确写「退出前没采过这一页」，
    /// 避免用户盯着「切换到本页时加载…」等一个永远不会来的结果。
    private func applyFrozen(_ cache: DetailLoadCache, pid: Int32,
                             snap: ProcessSnapshot?, tab: Int) {
        var ready: [String: DetailLoadCache.Payload] = [:]
        var keysForCurrentTab: [String] = []
        for t in DetailTab.collectable.map(\.rawValue) {
            let keys = items(for: t, pid: pid, path: snap?.exepath ?? "").map { $0.key }
            if t == tab { keysForCurrentTab = keys }
            for k in keys where ready[k] == nil {
                if let hit = cache.peek(k, pid: pid) { ready[k] = hit }
            }
        }
        let hasCurrent = keysForCurrentTab.contains { ready[$0] != nil }
        if !hasCurrent { showExitedPlaceholder(tab) }
        apply(ready, pid: pid, snap: snap)
    }

    private func showExitedPlaceholder(_ tab: Int) {
        // 概览 / 命令页用的是快照，没有表格可写占位
        guard let t = DetailTab(rawValue: tab),
              t != .overview, t != .command else { return }
        tableVC(for: tab)?.showPlaceholder(L("detail.exitedNothingCollected"))
    }

    /// C 层的采集失败会在首行写「错误」+ 原因，这种结果不该进缓存
    private static func payloadIsCollectionError(_ payload: DetailLoadCache.Payload) -> Bool {
        guard case .lines(let lines) = payload, let first = lines.first else {
            return false
        }
        let head = first.components(separatedBy: "\t").first ?? ""
        return L10n.cFieldZh(head) == "错误" || head == "错误"
    }

    private func cachedPort(pid: Int32, force: Bool) -> UInt32? {
        if let p = DetailLoadCache.shared.get("port", pid: pid, force: force),
           case .port(let v) = p {
            return v == 0 ? nil : v
        }
        return nil
    }

    private func commandText(pid: Int32, snap: ProcessSnapshot?) -> String {
        // 全部走语义 key + {0} 占位参数：格式串在 .strings 里，中文不再是 key，
        // 插值表达式也不再混进字符串字面量（上一轮正是在这里被正则截断的）。
        var text = L("detail.cmd.header", pid)
        text += L("detail.cmd.executable", snap?.exepath ?? "—")
        text += L("detail.cmd.bundle", snap?.bundlePath ?? "—")
        text += (snap?.cmdline.isEmpty == false ? snap!.cmdline
                 : (snap?.exepath ?? L("detail.detailCmdNoCommand")))
        text += L("detail.cmd.shortName", snap?.comm ?? "—")
        text += L("detail.cmd.longName", snap?.name ?? "—")
        return text
    }

    private func clearStalePages() {
        for vc in [files, env, dylibs, sockets, monitoring, audit, mach,
                   regions, pipePeers, tty, threads, windows, permissions] {
            vc.showPlaceholder(L("detail.loadedWhenThisTabIs"))
        }
        signing.showPlaceholder(L("detail.loadedWhenThisTabIs2"))
    }

    private func showLoading(_ key: String) {
        switch key {
        case "files":      files.showPlaceholder(L("detail.collectingOpenFiles"))
        case "env":        env.showPlaceholder(L("detail.readingEnvironmentVariables"))
        case "dylibs":     dylibs.showPlaceholder(L("detail.enumeratingLoadedImages"))
        case "sockets":    sockets.showPlaceholder(L("detail.parsingSockets"))
        case "monitoring": monitoring.showPlaceholder(L("detail.scanningFDsPipes"))
        case "pipePeers":  pipePeers.showPlaceholder(L("detail.scanningSystemWidePipePeers"))
        case "regions":    regions.showPlaceholder(L("detail.enumeratingMemoryMappings"))
        case "tty":        tty.showPlaceholder(L("detail.readingControllingTerminal"))
        case "windows":    windows.showPlaceholder(L("detail.enumeratingThisProcessSWindows"))
        case "mach":       mach.showPlaceholder(L("detail.readingMachSigningFlags"))
        case "audit":      audit.showPlaceholder(L("detail.readingAuditInfo"))
        case "signing":    signing.showPlaceholder(L("detail.verifyingCodeSignature"))
        case "permissions": permissions.showPlaceholder(L("perm.loading"))
        default: break
        }
    }

    private func apply(_ results: [String: DetailLoadCache.Payload],
                       pid: Int32, snap: ProcessSnapshot?) {
        for (key, payload) in results {
            switch payload {
            case .port(let p):
                if key == "port" { overview.setSnapshot(snap, port: p == 0 ? nil : p) }
            case .pairs(let rows):
                if key == "signing" { signing.setPairs(rows, headers: [L("detail.item4"), L("detail.value5")]) }
            case .lines(let lines):
                applyLines(lines, key: key)
            }
        }
        // 目标页数据已落表，此时选中/滚动才不会选到「正在采集…」占位行
        flushPendingLocate()
        flushPendingFocus()
    }

    private func applyLines(_ lines: [String], key: String) {
        switch key {
        case "files":
            files.setRows(parse(lines, titles: ["FD", "类型", "打开标志", "路径"]),
                          headers: ["FD", L("detail.type"), L("detail.openFlags"), L("detail.path")])
        case "env":
            env.setRows(parse(lines, titles: ["变量", "值"]),
                        headers: [L("detail.variable"), L("detail.value7")])
        case "dylibs":
            dylibs.setRows(parse(lines, titles: ["加载地址", "修改时间", "镜像路径"]),
                           headers: [L("detail.loadAddress"), L("detail.modified"), L("detail.imagePath")])
        case "sockets":
            sockets.setRows(parse(lines, titles: ["FD", "协议 / 族", "本地地址", "远端地址", "状态", "补充"]),
                            headers: ["FD", L("detail.protocolFamily"), L("detail.localAddress"), L("detail.remoteAddress"), L("detail.status"),
                                      L("detail.extraKindPcb")])
        case "monitoring":
            monitoring.setRows(parse(lines, titles: ["FD", "类型", "句柄 / 状态", "说明"]),
                               headers: ["FD", L("detail.type"), L("detail.handleState"), L("detail.descriptionPeerProcess")])
        case "pipePeers":
            pipePeers.setRows(parse(lines, titles: ["FD", "本端句柄", "对端句柄", "对端 PID", "对端进程", "对端 FD", "状态"]),
                              headers: ["FD", L("detail.localHandle"), L("detail.peerHandle"), L("detail.peerPid"),
                                        L("detail.peerProcess"), L("detail.peerFd"), L("detail.status")])
        case "regions":
            regions.setRows(parse(lines, titles: ["起始地址", "结束地址", "大小", "保护", "映射文件"]),
                            headers: [L("detail.startAddress"), L("detail.endAddress"), L("detail.size"), L("detail.protectionMaxProtection"),
                                      L("detail.mappedFile")])
        case "tty":
            tty.setRows(parse(lines, titles: ["项目", "值", "说明"]),
                        headers: [L("detail.item6"), L("detail.value"), L("detail.description")])
        case "threads":
            threads.setRows(
                parse(lines, titles: ["TID", "线程名", "状态", "CPU",
                                      "CPU 时间（用户 / 内核）",
                                      "优先级 / 调度策略"]),
                headers: ["TID", L("detail.threadName"), L("detail.status"),
                          "CPU", L("detail.cpuTimeUserSystem"),
                          L("detail.priorityPolicy")])
        case "permissions":
            // 字段已经是当前语言的成品，不能再走 parse() 的字段本地化
            permissions.setRows(
                lines.map { $0.components(separatedBy: "\t") },
                headers: [L("perm.colCategory"), L("perm.colPermission"),
                          L("perm.colState"), L("perm.colDetail"),
                          L("perm.colSource")])
        case "windows":
            windows.setRows(
                parse(lines, titles: ["窗口号", "标题", "层",
                                      "位置 / 尺寸", "屏幕状态", "共享 / Alpha"]),
                headers: [L("detail.windowId"), L("detail.title"), L("detail.layer"), L("detail.positionSize"),
                          L("detail.screenState"), L("detail.sharingAlpha")])
        case "mach":
            mach.setRows(parse(lines, titles: ["项目", "值", "说明"]),
                         headers: [L("detail.item"), L("detail.value"), L("detail.description")])
        case "audit":
            audit.setRows(parse(lines, titles: ["项目", "值", "说明"]),
                          headers: [L("detail.item"), L("detail.value"), L("detail.description")])
        default:
            // 采集了却没有落表 → 页签静默空白（「审计」页就曾这样空了一版）。
            // Debug 下直接在开发时炸出来，Release 里断言被编译掉，不影响用户。
            assertionFailure("applyLines: 未处理的详情键 \"\(key)\"，该页签会显示为空白")
        }
    }

    /// C 层输出是 \t 分隔的纯文本。三步顺序不能乱：
    ///  1) 先在**原始中文**上剥掉表头行（titles 保持中文，与 C 层协议一致；
    ///     若先本地化，英文下表头行就匹配不上，会变成一行数据）；
    ///  2) 按偏好丢掉 __hint__ 提示行（默认隐藏）；
    ///  3) 剩余字段逐列本地化（完整匹配 + 中文短语最长匹配）。
    private func parse(_ lines: [String], titles: [String]) -> [[String]] {
        var arr = lines.map { $0.components(separatedBy: "\t") }
        // C 层表头字段现在带双语标记，取「标记里的中文原文」与协议比较，
        // 否则英文下 first.first 变成 "Item"，匹配不上 titles.first 会把表头当数据行。
        if let first = arr.first, L10n.cFieldZh(first.first ?? "") == titles.first {
            arr.removeFirst()
        }
        let showHints = L10n.showDetailHints
        var out: [[String]] = []
        out.reserveCapacity(arr.count)
        for f in arr {
            if f.first == L10n.hintTag {
                if !showHints { continue }
                var g = f
                g[0] = L("detail.hint2")
                out.append(g.map(L10n.localizeField))
            } else {
                out.append(f.map(L10n.localizeField))
            }
        }
        return out
    }

    private func showEmpty() {
        if activeEpoch != 0 {
            ProcBridge.cancelDetailEpoch(activeEpoch)
            activeEpoch = 0
        }
        lastPID = nil
        loadedKeys.removeAll()
        pendingLocate = nil
        overview.setSnapshot(nil, port: nil)
        for vc in [files, env, dylibs, sockets, monitoring, audit, mach,
                   regions, pipePeers, tty, windows, permissions] {
            vc.showPlaceholder(L("detail.noProcessSelected4"))
        }
        signing.showPlaceholder(L("detail.noProcessSelected5"))
        permissions.showPlaceholder(L("detail.noProcessSelected5"))
        command.set(text: L("detail.noProcessSelected6"))
    }

    // -----------------------------------------------------------------
    // 权限页：TCC 授予 / 撤销
    //
    // 只在 SIP 文件系统保护关闭时开放（否则 TCC.db 受保护，写入必失败）。
    // 授予 / 撤销本身是一次 SQLite 写入，经 Privilege.run 以 root 执行，
    // 会弹系统的管理员授权框。
    // -----------------------------------------------------------------

    private final class TCCMenuTarget: NSObject {
        let service: String
        let record: TCCRecord?
        let allow: Bool

        init(service: String, record: TCCRecord?, allow: Bool) {
            self.service = service
            self.record = record
            self.allow = allow
        }
    }

    /// 右键菜单的附加项：只有 TCC 行才有（entitlements 由签名决定，不可改）
    private func permissionMenuItems(for row: [String]) -> [NSMenuItem] {
        guard row.count >= 2, let pid = currentPID,
              let rep = PermissionReader.cachedReport(pid: pid),
              row[0] == L("perm.catTcc") else { return [] }

        // 数据库读不到时只给「授权入口」，没有可写的记录
        guard rep.tccReadable else { return fullDiskAccessMenuItems() }

        guard rep.sip.canWriteTCC else {
            let item = NSMenuItem(title: L("perm.menuNeedsSipOff"),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]
        }

        // 表格存的是当前语言的成品文案，按「类别 + 名称」回查采集结果
        let match = rep.rows.first {
            $0.category == row[0] && $0.name == row[1] && $0.service != nil
        }

        var items: [NSMenuItem] = []
        if let match = match, let service = match.service {
            for (title, allow) in [(L("perm.menuGrant"), true),
                                   (L("perm.menuRevoke"), false)] {
                let item = NSMenuItem(title: title,
                                      action: #selector(tccMenuAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = TCCMenuTarget(service: service,
                                                       record: match.record,
                                                       allow: allow)
                items.append(item)
            }
        }

        // 「没有记录」的服务不再占表格行，但仍要能新增：放进子菜单。
        let used = Set(rep.rows.compactMap { $0.service })
        let grantable = PermissionReader.grantableServices(excluding: used)
        if !grantable.isEmpty {
            if !items.isEmpty { items.append(.separator()) }
            let parent = NSMenuItem(title: L("perm.menuGrantOther"),
                                    action: nil, keyEquivalent: "")
            let sub = NSMenu(title: L("perm.menuGrantOther"))
            for (service, name) in grantable {
                let item = NSMenuItem(title: name,
                                      action: #selector(tccMenuAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = TCCMenuTarget(service: service,
                                                       record: nil, allow: true)
                sub.addItem(item)
            }
            parent.submenu = sub
            items.append(parent)
        }
        return items
    }

    /// 「完全磁盘访问」是 TCC.db 的读取前提，系统不提供程序化授予：
    /// 只能把用户送到设置面板，并给出可拖拽的 App 位置。
    private func fullDiskAccessMenuItems() -> [NSMenuItem] {
        let open = NSMenuItem(title: L("perm.menuOpenFDA"),
                              action: #selector(openFullDiskAccess(_:)),
                              keyEquivalent: "")
        open.target = self
        let reveal = NSMenuItem(title: L("perm.menuRevealApp"),
                                action: #selector(revealAppForFDA(_:)),
                                keyEquivalent: "")
        reveal.target = self
        return [open, reveal]
    }

    @objc private func openFullDiskAccess(_ sender: Any?) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
        // macOS 没有「请求 FDA」的 API：把用户送到面板，再说明怎么加。
        let alert = NSAlert()
        alert.messageText = L("perm.fdaTitle")
        alert.informativeText = L("perm.fdaSteps")
        alert.addButton(withTitle: L("app.ok"))
        alert.runModal()
    }

    @objc private func revealAppForFDA(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func tccMenuAction(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TCCMenuTarget,
              let pid = currentPID else { return }
        let path = AppContext.shared.store.snapshotIncludingExited(for: pid)?.exepath
            ?? lastSnapshot?.exepath ?? ""
        let client = target.record?.client
            ?? PermissionReader.preferredClient(pid: pid, path: path) ?? "—"
        let db = target.record?.dbPath
            ?? (NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db")

        let alert = NSAlert()
        alert.messageText = L(target.allow ? "perm.confirmGrantTitle"
                                           : "perm.confirmRevokeTitle")
        alert.informativeText = L(target.allow ? "perm.confirmGrantBody"
                                               : "perm.confirmRevokeBody",
                                  PermissionReader.displayName(for: target.service),
                                  client, db)
        alert.addButton(withTitle: L(target.allow ? "perm.grant" : "perm.revoke"))
        alert.addButton(withTitle: L("app.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let (ok, text) = PermissionReader.writeTCC(service: target.service,
                                                   record: target.record,
                                                   pid: pid, path: path,
                                                   allow: target.allow)
        if ok {
            reload(force: true)
        } else {
            let fail = NSAlert()
            fail.messageText = L("perm.writeFailedTitle")
            fail.informativeText = text
            fail.addButton(withTitle: L("app.ok"))
            fail.runModal()
        }
    }

    deinit {
        if let t = tabSelectionObserver {
            NotificationCenter.default.removeObserver(t)
        }
        NotificationCenter.default.removeObserver(self)
    }
}
