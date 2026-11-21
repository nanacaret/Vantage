// SPDX-License-Identifier: MIT
import Foundation

// ---------------------------------------------------------------------
// C 层双语标记的解码
//
// 采集层（CProc）对每个含中文的字段输出：
//     \x1eL:<semantic.key>\x1f<中文>\x1f<English>\x1e
// GUI 用 L10n.localizeField 按当前语言取一份；CLI / MCP 没有 UI 语言设置，
// 这里按 LANG / VANTAGE_LANG 选，默认英文（脚本与管道里 ASCII 更安全）。
//
// 只是「读」，不参与生成：C 层仍然是唯一产出方，标记协议见
// docs/IMPLEMENTATION.md「国际化」一节。
// ---------------------------------------------------------------------

public enum Bilingual {

    public enum Language: String {
        case zh, en
    }

    /// 语言选择：`VANTAGE_LANG` 优先（zh / en / zh-Hans / en-US 都认），
    /// 其次 LC_ALL / LC_MESSAGES / LANG，最后默认英文。
    public static func detectLanguage() -> Language {
        let env = ProcessInfo.processInfo.environment
        for key in ["VANTAGE_LANG", "LC_ALL", "LC_MESSAGES", "LANG"] {
            guard let v = env[key]?.lowercased(), !v.isEmpty else { continue }
            if v.hasPrefix("zh") { return .zh }
            if v.hasPrefix("en") { return .en }
        }
        return .en
    }

    public static func language(from raw: String?) -> Language? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        return raw.hasPrefix("zh") ? .zh : (raw.hasPrefix("en") ? .en : nil)
    }

    /// 解一段文本里的所有标记；没有标记时原样返回（零分配之外的零成本）。
    public static func decode(_ s: String, _ lang: Language) -> String {
        guard s.contains("\u{1e}") else { return s }
        let parts = s.components(separatedBy: "\u{1e}")
        var out = parts[0]
        out.reserveCapacity(s.count)
        for p in parts.dropFirst() where !p.isEmpty {
            guard p.hasPrefix("L:") else {
                // 不认识的标记：原样保留控制字符，便于发现问题而不是静默吞掉
                out += "\u{1e}" + p
                continue
            }
            let f = p.dropFirst(2).components(separatedBy: "\u{1f}")
            if f.count >= 3 {
                out += (lang == .zh ? f[1] : f[2])
            } else if f.count == 2 {
                out += f[1]                    // 只有中文一份
            }
        }
        return out
    }

    /// 把一行 TSV 拆成字段并逐字段解码（标记不会跨字段）。
    public static func fields(of line: String, _ lang: Language) -> [String] {
        line.components(separatedBy: "\t").map { decode($0, lang) }
    }
}
