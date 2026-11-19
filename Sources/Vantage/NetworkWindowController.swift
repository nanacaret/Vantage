// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 系统网络窗口（⌘⌥N）
//
// 两个页签：
//   网卡 —— 系统网卡列表（ifconfig 的 interface 部分）+ 选中网卡的地址表，
//           可 up / down、改 MTU、增删 IPv4 / IPv6 地址；
//   路由 —— 路由表（route / netstat -rn），可增删路由与默认路由。
//
// 设计取舍：
//   · 所有修改都走 /sbin/ifconfig 与 /sbin/route（系统自带、行为与命令行
//     完全一致），不自己 ioctl 拼路由消息 —— 后者容易在 RTM_ADD 的
//     sockaddr 编码上出错，收益为零；
//   · 提权统一交给 Privilege（系统授权对话框），输入全部先校验再拼命令；
//   · 结果**不弹窗**：底部状态栏显示成功 / 失败与命令输出，失败时附原始
//     stderr，方便照抄去终端复现。
// ---------------------------------------------------------------------

final class NetworkWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, RowTextCopying {

    static let shared = NetworkWindowController()

    private static let frameName = "VantageNetworkWindow"

    // MARK: 数据

    private var ifaces: [NetIface] = []
    private var addrs: [NetAddr] = []
    private var routes: [NetRoute] = []
    private var shownIfaces: [NetIface] = []
    private var shownAddrs: [NetAddr] = []
    private var shownRoutes: [NetRoute] = []

    private var query = ""
    private var matcher = SearchMatcher(query: "", mode: .literal)
    private var tabIndex = 0

    // MARK: 控件

    private let segment = NSSegmentedControl(
        labels: [L("net.tab.interfaces"), L("net.tab.routes")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let refreshButton = NetworkWindowController.plainButton(L("net.refresh"))
    private let filterField = NSSearchField(frame: .zero)
    private let ifaceTable = ActionTableView(frame: .zero)
    private let addrTable = ActionTableView(frame: .zero)
    private let routeTable = ActionTableView(frame: .zero)
    private let ifaceContainer = NSView(frame: .zero)
    private let routeContainer = NSView(frame: .zero)
    private let statusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let rootLabel = UI.label("", size: 11, color: .secondaryLabelColor)

    private let upButton = NetworkWindowController.plainButton(L("net.act.up"))
    private let downButton = NetworkWindowController.plainButton(L("net.act.down"))
    private let mtuButton = NetworkWindowController.plainButton(L("net.act.mtu"))
    private let addAddrButton = NetworkWindowController.plainButton(L("net.act.addAddr"))
    private let delAddrButton = NetworkWindowController.plainButton(L("net.act.delAddr"))
    private let addRouteButton = NetworkWindowController.plainButton(L("net.act.addRoute"))
    private let delRouteButton = NetworkWindowController.plainButton(L("net.act.delRoute"))

    /// 先建按钮、稍后再挂 action（构造期间 self 还不能作为 target）
    private static func plainButton(_ title: String) -> NSButton {
        let b = NSButton(frame: .zero)
        b.title = title
        b.bezelStyle = .rounded
        b.font = NSFont.systemFont(ofSize: 12)
        b.target = nil
        b.action = nil
        return b
    }

    // MARK: 初始化

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = L("net.windowTitle")
        w.minSize = NSSize(width: 760, height: 460)
        w.center()
        w.setFrameAutosaveName(Self.frameName)
        super.init(window: w)
        setupUI()
        observe()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError(L("window.initCoderNotImplemented3")) }

    override func showWindow(_ sender: Any?) {
        window?.ensureVisibleOnScreens(autosaveName: Self.frameName)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        refresh()
        AppActivate.front()
    }

    // MARK: 界面

    private func setupUI() {
        guard let window = self.window else { return }
        let root = NSView()
        window.contentView = root

        segment.target = self
        segment.action = #selector(tabChanged(_:))
        segment.selectedSegment = 0
        segment.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))

        filterField.placeholderString = L("net.filterPlaceholder")
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topBar = NSStackView(views: [refreshButton, segment, filterField])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topBar)

        // ---- 网卡页 ----
        setupTable(ifaceTable, columns: [
            ("ifName", L("net.col.name"), 110),
            ("ifState", L("net.col.state"), 120),
            ("ifFlags", L("net.col.flags"), 200),
            ("ifMtu", L("net.col.mtu"), 60),
            ("ifMac", L("net.col.mac"), 150),
            ("ifV4", L("net.col.ipv4"), 200),
            ("ifV6", L("net.col.ipv6"), 220),
        ])
        setupTable(addrTable, columns: [
            ("adFamily", L("net.col.family"), 70),
            ("adAddr", L("net.col.address"), 300),
            ("adPrefix", L("net.col.prefix"), 60),
            ("adMask", L("net.col.netmask"), 220),
            ("adPeer", L("net.col.peer"), 170),
            ("adScope", L("net.col.scope"), 70),
        ])
        for b in [upButton, downButton, mtuButton, addAddrButton, delAddrButton] {
            b.target = self
            b.font = NSFont.systemFont(ofSize: 11)
        }
        upButton.action = #selector(linkUp(_:))
        downButton.action = #selector(linkDown(_:))
        mtuButton.action = #selector(editMTU(_:))
        addAddrButton.action = #selector(addAddress(_:))
        delAddrButton.action = #selector(deleteAddress(_:))

        let scrollIface = makeScroll(ifaceTable)
        let scrollAddr = makeScroll(addrTable)
        let addrBar = NSStackView(views: [upButton, downButton, mtuButton,
                                          addAddrButton, delAddrButton])
        addrBar.orientation = .horizontal
        addrBar.spacing = 6

        for v in [scrollIface, addrBar, scrollAddr] {
            v.translatesAutoresizingMaskIntoConstraints = false
            ifaceContainer.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scrollIface.topAnchor.constraint(equalTo: ifaceContainer.topAnchor),
            scrollIface.leadingAnchor.constraint(equalTo: ifaceContainer.leadingAnchor),
            scrollIface.trailingAnchor.constraint(equalTo: ifaceContainer.trailingAnchor),
            scrollIface.heightAnchor.constraint(
                greaterThanOrEqualToConstant: 180),

            addrBar.topAnchor.constraint(equalTo: scrollIface.bottomAnchor,
                                         constant: 8),
            addrBar.leadingAnchor.constraint(equalTo: ifaceContainer.leadingAnchor),
            addrBar.trailingAnchor.constraint(lessThanOrEqualTo:
                ifaceContainer.trailingAnchor),
            addrBar.heightAnchor.constraint(equalToConstant: 22),

            scrollAddr.topAnchor.constraint(equalTo: addrBar.bottomAnchor,
                                            constant: 6),
            scrollAddr.leadingAnchor.constraint(equalTo: ifaceContainer.leadingAnchor),
            scrollAddr.trailingAnchor.constraint(equalTo: ifaceContainer.trailingAnchor),
            scrollAddr.bottomAnchor.constraint(equalTo: ifaceContainer.bottomAnchor),
            scrollAddr.heightAnchor.constraint(equalToConstant: 210),
        ])

        // ---- 路由页 ----
        setupTable(routeTable, columns: [
            ("rtFamily", L("net.col.family"), 70),
            ("rtDest", L("net.col.destination"), 280),
            ("rtGateway", L("net.col.gateway"), 260),
            ("rtFlags", L("net.col.flags"), 120),
            ("rtNetif", L("net.col.netif"), 90),
            ("rtExpire", L("net.col.expire"), 80),
        ])
        for b in [addRouteButton, delRouteButton] {
            b.target = self
            b.font = NSFont.systemFont(ofSize: 11)
        }
        addRouteButton.action = #selector(addRoute(_:))
        delRouteButton.action = #selector(deleteRoute(_:))

        let routeBar = NSStackView(views: [addRouteButton, delRouteButton])
        routeBar.orientation = .horizontal
        routeBar.spacing = 6
        let scrollRoute = makeScroll(routeTable)
        for v in [routeBar, scrollRoute] {
            v.translatesAutoresizingMaskIntoConstraints = false
            routeContainer.addSubview(v)
        }
        NSLayoutConstraint.activate([
            routeBar.topAnchor.constraint(equalTo: routeContainer.topAnchor),
            routeBar.leadingAnchor.constraint(equalTo: routeContainer.leadingAnchor),
            routeBar.heightAnchor.constraint(equalToConstant: 22),

            scrollRoute.topAnchor.constraint(equalTo: routeBar.bottomAnchor,
                                             constant: 6),
            scrollRoute.leadingAnchor.constraint(equalTo: routeContainer.leadingAnchor),
            scrollRoute.trailingAnchor.constraint(equalTo: routeContainer.trailingAnchor),
            scrollRoute.bottomAnchor.constraint(equalTo: routeContainer.bottomAnchor),
        ])

        for v in [ifaceContainer, routeContainer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        routeContainer.isHidden = true

        let divider = NSBox(frame: .zero)
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isSelectable = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow,
                                                            for: .horizontal)
        rootLabel.font = NSFont.systemFont(ofSize: 11)
        rootLabel.textColor = .secondaryLabelColor
        rootLabel.setContentCompressionResistancePriority(.defaultHigh,
                                                          for: .horizontal)
        for v in [statusLabel, rootLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 24),

            ifaceContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor,
                                                constant: 10),
            ifaceContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                    constant: 12),
            ifaceContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                     constant: -12),
            ifaceContainer.bottomAnchor.constraint(equalTo: divider.topAnchor,
                                                   constant: -6),

            routeContainer.topAnchor.constraint(equalTo: ifaceContainer.topAnchor),
            routeContainer.leadingAnchor.constraint(equalTo: ifaceContainer.leadingAnchor),
            routeContainer.trailingAnchor.constraint(equalTo: ifaceContainer.trailingAnchor),
            routeContainer.bottomAnchor.constraint(equalTo: ifaceContainer.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: statusLabel.topAnchor,
                                            constant: -6),
            divider.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                 constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                                constant: -8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo:
                rootLabel.leadingAnchor, constant: -10),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),

            rootLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                constant: -12),
            rootLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
        ])

        updateRootLabel()
        updateButtons()
    }

    private func makeScroll(_ table: NSTableView) -> NSScrollView {
        let s = NSScrollView(frame: .zero)
        s.documentView = table
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = true
        s.autohidesScrollers = true
        s.borderType = .bezelBorder
        return s
    }

    private func setupTable(_ table: NSTableView,
                            columns: [(String, String, CGFloat)]) {
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 44
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .small
    }

    // MARK: 通知

    private func observe() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appColorsChanged),
            name: .appColorsDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchModeChanged),
            name: .searchModeDidChange, object: nil)
    }

    @objc private func appColorsChanged() {
        ifaceTable.reloadData()
        addrTable.reloadData()
        routeTable.reloadData()
    }

    @objc private func searchModeChanged() {
        filterChanged(nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: 读取

    @objc func refreshClicked(_ sender: Any?) { refresh() }

    func refresh() {
        ifaces = NetBridge.ifaces()
        addrs = NetBridge.addrs()
        routes = NetBridge.routes()
        reloadData()
        if statusLabel.stringValue.isEmpty {
            setStatus(L("net.status.loaded", ifaces.count, routes.count),
                      color: .secondaryLabelColor)
        }
        updateRootLabel()
    }

    private func reloadData() {
        shownIfaces = filter(ifaces) { iface in
            let addresses = addrs.filter { $0.ifname == iface.name }
            return ([iface.name, iface.type, iface.mac, iface.flagText]
                    + addresses.map { $0.addr }).joined(separator: " ")
        }
        ifaceTable.reloadData()

        // 地址表跟随网卡选择
        let selected = selectedIfaceName()
        shownAddrs = addrs.filter { selected == nil || $0.ifname == selected }
        shownAddrs = filter(shownAddrs) {
            [$0.ifname, $0.family, $0.addr, $0.netmask, $0.peer]
                .joined(separator: " ")
        }
        addrTable.reloadData()

        shownRoutes = filter(routes) {
            [$0.family, $0.dest, $0.gateway, $0.flags, $0.netif]
                .joined(separator: " ")
        }
        routeTable.reloadData()
        updateButtons()
    }

    /// 过滤：沿用主表的匹配语义（字面量 / 正则，正则无效自动回退）
    private func filter<T>(_ items: [T], text: (T) -> String) -> [T] {
        if matcher.isEmpty { return items }
        return items.filter { matcher.matches(text($0)) }
    }

    @objc private func filterChanged(_ sender: Any?) {
        query = filterField.stringValue
        matcher = SearchMatcher(
            query: query,
            mode: Preferences.shared.searchUseRegex ? .regex : .literal)
        reloadData()
    }

    @objc private func tabChanged(_ sender: Any?) {
        tabIndex = max(0, min(1, segment.selectedSegment))
        ifaceContainer.isHidden = tabIndex != 0
        routeContainer.isHidden = tabIndex != 1
        updateButtons()
    }

    private func selectedIface() -> NetIface? {
        guard tabIndex == 0 else { return nil }
        let row = ifaceTable.selectedRow
        return row >= 0 ? shownIfaces[safe: row] : nil
    }

    private func selectedIfaceName() -> String? { selectedIface()?.name }

    private func selectedAddr() -> NetAddr? {
        let row = addrTable.selectedRow
        return row >= 0 ? shownAddrs[safe: row] : nil
    }

    private func selectedRoute() -> NetRoute? {
        guard tabIndex == 1 else { return nil }
        let row = routeTable.selectedRow
        return row >= 0 ? shownRoutes[safe: row] : nil
    }

    private func updateButtons() {
        let iface = selectedIface()
        upButton.isEnabled = iface?.isUp == false
        downButton.isEnabled = iface?.isUp == true
        mtuButton.isEnabled = iface != nil
        addAddrButton.isEnabled = iface != nil
        delAddrButton.isEnabled = (selectedAddr()?.family).map { $0 != "link" } ?? false
        addRouteButton.isEnabled = true
        delRouteButton.isEnabled = selectedRoute() != nil
    }

    private func updateRootLabel() {
        if Privilege.isRoot {
            rootLabel.stringValue = L("priv.runningAsRoot")
            rootLabel.textColor = .systemGreen
        } else {
            rootLabel.stringValue = L("net.rootHint")
            rootLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: 表格数据源

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case ifaceTable: return shownIfaces.count
        case addrTable:  return shownAddrs.count
        default:         return shownRoutes.count
        }
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let id = column.identifier.rawValue
        let cell = tableView.makeView(withIdentifier: column.identifier,
                                      owner: self) as? TextCell
            ?? TextCell(frame: .zero)
        cell.identifier = column.identifier

        func set(_ text: String, _ color: NSColor = .labelColor) {
            cell.configure(text, color: color)
        }

        switch tableView {
        case ifaceTable:
            guard let i = shownIfaces[safe: row] else { return cell }
            switch id {
            case "ifName":  set(i.name, i.isUp ? .labelColor : .secondaryLabelColor)
            case "ifState": set(stateText(i), i.isUp ? .labelColor : .secondaryLabelColor)
            case "ifFlags": set(i.flagText, .secondaryLabelColor)
            case "ifMtu":   set("\(i.mtu)")
            case "ifMac":   set(i.mac.isEmpty ? "-" : i.mac)
            case "ifV4":    set(listText(addrs.filter { $0.ifname == i.name && $0.family == "inet" }))
            case "ifV6":    set(listText(addrs.filter { $0.ifname == i.name && $0.family == "inet6" }))
            default:        set("-")
            }
        case addrTable:
            guard let a = shownAddrs[safe: row] else { return cell }
            switch id {
            case "adFamily": set(a.family)
            case "adAddr":   set(a.addr)
            case "adPrefix": set(a.prefix >= 0 ? "\(a.prefix)" : "-")
            case "adMask":   set(a.netmask)
            case "adPeer":   set(a.peer)
            case "adScope":  set(a.scope == 0 ? "-" : "\(a.scope)")
            default:         set("-")
            }
        default:
            guard let r = shownRoutes[safe: row] else { return cell }
            switch id {
            case "rtFamily": set(r.family, .secondaryLabelColor)
            case "rtDest":   set(r.dest)
            case "rtGateway":set(r.gateway)
            case "rtFlags":  set(r.flags, .secondaryLabelColor)
            case "rtNetif":  set(r.netif)
            case "rtExpire": set(r.expire > 0 ? "\(r.expire)" : "-")
            default:         set("-")
            }
        }
        return cell
    }

    private func stateText(_ i: NetIface) -> String {
        if !i.isUp { return L("net.state.down") }
        return i.isRunning ? L("net.state.upRunning") : L("net.state.up")
    }

    /// 地址列：最多列 3 个，其余用 "+N" 收尾，避免把列撑爆
    private func listText(_ items: [NetAddr]) -> String {
        guard !items.isEmpty else { return "-" }
        let head = items.prefix(3).map {
            $0.prefix >= 0 ? "\($0.addr)/\($0.prefix)" : $0.addr
        }
        let tail = items.count > 3 ? " +\(items.count - 3)" : ""
        return head.joined(separator: ", ") + tail
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === ifaceTable {
            let name = selectedIfaceName()
            shownAddrs = addrs.filter { name == nil || $0.ifname == name }
            shownAddrs = filter(shownAddrs) {
                [$0.ifname, $0.family, $0.addr, $0.netmask, $0.peer]
                    .joined(separator: " ")
            }
            addrTable.reloadData()
        }
        updateButtons()
    }

    // MARK: ⌘C

    func copySelectedRowsToPasteboard() -> Bool {
        let table: NSTableView
        if let first = window?.firstResponder as? NSTableView {
            table = first
        } else {
            table = tabIndex == 0 ? ifaceTable : routeTable
        }
        let rows = selectedRowIndexes(of: table)
        guard !rows.isEmpty else { return false }

        var lines: [String] = []
        if table === ifaceTable {
            lines = rows.compactMap { shownIfaces[safe: $0] }.map {
                [$0.name, stateText($0), $0.flagText, "\($0.mtu)", $0.mac].joined(separator: "\t")
            }
        } else if table === addrTable {
            lines = rows.compactMap { shownAddrs[safe: $0] }.map {
                [$0.family, $0.addr, "\($0.prefix)", $0.netmask, $0.peer].joined(separator: "\t")
            }
        } else {
            lines = rows.compactMap { shownRoutes[safe: $0] }.map {
                [$0.family, $0.dest, $0.gateway, $0.flags, $0.netif].joined(separator: "\t")
            }
        }
        guard !lines.isEmpty else { return false }
        Clipboard.setString(lines.joined(separator: "\n"))
        return true
    }

    private func selectedRowIndexes(of table: NSTableView) -> [Int] {
        let idx = table.selectedRowIndexes
        if idx.isEmpty, table.selectedRow >= 0 { return [table.selectedRow] }
        return Array(idx)
    }

    // MARK: 动作 —— 网卡

    @objc private func linkUp(_ sender: Any?) {
        guard let iface = selectedIface() else { return needIface() }
        run(L("net.act.up"), NetAdmin.setLink(iface: iface.name, up: true))
    }

    @objc private func linkDown(_ sender: Any?) {
        guard let iface = selectedIface() else { return needIface() }
        run(L("net.act.down"), NetAdmin.setLink(iface: iface.name, up: false))
    }

    @objc private func editMTU(_ sender: Any?) {
        guard let iface = selectedIface() else { return needIface() }
        prompt(title: L("net.dlg.mtuTitle"),
               info: L("net.dlg.mtuInfo", iface.name, iface.mtu),
               action: L("net.act.mtu"),
               fields: [(L("net.dlg.mtuLabel"), "\(iface.mtu)")]) { values in
            let text = values.first ?? ""
            guard let mtu = Int(text), (68...65535).contains(mtu) else {
                self.badInput(L("net.err.badMTU", text))
                return
            }
            self.run(L("net.act.mtu"),
                     NetAdmin.setMTU(iface: iface.name, mtu: mtu))
        }
    }

    @objc private func addAddress(_ sender: Any?) {
        guard let iface = selectedIface() else { return needIface() }
        prompt(title: L("net.dlg.addAddrTitle"),
               info: L("net.dlg.addAddrInfo", iface.name),
               action: L("net.dlg.add"),
               fields: [(L("net.dlg.addrLabel"), ""),
                        (L("net.dlg.prefixLabel"), "")]) { values in
            let rawAddr = values.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let rawPrefix = values.count > 1
                ? values[1].trimmingCharacters(in: .whitespaces) : ""

            // 允许用户直接在地址栏写 CIDR
            var address = rawAddr
            var prefixText = rawPrefix
            if rawAddr.contains("/") {
                let parts = rawAddr.split(separator: "/", maxSplits: 1)
                address = String(parts[0])
                if parts.count > 1 { prefixText = String(parts[1]) }
            }
            let isV6 = NetValidate.isIPv6(address)
            guard NetValidate.isIPv4(address) || isV6 else {
                self.badInput(L("net.err.badAddress", rawAddr))
                return
            }
            let maxBits = isV6 ? 128 : 32
            let prefix = prefixText.isEmpty
                ? (isV6 ? 64 : 24) : (Int(prefixText) ?? -1)
            guard (0...maxBits).contains(prefix) else {
                self.badInput(L("net.err.badPrefix", prefixText))
                return
            }
            self.run(L("net.act.addAddr"),
                     NetAdmin.addAddress(iface: iface.name, address: address,
                                         prefix: prefix, isV6: isV6))
        }
    }

    @objc private func deleteAddress(_ sender: Any?) {
        guard let iface = selectedIface() else { return needIface() }
        guard let addr = selectedAddr(), addr.family != "link" else {
            return badInput(L("net.err.needAddr"))
        }
        let isV6 = addr.isIPv6
        run(L("net.act.delAddr"),
            NetAdmin.removeAddress(iface: iface.name, address: addr.addr,
                                   isV6: isV6))
    }

    // MARK: 动作 —— 路由

    @objc private func addRoute(_ sender: Any?) {
        prompt(title: L("net.dlg.addRouteTitle"),
               info: L("net.dlg.addRouteInfo"),
               action: L("net.dlg.add"),
               fields: [(L("net.dlg.destLabel"), "default"),
                        (L("net.dlg.gatewayLabel"), "")]) { values in
            let destText = values.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let gateway = values.count > 1
                ? values[1].trimmingCharacters(in: .whitespaces) : ""
            guard let dest = NetValidate.parseDestination(destText) else {
                self.badInput(L("net.err.badDest", destText))
                return
            }
            let known = Set(self.ifaces.map { $0.name })
            guard NetValidate.isGateway(gateway, known: known) else {
                self.badInput(L("net.err.badGateway", gateway))
                return
            }
            self.run(L("net.act.addRoute"),
                     NetAdmin.addRoute(address: dest.address,
                                       prefix: dest.prefix,
                                       isV6: dest.isV6,
                                       gateway: gateway,
                                       reject: false))
        }
    }

    @objc private func deleteRoute(_ sender: Any?) {
        guard let route = selectedRoute() else {
            return badInput(L("net.err.needRoute"))
        }
        guard let dest = NetValidate.parseDestination(route.dest) else {
            return badInput(L("net.err.badDest", route.dest))
        }
        run(L("net.act.delRoute"),
            NetAdmin.deleteRoute(address: dest.address, prefix: dest.prefix,
                                 isV6: dest.isV6, gateway: route.gateway))
    }

    // MARK: 执行与反馈（不弹窗）

    private func run(_ action: String, _ result: (rc: Int32, output: String)) {
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.rc == 0 {
            setStatus(text.isEmpty ? L("net.result.ok", action)
                                   : L("net.result.okDetail", action, text),
                      color: .systemGreen)
        } else {
            setStatus(L("net.result.fail", action,
                        text.isEmpty ? "rc=\(result.rc)" : text),
                      color: .systemRed)
        }
        refresh()
    }

    private func needIface() { badInput(L("net.err.needIface")) }

    private func badInput(_ message: String) {
        setStatus(message, color: .systemOrange)
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.toolTip = text
    }

    // MARK: 输入表单

    /// 轻量输入表：NSAlert + accessoryView，回车即提交。
    /// 只用于**输入**；结果一律走底部状态栏，不再弹第二个框。
    private func prompt(title: String, info: String, action: String,
                        fields: [(label: String, value: String)],
                        onOK: @escaping ([String]) -> Void) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("app.cancel"))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var editors: [NSTextField] = []
        for f in fields {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let label = UI.label(f.label, size: 11, color: .secondaryLabelColor)
            label.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let tf = NSTextField(string: f.value)
            tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tf.widthAnchor.constraint(equalToConstant: 250).isActive = true
            row.addArrangedSubview(label)
            row.addArrangedSubview(tf)
            stack.addArrangedSubview(row)
            editors.append(tf)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 330,
                             height: CGFloat(fields.count) * 28)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = editors.first

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            onOK(editors.map { $0.stringValue })
        }
    }
}
