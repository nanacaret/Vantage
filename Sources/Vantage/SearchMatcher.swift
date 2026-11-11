// SPDX-License-Identifier: MIT
import Foundation

// ---------------------------------------------------------------------
// 统一搜索匹配器
//
// 主表过滤、详情页当前页过滤、全局搜索窗口的结果过滤共用这一套语义：
//   · literal：大小写 / 变音不敏感的子串匹配（旧行为）
//   · regex  ：NSRegularExpression，大小写不敏感，按「字段」匹配
//              —— ^WeChat$ 能精确命中名称字段，而不是被拼成一整行后失配
// 正则编译失败时**自动回退到字面量**，并给出 errorText：用户敲到一半
// （例如只输入了 "["）不会突然把整个列表清空，状态栏还能明确提示原因。
// ---------------------------------------------------------------------

enum SearchMatchMode: Int {
    case literal = 0
    case regex = 1
}

struct SearchMatcher {

    let query: String
    let mode: SearchMatchMode
    let isEmpty: Bool
    /// 正则编译失败的原因（已回退到字面量匹配）；nil 表示模式有效
    let errorText: String?
    private let regex: NSRegularExpression?

    init(query: String, mode: SearchMatchMode) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = q
        self.mode = mode
        self.isEmpty = q.isEmpty

        // 用局部变量编译，最后一次性赋给 stored properties。
        // 不直接写 `self.regex = try ...`：Swift 的 definite-initialization
        // 分析对 init 里的 do/catch 路径较严格，局部变量写法最稳。
        var compiled: NSRegularExpression?
        var compileError: String?
        if mode == .regex, !q.isEmpty {
            do {
                compiled = try NSRegularExpression(
                    pattern: q, options: [.caseInsensitive])
            } catch {
                compileError = (error as NSError).localizedDescription
            }
        }
        self.regex = compiled
        self.errorText = compileError
    }

    /// 该模式是否真的按正则在跑（而不是回退到字面量）
    var isRegexActive: Bool { regex != nil }

    func matches(_ text: String) -> Bool {
        if isEmpty { return true }
        if let re = regex {
            let ns = text as NSString
            return re.firstMatch(in: text,
                                 range: NSRange(location: 0, length: ns.length)) != nil
        }
        return text.range(of: query,
                          options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// 字段级匹配：任一字段命中即可。正则模式下 ^ / $ 作用于单个字段。
    func matches(anyOf fields: [String]) -> Bool {
        if isEmpty { return true }
        return fields.contains { matches($0) }
    }
}
