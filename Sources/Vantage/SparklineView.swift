// SPDX-License-Identifier: MIT
import AppKit

/// 轻量折线 / 面积图，用于底部系统统计（CPU 用户+系统堆叠、内存占用）
final class SparklineView: NSView {
    var primary: [Double] = []
    var secondary: [Double] = []      // 叠加在 primary 之上（CPU 系统态）
    var maxValue: Double = 100
    var primaryColor: NSColor = .systemBlue
    var secondaryColor: NSColor = .systemOrange
    var title: String = "" { didSet { needsDisplay = true } }

    func reload() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let r = bounds
        guard r.width > 4, r.height > 4 else { return }

        NSColor.controlBackgroundColor.setFill()
        r.fill()

        // 网格线
        let grid = NSColor.separatorColor.withAlphaComponent(0.55)
        grid.setStroke()
        for f in [0.25, 0.5, 0.75] as [CGFloat] {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: r.height * f))
            p.line(to: NSPoint(x: r.width, y: r.height * f))
            p.lineWidth = 0.5
            p.stroke()
        }

        // 系统态叠加层（先画在底层）
        if !secondary.isEmpty {
            let n = min(primary.count, secondary.count)
            let total = (0..<n).map { i in
                min(primary[i] + secondary[i], maxValue)
            }
            fill(total, with: secondaryColor.withAlphaComponent(0.45))
        }

        fill(primary, with: primaryColor.withAlphaComponent(0.5))
        stroke(primary, with: primaryColor)

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        if !title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            (title as NSString).draw(at: NSPoint(x: 6, y: r.height - 17),
                                     withAttributes: attrs)
        }
    }

    private func point(_ i: Int, _ v: Double, _ n: Int) -> NSPoint {
        let step = bounds.width / CGFloat(max(n - 1, 1))
        let f = CGFloat(min(max(v, 0), maxValue) / maxValue)
        return NSPoint(x: CGFloat(i) * step, y: f * bounds.height)
    }

    private func linePath(_ values: [Double]) -> NSBezierPath {
        let p = NSBezierPath()
        guard !values.isEmpty else { return p }
        for (i, v) in values.enumerated() {
            let pt = point(i, v, values.count)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        return p
    }

    private func fill(_ values: [Double], with color: NSColor) {
        guard !values.isEmpty else { return }
        let p = linePath(values)
        p.line(to: NSPoint(x: bounds.width, y: 0))
        p.line(to: NSPoint(x: 0, y: 0))
        p.close()
        color.setFill()
        p.fill()
    }

    private func stroke(_ values: [Double], with color: NSColor) {
        guard !values.isEmpty else { return }
        color.setStroke()
        let p = linePath(values)
        p.lineWidth = 1.5
        p.stroke()
    }
}
