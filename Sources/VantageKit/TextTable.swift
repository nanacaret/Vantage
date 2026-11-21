// SPDX-License-Identifier: MIT
import Foundation

// ---------------------------------------------------------------------
// 终端排版：等宽列对齐 + 常用的人类可读格式
//
// 中文/emoji 在终端里占两格，按 `count` 补空格会错位，所以宽度按
// East Asian Width 的常用区间近似计算（够用即可，不做完整 Unicode 表）。
// ---------------------------------------------------------------------

public enum TextTable {

    /// 终端显示宽度：CJK / 全角 / emoji 记 2，其余记 1
    public static func width(_ s: String) -> Int {
        var w = 0
        for u in s.unicodeScalars {
            let v = u.value
            if v == 0x200B || v == 0xFEFF { continue }          // 零宽
            if (0x0300...0x036F).contains(v) { continue }        // 组合符号
            if isWide(v) { w += 2 } else { w += 1 }
        }
        return w
    }

    private static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F,       // Hangul Jamo
             0x2E80...0x303E,       // CJK 部首 / 标点
             0x3041...0x33FF,       // 假名 / 注音 / CJK 兼容
             0x3400...0x4DBF,       // CJK 扩展 A
             0x4E00...0x9FFF,       // CJK 基本区
             0xA000...0xA4CF,       // 彝文
             0xAC00...0xD7A3,       // Hangul 音节
             0xF900...0xFAFF,       // CJK 兼容表意
             0xFE30...0xFE4F,       // CJK 兼容形式
             0xFF00...0xFF60,       // 全角 ASCII
             0xFFE0...0xFFE6,       // 全角符号
             0x1F300...0x1FAFF,     // emoji
             0x20000...0x3FFFD:     // CJK 扩展 B+
            return true
        default:
            return false
        }
    }

    public static func pad(_ s: String, _ n: Int, right: Bool = false) -> String {
        let w = width(s)
        guard w < n else { return s }
        let fill = String(repeating: " ", count: n - w)
        return right ? fill + s : s + fill
    }

    /// 按显示宽度截断，超出时补 `…`
    public static func clip(_ s: String, _ n: Int) -> String {
        guard n > 1, width(s) > n else { return s }
        var out = ""
        var w = 0
        for ch in s {
            let cw = width(String(ch))
            if w + cw > n - 1 { break }
            out.append(ch)
            w += cw
        }
        return out + "…"
    }

    /// 渲染等宽表：首行表头，随后数据行；空字符串表示该列不设表头。
    /// `lastColumnMax` 用于限制最后一列（命令行 / 路径）的宽度，避免刷屏。
    public static func render(headers: [String],
                              rows: [[String]],
                              lastColumnMax: Int? = nil) -> String {
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        guard cols > 0 else { return "" }

        var cells: [[String]] = rows.map { r in
            (0..<cols).map { $0 < r.count ? r[$0] : "" }
        }
        if let cap = lastColumnMax, cols > 0 {
            cells = cells.map { r in
                var r = r
                r[cols - 1] = clip(r[cols - 1], cap)
                return r
            }
        }
        let head = (0..<cols).map { $0 < headers.count ? headers[$0] : "" }

        let widths = (0..<cols).map { i in
            max(width(head[i]), cells.map { width($0[i]) }.max() ?? 0)
        }
        // 数值列右对齐：表头以数字结尾或整列都是数字时（PID / 大小 / 线程数）
        let numeric = (0..<cols).map { i in
            !head[i].isEmpty && cells.allSatisfy {
                $0[i].isEmpty || $0[i].allSatisfy { $0.isNumber || $0 == "-" || $0 == "." }
                    || $0[i].hasSuffix("%")
            }
        }

        func line(_ r: [String]) -> String {
            (0..<cols).map { i in
                pad(r[i], widths[i], right: numeric[i])
            }.joined(separator: "  ").replacingOccurrences(of: "\\s+$",
                                                           with: "",
                                                           options: .regularExpression)
        }

        var out = head.contains(where: { !$0.isEmpty }) ? line(head) + "\n" : ""
        // 表头分隔线：纯 ASCII 时给一条，方便看清列界
        if head.contains(where: { !$0.isEmpty }) {
            out += (0..<cols).map { String(repeating: "-", count: widths[$0]) }
                .joined(separator: "  ") + "\n"
        }
        for r in cells { out += line(r) + "\n" }
        return out
    }
}

// MARK: - 人类可读格式

public enum Human {

    public static func bytes(_ v: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var x = Double(v)
        var i = 0
        while x >= 1024, i < units.count - 1 { x /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", x, units[i])
    }

    public static func duration(_ ns: UInt64) -> String {
        let total = Double(ns) / 1e9
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    public static func date(_ epoch: UInt64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
