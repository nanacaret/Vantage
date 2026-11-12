// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics
import Foundation

// ---------------------------------------------------------------------
// 准星选取（SystemInformer "Find window's process" 风格）
//
// 进入后隐藏调用方窗口 → 鼠标移动时把最前面的普通窗口用蓝色边框高亮，
// 并在左上角浮层显示 owner 进程名 / PID → 单击选定 → 回调 ownerPID。
//
// 只依赖 CGWindowListCopyWindowInfo + AppKit 全局事件监听，不需要辅助功能
// 或屏幕录制授权（授权只影响能否显示窗口标题）。
// ---------------------------------------------------------------------

private final class PickerHighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let r = bounds.insetBy(dx: 2, dy: 2)
        guard r.width > 4, r.height > 4 else { return }
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        NSColor.systemBlue.withAlphaComponent(0.10).setFill()
        path.fill()
        path.lineWidth = 4
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}

final class WindowPicker: NSObject {

    static let shared = WindowPicker()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var overlay: NSWindow?
    private var badge: NSWindow?
    private var titleLabel: NSTextField?
    private var subLabel: NSTextField?
    private var hiddenWindows: [NSWindow] = []
    private var current: WindowInfo?
    private var onPick: ((Int32) -> Void)?
    private var onCancel: (() -> Void)?
    private var active = false

    var isActive: Bool { active }

    // -----------------------------------------------------------------
    // 进入 / 退出
    // -----------------------------------------------------------------

    /// - parameter hiding: 进入选取时临时隐藏的窗口（本 App 的窗口），
    ///   否则它们会挡住用户想选的目标窗口，结束时逐个恢复。
    func begin(hiding windows: [NSWindow],
               onPick: @escaping (Int32) -> Void,
               onCancel: (() -> Void)? = nil) {
        guard !active else { return }
        active = true
        self.onPick = onPick
        self.onCancel = onCancel

        hiddenWindows = windows.filter { $0.isVisible }
        for w in hiddenWindows { w.orderOut(nil) }

        // 高亮边框：完全透明、忽略鼠标事件、跨 Space 显示
        let ov = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        ov.isOpaque = false
        ov.backgroundColor = .clear
        ov.level = .floating
        ov.ignoresMouseEvents = true
        ov.hasShadow = false
        ov.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                 .fullScreenAuxiliary]
        ov.contentView = PickerHighlightView()
        ov.orderFrontRegardless()
        overlay = ov

        buildBadge()
        badge?.orderFrontRegardless()

        // 全局监听 = 其他 App 的窗口；local 监听 = 本 App 残留窗口 / Esc
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .keyDown]) { [weak self] e in
                self?.handleGlobal(e)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .keyDown]) { [weak self] e in
                self?.handleLocal(e)
                return e
        }

        update(at: WindowLocator.mouseCGPoint())
    }

    private func buildBadge() {
        let screen = NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let f = NSRect(x: screen.minX + 20, y: screen.maxY - 108,
                       width: 380, height: 88)
        let w = NSWindow(contentRect: f, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = NSColor.windowBackgroundColor
        w.level = .floating
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 10
        w.contentView?.layer?.masksToBounds = true

        let t = UI.label(L("window.moveThePointerOverThe"), size: 13, weight: .semibold)
        t.frame = NSRect(x: 14, y: 50, width: 258, height: 22)
        let s = UI.label(L("window.clickToPickEscTo"), size: 11,
                         color: .secondaryLabelColor)
        s.frame = NSRect(x: 14, y: 26, width: 258, height: 18)
        let cancel = UI.button(L("window.cancel2"), target: self,
                               action: #selector(cancelClicked))
        cancel.frame = NSRect(x: 288, y: 29, width: 78, height: 30)

        w.contentView?.addSubview(t)
        w.contentView?.addSubview(s)
        w.contentView?.addSubview(cancel)
        titleLabel = t
        subLabel = s
        badge = w
    }

    // -----------------------------------------------------------------
    // 事件
    // -----------------------------------------------------------------

    private func handleGlobal(_ e: NSEvent) {
        switch e.type {
        case .mouseMoved:
            update(at: WindowLocator.mouseCGPoint())
        case .leftMouseDown:
            commit()
        case .keyDown where e.keyCode == 53:   // Esc
            cancel()
        default:
            break
        }
    }

    private func handleLocal(_ e: NSEvent) {
        if e.type == .keyDown, e.keyCode == 53 {
            cancel()
        } else if e.type == .mouseMoved {
            update(at: WindowLocator.mouseCGPoint())
        }
    }

    private func update(at cg: CGPoint) {
        let w = WindowLocator.window(at: cg)
        current = w
        guard let w = w else {
            overlay?.orderOut(nil)
            titleLabel?.stringValue = L("window.moveThePointerOverThe2")
            subLabel?.stringValue = L("window.clickToPickEscTo2")
            return
        }
        overlay?.setFrame(WindowLocator.nsFrame(w.bounds), display: true)
        overlay?.orderFrontRegardless()
        titleLabel?.stringValue = w.ownerName.isEmpty
            ? "PID \(w.ownerPID)" : w.ownerName
        subLabel?.stringValue = "PID \(w.ownerPID) · \(w.displayTitle)"
    }

    private func commit() {
        guard active, let pid = current?.ownerPID, pid > 0 else { return }
        finish()
        let cb = onPick
        clearCallbacks()
        cb?(pid)
    }

    @objc private func cancelClicked() { cancel() }

    func cancel() {
        guard active else { return }
        finish()
        let cb = onCancel
        clearCallbacks()
        cb?()
    }

    private func finish() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil

        overlay?.orderOut(nil)
        overlay = nil
        badge?.orderOut(nil)
        badge = nil
        titleLabel = nil
        subLabel = nil

        for w in hiddenWindows { w.orderFrontRegardless() }
        hiddenWindows = []
        current = nil
        active = false
    }

    private func clearCallbacks() {
        onPick = nil
        onCancel = nil
    }
}
