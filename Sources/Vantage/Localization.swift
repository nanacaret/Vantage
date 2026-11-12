// SPDX-License-Identifier: MIT
import Foundation
import AppKit

// ---------------------------------------------------------------------
// 本地化：语义 key
//
//   L("proc.name")                    → 查当前语言表
//   L("inspector.title", name, pid)  → 格式串用 {0} {1} 占位
//
// 中文**不是 key**，而是 zh-Hans.lproj 里的 value；源码里不出现 UI 中文。
// 两张表的唯一数据源是 Tools/l10n_master.py，由 build_l10n.py 生成
// Resources/*.lproj 与 L10nTable.swift（内嵌兜底）。
//
// C 层输出是 \t 分隔的运行时文本（格式串里混着变量），无法分配 key，
// 只在 localizeField 里按「中文短语 → 英文」做字段级替换，属必要例外。
// ---------------------------------------------------------------------

/// 全局简写。args 用 {0} {1} 占位，按序替换，不依赖 %@ / %d 的类型匹配。
func L(_ key: String, _ args: Any...) -> String { L10n.format(key, args) }

enum L10n {

    enum Language: Int, CaseIterable {
        case system = 0
        case zhHans = 1
        case english = 2

        var title: String {
            switch self {
            case .system:  return L("lang.followSystem")
            case .zhHans:  return L("lang.zhHans")
            case .english: return L("lang.english")
            }
        }
    }

    /// C 层提示行的稳定结构标记（ASCII，不是 UI 文案，不参与本地化）
    static let hintTag = "__hint__"

    static let languageKey = "Vantage.pref.language"
    static let hintsKey = "Vantage.pref.showDetailHints"

    /// 详情提示行默认隐藏；偏好窗口与 parse() 共用同一个 key。
    static var showDetailHints: Bool {
        get { UserDefaults.standard.object(forKey: hintsKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: hintsKey) }
    }

    /// 动态句子的译文缓存（NSCache 线程安全）；语言切换时清空。
    private static let cache = NSCache<NSString, NSString>()

    static var language: Language {
        get {
            let v = UserDefaults.standard.object(forKey: languageKey) as? Int ?? 0
            return Language(rawValue: min(max(v, 0), 2)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
            notifyChanged()
        }
    }

    static var isEnglish: Bool {
        switch language {
        case .english: return true
        case .zhHans:  return false
        case .system:
            let pref = Locale.preferredLanguages.first
                ?? Bundle.main.preferredLocalizations.first
                ?? "zh-Hans"
            return pref.lowercased().hasPrefix("en")
        }
    }

    // -----------------------------------------------------------------
    // 表：内嵌兜底 + Bundle 里可编辑的 .lproj 覆盖
    // -----------------------------------------------------------------

    static let zh: [String: String] = load("zh-Hans", fallback: L10nTable.zh)
    static let en: [String: String] = load("en", fallback: L10nTable.en)

    private static func load(_ lang: String, fallback: [String: String]) -> [String: String] {
        var d = fallback
        // 只读对应语言的 .lproj，绝不退化到「无 subdirectory」的那个，
        // 否则 en 表会被 zh 表覆盖（或反之）。读不到就用内嵌兜底。
        guard let u = Bundle.main.url(forResource: "Localizable",
                                      withExtension: "strings",
                                      subdirectory: "\(lang).lproj"),
              let t = try? String(contentsOf: u, encoding: .utf8) else { return d }
        for (k, v) in parseStrings(t) { d[k] = v }
        return d
    }

    /// 解析 .strings 的 "k" = "v"; —— 逐字符反转义，与生成端 esc() 严格互逆
    private static func parseStrings(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        let pattern = #""((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return out }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 3 else { continue }
            out.append((unescape(ns.substring(with: m.range(at: 1))),
                        unescape(ns.substring(with: m.range(at: 2)))))
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        let cs = Array(s)
        var out = ""
        var i = 0
        while i < cs.count {
            if cs[i] == "\\", i + 1 < cs.count {
                switch cs[i + 1] {
                case "n":  out.append("\n")
                case "t":  out.append("\t")
                case "r":  out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default:   out.append("\\"); out.append(cs[i + 1])
                }
                i += 2
            } else {
                out.append(cs[i]); i += 1
            }
        }
        return out
    }

    // -----------------------------------------------------------------
    // 取值
    // -----------------------------------------------------------------

    static func string(_ key: String) -> String {
        (isEnglish ? en : zh)[key] ?? key
    }

    static func format(_ key: String, _ args: [Any]) -> String {
        let s = string(key)
        guard !args.isEmpty else { return s }
        var r = s
        for (i, a) in args.enumerated() {
            r = r.replacingOccurrences(of: "{\(i)}", with: String(describing: a))
        }
        return r
    }

    // -----------------------------------------------------------------
    // C 层运行时文本（唯一仍按中文文本匹配的例外）
    // -----------------------------------------------------------------

    static func localizeField(_ s: String) -> String {
        // 先解 C 层双语标记（精确、零猜测）；未标记的运行时文本才走短语兜底。
        if s.hasPrefix(cMark) { return resolveCField(s) }
        guard isEnglish, L10nTable.hasChinese(s) else { return s }
        let k = s as NSString
        if let hit = cache.object(forKey: k) { return hit as String }
        let r: String
        if let exact = L10nTable.phraseExact[s] {
            r = exact
        } else {
            var t = s
            for (zh, en) in L10nTable.phrases where t.contains(zh) {
                t = t.replacingOccurrences(of: zh, with: en)
            }
            r = t
        }
        cache.setObject(r as NSString, forKey: k)
        return r
    }

    // -----------------------------------------------------------------
    // C 层双语标记：\x1eL:<key>\x1f<zh>\x1f<en>\x1e
    // 控制字符不会出现在真实数据里；中文是 value，key 是语义标识。
    // -----------------------------------------------------------------
    static let cMark = "\u{1e}L:"
    static let cEnd: Character = "\u{1e}"
    static let cSep: Character = "\u{1f}"

    static func cParts(_ s: String) -> (key: String, zh: String, en: String)? {
        guard s.hasPrefix(cMark) else { return nil }
        var body = String(s.dropFirst(cMark.count))
        if body.last == cEnd { body.removeLast() }
        let p = body.split(separator: cSep, maxSplits: 2,
                           omittingEmptySubsequences: false)
        guard p.count >= 3 else { return nil }
        return (String(p[0]), String(p[1]), String(p[2]))
    }

    /// 单个字段：按当前语言取一份。
    static func resolveCField(_ s: String) -> String {
        guard let p = cParts(s) else { return s }
        return isEnglish ? p.en : p.zh
    }

    /// 与 C 层中文协议比较时取「标记里的中文原文」，不受语言影响。
    static func cFieldZh(_ s: String) -> String {
        guard let p = cParts(s) else { return s }
        return p.zh
    }

    /// 整段文本（性能窗口状态栏 / 逐通道诊断）：替换其中所有标记。
    static func resolveCText(_ s: String) -> String {
        guard s.contains(cMark) else { return s }
        guard let re = try? NSRegularExpression(
                pattern: "\u{1e}L:[^\u{1f}]*\u{1f}([^\u{1f}]*)\u{1f}([^\u{1e}]*)\u{1e}") else {
            return s
        }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = s as NSString
        for m in matches.reversed() {
            guard m.numberOfRanges >= 3 else { continue }
            let zh = ns.substring(with: m.range(at: 1))
            let en = ns.substring(with: m.range(at: 2))
            out = out.replacingCharacters(in: m.range, with: isEnglish ? en : zh) as NSString
        }
        return out as String
    }

    // -----------------------------------------------------------------
    // 静态控件就地刷新：显示值 → key → 当前语言值
    // -----------------------------------------------------------------

    /// 合并两张表的「值 → key」反查：中→英、英→中都能转。
    /// 同一中文值对应多个 key 时取其一，string(key) 的结果是一样的。
    static let valueToKey: [String: String] = {
        var d: [String: String] = [:]
        for (k, v) in zh { d[v] = k }
        for (k, v) in en { d[v] = k }
        return d
    }()

    /// 只处理「完整等于某个表值」的字符串；动态数值文本不会命中，安全。
    static func convertDisplayed(_ s: String) -> String {
        guard let k = valueToKey[s] else { return s }
        return string(k)
    }

    static func relocalize(_ view: NSView) {
        if let tv = view as? NSTableView { relocalizeColumns(tv) }
        for sub in view.subviews {
            if let tv = sub as? NSTableView { relocalizeColumns(tv) }
            // NSScrollView 的 documentView 不在 subviews 里
            if let sv = sub as? NSScrollView, let doc = sv.documentView { relocalize(doc) }
            if let b = sub as? NSButton {
                b.title = convertDisplayed(b.title)
                // macOS 26 SDK 里 alternateTitle 是非 Optional 的 String
                let alt = b.alternateTitle
                if !alt.isEmpty { b.alternateTitle = convertDisplayed(alt) }
            }
            if let tf = sub as? NSTextField {
                if !tf.isEditable { tf.stringValue = convertDisplayed(tf.stringValue) }
                if let ph = tf.placeholderString {
                    tf.placeholderString = convertDisplayed(ph)
                }
            }
            if let pop = sub as? NSPopUpButton {
                for item in pop.itemArray { item.title = convertDisplayed(item.title) }
            }
            if let seg = sub as? NSSegmentedControl {
                for i in 0..<seg.segmentCount {
                    if let label = seg.label(forSegment: i) {
                        seg.setLabel(convertDisplayed(label), forSegment: i)
                    }
                }
            }
            relocalize(sub)
        }
    }

    static func relocalizeColumns(_ table: NSTableView) {
        for col in table.tableColumns {
            col.title = convertDisplayed(col.title)
            col.headerCell.stringValue = convertDisplayed(col.headerCell.stringValue)
        }
    }

    static func relocalizeMenu(_ menu: NSMenu) {
        for item in menu.items {
            item.title = convertDisplayed(item.title)
            if let sub = item.submenu { relocalizeMenu(sub) }
        }
    }

    // -----------------------------------------------------------------

    static func notifyChanged() {
        cache.removeAllObjects()
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
    }
}

extension Notification.Name {
    static let languageDidChange =
        Notification.Name("com.vantage.languageDidChange")
}
