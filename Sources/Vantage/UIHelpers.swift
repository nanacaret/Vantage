// SPDX-License-Identifier: MIT
import AppKit

/// 安全下标：设备树 / 扩展列表等窗口按索引取数组时用，避免越界 trap。
extension Array {
    subscript(safe i: Int) -> Element? {
        (i >= 0 && i < count) ? self[i] : nil
    }
}

// ---------------------------------------------------------------------
// 窗口 frame 校正（internal，供主窗口 / 全局搜索 / 设备树 / 扩展列表共用）
//
// 屏幕配置变化或 UserDefaults 里存了异常 frame 时，窗口会整个跑到屏幕外：
// isVisible 仍为 true，但用户看不到。这里按当前窗口自己的尺寸重新居中，
// 不再写死某个窗口的 autosave 名 —— 之前那段是 fileprivate，新窗口调用
// 会直接编译报 'inaccessible due to fileprivate protection level'。
// ---------------------------------------------------------------------
extension NSWindow {
    /// `autosaveName` 由调用方传自己的常量字符串，不读 frameAutosaveName 属性
    /// （该属性在不同 SDK 是 Optional / 非 Optional 的 String 别名，读它会踩坑）。
    func ensureVisibleOnScreens(autosaveName: String = "") {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        var best: CGFloat = 0
        for s in screens {
            let i = frame.intersection(s.visibleFrame)
            if !i.isNull && !i.isEmpty { best = max(best, i.width * i.height) }
        }
        if best < 200 * 120 {
            let size = frame.size
            setFrame(NSRect(x: 0, y: 0,
                            width: max(size.width, 720),
                            height: max(size.height, 420)), display: false)
            center()
            if !autosaveName.isEmpty {
                UserDefaults.standard.removeObject(
                    forKey: "NSWindow Frame \(autosaveName)")
            }
        }
    }
}

enum UI {
    static func label(_ text: String,
                      size: CGFloat = 12,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor,
                      alignment: NSTextAlignment = .left,
                      monospaced: Bool = false) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        tf.textColor = color
        tf.alignment = alignment
        tf.lineBreakMode = .byTruncatingTail
        tf.isSelectable = false
        return tf
    }

    static func button(_ title: String, target: Any?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.font = NSFont.systemFont(ofSize: 12)
        return b
    }

    /// 把子视图用 Auto Layout 铺满父视图
    static func pin(_ sub: NSView, in parent: NSView,
                    top: CGFloat = 8, left: CGFloat = 10,
                    bottom: CGFloat = 8, right: CGFloat = 10) {
        sub.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(sub)
        NSLayoutConstraint.activate([
            sub.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: left),
            sub.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -right),
            sub.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
            sub.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -bottom),
        ])
    }
}
