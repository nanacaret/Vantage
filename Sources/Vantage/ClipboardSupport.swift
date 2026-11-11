// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 统一的 ⌘C 分发
//
// 背景：主菜单「编辑」原来只有「复制 PID」「复制完整命令行」两个自定义项，
// 且都没有 keyEquivalent。AppKit 的 ⌘C 不会凭空发给第一响应者 —— 它必须由
// 主菜单里一个带 "c" + .command 的 NSMenuItem 触发 NSApplication.sendAction。
// 缺了这一项，NSTextView 的右键菜单「复制」还能用（那是视图自带的），
// 但键盘快捷键完全不工作，表现就是「选中文字后 ⌘C 无效，只能右键复制」。
//
// 分发顺序（优先级从高到低）：
//   1. 第一响应者是文本视图 / field editor 且有选中文字 → 系统 copy:
//      （NSSearchField、偏好设置输入框、命令行页、性能诊断栏都走这条）
//   2. 只读文本视图没有选中文字 → 复制它的全部内容
//   3. 沿响应链找 RowTextCopying → 复制表格选中行（Tab 分隔 / 换行分隔）
//   4. 兜底 → 复制当前选中进程 PID；都没有则 beep
// ---------------------------------------------------------------------
// 标准响应链动作的 selector
//
// 刻意用 NSSelectorFromString 而不是 Selector("copy:") 字面量：
//  · Selector("…:") 字面量会触发编译器的 ObjC 方法存在性检查。
//    undo: / redo: 在纯 NSApplication（非 NSDocument、无 NSUndoManager）
//    里根本没有 @objc 声明，于是报 "no method declared with Objective-C
//    selector 'undo:'"；cut: / paste: / selectAll: 则报 "use '#selector'
//    instead of explicitly constructing a 'Selector'"。
//  · 改用 #selector 又必须假设这些动作声明在 NSResponder、NSText 还是
//    NSStandardKeyBindingResponding —— 不同 SDK 位置不一，本项目一直刻意
//    规避这种依赖，不值得为消警告把它引回来。
//  · NSSelectorFromString 是运行时构造，编译器不检查、不告警，得到的是
//    同一个 SEL，target=nil 时照样沿响应链分发，行为完全不变。
//
// 注：undo:/redo: 在没有注册 NSUndoManager 的窗口里会被 NSMenu 自动灰掉
// （响应链无人响应该 action），保留菜单项不会造成误操作。
// ---------------------------------------------------------------------
enum ResponderAction {
    static let undo      = NSSelectorFromString("undo:")
    static let redo      = NSSelectorFromString("redo:")
    static let cut       = NSSelectorFromString("cut:")
    static let copy      = NSSelectorFromString("copy:")
    static let paste     = NSSelectorFromString("paste:")
    static let selectAll = NSSelectorFromString("selectAll:")
}

// ---------------------------------------------------------------------

/// 响应链上的对象可实现它，为「没有选中文字时的 ⌘C」提供行级文本。
/// 用协议而不是 override NSResponder.copy(_:)，避免依赖不同 SDK 里
/// NSResponder 标准动作的声明位置（有的在基类、有的在 extension）。
protocol RowTextCopying: AnyObject {
    /// 成功复制返回 true（分发到此为止），没有可复制内容返回 false
    func copySelectedRowsToPasteboard() -> Bool
}

enum Clipboard {
    static func setString(_ s: String) {
        guard !s.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// 主菜单「编辑 → 复制」的动作，也供任何想复用同一套逻辑的入口调用。
    static func copy(_ sender: Any?) {
        var responder = NSApp.keyWindow?.firstResponder

        // 1) 文本优先：选中文字必须原样复制，不能被「复制整行」抢走。
        //    NSSearchField / 可编辑 NSTextField 的第一响应者通常是 field editor，
        //    它本身就是 NSTextView，所以这一分支也覆盖了输入框。
        if let tv = responder as? NSTextView {
            if tv.selectedRange.length > 0 {
                NSApp.sendAction(ResponderAction.copy, to: tv, from: sender)
                return
            }
            // 只读文本视图（命令行页 / 性能诊断栏）无选中 → 复制全部内容，
            // 比「复制空字符串」或「复制 PID」都更符合直觉。
            if !tv.isEditable, !tv.string.isEmpty {
                setString(tv.string)
                return
            }
        } else if let tf = responder as? NSTextField,
                  tf.isEditable || tf.isSelectable {
            // 少数情况 firstResponder 直接是 NSTextField 而不是 field editor。
            // 用运行时构造的 SEL 分发，不需要编译期假设方法声明位置。
            if NSApp.sendAction(ResponderAction.copy, to: tf, from: sender) { return }
        }

        // 2) 沿响应链找行级提供者：NSTableView / NSOutlineView 自己不实现
        //    copy:，但它们的 view controller 在响应链上。
        let first = responder
        while let r = responder {
            if let provider = r as? RowTextCopying,
               provider.copySelectedRowsToPasteboard() { return }
            responder = r.nextResponder
        }

        // 2b) 某些容器（嵌套 split / 自定义 contentViewController）里 VC 可能
        //     不在第一响应者链上。表格的 delegate / dataSource 通常就是那个 VC，
        //     直接问一次，且只问第一响应者这张表，不会误复制到隐藏页。
        if let t = first as? NSTableView {
            if let p = t.delegate as? RowTextCopying,
               p.copySelectedRowsToPasteboard() { return }
            if let p = t.dataSource as? RowTextCopying,
               p.copySelectedRowsToPasteboard() { return }
        }

        // 3) 兜底：至少别让 ⌘C 静默无反应
        if let pid = AppContext.shared.selectedPID {
            setString("\(pid)")
        } else {
            NSSound.beep()
        }
    }

    /// 表格行文本：标题行 + 若干数据行，列间 Tab、行间换行。
    /// 不带表头调用时把 columns 传空数组即可。
    static func joined(rows: [[String]], columns: [String] = []) -> String {
        var lines: [String] = []
        if !columns.isEmpty { lines.append(columns.joined(separator: "\t")) }
        for row in rows { lines.append(row.joined(separator: "\t")) }
        return lines.joined(separator: "\n")
    }
}
