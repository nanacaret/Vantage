// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import Darwin

// ---------------------------------------------------------------------
// 迷你环形仪表
// ---------------------------------------------------------------------

private final class MiniGaugeView: NSView {
    var fraction: Double = 0          // 0...1
    var tint: NSColor = .systemBlue
    var invalid: Bool = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let r = bounds.insetBy(dx: 2, dy: 2)
        let c = NSPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2 - 3
        guard radius > 3 else { return }

        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 90,
                        endAngle: 450, clockwise: false)
        track.lineWidth = 5
        (invalid ? NSColor.tertiaryLabelColor : tint.withAlphaComponent(0.18)).setStroke()
        track.stroke()

        if invalid {
            // 「读不到」画一段虚线，而不是空环或满环
            let dash = NSBezierPath()
            dash.appendArc(withCenter: c, radius: radius, startAngle: 90,
                           endAngle: 450, clockwise: false)
            dash.lineWidth = 5
            let pattern: [CGFloat] = [2, 6]
            dash.setLineDash(pattern, count: pattern.count, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            dash.stroke()
            return
        }

        let f = min(max(fraction, 0), 1)
        guard f > 0.001 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: radius, startAngle: 90,
                      endAngle: 90 - 360 * CGFloat(f), clockwise: true)
        arc.lineWidth = 5
        arc.lineCapStyle = .round
        tint.setStroke()
        arc.stroke()
    }
}

// ---------------------------------------------------------------------
// 指标卡片
// ---------------------------------------------------------------------

private final class MetricCardView: NSView {

    private let titleLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let valueLabel = UI.label("—", size: 26, weight: .semibold)
    private let unitLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let detailLabel = UI.label("", size: 10, color: .tertiaryLabelColor)
    private let badgeLabel = UI.label("", size: 11, weight: .semibold)
    private let gauge = MiniGaugeView(frame: .zero)
    private let spark = SparklineView(frame: .zero)

    var tint: NSColor = .systemBlue {
        didSet { gauge.tint = tint; spark.primaryColor = tint }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        valueLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 2

        gauge.translatesAutoresizingMaskIntoConstraints = false
        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.title = ""
        spark.maxValue = 1

        badgeLabel.alignment = .right
        for v in [titleLabel, valueLabel, unitLabel, detailLabel, badgeLabel,
                  gauge, spark] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            unitLabel.firstBaselineAnchor.constraint(equalTo: valueLabel.firstBaselineAnchor),
            unitLabel.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 5),

            gauge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            gauge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            gauge.widthAnchor.constraint(equalToConstant: 32),
            gauge.heightAnchor.constraint(equalToConstant: 32),

            badgeLabel.topAnchor.constraint(equalTo: gauge.bottomAnchor, constant: 1),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: valueLabel.trailingAnchor,
                                                constant: 4),

            spark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            spark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -76),
            spark.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 4),
            spark.heightAnchor.constraint(equalToConstant: 22),

            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    func update(title: String, value: String, unit: String, detail: String,
                badge: String = "", badgeColor: NSColor = .systemGreen,
                fraction: Double?, valid: Bool,
                sparkValues: [Double], sparkMax: Double) {
        titleLabel.stringValue = title
        valueLabel.stringValue = valid ? value : "—"
        valueLabel.textColor = valid ? .labelColor : .tertiaryLabelColor
        unitLabel.stringValue = valid ? unit : ""
        detailLabel.stringValue = detail
        badgeLabel.stringValue = badge
        badgeLabel.textColor = badgeColor
        gauge.invalid = !valid
        gauge.fraction = fraction ?? 0
        gauge.needsDisplay = true

        spark.primary = sparkValues
        spark.secondary = []
        spark.maxValue = max(sparkMax, 0.0001)
        spark.reload()
    }
}

// ---------------------------------------------------------------------
// 多序列曲线（自动纵轴缩放）
// ---------------------------------------------------------------------

struct PerfSeries {
    let name: String
    let color: NSColor
    let values: [Double]
}

private final class PerfChartView: NSView {
    var title: String = "" { didSet { needsDisplay = true } }
    var unit: String = "" { didSet { needsDisplay = true } }
    var series: [PerfSeries] = [] { didSet { needsDisplay = true } }

    func reload() { needsDisplay = true }

    private func niceMax(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let exp = floor(log10(v))
        let base = pow(10, exp)
        let n = v / base
        let step: Double = n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10
        return step * base
    }

    private func fmt(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.1fG", v / 1e9) }
        if v >= 1_000_000     { return String(format: "%.1fM", v / 1e6) }
        if v >= 1_000         { return String(format: "%.1fk", v / 1e3) }
        if v >= 10            { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let r = bounds
        guard r.width > 20, r.height > 20 else { return }

        NSColor.controlBackgroundColor.setFill()
        r.fill()

        let padTop: CGFloat = 22
        let padBottom: CGFloat = 16
        let plot = NSRect(x: 4, y: padBottom, width: r.width - 8,
                          height: r.height - padTop - padBottom)
        guard plot.height > 4 else { return }

        var peak = 0.0
        for s in series { for v in s.values { if v.isFinite && v > peak { peak = v } } }
        let maxY = niceMax(peak * 1.15)

        // 网格 + 纵轴刻度
        let grid = NSColor.separatorColor.withAlphaComponent(0.5)
        for f in [0.0, 0.25, 0.5, 0.75, 1.0] as [CGFloat] {
            let y = plot.minY + plot.height * f
            grid.setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: plot.minX, y: y))
            p.line(to: NSPoint(x: plot.maxX, y: y))
            p.lineWidth = 0.5
            p.stroke()
        }
        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        (fmt(maxY) as NSString).draw(at: NSPoint(x: plot.minX + 3,
                                                  y: plot.maxY - 11),
                                     withAttributes: axisAttrs)
        ("0" as NSString).draw(at: NSPoint(x: plot.minX + 3, y: plot.minY + 2),
                               withAttributes: axisAttrs)

        // 每条序列
        for s in series {
            let vals = s.values
            guard !vals.isEmpty else { continue }
            let n = vals.count
            let step = plot.width / CGFloat(max(n - 1, 1))
            let point = { (i: Int, v: Double) -> NSPoint in
                let f = CGFloat(min(max(v.isFinite ? v : 0, 0), maxY) / maxY)
                return NSPoint(x: plot.minX + CGFloat(i) * step,
                               y: plot.minY + f * plot.height)
            }
            let path = NSBezierPath()
            for i in 0..<n {
                let p = point(i, vals[i])
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }

            let fill = path.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: plot.maxX, y: plot.minY))
            fill.line(to: NSPoint(x: plot.minX, y: plot.minY))
            fill.close()
            s.color.withAlphaComponent(0.16).setFill()
            fill.fill()

            s.color.setStroke()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.stroke()
        }

        // 边框
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 0.5
        border.stroke()

        // 标题 + 图例（名称 + 当前值）
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        (title as NSString).draw(at: NSPoint(x: 7, y: r.height - 16),
                                 withAttributes: titleAttrs)

        var x: CGFloat = 7 + (title as NSString).size(withAttributes: titleAttrs).width + 12
        for s in series {
            let cur = s.values.last ?? 0
            // 频率图不能套 k 缩写：fmt(3962)="4.0k" 再拼 "MHz" 会变成 "4.0kMHz"，
            // 既冗余又容易被读成 GHz。MHz 一律显示整数，与卡片/副标题口径一致。
            let valueText = unit == "MHz" ? String(format: "%.0f", cur) : fmt(cur)
            let text = "\(s.name) \(valueText)\(unit)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: s.color,
            ]
            let w = (text as NSString).size(withAttributes: attrs).width
            if x + w > r.width - 6 { break }
            (text as NSString).draw(at: NSPoint(x: x, y: r.height - 16),
                                    withAttributes: attrs)
            x += w + 10
        }
    }
}

// ---------------------------------------------------------------------
// 小信息块（标题 + 数值）
// ---------------------------------------------------------------------

private final class KeyValView: NSView {
    private let k = UI.label("", size: 9, color: .tertiaryLabelColor)
    private let v = UI.label("—", size: 12, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        v.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for x in [k, v] { x.translatesAutoresizingMaskIntoConstraints = false; addSubview(x) }
        NSLayoutConstraint.activate([
            k.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            k.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            k.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            v.topAnchor.constraint(equalTo: k.bottomAnchor, constant: 1),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ key: String, _ value: String) {
        k.stringValue = key
        v.stringValue = value
        v.textColor = (value == "—") ? .tertiaryLabelColor : .labelColor
    }
}

// ---------------------------------------------------------------------
// 性能窗口
// ---------------------------------------------------------------------

final class PerformanceWindowController: NSWindowController, RowTextCopying {

    static let shared = PerformanceWindowController()

    private let titleLabel = UI.label(L("perf.performanceMonitor"), size: 15, weight: .semibold)
    private let subLabel = UI.label(L("perf.initializingSampler"), size: 10,
                                    color: .secondaryLabelColor)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pauseButton = NSButton(frame: .zero)

    private var cards: [MetricCardView] = []
    private var charts: [PerfChartView] = []
    private var infos: [KeyValView] = []
    private let statusText = NSTextView(frame: .zero)
    private var observer: NSObjectProtocol?
    private var paused = false

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 840),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("perf.performanceMonitor2")
        w.minSize = NSSize(width: 900, height: 680)
        w.isReleasedWhenClosed = false
        w.center()
        super.init(window: w)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // ---------------------------------------------------------------
    // 布局
    // ---------------------------------------------------------------

    /// 逐个套用可能出现的标题，取 intrinsic 宽度的最大值。
    /// NSButton / NSPopUpButton 的默认度量已包含 bezel 内边距与下拉箭头，
    /// 比按字数估算或写死常量可靠；本地化文案变化也不会再截断。
    private static func fittedButtonWidth(for button: NSButton,
                                          titles: [String],
                                          minimum: CGFloat) -> CGFloat {
        let original = button.title
        var w = minimum
        for t in titles {
            button.title = t
            let m = button.intrinsicContentSize.width
            if m > 0 && m != NSView.noIntrinsicMetric { w = max(w, ceil(m)) }
        }
        button.title = original
        return w
    }

    private static func fittedPopupWidth(_ popup: NSPopUpButton,
                                         minimum: CGFloat) -> CGFloat {
        let original = popup.indexOfSelectedItem
        let originalTarget = popup.target
        popup.target = nil            // 程序化切换不应触发 intervalChanged
        var w = minimum
        for i in 0..<popup.numberOfItems {
            popup.selectItem(at: i)
            let m = popup.intrinsicContentSize.width
            if m > 0 && m != NSView.noIntrinsicMetric { w = max(w, ceil(m)) }
        }
        if original >= 0 && original < popup.numberOfItems {
            popup.selectItem(at: original)
        }
        popup.target = originalTarget
        return w
    }

    private func buildUI() {
        guard let window = window else { return }
        let rootVC = NSViewController()
        rootVC.view = NSView()
        window.contentViewController = rootVC
        let content = rootVC.view

        // 顶部
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(subLabel)

        intervalPopup.addItems(withTitles: [L("perf.sampleS"), L("perf.sampleS2"),
                                            L("perf.sampleS3"), L("perf.sampleS4")])
        let perfValues = [500, 1000, 2000, 5000]
        intervalPopup.selectItem(at:
            perfValues.firstIndex(of: Preferences.shared.perfIntervalMs) ?? 1)
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged(_:))
        intervalPopup.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(intervalPopup)

        pauseButton.title = L("perf.pauseRefresh")
        pauseButton.bezelStyle = .rounded
        pauseButton.font = NSFont.systemFont(ofSize: 12)
        pauseButton.target = self
        pauseButton.action = #selector(pauseToggled(_:))
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(pauseButton)

        // 宽度按「所有可能显示的标题」里最宽的一个测量，不能写死 88pt ——
        // 那会把 "Pause Refresh" / "Resume Refresh" 截成 "Pause Refr..."。
        // greaterThanOrEqualTo + 高 hugging：两态标题宽度一致、窗口变宽也不被拉伸。
        let pauseWidth = Self.fittedButtonWidth(
            for: pauseButton,
            titles: [L("perf.pauseRefresh"), L("perf.pauseRefresh2"),
                     L("perf.resumeRefresh")],
            minimum: 116)
        let popupWidth = Self.fittedPopupWidth(intervalPopup, minimum: 132)
        for v in [intervalPopup, pauseButton] {
            v.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            v.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            header.heightAnchor.constraint(equalToConstant: 42),

            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: intervalPopup.leadingAnchor,
                                                 constant: -8),
            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: intervalPopup.leadingAnchor,
                                               constant: -8),

            intervalPopup.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            intervalPopup.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor,
                                                    constant: -8),
            intervalPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: popupWidth),
            pauseButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pauseButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            pauseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: pauseWidth),
        ])

        // 卡片 3×2
        let cardsBox = NSView()
        cardsBox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cardsBox)
        let cardGrid = grid(rows: 2, cols: 3, spacing: 8)
        UI.pin(cardGrid, in: cardsBox, top: 0, left: 0, bottom: 0, right: 0)
        for _ in 0..<6 {
            let c = MetricCardView(frame: .zero)
            c.translatesAutoresizingMaskIntoConstraints = false
            cards.append(c)
        }
        fillGrid(cardGrid, views: cards, rows: 2, cols: 3)

        // 曲线 2×3
        let chartsBox = NSView()
        chartsBox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(chartsBox)
        let chartGrid = grid(rows: 3, cols: 2, spacing: 8)
        UI.pin(chartGrid, in: chartsBox, top: 0, left: 0, bottom: 0, right: 0)
        for _ in 0..<6 {
            let c = PerfChartView(frame: .zero)
            c.translatesAutoresizingMaskIntoConstraints = false
            c.wantsLayer = true
            c.layer?.cornerRadius = 6
            charts.append(c)
        }
        fillGrid(chartGrid, views: charts, rows: 3, cols: 2)

        // 数值条
        let infoStrip = NSStackView()
        infoStrip.orientation = .horizontal
        infoStrip.distribution = .fillEqually
        infoStrip.spacing = 6
        infoStrip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(infoStrip)
        let keys = [L("perf.diskRead"), L("perf.diskWrite"), L("perf.networkDown"), L("perf.networkUp"),
                    L("perf.memoryUsed"), "Swap", L("perf.thermalPressure"), L("perf.tempCpuGpu")]
        for k in keys {
            let kv = KeyValView(frame: .zero)
            kv.translatesAutoresizingMaskIntoConstraints = false
            kv.wantsLayer = true
            kv.layer?.cornerRadius = 5
            kv.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            infoStrip.addArrangedSubview(kv)
            infos.append(kv)
            kv.set(k, "—")
        }

        // 状态说明
        let statusScroll = NSScrollView(frame: .zero)
        statusScroll.translatesAutoresizingMaskIntoConstraints = false
        statusScroll.hasVerticalScroller = true
        statusScroll.borderType = .noBorder
        statusScroll.drawsBackground = false
        statusText.isEditable = false
        statusText.isSelectable = true
        statusText.isRichText = false
        statusText.isVerticallyResizable = true
        statusText.isHorizontallyResizable = false
        statusText.autoresizingMask = [.width]
        statusText.textContainer?.widthTracksTextView = true
        statusText.font = NSFont.systemFont(ofSize: 10)
        statusText.textColor = .secondaryLabelColor
        statusText.textContainerInset = NSSize(width: 6, height: 4)
        statusScroll.documentView = statusText
        content.addSubview(statusScroll)

        NSLayoutConstraint.activate([
            cardsBox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            cardsBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            cardsBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            cardsBox.heightAnchor.constraint(equalToConstant: 228),

            chartsBox.topAnchor.constraint(equalTo: cardsBox.bottomAnchor, constant: 10),
            chartsBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            chartsBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            chartsBox.bottomAnchor.constraint(equalTo: infoStrip.topAnchor, constant: -10),

            infoStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            infoStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            infoStrip.bottomAnchor.constraint(equalTo: statusScroll.topAnchor, constant: -8),
            infoStrip.heightAnchor.constraint(equalToConstant: 42),

            statusScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            statusScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            statusScroll.heightAnchor.constraint(equalToConstant: 116),
        ])

        configureTitles()

        observer = NotificationCenter.default.addObserver(
            forName: .perfDidUpdate, object: nil, queue: .main) { [weak self] _ in
                self?.render()
        }
        render()
    }

    private func grid(rows: Int, cols: Int, spacing: CGFloat) -> NSStackView {
        let g = NSStackView()
        g.orientation = .vertical
        g.distribution = .fillEqually
        g.spacing = spacing
        g.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = spacing
            row.translatesAutoresizingMaskIntoConstraints = false
            g.addArrangedSubview(row)
        }
        return g
    }

    private func fillGrid(_ g: NSStackView, views: [NSView], rows: Int, cols: Int) {
        var i = 0
        for r in 0..<rows {
            guard let row = g.arrangedSubviews[r] as? NSStackView else { continue }
            for _ in 0..<cols where i < views.count {
                row.addArrangedSubview(views[i])
                i += 1
            }
        }
    }

    private func configureTitles() {
        let tints: [NSColor] = [.systemOrange, .systemPurple, .systemTeal,
                                .systemGreen, .systemRed, .systemBlue]
        for (i, c) in cards.enumerated() { c.tint = tints[i % tints.count] }

        let chartTitles = [L("perf.cpuGpuAneDramPower"),
                           L("perf.cpuUsageClusters"),
                           L("perf.cpuGpuActiveResidency"),
                           L("perf.perClusterFrequencyMHz"),
                           L("perf.diskThroughputMbS"),
                           L("perf.networkThroughputMbS")]
        for (i, c) in charts.enumerated() {
            c.title = chartTitles[i]
            c.unit = i == 0 ? "W" : (i == 1 || i == 2) ? "%" :
                     i == 3 ? "MHz" : "MB/s"
        }
    }

    // ---------------------------------------------------------------
    // 辅助
    // ---------------------------------------------------------------

    private func avg(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        return v.reduce(0, +) / Double(v.count)
    }

    private func peak(_ v: [Double]) -> Double { v.max() ?? 0 }

    private func pct(_ r: Double) -> String { String(format: "%.0f", r * 100) }

    /// macmon 顶栏风格的 "E-CPU 13% @ 1863 MHz · S-CPU 15% @ 3699 MHz"
    private func tierLine(_ s: PerfSnapshot) -> String {
        var parts: [String] = []
        if s.has(.tiers) {
            let freqText: (Double) -> String = { $0 > 0 ? "\(Int($0)) MHz" : "— MHz" }
            if s.eFreqMHz > 0 || s.eActiveRatio > 0 {
                parts.append("E-CPU \(pct(s.eActiveRatio))% @ \(freqText(s.eFreqMHz))")
            }
            if s.mFreqMHz > 0 || s.mActiveRatio > 0 {
                parts.append("S-CPU \(pct(s.mActiveRatio))% @ \(freqText(s.mFreqMHz))")
            }
            if s.pFreqMHz > 0 || s.pActiveRatio > 0 {
                parts.append("P-CPU \(pct(s.pActiveRatio))% @ \(freqText(s.pFreqMHz))")
            }
            if s.gpuFreqMHz > 0 {
                parts.append("GPU \(pct(s.gpuActiveRatio))% @ \(freqText(s.gpuFreqMHz))")
            }
        }
        if parts.isEmpty {
            if s.has(.freq) && s.cpuFreqMHz > 0 {
                parts.append(L("perf.cpuAvgMHz", Int(s.cpuFreqMHz)))
            } else {
                parts.append(L("perf.iOReportPStateResidencyUnavailable"))
            }
        }
        let cap = dvfsDetail(s)
        if !cap.isEmpty && cap != L("perf.dvfsTableUnavailable") { parts.append(cap) }
        return parts.joined(separator: " · ")
    }

    private func powerSourceName(_ s: PerfSnapshot) -> String {
        switch s.powerSource {
        case PerfPowerSource.clpc: return "CLPC Stats"
        case PerfPowerSource.energyModel: return "Energy Model"
        default: return L("perf.noIOReportEnergyChannels")
        }
    }

    private func tempSourceName(_ s: PerfSnapshot) -> String {
        switch s.tempSource {
        case PerfTempSource.smc: return "AppleSMC"
        case PerfTempSource.hid: return L("perf.iohidCoreSensors")
        case PerfTempSource.pmu: return L("perf.iohidPmuNotCoreHotspots")
        default: return L("perf.unavailable")
        }
    }

    /// 动态诊断：把「为什么某项是 —」直接摆在界面上，不靠猜
    private func dynamicDiagnostics(_ s: PerfSnapshot) -> String {
        let p = [
            L("perf.matchedEnergyChannelsPState", s.matchedEnergyChannels, s.matchedStateChannels),
            L("perf.powerSourceTempSource", powerSourceName(s), tempSourceName(s)),
            L("perf.cpuTierTiersDvfsTable", s.tierCount, freqSteps(s.eFreqMaxMHz), freqSteps(s.pFreqMaxMHz), freqSteps(s.mFreqMaxMHz), freqSteps(s.gpuFreqMaxMHz)),
        ]
        return p.joined(separator: "\n")
    }

    private func freqSteps(_ maxMHz: UInt32) -> String {
        maxMHz > 0 ? "≤\(maxMHz)MHz" : "—"
    }

    // ---------------------------------------------------------------
    // 渲染
    // ---------------------------------------------------------------

    private func render() {
        if paused { return }
        let store = PerformanceStore.shared
        guard let s = store.latest else {
            subLabel.stringValue = L("perf.waitingForFirstSample")
            statusText.string = L("perf.performanceSamplingHasNotStarted")
            return
        }
        let h = store.history

        titleLabel.stringValue = L("perf.performance", s.socName)
        subLabel.stringValue = subTitle(s)
        let diag = PerfDiagnostics.text
        // C 层状态 / 诊断文本带 \x1eL:key\x1fzh\x1fen\x1e 标记，按当前语言取一份。
        let raw = s.status + "\n" + dynamicDiagnostics(s) +
            (diag.isEmpty ? "" : L("perf.perChannelDiagnosticsForVerifying") + diag)
        statusText.string = L10n.resolveCText(raw)

        // ---- 6 张卡片 ----
        let powerValid = s.has(.power)
        let freqValid = s.has(.freq)
        let tempValid = s.has(.temp)
        let sysValid = s.has(.sysPower)
        let coresValid = s.has(.cores)
        let diskValid = s.has(.disk)
        let netValid = s.has(.net)
        let resValid = s.has(.residency)
        let tierValid = s.has(.tiers)

        let cpuHist = h.map { $0.cpuPowerW }
        let gpuHist = h.map { $0.gpuPowerW }
        let aneHist = h.map { $0.anePowerW }
        let dramHist = h.map { $0.dramPowerW }
        let sysHist = h.map { $0.sysPowerW }

        cards[0].update(
            title: L("perf.cpuPower"),
            value: PerfFmt.watts(s.cpuPowerW), unit: "W",
            detail: L("perf.avgPeakW", PerfFmt.watts(avg(cpuHist), digits: 1), PerfFmt.watts(peak(cpuHist), digits: 1), powerSourceName(s)),
            badge: tempValid && s.cpuTempC > 0 ? "\(PerfFmt.temp(s.cpuTempC))°C" : "",
            badgeColor: .systemOrange,
            fraction: s.cpuPowerW / 40.0, valid: powerValid,
            sparkValues: cpuHist, sparkMax: max(peak(cpuHist), 1))

        cards[1].update(
            title: L("perf.gpuPower"),
            value: PerfFmt.watts(s.gpuPowerW), unit: "W",
            detail: L("perf.inclGpuSramAvgPeak", PerfFmt.watts(avg(gpuHist), digits: 1), PerfFmt.watts(peak(gpuHist), digits: 1)),
            badge: tempValid && s.gpuTempC > 0 ? "\(PerfFmt.temp(s.gpuTempC))°C" : "",
            badgeColor: .systemPurple,
            fraction: s.gpuPowerW / 40.0, valid: powerValid,
            sparkValues: gpuHist, sparkMax: max(peak(gpuHist), 1))

        let aneDram = h.map { $0.anePowerW + $0.dramPowerW }
        cards[2].update(
            title: "ANE / DRAM",
            value: PerfFmt.watts(s.anePowerW + s.dramPowerW), unit: "W",
            detail: L("perf.aneDramAvgPeak", PerfFmt.watts(s.anePowerW, digits: 2), PerfFmt.watts(s.dramPowerW, digits: 2), PerfFmt.watts(avg(aneHist) + avg(dramHist), digits: 1), PerfFmt.watts(peak(aneDram), digits: 1)),
            fraction: (s.anePowerW + s.dramPowerW) / 20.0, valid: powerValid,
            sparkValues: aneDram, sparkMax: max(peak(aneDram), 1))

        cards[3].update(
            title: L("perf.totalSystemPowerSmcPstr"),
            value: PerfFmt.watts(s.sysPowerW, digits: 1), unit: "W",
            detail: L("perf.avgPeakSoCBreakdownW", PerfFmt.watts(avg(sysHist), digits: 1), PerfFmt.watts(peak(sysHist), digits: 1), PerfFmt.watts(s.socPowerW, digits: 1)),
            fraction: s.sysPowerW / 120.0, valid: sysValid,
            sparkValues: sysHist, sparkMax: max(peak(sysHist), 1))

        // CPU 分簇：把 macmon 的 "E-CPU 13% @ 1863 MHz / S-CPU 15% @ 3699 MHz"
        // 收进一张卡片，主数值给最高簇实时频率。
        let topFreq = max(s.eFreqMHz, s.pFreqMHz, s.mFreqMHz, s.cpuFreqMHz)
        cards[4].update(
            title: L("perf.perClusterCpuFrequency"),
            value: tierValid && topFreq > 0 ? "\(Int(topFreq))" : (freqValid && s.cpuFreqMHz > 0 ? "\(Int(s.cpuFreqMHz))" : "—"),
            unit: "MHz",
            detail: tierLine(s),
            badge: resValid ? "CPU \(Int(s.cpuActiveRatio * 100))%" : "",
            badgeColor: .systemRed,
            fraction: topFreq / Double(max(s.pFreqMaxMHz, 1000)),
            valid: tierValid || freqValid,
            sparkValues: h.map { max($0.eFreqMHz, $0.pFreqMHz, $0.mFreqMHz, $0.cpuFreqMHz) },
            sparkMax: Double(max(s.pFreqMaxMHz, 1000)))

        // RAM / SWAP 百分比（macmon 顶栏的 "RAM 83% · SWAP 80%"）
        let memPct = s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) * 100 : 0
        let swapPct = s.swapTotal > 0 ? Double(s.swapUsed) / Double(s.swapTotal) * 100 : 0
        cards[5].update(
            title: "RAM / SWAP",
            value: s.has(.mem) ? String(format: "%.0f", memPct) : "—", unit: "%",
            detail: "\(PerfFmt.bytes(s.memUsed)) / \(PerfFmt.bytes(s.memTotal)) · SWAP \(String(format: "%.0f", swapPct))% (\(PerfFmt.bytes(s.swapUsed)))",
            badge: s.has(.mem) ? "SWAP \(String(format: "%.0f", swapPct))%" : "",
            badgeColor: swapPct >= 70 ? .systemRed : .systemTeal,
            fraction: memPct / 100.0, valid: s.has(.mem),
            sparkValues: h.map { $0.memTotal > 0 ? Double($0.memUsed) / Double($0.memTotal) * 100 : 0 },
            sparkMax: 100)

        // ---- 6 张曲线 ----
        let mb = 1_000_000.0
        charts[0].series = powerValid ? [
            PerfSeries(name: "CPU", color: .systemOrange, values: cpuHist),
            PerfSeries(name: "GPU", color: .systemPurple, values: gpuHist),
            PerfSeries(name: "ANE", color: .systemTeal,   values: aneHist),
            PerfSeries(name: "DRAM", color: .systemPink,  values: dramHist),
        ] : []

        var cpuSeries = [
            PerfSeries(name: L("perf.total"), color: .systemBlue,
                       values: h.map { $0.cpuTotalPct }),
        ]
        if coresValid {
            cpuSeries.append(PerfSeries(name: L("perf.pCluster"), color: .systemRed,
                                        values: h.map { $0.pCorePct }))
            cpuSeries.append(PerfSeries(name: L("perf.eCluster"), color: .systemGreen,
                                        values: h.map { $0.eCorePct }))
        }
        if tierValid {
            cpuSeries.append(PerfSeries(name: "P", color: .systemOrange,
                                        values: h.map { $0.pActiveRatio * 100 }))
            cpuSeries.append(PerfSeries(name: "E", color: .systemMint,
                                        values: h.map { $0.eActiveRatio * 100 }))
            if s.mFreqMHz > 0 || s.mActiveRatio > 0 {
                cpuSeries.append(PerfSeries(name: "S", color: .systemPurple,
                                            values: h.map { $0.mActiveRatio * 100 }))
            }
        }
        charts[1].series = cpuSeries

        charts[2].series = resValid ? [
            PerfSeries(name: "CPU", color: .systemOrange,
                       values: h.map { $0.cpuActiveRatio * 100 }),
            PerfSeries(name: "GPU", color: .systemPurple,
                       values: h.map { $0.gpuActiveRatio * 100 }),
        ] : []

        var freqSeries: [PerfSeries] = []
        if tierValid {
            freqSeries.append(PerfSeries(name: "E", color: .systemGreen,
                                         values: h.map { $0.eFreqMHz }))
            freqSeries.append(PerfSeries(name: "P", color: .systemOrange,
                                         values: h.map { $0.pFreqMHz }))
            if s.mFreqMHz > 0 || s.mActiveRatio > 0 {
                freqSeries.append(PerfSeries(name: "S", color: .systemPurple,
                                             values: h.map { $0.mFreqMHz }))
            }
        } else if freqValid {
            freqSeries.append(PerfSeries(name: "CPU", color: .systemOrange,
                                         values: h.map { $0.cpuFreqMHz }))
        }
        if freqValid && s.gpuFreqMHz > 0 {
            freqSeries.append(PerfSeries(name: "GPU", color: .systemTeal,
                                         values: h.map { $0.gpuFreqMHz }))
        }
        charts[3].series = freqSeries

        charts[4].series = diskValid ? [
            PerfSeries(name: L("perf.read"), color: .systemGreen,
                       values: h.map { $0.diskReadBPS / mb }),
            PerfSeries(name: L("perf.write"), color: .systemOrange,
                       values: h.map { $0.diskWriteBPS / mb }),
        ] : []
        charts[5].series = netValid ? [
            PerfSeries(name: L("perf.download"), color: .systemBlue,
                       values: h.map { $0.netRxBPS / mb }),
            PerfSeries(name: L("perf.upload"), color: .systemTeal,
                       values: h.map { $0.netTxBPS / mb }),
        ] : []
        for c in charts { c.reload() }

        // ---- 数值条 ----
        let vals = [
            s.has(.disk) ? PerfFmt.rate(s.diskReadBPS) : "—",
            s.has(.disk) ? PerfFmt.rate(s.diskWriteBPS) : "—",
            s.has(.net)  ? PerfFmt.rate(s.netRxBPS) : "—",
            s.has(.net)  ? PerfFmt.rate(s.netTxBPS) : "—",
            s.has(.mem) && s.memTotal > 0
                ? "\(String(format: "%.0f", memPct))% · \(PerfFmt.bytes(s.memUsed))/\(PerfFmt.bytes(s.memTotal))" : "—",
            s.has(.mem)
                ? "\(String(format: "%.0f", swapPct))% · \(PerfFmt.bytes(s.swapUsed))" : "—",
            s.has(.thermal) ? PerfFmt.pressure(s.thermalPressure) : "—",
            tempValid ? "CPU \(PerfFmt.temp(s.cpuTempC))°C / GPU \(s.gpuTempC > 0 ? PerfFmt.temp(s.gpuTempC) : "—")°C" : "—",
        ]
        for (i, kv) in infos.enumerated() {
            let key = [L("perf.diskRead2"), L("perf.diskWrite2"), L("perf.networkDown2"), L("perf.networkUp2"),
                       L("perf.memoryUsed2"), "Swap", L("perf.thermalPressure2"), L("perf.tempCpuGpu2")][i]
            kv.set(key, vals[i])
        }
    }

    private func subTitle(_ s: PerfSnapshot) -> String {
        var parts: [String] = []
        if s.nperflevels >= 2 {
            parts.append(L("perf.pE", s.pCores, s.eCores))
        } else {
            parts.append(L("perf.logicalCores", ProcessInfo.processInfo.processorCount))
        }
        if s.gpuCores > 0 { parts.append(L("perf.gpu", s.gpuCores)) }
        if s.has(.tiers) {
            // 不要写 "CPU 3962 MHz"：那是最高簇（P）的值，E 簇此时只有 1345，
            // 会被误读成整颗 CPU 都跑在 3.96 GHz。明确标出 E / P 各自频率。
            var t: [String] = []
            if s.eFreqMHz > 0 { t.append("E \(Int(s.eFreqMHz))") }
            if s.pFreqMHz > 0 { t.append("P \(Int(s.pFreqMHz))") }
            if !t.isEmpty {
                parts.append(L("perf.clusterFreq", t.joined(separator: " / "), s.tierCount))
            }
        } else if s.has(.freq) && s.cpuFreqMHz > 0 {
            parts.append("CPU \(Int(s.cpuFreqMHz)) MHz")
        }
        if s.has(.power) { parts.append("SoC \(PerfFmt.watts(s.socPowerW, digits: 1)) W") }
        if s.has(.temp) && s.cpuTempC > 0 {
            parts.append("CPU \(PerfFmt.temp(s.cpuTempC))°C (\(tempSourceName(s)))")
        }
        if s.has(.thermal) { parts.append(PerfFmt.pressure(s.thermalPressure)) }
        parts.append(L("perf.samples", PerformanceStore.shared.history.count))
        return parts.joined(separator: "  ·  ")
    }

    private func dvfsDetail(_ s: PerfSnapshot) -> String {
        guard s.has(.dvfs) else { return L("perf.dvfsTableUnavailable2") }
        var p: [String] = []
        if s.pFreqMaxMHz > 0 { p.append("P≤\(s.pFreqMaxMHz)MHz") }
        if s.eFreqMaxMHz > 0 { p.append("E≤\(s.eFreqMaxMHz)MHz") }
        if s.gpuFreqMaxMHz > 0 { p.append("GPU≤\(s.gpuFreqMaxMHz)MHz") }
        return p.isEmpty ? L("perf.pmgrExposesNoFrequencyTable") : p.joined(separator: " · ")
    }

    // ---------------------------------------------------------------
    // 动作
    // ---------------------------------------------------------------

    override func showWindow(_ sender: Any?) {
        PerformanceStore.shared.start()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        AppActivate.front()
        render()
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        let ms: [UInt32] = [500, 1000, 2000, 5000]
        let idx = max(0, min(sender.indexOfSelectedItem, ms.count - 1))
        PerformanceStore.shared.setInterval(ms[idx])
        Preferences.shared.perfIntervalMs = Int(ms[idx])
        Preferences.shared.applyToRuntime()
    }

    /// ⌘C 且第一响应者不是诊断文本框时，复制整段状态/逐通道诊断文本。
    /// 文本框内选中文字时由 Clipboard.copy 第 1 步交给系统 copy: 处理。
    func copySelectedRowsToPasteboard() -> Bool {
        let s = statusText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        Clipboard.setString(s)
        return true
    }

    @objc private func pauseToggled(_ sender: NSButton) {
        paused.toggle()
        sender.title = paused ? L("perf.resumeRefresh") : L("perf.pauseRefresh2")
        if !paused { render() }
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }
}
