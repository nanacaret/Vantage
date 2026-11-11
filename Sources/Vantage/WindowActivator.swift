// SPDX-License-Identifier: MIT
import AppKit
import ApplicationServices
import CoreGraphics
import CoreFoundation
import Darwin
import Foundation

// ---------------------------------------------------------------------
// 激活某个具体的窗口（把该窗口前置、取消最小化、设为焦点窗口）
//
// CGWindowListCopyWindowInfo 只给 CGWindowID（窗口号）和 ownerPID，
// 没有「激活」接口。要把某一个窗口（而不是整个 App 的任一窗口）抬到前面，
// 走 Accessibility：
//   AXUIElementCreateApplication(pid) → kAXWindowsAttribute
//   → 找到 windowID 对应的 AXUIElement → kAXRaiseAction + 设焦点/主窗口
//
// CGWindowID ↔ AXUIElement 的桥接用 _AXUIElementGetWindow（HIServices 私有
// SPI，很多窗口管理工具都用）。全部符号运行时 dlsym，不做链接期依赖；
// 拿不到时退回「按 bounds / 标题匹配」，再不行返回 windowNotFound。
//
// 权限：需要「辅助功能」（与窗口标题所需的「屏幕录制」是两项不同授权）。
// ---------------------------------------------------------------------

enum WindowActivationResult {
    case activated
    case needsAccessibility
    case windowNotFound
    case failed(String)
}

enum WindowActivator {

    // MARK: - 对外入口

    /// 激活并按需弹出提示；返回是否成功。
    @discardableResult
    static func activateAndReport(windowNumber: Int, ownerPID: Int32) -> Bool {
        switch activate(windowNumber: windowNumber, ownerPID: ownerPID) {
        case .activated:
            return true
        case .needsAccessibility:
            let a = NSAlert()
            a.alertStyle = .informational
            a.messageText = L("window.accessibilityPermissionRequired")
            a.informativeText =
                L("window.activatingAWindowRequiresAccessibility") +
                L("window.allowVantageInSystemSettings") +
                L("window.screenRecordingForWindowTitles")
            a.addButton(withTitle: L("window.openSystemSettings"))
            a.addButton(withTitle: L("window.cancel"))
            if a.runModal() == .alertFirstButtonReturn { openAccessibilitySettings() }
        case .windowNotFound:
            AppContext.shared.showError(
                L("window.noAccessibleAxWindowFor", windowNumber) +
                L("window.theWindowMayBeClosed"))
        case .failed(let msg):
            AppContext.shared.showError(msg)
        }
        return false
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func openAccessibilitySettings() {
        guard let u = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: - 激活实现

    static func activate(windowNumber: Int, ownerPID: Int32) -> WindowActivationResult {
        guard ownerPID > 0, windowNumber > 0 else {
            return .failed(L("window.invalidWindowNumberOrProcess"))
        }
        guard AXIsProcessTrusted() else { return .needsAccessibility }

        let appEl = AXUIElementCreateApplication(pid_t(ownerPID))
        var cfWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &cfWindows)
                == .success else {
            return .failed(L("window.cannotReadTheWindowList", ownerPID))
        }
        let windows = axArray(cfWindows)
        guard !windows.isEmpty else { return .windowNotFound }

        var target: AXUIElement?
        if let getID = getWindowID {
            for w in windows {
                var wid: UInt32 = 0
                if getID(w, &wid) == .success, Int(wid) == windowNumber {
                    target = w
                    break
                }
            }
        }
        if target == nil {
            // 私有 SPI 不可用时的兜底：按位置 + 尺寸（+ 标题，若已授权）匹配
            target = matchByFrame(windows, number: windowNumber)
        }
        guard let win = target else { return .windowNotFound }

        // 最小化的窗口先还原，否则 raise 无效
        var cfMin: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &cfMin) == .success,
           let v = cfMin, CFGetTypeID(v) == CFBooleanGetTypeID(),
           CFBooleanGetValue(unsafeBitCast(v, to: CFBoolean.self)) {
            _ = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString,
                                             kCFBooleanFalse as CFTypeRef)
        }

        // 先把 App 前置（空 options = 普通激活，避开 deprecated 的 ignoringOtherApps）
        NSRunningApplication(processIdentifier: ownerPID)?
            .activate(options: [])
        _ = AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString,
                                         kCFBooleanTrue as CFTypeRef)

        // 再把「这一个」窗口抬到最前并设为焦点 / 主窗口
        _ = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString,
                                         kCFBooleanTrue as CFTypeRef)
        _ = AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString,
                                         win as CFTypeRef)
        return .activated
    }

    // MARK: - CGWindowID ↔ AXUIElement

    private typealias GetWindowIDFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    /// _AXUIElementGetWindow 是私有 SPI，运行时解析；拿不到就走 frame 兜底。
    private static let getWindowID: GetWindowIDFn? = {
        let paths = [
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        ]
        for p in paths {
            if let h = dlopen(p, RTLD_LAZY),
               let s = dlsym(h, "_AXUIElementGetWindow") {
                return unsafeBitCast(s, to: GetWindowIDFn.self)
            }
        }
        // RTLD_DEFAULT 在 dlfcn.h 里是 ((void *)-2) 宏，Swift 不导入这类
        // 负指针常量；用位模式构造等价句柄（Apple DTS / Swift 标准做法）。
        if let h = UnsafeMutableRawPointer(bitPattern: -2),
           let s = dlsym(h, "_AXUIElementGetWindow") {
            return unsafeBitCast(s, to: GetWindowIDFn.self)
        }
        return nil
    }()

    private static func axArray(_ cf: CFTypeRef?) -> [AXUIElement] {
        guard let cf = cf else { return [] }
        // 先试 Swift 桥接；若得到空数组还要继续走 CFArray 逐项取，
        // 因为不同 SDK 下 CFArray → [AXUIElement] 的桥接行为不一致。
        if let a = cf as? [AXUIElement], !a.isEmpty { return a }
        // macOS 26 SDK 把 CF 类型导入成 Swift class，CFTypeRef(=AnyObject)
        // `as? CFArray` 会被判定为「一定成功」而报错。改用 CFGetTypeID
        // 显式校验类型 ID，再 unsafeBitCast（两者都是指针大小，安全）。
        guard CFGetTypeID(cf) == CFArrayGetTypeID() else { return [] }
        let arr = unsafeBitCast(cf, to: CFArray.self)
        let n = CFArrayGetCount(arr)
        var out: [AXUIElement] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let p = CFArrayGetValueAtIndex(arr, i) else { continue }
            out.append(Unmanaged<AXUIElement>.fromOpaque(p).takeUnretainedValue())
        }
        return out
    }

    /// 按 bounds 匹配。CG bounds 与 AX position/size 都是「主屏左上原点、y 向下」
    /// 的全局坐标；容差 3pt 兼容多显示器缩放与边框差异。
    private static func matchByFrame(_ windows: [AXUIElement],
                                     number: Int) -> AXUIElement? {
        guard let info = WindowLocator.windowInfo(number: number) else { return nil }
        let want = info.bounds
        var best: (el: AXUIElement, score: CGFloat)?

        for w in windows {
            guard let (p, s) = axFrame(w) else { continue }
            let d = abs(p.x - want.minX) + abs(p.y - want.minY)
                + abs(s.width - want.width) + abs(s.height - want.height)
            guard d < 6 else { continue }

            var score = d
            // 有标题时同标题加分（没有屏幕录制授权就跳过这一步）
            if !info.title.isEmpty {
                var cfTitle: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &cfTitle)
                    == .success, let t = cfTitle as? String {
                    score += (t == info.title) ? -2 : 8
                }
            }
            if best == nil || score < best!.score { best = (w, score) }
        }
        return best?.el
    }

    private static func axFrame(_ w: AXUIElement) -> (CGPoint, CGSize)? {
        var cfP: CFTypeRef?, cfS: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &cfP) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &cfS) == .success,
              let pRef = cfP, let sRef = cfS,
              CFGetTypeID(pRef) == AXValueGetTypeID(),
              CFGetTypeID(sRef) == AXValueGetTypeID() else { return nil }
        let vp = unsafeBitCast(pRef, to: AXValue.self)
        let vs = unsafeBitCast(sRef, to: AXValue.self)
        var p = CGPoint.zero, s = CGSize.zero
        let okP = withUnsafeMutablePointer(to: &p) {
            AXValueGetValue(vp, .cgPoint, UnsafeMutableRawPointer($0))
        }
        let okS = withUnsafeMutablePointer(to: &s) {
            AXValueGetValue(vs, .cgSize, UnsafeMutableRawPointer($0))
        }
        guard okP, okS else { return nil }
        return (p, s)
    }
}
