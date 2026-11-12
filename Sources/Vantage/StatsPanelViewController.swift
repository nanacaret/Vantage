// SPDX-License-Identifier: MIT
import AppKit

final class StatsPanelViewController: NSViewController {

    private let cpuChart = SparklineView()
    private let memChart = SparklineView()
    private let legend = UI.label("", size: 11, color: .secondaryLabelColor)
    private var valueLabels: [String: NSTextField] = [:]

    private let statKeys = [
        L("stats.processes"), L("stats.totalThreads"), L("stats.logicalPhysicalCpu"),
        L("stats.cpuUser"), L("stats.cpuSystem"), L("stats.cpuTotal"),
        L("stats.physicalMemory"), L("stats.usedMemory"), L("stats.freeMemory"), "Wired", L("stats.compressed"),
        L("stats.swapUsed"), L("stats.load"),
    ]

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container

        applyColors()
        cpuChart.title = L("stats.cpuUsage")
        memChart.title = L("stats.memoryUsed")
        memChart.maxValue = 100

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        UI.pin(stack, in: container, top: 0, left: 0, bottom: 0, right: 0)

        let header = UI.label(L("stats.systemOverview"), size: 13, weight: .semibold)
        add(stack, header)

        add(stack, cpuChart, height: 74)
        add(stack, legend, height: 16)
        add(stack, memChart, height: 48)

        let divider = NSBox(frame: .zero)
        divider.boxType = .separator
        add(stack, divider, height: 8)

        for key in statKeys {
            let k = UI.label(key, size: 11, color: .secondaryLabelColor)
            let v = UI.label("—", size: 11, alignment: .right,
                             monospaced: true)
            valueLabels[key] = v

            let row = NSStackView(views: [k, v])
            row.orientation = .horizontal
            row.spacing = 6
            k.widthAnchor.constraint(equalToConstant: 110).isActive = true
            add(stack, row, height: 16)
        }

        // 弹簧，把内容顶到上方
        let spring = NSView()
        add(stack, spring, height: 8)
        spring.heightAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(update),
            name: .procStoreDidUpdate, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(colorsChanged),
            name: .appColorsDidChange, object: nil)
        update()
    }

    private func applyColors() {
        let C = AppColors.shared
        cpuChart.primaryColor = C.color(.chartUser)
        cpuChart.secondaryColor = C.color(.chartSystem)
        memChart.primaryColor = C.color(.chartMemory)
        cpuChart.reload()
        memChart.reload()
    }

    @objc private func colorsChanged(_ n: Notification) {
        guard isViewLoaded else { return }
        applyColors()
    }

    private func add(_ stack: NSStackView, _ v: NSView, height: CGFloat? = nil) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                 constant: -20).isActive = true
        if let h = height {
            v.heightAnchor.constraint(equalToConstant: h).isActive = true
        }
    }

    private func set(_ key: String, _ value: String) {
        valueLabels[key]?.stringValue = value
    }

    @objc private func update() {
        let store = AppContext.shared.store
        let s = store.system

        cpuChart.primary = store.cpuUserHistory
        cpuChart.secondary = store.cpuSysHistory
        cpuChart.reload()

        memChart.primary = store.memHistory
        memChart.reload()

        let total = store.systemCPUUser + store.systemCPUSys
        legend.stringValue = String(
            format: L("stats.userFSystemFTotal"),
            store.systemCPUUser, store.systemCPUSys, total, s.logicalCPUs)

        set(L("stats.processes2"), "\(store.processes.count)")
        set(L("stats.totalThreads2"), Fmt.number(s.threadsTotal))
        set(L("stats.logicalPhysicalCpu2"), "\(s.logicalCPUs) / \(s.physicalCPUs)")
        set(L("stats.cpuUser2"), String(format: "%.1f %%", store.systemCPUUser))
        set(L("stats.cpuSystem2"), String(format: "%.1f %%", store.systemCPUSys))
        set(L("stats.cpuTotal2"), String(format: "%.1f %%", total))
        set(L("stats.physicalMemory2"), Fmt.bytes(s.memTotal))
        set(L("stats.usedMemory2"), Fmt.bytes(s.memUsed))
        set(L("stats.freeMemory2"), Fmt.bytes(s.memFree))
        set("Wired", Fmt.bytes(s.memWired))
        set(L("stats.compressed2"), Fmt.bytes(s.memCompressed))
        set(L("stats.swapUsed2"), s.swapTotal > 0
            ? "\(Fmt.bytes(s.swapUsed)) / \(Fmt.bytes(s.swapTotal))"
            : Fmt.bytes(s.swapUsed))
        set(L("stats.load2"),
            String(format: "%.2f / %.2f / %.2f", s.load1, s.load5, s.load15))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
