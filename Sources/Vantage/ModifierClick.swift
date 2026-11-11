// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 「修饰键 + 单击」的通用支持
//
// AppKit 表格的双击由 doubleAction 处理。这里让 ⌘ / ⌥ + 单击也能触发一个
// handler，规则：
//   · 绝大多数表格：修饰键单击 ≡ 双击（效果完全相同）
//   · 「窗口列表」是唯一例外：双击 = 定位进程，修饰键单击 = 激活该窗口
//
// 选 ⌘ 或 ⌥ 任一即可，不占用 Control / Shift（避免与右键菜单、范围选择冲突）。
// ---------------------------------------------------------------------

enum ModifierClick {
    static let mask: NSEvent.ModifierFlags = [.command, .option]

    static func isModifier(_ e: NSEvent) -> Bool {
        !e.modifierFlags.intersection(mask).isEmpty
    }

    static var hint: String { L("list.click") }
}

/// 双击回调开头调用：若 <0.5s 内刚发生过修饰键单击，吞掉这次双击。
/// 防止「⌘+快速点两下」同时触发修饰键 handler 和 doubleAction 造成双执行。
final class ModifierClickGate {
    private var last: TimeInterval = 0

    func mark() { last = Date().timeIntervalSince1970 }

    @discardableResult
    func consumeRecent() -> Bool {
        let now = Date().timeIntervalSince1970
        if now - last < 0.5 {
            last = 0
            return true
        }
        return false
    }
}

/// 带修饰键单击支持的 NSTableView。
/// 详情页 / 窗口列表都用它；主表是 NSOutlineView，见 ProcOutlineView。
final class ActionTableView: NSTableView {

    /// (row, column) —— 单击落在行内时才触发
    var onModifierClick: ((Int, Int) -> Void)?
    let clickGate = ModifierClickGate()

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let row = self.row(at: loc)
        let col = self.column(at: loc)
        if event.clickCount == 1, row >= 0, ModifierClick.isModifier(event) {
            clickGate.mark()
            super.mouseDown(with: event)
            // ⌘ 单击可能被 AppKit 解释为「取消选择」，显式选中该行
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            onModifierClick?(row, col)
            return
        }
        super.mouseDown(with: event)
    }
}
