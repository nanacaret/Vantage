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
