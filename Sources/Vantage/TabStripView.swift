// SPDX-License-Identifier: MIT
import AppKit

// ---------------------------------------------------------------------
// 页签条样式：检查器与偏好设置共用同一套（同一份偏好）
//   · auto   —— 按每个标题的实际文字宽度贪心折行，行内不拉伸，
//                每行个数可以不同，窄窗口自动多折一行
//   · fixed  —— 每行固定 N 个、等宽等分
//   · left   —— 标题竖排在左侧，超出高度时可滚动
// ---------------------------------------------------------------------

enum TabBarStyle: Int, CaseIterable {
    case auto = 0
    case fixed = 1
    case left = 2

    /// 横向排布时每行固定几个（0 = 自动折行）。left 模式下不使用。
    static func perRow(for style: TabBarStyle, fixed: Int) -> Int {
        style == .fixed ? max(2, fixed) : 0
    }
}

/// 顶部对齐的 clip view。
///
/// `NSClipView` 默认不翻转：文档比可视区**矮**时内容会贴底（纵向页签只有
/// 十来个条目时，整列会掉到面板最下面），比可视区高时滚动起点也不在顶部。
/// 翻过来以后坐标系原点在左上，两种情况都符合直觉。
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        if let doc = documentView, doc.frame.height <= bounds.height {
            r.origin.y = 0
        }
        return r
    }
}

/// 一条页签条。横向（多行 NSSegmentedControl）与纵向（左侧列表 + 滚动）两态，
/// 由容器在两种约束之间切换。
final class TabStripView: NSView {

    enum Mode: Equatable {
        /// perRow = 0 自动折行；> 0 每行固定个数
        case horizontal(perRow: Int)
        case vertical
    }

    var onSelect: ((Int) -> Void)?

    private(set) var selectedIndex = 0
    /// 纵向模式下的建议宽度（按最长标题实测；容器拿到后加约束）
    private(set) var columnWidth: CGFloat = 132

    private let rowStack = NSStackView()
    private let columnScroll = NSScrollView()
    private let columnStack = NSStackView()
    private var segments: [NSSegmentedControl] = []
    private var sideButtons: [SideTabButton] = []
    private var titles: [String] = []
    private var mode: Mode = .horizontal(perRow: 0)
    private var heightC: NSLayoutConstraint!
    private var packedWidth: CGFloat = -1
    private var isRebuilding = false

    private static let rowHeight: CGFloat = 22
    private static let rowSpacing: CGFloat = 4
    /// 段宽 = 文字宽 + 该常量（.small 分段控件的左右内边距与分隔线，
    /// 实测 ≈18.5，取 20 留一点余量避免末尾字母被切）
    private static let segmentPadding: CGFloat = 20
    private static let labelFont = NSFont.systemFont(ofSize: 11)

    // 纵向样式
    private static let sideItemHeight: CGFloat = 24
    private static let sideItemSpacing: CGFloat = 2
    private static let sideInset: CGFloat = 8
    private static let sideFont = NSFont.systemFont(ofSize: 12)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        rowStack.orientation = .vertical
        rowStack.spacing = Self.rowSpacing
        rowStack.alignment = .centerX
        rowStack.distribution = .fill
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)

        columnStack.orientation = .vertical
        columnStack.spacing = Self.sideItemSpacing
        columnStack.alignment = .leading
        columnStack.distribution = .fill
        columnStack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        columnStack.translatesAutoresizingMaskIntoConstraints = false

        columnScroll.hasVerticalScroller = true
        columnScroll.autohidesScrollers = true
        columnScroll.drawsBackground = false
        columnScroll.borderType = .noBorder
        columnScroll.contentView = FlippedClipView()
        columnScroll.documentView = columnStack
        columnScroll.isHidden = true
        columnScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columnScroll)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            columnScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            columnScroll.topAnchor.constraint(equalTo: topAnchor),
            columnScroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // documentView 只固定「上 / 左 / 宽」，高度由内容撑开，
            // 否则栈会被压成 clipView 高度、页签全叠在一起。
            columnStack.leadingAnchor.constraint(
                equalTo: columnScroll.contentView.leadingAnchor),
            columnStack.topAnchor.constraint(
                equalTo: columnScroll.contentView.topAnchor),
            columnStack.widthAnchor.constraint(
                equalTo: columnScroll.contentView.widthAnchor),
        ])

        heightC = heightAnchor.constraint(equalToConstant: Self.rowHeight)
        heightC.isActive = true
    }

    required init?(coder: NSCoder) { return nil }

    // -----------------------------------------------------------------
    // 配置 / 选中
    // -----------------------------------------------------------------

    func configure(titles: [String], mode: Mode) {
        self.titles = titles
        self.mode = mode
        packedWidth = -1

        switch mode {
        case .horizontal:
            columnScroll.isHidden = true
            rowStack.isHidden = false
            heightC.isActive = true
            // 首次 configure 时还没进窗口，bounds.width == 0。用 0 去折行会
            // 变成「一个页签一行」，窗口会被瞬间撑高（15 行）。给个接近
            // 实际窗口宽度的估值，真正的宽度在 layout() 里再校正。
            rebuildRows(available: bounds.width > 0 ? bounds.width : 620)
        case .vertical:
            rowStack.isHidden = true
            columnScroll.isHidden = false
            heightC.isActive = false
            columnWidth = Self.columnWidth(for: titles)
            rebuildColumns()
        }
        syncSelection()
    }

    func select(_ index: Int) {
        selectedIndex = index
        syncSelection()
    }

    // -----------------------------------------------------------------
    // 横向：多行分段控件
    // -----------------------------------------------------------------

    private func rebuildRows(available: CGFloat) {
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        for v in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        segments.removeAll()

        let perRow: Int
        if case .horizontal(let n) = mode { perRow = max(0, n) } else { perRow = 0 }

        // 固定模式每行等宽铺满（居中）；自动模式行宽随内容，左对齐
        rowStack.alignment = perRow > 0 ? .centerX : .leading

        for group in rowGroups(available: available, perRow: perRow) {
            guard let first = group.first else { continue }
            let seg = NSSegmentedControl(
                labels: group.map { titles[$0] },
                trackingMode: .selectOne,
                target: self,
                action: #selector(segmentClicked(_:)))
            seg.tag = first
            seg.controlSize = .small
            seg.font = Self.labelFont
            seg.translatesAutoresizingMaskIntoConstraints = false
            seg.heightAnchor.constraint(
                equalToConstant: Self.rowHeight).isActive = true
            seg.toolTip = group.compactMap { titles[safe: $0] }
                .joined(separator: " · ")

            if perRow > 0 {
                seg.segmentDistribution = .fillEqually
                seg.setContentHuggingPriority(.defaultLow, for: .horizontal)
                rowStack.addArrangedSubview(seg)
                seg.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
            } else {
                seg.segmentDistribution = .fill
                let limit = max(available, 80)
                for (i, idx) in group.enumerated() {
                    let w = min(Self.segmentWidth(for: titles[idx]), limit)
                    seg.setWidth(w, forSegment: i)
                }
                seg.setContentHuggingPriority(.required, for: .horizontal)
                seg.setContentCompressionResistancePriority(.required,
                                                            for: .horizontal)
                rowStack.addArrangedSubview(seg)
            }
            segments.append(seg)
        }

        let n = CGFloat(segments.count)
        heightC.constant = n * Self.rowHeight + max(0, n - 1) * Self.rowSpacing
        syncSelection()
    }

    private func rowGroups(available: CGFloat, perRow: Int) -> [[Int]] {
        guard !titles.isEmpty else { return [] }
        if perRow > 0 {
            var out: [[Int]] = []
            var start = 0
            while start < titles.count {
                let end = min(start + perRow, titles.count)
                out.append(Array(start..<end))
                start = end
            }
            return out
        }
        return Self.pack(titles: titles, available: max(available, 120))
    }

    /// 自动模式折行：先贪心算出最少要几行，再把总宽度尽量平均到各行，
    /// 避免出现「第一行塞满 + 第二行只有一个页签」的孤行。
    private static func pack(titles: [String], available: CGFloat) -> [[Int]] {
        let widths = titles.map { min(segmentWidth(for: $0), available) }
        let greedy = pack(widths: widths, limit: available)
        guard greedy.count > 1 else { return greedy }

        // 二分「单行宽度上限」：行数不变的前提下取最小的上限，
        // 各行宽度就趋于一致（页签仍按原顺序，个数可以不同）。
        var lo = widths.max() ?? 0
        var hi = available
        for _ in 0..<10 {
            let mid = (lo + hi) / 2
            if pack(widths: widths, limit: mid).count <= greedy.count {
                hi = mid
            } else {
                lo = mid
            }
        }
        return pack(widths: widths, limit: hi)
    }

    private static func pack(widths: [CGFloat], limit: CGFloat) -> [[Int]] {
        var out: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if !current.isEmpty, used + w + 1 > limit {
                out.append(current)
                current = []
                used = 0
            }
            current.append(i)
            used += w + 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func segmentWidth(for title: String) -> CGFloat {
        let w = (title as NSString).size(withAttributes: [.font: labelFont]).width
        return ceil(w) + segmentPadding
    }

    // -----------------------------------------------------------------
    // 纵向：左侧列表
    // -----------------------------------------------------------------

    private static func columnWidth(for titles: [String]) -> CGFloat {
        let w = titles.map {
            ceil(($0 as NSString).size(withAttributes: [.font: sideFont]).width)
        }.max() ?? 60
        // 左右各 sideInset 的内边距 + 滚动条余量
        return min(max(w + sideInset * 2 + 12, 96), 190)
    }

    private func rebuildColumns() {
        for v in columnStack.arrangedSubviews {
            columnStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        sideButtons.removeAll()

        for (i, title) in titles.enumerated() {
            let b = SideTabButton(title: title, font: Self.sideFont)
            b.tag = i
            b.target = self
            b.action = #selector(sideClicked(_:))
            b.toolTip = title
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(
                equalToConstant: Self.sideItemHeight).isActive = true
            columnStack.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: columnStack.widthAnchor,
                                     constant: -(Self.sideInset - 2) * 2).isActive = true
            sideButtons.append(b)
        }
        syncSelection()
    }

    @objc private func sideClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < titles.count else { return }
        selectedIndex = index
        syncSelection()
        onSelect?(index)
    }

    // -----------------------------------------------------------------
    // 共用
    // -----------------------------------------------------------------

    private func syncSelection() {
        for seg in segments {
            let offset = selectedIndex - seg.tag
            seg.selectedSegment = (offset >= 0 && offset < seg.segmentCount)
                ? offset : -1
        }
        for (i, b) in sideButtons.enumerated() {
            b.selectedTab = (i == selectedIndex)
        }
    }

    @objc private func segmentClicked(_ sender: NSSegmentedControl) {
        let index = sender.tag + sender.selectedSegment
        guard index >= 0, index < titles.count else { return }
        selectedIndex = index
        syncSelection()
        onSelect?(index)
    }

    /// 自动折行要在宽度变化时重排。重排会改约束，从而触发下一次 layout，
    /// 用 packedWidth 去重，避免「重建 → 布局 → 重建」的自激循环。
    override func layout() {
        super.layout()
        switch mode {
        case .horizontal(let perRow):
            guard perRow == 0, bounds.width > 0 else { return }
            guard abs(bounds.width - packedWidth) > 0.5 else { return }
            packedWidth = bounds.width
            rebuildRows(available: bounds.width)
        case .vertical:
            updateScroller()
        }
    }

    /// 条目装得下就彻底关掉滚动（连橡皮筋效果一起）：
    /// `hasVerticalScroller` + `autohidesScrollers` 只是把滚动条藏起来，
    /// 内容不足一屏时仍能拖动出回弹，手感像「能滚却什么都没有」。
    private func updateScroller() {
        let viewport = columnScroll.contentSize.height
        guard viewport > 0, !titles.isEmpty else { return }
        let content = CGFloat(titles.count) * Self.sideItemHeight
            + CGFloat(max(0, titles.count - 1)) * Self.sideItemSpacing
            + 4                       // columnStack 的上下 edgeInsets
        let fits = content <= viewport + 0.5
        // 竖向滚动条只影响宽度，不会改变 contentSize.height，所以这里
        // 不会出现「切换 → 高度变化 → 再切换」的振荡。
        if columnScroll.hasVerticalScroller == fits {
            columnScroll.hasVerticalScroller = !fits
            columnScroll.verticalScrollElasticity = fits ? .none : .automatic
        }
    }
}

// ---------------------------------------------------------------------
// 纵向页签的按钮：Finder 侧边栏那种「选中项浅色圆角底 + 左侧强调色」。
// 用无边框 NSButton + 自绘背景，保留原生点击 / 键盘可达性。
// ---------------------------------------------------------------------

final class SideTabButton: NSButton {

    var selectedTab = false {
        didSet {
            guard selectedTab != oldValue else { return }
            refreshTitle()
            needsDisplay = true
        }
    }

    private var hovering = false
    private var tracking: NSTrackingArea?
    private let baseFont: NSFont

    init(title: String, font: NSFont) {
        self.baseFont = font
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        alignment = .left
        setButtonType(.momentaryChange)
        focusRingType = .none
        refreshTitle()
    }

    required init?(coder: NSCoder) { return nil }

    private func refreshTitle() {
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byTruncatingTail
        // 文字从按钮左边缩进，自绘的选中底色才不会被文字贴边
        para.firstLineHeadIndent = 8
        para.headIndent = 8
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: selectedTab
                ? NSFont.systemFont(ofSize: baseFont.pointSize, weight: .medium)
                : baseFont,
            .foregroundColor: selectedTab ? NSColor.labelColor
                                          : NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        if selectedTab {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            path.fill()
        }
        if selectedTab {
            // 左侧 2pt 强调条：色觉之外还能靠位置分辨选中项
            let bar = NSRect(x: r.minX + 1, y: r.minY + 4,
                             width: 2, height: r.height - 8)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
        super.draw(dirtyRect)
    }
}
