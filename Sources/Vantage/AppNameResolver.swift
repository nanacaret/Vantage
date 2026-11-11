// SPDX-License-Identifier: MIT
import Foundation

// ---------------------------------------------------------------------
// 应用显示名解析
//
// 一个 .app 里往往有一堆 helper（crashpad_handler、WeChat Helper (Renderer)
// 之类），它们的 exepath 都落在同一个 bundle 下。只显示 bundle 名时，主表里
// 会冒出好几行「WeChat」，不点开检查器根本分不清哪个是真正的主进程。
//
// 这里提供两件事：
//  1. 从 bundle 的 Info.plist 读真正的本地化显示名（CFBundleDisplayName /
//     CFBundleName），Activity Monitor 口径；
//  2. 缓存 —— 几百个进程可能共享十几个 bundle，不能每行每次刷新都去读 plist。
// ---------------------------------------------------------------------

/// 主表里「同时显示 raw 名」的拼接格式
enum RawNameStyle: Int, CaseIterable {
    case parentheses    = 0   // WeChat (crashpad_handler)
    case middleDot      = 1   // WeChat · crashpad_handler
    case squareBrackets = 2   // WeChat [crashpad_handler]

    var title: String {
        switch self {
        case .parentheses:    return L("app.parenthesesRaw")
        case .middleDot:      return L("app.middleDotRaw")
        case .squareBrackets: return L("app.squareBracketsRaw")
        }
    }

    func wrap(_ raw: String) -> String {
        switch self {
        case .parentheses:    return " (\(raw))"
        case .middleDot:      return " · \(raw)"
        case .squareBrackets: return " [\(raw)]"
        }
    }

    /// 示例：偏好设置里的实时预览用
    var example: String { "WeChat" + wrap("crashpad_handler") }
}

enum AppNameResolver {
    /// NSString 缓存，空串表示「该 bundle 没有可用的本地化名」，避免反复读盘。
    /// NSCache 是线程安全的；主表刷新可能在主线程，也可能在采集队列。
    private static let cache = NSCache<NSString, NSString>()

    /// 返回 bundle 的本地化显示名；没有则返回 nil，调用方回退到 .app 目录名。
    static func localizedName(forBundlePath path: String) -> String? {
        let key = path as NSString
        if let hit = cache.object(forKey: key) {
            return hit.length == 0 ? nil : (hit as String)
        }
        var found: String?
        if let bundle = Bundle(path: path) {
            found = pick(bundle.localizedInfoDictionary)
                ?? pick(bundle.infoDictionary)
        }
        // 极端情况防呆：plist 里塞超长字符串会把整行撑爆
        if let s = found, s.count > 80 { found = String(s.prefix(80)) }
        let stored = (found ?? "") as NSString
        cache.setObject(stored, forKey: key)
        return found?.isEmpty == true ? nil : found
    }

    private static func pick(_ dict: [String: Any]?) -> String? {
        guard let d = dict else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let s = d[key] as? String,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }

    /// 偏好切换时清空，避免旧值残留（bundle 内容一般不会变，但改 Info.plist
    /// 或替换 .app 后能立刻生效）。
    static func invalidate() { cache.removeAllObjects() }
}
