// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics
import CoreFoundation
import Foundation

// ---------------------------------------------------------------------
// 通过窗口定位进程（参考 Windows SystemInformer 的 "Find window's process"）
//
// 数据源是 CGWindowListCopyWindowInfo：数组顺序即 z-order（前 → 后），
// 每项带 kCGWindowOwnerPID / kCGWindowOwnerName / kCGWindowBounds /
// kCGWindowLayer / kCGWindowNumber。
//
// 权限要点：kCGWindowName（窗口标题）在 macOS 10.15+ 需要「屏幕录制」授权，
// 但 **ownerPID / bounds / layer 不需要任何授权**——所以即使未授权，
// 准星选取与 PID 定位仍然完全可用，只是标题显示为空。
// ---------------------------------------------------------------------

struct WindowInfo {
    let number: Int
    let ownerPID: Int32
    let ownerName: String
    let title: String
    let layer: Int
    let bounds: CGRect          // CG 全局坐标：原点在主屏左上角，y 向下

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !ownerName.isEmpty { return L("window.titleNeedsScreenRecordingPermission", ownerName) }
        return L("window.window2", number)
    }
    var boundsText: String {
        String(format: "%.0f, %.0f · %.0f×%.0f",
               bounds.minX, bounds.minY, bounds.width, bounds.height)
    }
}

enum WindowLocator {

    private static var cache: [WindowInfo] = []
    private static var cacheAt: TimeInterval = 0
    private static let cacheLock = NSLock()

    /// 枚举窗口字典。CGWindowListCopyWindowInfo 返回 CFArray<CFDictionary>，
    /// 不同 SDK 下 Swift 桥接行为略有差异，两种取法都保留。
    /// 纯 CG API，可在后台串行队列调用（详情页惰性采集会用到）。
    private static func fetch(_ options: CGWindowListOption) -> [[String: Any]] {
        guard let cf = CGWindowListCopyWindowInfo(options, kCGNullWindowID) else {
            return []
        }
        if let bridged = cf as? [[String: Any]] { return bridged }

        var dicts: [[String: Any]] = []
        dicts.reserveCapacity(CFArrayGetCount(cf))
        for i in 0..<CFArrayGetCount(cf) {
            guard let p = CFArrayGetValueAtIndex(cf, i) else { continue }
            let obj = Unmanaged<NSDictionary>.fromOpaque(p)
                .takeUnretainedValue()
            if let d = obj as? [String: Any] { dicts.append(d) }
        }
        return dicts
    }

    /// 鼠标移动时会被高频调用，缓存 0.4 秒避免每次都枚举全部窗口。
    /// 窗口列表窗口 / 准星开始时用 force=true 拿最新快照。
    static func onScreenWindows(force: Bool = false) -> [WindowInfo] {
        let now = Date().timeIntervalSince1970
        cacheLock.lock()
        if !force, !cache.isEmpty, now - cacheAt < 0.4 {
            let hit = cache
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let dicts = fetch([.optionOnScreenOnly, .excludeDesktopElements])
        let result: [WindowInfo] = dicts.compactMap(makeInfo)
        cacheLock.lock()
        cache = result
        cacheAt = now
        cacheLock.unlock()
        return result
    }

    /// 从一条 CGWindow 字典构造 WindowInfo；纯数据转换，可后台调用。
    private static func makeInfo(_ d: [String: Any]) -> WindowInfo? {
        guard let pid = intValue(d, kCGWindowOwnerPID as String), pid > 0,
              let num = intValue(d, kCGWindowNumber as String) else { return nil }
        return WindowInfo(
            number: num,
            ownerPID: Int32(pid),
            ownerName: stringValue(d, kCGWindowOwnerName as String),
            title: stringValue(d, kCGWindowName as String),
            layer: intValue(d, kCGWindowLayer as String) ?? 0,
            bounds: boundsValue(d))
    }

    /// 按 CGWindowID 查窗口信息（`.optionAll`，含最小化 / 隐藏窗口）。
    /// 供 WindowActivator 在私有 SPI 不可用时按 bounds / 标题兜底匹配 AX 窗口。
    static func windowInfo(number: Int) -> WindowInfo? {
        for d in fetch([.optionAll]) {
            if intValue(d, kCGWindowNumber as String) == number,
               let w = makeInfo(d) { return w }
        }
        return nil
    }

    /// 详情页「窗口」Tab 的数据源：列出某个 PID 拥有的**全部**窗口
    /// （`.optionAll`，包含最小化 / 其他 Space / 隐藏的），并标注是否在屏幕上。
    ///
    /// 返回 `\t` 分隔行，第一行为表头，供 DetailTableViewController.parse 使用。
    /// 不读 onScreenWindows 的缓存（准星在主线程高频刷新它），也不调用
    /// CGPreflightScreenCaptureAccess / 任何 AppKit 主线程 API，因此可以
    /// 安全地跑在 DetailLoadQueue 后台队列里。
    static func detailLines(for pid: Int32) -> [String] {
        let cols = [L("window.windowId2"), L("window.title"), L("window.layer2"), L("window.positionSize2"),
                    L("window.screenState"), L("window.sharingAlpha")]
        var lines: [String] = [cols.joined(separator: "\t")]

        // 屏幕上的窗口号集合：kCGWindowIsOnscreen 字段在部分系统版本缺失，
        // 用一次 onScreenOnly 枚举做交叉验证更可靠。
        var onScreenNumbers = Set<Int>()
        for d in fetch([.optionOnScreenOnly, .excludeDesktopElements]) {
            if let n = intValue(d, kCGWindowNumber as String) {
                onScreenNumbers.insert(n)
            }
        }

        let dicts = fetch([.optionAll]).filter {
            intValue($0, kCGWindowOwnerPID as String) == Int(pid) && pid > 0
        }

        if dicts.isEmpty {
            lines.append(["—", L("window.thisProcessHasNoEnumerable"),
                          "—", "—", "—", "—"].joined(separator: "\t"))
        } else {
            for (z, d) in dicts.enumerated() {
                let num = intValue(d, kCGWindowNumber as String) ?? 0
                let title = stringValue(d, kCGWindowName as String)
                let owner = stringValue(d, kCGWindowOwnerName as String)
                let ownerSuffix = owner.isEmpty ? "" : " · " + owner
                let shownTitle = title.isEmpty
                    ? L("window.titleNeedsPermission", ownerSuffix)
                    : title
                let layer = intValue(d, kCGWindowLayer as String) ?? 0
                let b = boundsValue(d)
                let bText = String(format: "%.0f, %.0f · %.0f×%.0f",
                                   b.minX, b.minY, b.width, b.height)

                let fieldOn = (d["kCGWindowIsOnscreen"] as? NSNumber)?.boolValue
                let visible = fieldOn ?? onScreenNumbers.contains(num)
                let state = visible ? L("window.onScreenZOrder", z + 1)
                                   : L("window.offScreenMinimizedAnotherSpace")

                let sharing = intValue(d, "kCGWindowSharingState") ?? -1
                let shareText: String
                switch sharing {
                case 0:  shareText = L("window.notShared")
                case 1:  shareText = L("window.readOnly")
                case 2:  shareText = L("window.readWrite")
                default: shareText = L("window.unknown")
                }
                let alpha = doubleValue(d, "kCGWindowAlpha")
                let alphaText = alpha.map { String(format: "%.2f", $0) } ?? "—"

                lines.append([
                    "\(num)", shownTitle, "\(layer)", bText, state,
                    "\(shareText) / \(alphaText)",
                ].joined(separator: "\t"))
            }
        }

        // 摘要行：Owner PID 单独成行，双击数值格可定位到本进程（单实例激活）
        lines.append(["Owner PID", "\(pid)", "", "", "", ""]
            .joined(separator: "\t"))
        lines.append([L("window.hint"),
                      L("window.orderedAsReturnedByCGWindowList"),
                      "", "", "", ""].joined(separator: "\t"))
        lines.append([L("window.action"),
                      L("window.doubleClickAWindowRow"),
                      "", "", "", ""].joined(separator: "\t"))
        return lines
    }

    /// 返回覆盖该点的最前面的普通窗口（layer 0）。
    /// 数组已经是 z-order 前→后，第一个命中即可。
    static func window(at cgPoint: CGPoint) -> WindowInfo? {
        for w in onScreenWindows() where w.layer == 0 {
            if w.bounds.contains(cgPoint) { return w }
        }
        return nil
    }

    /// NSEvent.mouseLocation 是 NS 全局坐标（主屏左下原点，y 向上）；
    /// CG 窗口坐标原点在主屏左上角（y 向下）。
    static func mouseCGPoint() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }

    /// CG bounds → NSWindow frame
    static func nsFrame(_ b: CGRect) -> NSRect {
        NSRect(x: b.minX, y: mainDisplayHeight - b.maxY,
               width: max(1, b.width), height: max(1, b.height))
    }

    private static var mainDisplayHeight: CGFloat {
        CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
    }

    // -----------------------------------------------------------------
    // 屏幕录制授权（只影响窗口标题，不影响 PID 定位）
    // -----------------------------------------------------------------

    static var hasScreenCaptureAccess: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()
        cacheLock.lock()
        cacheAt = 0
        cacheLock.unlock()
    }

    // -----------------------------------------------------------------
    // CFDictionary 取值（CFNumber / CFString 在不同 SDK 桥接行为不同）
    // -----------------------------------------------------------------

    private static func intValue(_ d: [String: Any], _ key: String) -> Int? {
        if let n = d[key] as? NSNumber { return n.intValue }
        if let n = d[key] as? Int { return n }
        return nil
    }

    private static func doubleValue(_ d: [String: Any], _ key: String) -> Double? {
        if let n = d[key] as? NSNumber { return n.doubleValue }
        if let n = d[key] as? Double { return n }
        return nil
    }

    private static func stringValue(_ d: [String: Any], _ key: String) -> String {
        (d[key] as? String) ?? ""
    }

    private static func boundsValue(_ d: [String: Any]) -> CGRect {
        guard let b = d[kCGWindowBounds as String] as? [String: Any] else {
            return .zero
        }
        func n(_ k: String) -> CGFloat {
            if let v = b[k] as? NSNumber { return CGFloat(v.doubleValue) }
            if let v = b[k] as? Double { return CGFloat(v) }
            return 0
        }
        return CGRect(x: n("X"), y: n("Y"),
                      width: n("Width"), height: n("Height"))
    }
}
