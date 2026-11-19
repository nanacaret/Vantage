// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// 「在 Finder 中显示」用的路径识别与归一化
//
// 详情表里带路径的列很多：文件页「路径」、镜像页「镜像路径」、映射页
// 「映射文件」、概览页「可执行文件路径 / Bundle」、签名页、TTY 页的设备名……
// 但单元格文本并不总是干净路径：
//   · 空值占位："—" / "-" / "?" / "(未知路径)" / "(路径读取失败…)"
//   · 引号包裹（粘贴进来的路径）与 "file:///Users/..." 形式
//   · 内核追加的删除标记：" (deleted)" / " (revoked)" / " (unlinked)"
//   · 以 "/" 开头但其实是列表的值：PATH=/usr/bin:/bin:…
// 这里统一归一化成「一个能交给 NSWorkspace 的绝对路径」，认不出来返回 nil，
// 菜单项据此置灰 —— 避免点了没反应，也避免把整段列表当成一个文件名。
// ---------------------------------------------------------------------

enum PathReveal {

    /// 明显不是路径的占位文本（C 层在取不到路径时会输出这些）
    private static let placeholders: Set<String> = [
        "", "-", "—", "–", "?", "n/a", "none", "null",
    ]

    /// 内核标记的尾部提示，剥掉后才是真实路径
    private static let kernelSuffixes = [
        " (deleted)", " (revoked)", " (unlinked)", " (deleted by kernel)",
    ]

    /// 单元格文本 → 绝对路径；不像路径则返回 nil。
    static func resolve(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !placeholders.contains(s.lowercased()) else { return nil }

        // 只取第一行：「值」列里可能带换行（命令行、多行说明）
        if let br = s.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            s = String(s[s.startIndex..<br])
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // 成对引号
        for q in ["\"", "'"] where s.count > 2 {
            if s.hasPrefix(q), s.hasSuffix(q) {
                s = String(s.dropFirst().dropLast())
                break
            }
        }

        // file:// URL
        if s.lowercased().hasPrefix("file://") {
            guard let u = URL(string: s) else { return nil }
            s = u.path
        }

        for suffix in kernelSuffixes where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }

        if s.hasPrefix("~") {
            s = (s as NSString).expandingTildeInPath
        }

        guard s.hasPrefix("/") else { return nil }
        // 冒号基本只出现在 PATH 这类「多路径拼接」的值里，单文件路径极少有
        guard !s.contains(":"), !s.contains("\t") else { return nil }
        return s
    }

    /// 菜单标题用：路径太长时保留尾部（尾部才是有信息量的部分）
    static func abbreviated(_ path: String, limit: Int = 64) -> String {
        guard path.count > limit else { return path }
        return "…" + path.suffix(limit)
    }

    /// 在 Finder 中选中该路径。
    /// 路径已不存在（进程退出后映射文件消失、卷被卸载）时逐级向上找仍存在的
    /// 祖先并选中它 —— 与 Finder 自己的行为一致；一直找不到才提示错误。
    static func reveal(_ path: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: path)])
            return
        }
        var url = URL(fileURLWithPath: path)
        var hops = 0
        while hops < 64 {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }          // 已到 "/"
            if parent.path != "/", fm.fileExists(atPath: parent.path) {
                NSWorkspace.shared.activateFileViewerSelecting([parent])
                return
            }
            url = parent
            hops += 1
        }
        AppContext.shared.showError(L("detail.revealPathMissing", path))
    }
}
