// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 系统信息窗口（⌘⌥I）
//
// SIP 是整机属性，不属于某个进程，所以从检查器「权限」页搬到这里：
//   · 系统段：主机名 / 型号 / 芯片 / 内存 / macOS / 内核 / 运行时间
//   · SIP 段：活动配置位图逐项展开（文件系统保护、调试限制、task_for_pid）
//
// 表格直接复用 DetailTableViewController（过滤、列宽记忆、复制都现成）。
// ---------------------------------------------------------------------

final class SystemInfoWindowController: NSWindowController {

    static let shared = SystemInfoWindowController()

    private static let frameName = "VantageSystemInfoWindow"

    private let table = DetailTableViewController()
    private let refreshButton = NSButton(frame: .zero)
    private let hintLabel = UI.label("", size: 11, color: .secondaryLabelColor)

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = L("sysinfo.windowTitle")
        w.minSize = NSSize(width: 700, height: 400)
        w.center()
        w.setFrameAutosaveName(Self.frameName)
        super.init(window: w)

        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChanged),
            name: .languageDidChange, object: nil)
        reload()
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

        refreshButton.title = L("sysinfo.refresh")
        refreshButton.bezelStyle = .rounded
        refreshButton.font = NSFont.systemFont(ofSize: 12)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))

        hintLabel.stringValue = L("sysinfo.sipHint")
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow,
                                                          for: .horizontal)

        let bar = NSStackView(views: [refreshButton, hintLabel])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false

        table.storageKey = "Vantage.sysinfo"
        table.columnWeights = [100, 170, 240, 220, 130]
        let tableView = table.view
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(bar)
        root.addSubview(tableView)
        window.contentView = root
        window.setContentSize(NSSize(width: 980, height: 540))
        window.center()

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),

            tableView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    @objc private func refreshClicked(_ sender: Any?) { reload() }

    @objc private func languageChanged() {
        window?.title = L("sysinfo.windowTitle")
        refreshButton.title = L("sysinfo.refresh")
        hintLabel.stringValue = L("sysinfo.sipHint")
        table.reapplyFilter()
        reload()
    }

    // MARK: 数据

    private func reload() {
        var rows: [[String]] = []
        rows += systemRows()
        rows += PermissionReader.sipInformation().map {
            [$0.category, $0.name, $0.state, $0.detail, $0.source]
        }
        table.setRows(rows, headers: [L("perm.colCategory"),
                                      L("sysinfo.colItem"),
                                      L("sysinfo.colValue"),
                                      L("perm.colDetail"),
                                      L("perm.colSource")])
    }

    private func systemRows() -> [[String]] {
        let cat = L("sysinfo.catSystem")
        let pi = ProcessInfo.processInfo
        var rows: [[String]] = []

        func add(_ item: String, _ value: String, _ note: String,
                 _ source: String) {
            rows.append([cat, item, value, note, source])
        }

        add(L("sysinfo.hostName"), pi.hostName, "", "ProcessInfo")

        if let model = Self.sysctlString("hw.model") {
            add(L("sysinfo.model"), model, "hw.model", "sysctl")
        }
        if let chip = Self.sysctlString("machdep.cpu.brand_string") {
            add(L("sysinfo.chip"), chip, "machdep.cpu.brand_string", "sysctl")
        }
        if let mem = Self.sysctlUInt64("hw.memsize") {
            add(L("sysinfo.memory"), Fmt.bytes(mem), "hw.memsize", "sysctl")
        }

        add(L("sysinfo.osVersion"), pi.operatingSystemVersionString, "",
            "ProcessInfo")

        let release = Self.sysctlString("kern.osrelease") ?? "—"
        let build = Self.sysctlString("kern.osversion") ?? "—"
        add(L("sysinfo.kernel"), "Darwin \(release) (\(build))",
            "kern.osrelease / kern.osversion", "sysctl")

        add(L("sysinfo.uptime"), Self.uptime(pi.systemUptime), "",
            "ProcessInfo")

        return rows
    }

    private static func uptime(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        let d = t / 86400, h = (t % 86400) / 3600
        let m = (t % 3600) / 60, s = t % 60
        if d > 0 { return String(format: "%dd %02d:%02d:%02d", d, h, m, s) }
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
