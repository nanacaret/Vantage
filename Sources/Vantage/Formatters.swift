// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import Darwin

enum Fmt {
    static func bytes(_ v: UInt64) -> String {
        let d = Double(v)
        if d >= 1_099_511_627_776 { return String(format: "%.2f TB", d / 1_099_511_627_776) }
        if d >= 1_073_741_824     { return String(format: "%.2f GB", d / 1_073_741_824) }
        if d >= 1_048_576         { return String(format: "%.1f MB", d / 1_048_576) }
        if d >= 1024              { return String(format: "%.0f KB", d / 1024) }
        return "\(v) B"
    }

    static func percent(_ v: Double) -> String { String(format: "%.1f", max(0, v)) }

    static func number(_ v: UInt64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// 累积 CPU 时间 -> "1:23:45.67" / "12.34"
    static func cpuTime(_ ns: UInt64) -> String {
        let total = Double(ns) / 1_000_000_000.0
        let h = Int(total / 3600)
        let m = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        let s = total.truncatingRemainder(dividingBy: 60)
        if h > 0 { return String(format: "%d:%02d:%05.2f", h, m, s) }
        if m > 0 { return String(format: "%d:%05.2f", m, s) }
        return String(format: "%.2f", s)
    }

    static func startDate(_ p: ProcessSnapshot) -> String {
        guard p.startSec > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: Double(p.startSec) +
                     Double(p.startUSec) / 1_000_000.0)
        return startFormatter.string(from: d)
    }

    private static let startFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func flags(_ v: UInt32) -> String { String(format: "0x%08x", v) }
}

final class UserNameCache {
    static let shared = UserNameCache()
    private var cache: [Int32: String] = [:]
    private let lock = NSLock()

    func name(_ uid: Int32) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let s = cache[uid] { return s }
        var result = "\(uid)"
        if let pw = getpwuid(uid_t(bitPattern: uid)) {
            result = String(cString: pw.pointee.pw_name)
        }
        cache[uid] = result
        return result
    }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for proc: ProcessSnapshot, size: CGFloat = 16) -> NSImage {
        let key = (proc.bundlePath ?? proc.exepath) as NSString
        if key.length > 0, let cached = cache.object(forKey: key) { return cached }

        var img: NSImage
        if key.length > 0 {
            img = NSWorkspace.shared.icon(forFile: key as String)
        } else {
            img = IconCache.genericIcon()
        }
        img.size = NSSize(width: size, height: size)
        if key.length > 0 { cache.setObject(img, forKey: key) }
        return img
    }

    static func genericIcon() -> NSImage {
        let s = NSSize(width: 16, height: 16)
        let img = NSImage(size: s)
        img.lockFocus()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: s),
                     xRadius: 3, yRadius: 3).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 6, height: 6)).fill()
        img.unlockFocus()
        return img
    }
}

// ---------------------------------------------------------------------
// TSV 字段转义
//
// 详情表与主表的「行 → 文本」通道是「Tab 分列、换行分行」。文件名、argv /
// 环境变量、窗口标题里都可能出现 Tab 或换行（APFS 除 NUL 与 '/' 之外几乎
// 所有字节都合法），直接拼进去会让一行多切一列、复制出的表格断行。
//
// 口径与 C 层 `lb_addf` 的 `lb_escape_fields()` 完全一致：\t \n \r 用
// 两字符转义，其余 C0 控制字符与 DEL 用 \xNN。转义后不含控制字符，所以
// 重复调用是幂等的（不会把 "\t" 再转成 "\\t"）。
// ---------------------------------------------------------------------
enum TSV {
    /// 转义 token 的底色（中性灰，深浅色主题都自适应）
    static func tokenBackground() -> NSColor {
        // 中性灰而不是强调色：强调色底 + 正常文字很容易读成「文字被选中了」，
        // 灰色底 + 强调色文字则是「行内代码」的既有视觉语言，不会误会。
        // 0.16 在浅色主题下约等于 #E4E4E4，深色下是一层很淡的提亮，两边都看得见。
        NSColor.labelColor.withAlphaComponent(0.16)
    }

    /// 控制字符的显示字形：Unicode Control Pictures（与 VS Code 渲染控制字符同一套）。
    /// 0x00..0x1F → U+2400..U+241F，0x7F → U+2421。
    static func picture(_ c: UInt32) -> UnicodeScalar? {
        if c == 0x7f { return UnicodeScalar(0x2421) }
        if c < 0x20 { return UnicodeScalar(0x2400 + c) }
        return nil
    }

    /// 该码点是不是「控制字符字形」（用于渲染成 token、以及还原成真实字符）
    static func isPicture(_ v: UInt32) -> Bool {
        (v >= 0x2400 && v <= 0x241F) || v == 0x2421
    }

    /// 把含控制字符字形的文本渲染成「token 带底色」的富文本；
    /// 没有 token 时返回 nil（调用方退回纯文本，零开销）。
    ///
    /// 为什么需要：`␉` 夹在一长串路径里虽然比 `\t` 清楚，但仍然只是普通字符。
    /// 给 token 加一层底色，读起来才是「这里有一个不可见字符」。
    static func attributed(_ s: String, font: NSFont,
                           color: NSColor) -> NSAttributedString? {
        let u = Array(s.utf16)
        var tokens: [NSRange] = []
        for (i, ch) in u.enumerated() where isPicture(UInt32(ch)) {
            tokens.append(NSRange(location: i, length: 1))
        }
        guard !tokens.isEmpty else { return nil }

        let out = NSMutableAttributedString(
            string: s,
            attributes: [.font: font, .foregroundColor: color])
        let bg = tokenBackground()
        for r in tokens {
            out.addAttributes([
                .backgroundColor: bg,
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.monospacedSystemFont(ofSize: font.pointSize,
                                                   weight: .medium),
            ], range: r)
        }
        return out
    }

    static func field(_ s: String) -> String {
        let needs = s.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7f
        }
        guard needs else { return s }
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count + 8)
        for u in s.unicodeScalars {
            if let pic = picture(u.value) { out.unicodeScalars.append(pic) }
            else { out.unicodeScalars.append(u) }
        }
        return out
    }
}
