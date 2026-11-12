// SPDX-License-Identifier: MIT
import Foundation
import Security

// ---------------------------------------------------------------------
// 系统扩展 / 驱动 bundle 扫描
//
// 覆盖四类「extension bundle」：
//   .kext            传统内核扩展
//   .dext            DriverKit 驱动扩展
//   .systemextension 系统扩展（网络 / 端点安全 / DriverKit）
//   .appex           App Extension（含系统内置插件）
//
// 主信息全部来自各 bundle 自带的 Contents/Info.plist（公开格式），
// 「是否已加载 / 已激活」分别来自 kmutil showloaded 与
// systemextensionsctl list；两条 CLI 任一不可用就显示「—」，绝不用
// 「没查到」冒充「未加载」。签名 Team ID 按需读取（选中行时才校验），
// 避免几百个 bundle 逐个 SecStaticCode 拖慢扫描。
// ---------------------------------------------------------------------

enum ExtensionKind: String, CaseIterable {
    case kext
    case dext
    case systemExtension
    case appExtension

    var suffix: String {
        switch self {
        case .kext:             return ".kext"
        case .dext:             return ".dext"
        case .systemExtension:  return ".systemextension"
        case .appExtension:     return ".appex"
        }
    }

    var title: String { L("ext.kind.\(rawValue)") }

    static func match(_ name: String) -> ExtensionKind? {
        let lower = name.lowercased()
        return allCases.first { lower.hasSuffix($0.suffix) }
    }
}

struct ExtensionBundle {
    let kind: ExtensionKind
    let name: String
    let bundleID: String
    let shortVersion: String
    let version: String
    let executable: String
    let extensionPoint: String
    let path: String
    let ioClasses: [String]
    let status: String          // "loaded" / "activated" / ""
    let infoPlistOK: Bool

    var displayVersion: String {
        if !shortVersion.isEmpty && !version.isEmpty && shortVersion != version {
            return "\(shortVersion) (\(version))"
        }
        return shortVersion.isEmpty ? version : shortVersion
    }
    var statusTitle: String {
        switch status {
        case "loaded":    return L("ext.status.loaded")
        case "activated": return L("ext.status.activated")
        default:          return L("ext.status.unknown")
        }
    }
}

private struct ExtRoots {
    let path: String
    let maxDepth: Int
    let apps: Bool
}

final class ExtensionScanner {

    static let shared = ExtensionScanner()

    /// 只在主线程读写；扫描完成一次性整体替换
    private(set) var bundles: [ExtensionBundle] = []
    private(set) var scannedAt: Date?
    private(set) var statusCLIsAvailable = false
    private(set) var truncated = false

    private static let cap = 20000

    private static let baseRoots: [ExtRoots] = [
        ExtRoots(path: "/System/Library/Extensions",          maxDepth: 3, apps: false),
        ExtRoots(path: "/Library/Extensions",                  maxDepth: 3, apps: false),
        ExtRoots(path: "/System/Library/DriverExtensions",    maxDepth: 3, apps: false),
        ExtRoots(path: "/Library/DriverExtensions",            maxDepth: 3, apps: false),
        ExtRoots(path: "/Library/SystemExtensions",            maxDepth: 4, apps: false),
        ExtRoots(path: "/System/Library/SystemExtensions",     maxDepth: 4, apps: false),
        ExtRoots(path: "/System/Library/CoreServices",         maxDepth: 5, apps: false),
        ExtRoots(path: "/System/Library/Frameworks",           maxDepth: 6, apps: false),
        ExtRoots(path: "/System/Library/PrivateFrameworks",    maxDepth: 7, apps: false),
        ExtRoots(path: "/System/Applications",                 maxDepth: 6, apps: false),
    ]

    private static let appRoots: [ExtRoots] = [
        ExtRoots(path: "/Applications",                        maxDepth: 7, apps: true),
    ]

    // -----------------------------------------------------------------
    // 公开入口
    // -----------------------------------------------------------------

    func scan(includeApps: Bool,
              completion: @escaping ([ExtensionBundle]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Self.loadedKextIDs()
            let activated = Self.activatedExtensionIDs()
            let cliOK = !loaded.isEmpty || !activated.isEmpty
            var result: [ExtensionBundle] = []
            var cut = false

            var roots = Self.baseRoots
            if includeApps { roots.append(contentsOf: Self.appRoots) }
            for r in roots {
                if result.count >= Self.cap { cut = true; break }
                Self.walk(r.path, depth: 0, maxDepth: r.maxDepth,
                          loaded: loaded, activated: activated,
                          into: &result)
                if result.count >= Self.cap { cut = true; break }
            }
            var seen = Set<String>()
            result = result.filter { seen.insert($0.path).inserted }
            result.sort {
                let a = $0.kind.rawValue, b = $1.kind.rawValue
                return a == b ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                              : a < b
            }
            let final = result
            let truncated = cut
            let cli = cliOK
            DispatchQueue.main.async {
                self.bundles = final
                self.scannedAt = Date()
                self.statusCLIsAvailable = cli
                self.truncated = truncated
                completion(final)
            }
        }
    }

    func lookup(bundleID: String) -> ExtensionBundle? {
        guard !bundleID.isEmpty else { return nil }
        return bundles.first { $0.bundleID == bundleID }
    }

    func lookup(ioClass: String) -> ExtensionBundle? {
        guard !ioClass.isEmpty else { return nil }
        return bundles.first { $0.ioClasses.contains(ioClass) }
    }

    /// 设备树节点反查：先用节点自带的 bundle id，再用 IOClass 查
    /// IOKitPersonalities 索引（很多 Apple 驱动节点不带 CFBundleIdentifier）。
    func lookup(bundleID: String, ioClass: String) -> ExtensionBundle? {
        if let b = lookup(bundleID: bundleID) { return b }
        return lookup(ioClass: ioClass)
    }

    // -----------------------------------------------------------------
    // 签名（按需）
    // -----------------------------------------------------------------

    static func signing(path: String) -> (team: String, identifier: String) {
        guard !path.isEmpty else { return ("", "") }
        var code: SecStaticCode?
        let st = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL, [], &code)
        guard st == errSecSuccess, let target = code else { return ("", "") }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(target, flags, &info) == errSecSuccess,
              let d = info as? [String: Any] else { return ("", "") }
        let team = d[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        let ident = d[kSecCodeInfoIdentifier as String] as? String ?? ""
        return (team, ident)
    }

    // -----------------------------------------------------------------
    // 状态 CLI
    // -----------------------------------------------------------------

    private static func shell(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// 从输出里抓形如 com.apple.driver.X 的 bundle id token
    private static func ids(_ text: String?) -> Set<String> {
        guard let text = text else { return [] }
        var out: Set<String> = []
        for line in text.split(separator: "\n") {
            for tok in line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" || $0 == ")" }) {
                let s = String(tok).trimmingCharacters(in: CharacterSet(charactersIn: "[]<>,;\"'"))
                guard s.count >= 5, s.contains("."),
                      !s.hasPrefix("."), !s.hasSuffix("."),
                      s.range(of: "^[A-Za-z][A-Za-z0-9_.-]*$", options: .regularExpression) != nil,
                      !s.contains("..") else { continue }
                // 排除版本 / 路径 / 数字开头
                if s.first?.isNumber == true { continue }
                if s.hasPrefix("/") || s.contains("/") { continue }
                out.insert(s)
            }
        }
        return out
    }

    private static func loadedKextIDs() -> Set<String> {
        ids(shell("/usr/bin/kmutil", ["showloaded"]))
    }

    private static func activatedExtensionIDs() -> Set<String> {
        ids(shell("/usr/bin/systemextensionsctl", ["list"]))
    }

    // -----------------------------------------------------------------
    // 目录递归
    // -----------------------------------------------------------------

    private static func walk(_ dir: String, depth: Int, maxDepth: Int,
                             loaded: Set<String>, activated: Set<String>,
                             into: inout [ExtensionBundle]) {
        guard depth <= maxDepth, into.count < cap else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names where !name.hasPrefix(".") {
            if into.count >= cap { return }
            let path = (dir as NSString).appendingPathComponent(name)
            if let kind = ExtensionKind.match(name) {
                into.append(parse(path: path, kind: kind,
                                  loaded: loaded, activated: activated))
                // .systemextension / .kext 里可能内嵌 .dext，再往下两层
                if depth + 2 <= maxDepth {
                    walk(path, depth: depth + 1,
                         maxDepth: min(maxDepth, depth + 3),
                         loaded: loaded, activated: activated, into: &into)
                }
            } else {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                // 已命中的 bundle 目录不再深入扫普通子目录（上面的定向递归已做）
                walk(path, depth: depth + 1, maxDepth: maxDepth,
                     loaded: loaded, activated: activated, into: &into)
            }
        }
    }

    private static func parse(path: String, kind: ExtensionKind,
                              loaded: Set<String>,
                              activated: Set<String>) -> ExtensionBundle {
        let name = (path as NSString).lastPathComponent
            .replacingOccurrences(of: kind.suffix, with: "", options: .caseInsensitive)
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        let altPath = (path as NSString).appendingPathComponent("Info.plist")
        let d1 = NSDictionary(contentsOfFile: plistPath) as? [String: Any]
        let d2 = NSDictionary(contentsOfFile: altPath) as? [String: Any]
        let dict = d1 ?? d2 ?? [:]
        let str = { (k: String) -> String in
            (dict[k] as? String) ?? (dict[k] as? NSNumber)?.stringValue ?? ""
        }
        let bid = str("CFBundleIdentifier")
        var classes: [String] = []
        if let pers = dict["IOKitPersonalities"] as? [String: Any] {
            for (_, v) in pers {
                guard let d = v as? [String: Any] else { continue }
                if let c = d["IOClass"] as? String, !c.isEmpty { classes.append(c) }
            }
        }
        classes = Array(Set(classes)).sorted()

        var point = ""
        if let ne = dict["NSExtension"] as? [String: Any] {
            point = ne["NSExtensionPointIdentifier"] as? String ?? ""
        }
        if point.isEmpty, let p = dict["EXAppExtensionAttributes"] as? [String: Any] {
            point = p["NSExtensionPointIdentifier"] as? String ?? ""
        }
        if point.isEmpty && !classes.isEmpty { point = "IOKit" }

        let status: String
        if !bid.isEmpty, loaded.contains(bid) { status = "loaded" }
        else if !bid.isEmpty, activated.contains(bid) { status = "activated" }
        else { status = "" }

        return ExtensionBundle(
            kind: kind,
            name: name.isEmpty ? (path as NSString).lastPathComponent : name,
            bundleID: bid,
            shortVersion: str("CFBundleShortVersionString"),
            version: str("CFBundleVersion"),
            executable: str("CFBundleExecutable"),
            extensionPoint: point,
            path: path,
            ioClasses: classes,
            status: status,
            infoPlistOK: !dict.isEmpty)
    }
}
