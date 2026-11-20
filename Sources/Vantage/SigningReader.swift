// SPDX-License-Identifier: MIT
import Foundation
import Security

struct SigningInfo {
    var rows: [(String, String)]
}

enum SigningReader {

    /// 代码签名信息字典（Security.framework 的 kSecCodeInfo* 键）。
    /// 「签名」页与「权限」页共用，避免两处各写一遍 guest → static → info。
    static func signingInformation(pid: Int32, path: String) -> [String: Any]? {
        var staticCode: SecStaticCode?

        // 优先按 pid 取运行中的 code；拿不到（其他用户的进程、已退出）时
        // 退回按可执行文件路径读静态签名 —— 读磁盘不需要 task port。
        var guest: SecCode?
        let attrs: [String: Any] = [
            kSecGuestAttributePid as String: NSNumber(value: pid)
        ]
        if SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &guest)
                == errSecSuccess, let code = guest {
            if SecCodeCopyStaticCode(code, [], &staticCode) != errSecSuccess {
                staticCode = nil
            }
        }
        if staticCode == nil, !path.isEmpty {
            SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL,
                                        [], &staticCode)
        }
        guard let target = staticCode else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(target, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict
    }

    /// 已声明的 entitlements（未签名 / 无 entitlement 时返回 nil）
    static func entitlements(pid: Int32, path: String) -> [String: Any]? {
        guard let dict = signingInformation(pid: pid, path: path) else { return nil }
        return dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    }

    /// 签名标识符；未签名时可能等于路径或 nil
    static func signingIdentifier(pid: Int32, path: String) -> String? {
        guard let dict = signingInformation(pid: pid, path: path) else { return nil }
        return dict[kSecCodeInfoIdentifier as String] as? String
    }

    static func read(pid: Int32, path: String) -> SigningInfo {
        var rows: [(String, String)] = []

        var guest: SecCode?
        let attrs: [String: Any] = [
            kSecGuestAttributePid as String: NSNumber(value: pid)
        ]
        let st = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &guest)
        guard st == errSecSuccess, let code = guest else {
            rows.append((L("signing.status"), L("signing.secCodeUnavailableOSStatus", st)))
            rows.append((L("signing.description"), L("signing.theProcessMayHaveExited")))
            return SigningInfo(rows: rows)
        }

        let validity = SecCodeCheckValidity(code, [], nil)
        rows.append((L("signing.signatureValidation"), validity == errSecSuccess
                     ? L("signing.validPassesBasicRequirementChecks")
                     : L("signing.invalidUnsignedOSStatus", validity)))

        var staticCode: SecStaticCode?
        if SecCodeCopyStaticCode(code, [], &staticCode) != errSecSuccess ||
            staticCode == nil {
            if !path.isEmpty {
                SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL,
                                            [], &staticCode)
            }
        }

        guard let target = staticCode else {
            rows.append((L("signing.status2"), L("signing.couldNotObtainStaticCode")))
            return SigningInfo(rows: rows)
        }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        let ist = SecCodeCopySigningInformation(target, flags, &info)
        guard ist == errSecSuccess, let dict = info as? [String: Any] else {
            rows.append((L("signing.status3"), L("signing.couldNotReadSigningInfo", ist)))
            return SigningInfo(rows: rows)
        }

        rows.append((L("signing.signed"),
                     dict[kSecCodeInfoIdentifier as String] == nil ? L("signing.noAdHocUnsigned") : L("signing.yes")))

        add(rows: &rows, dict: dict, key: kSecCodeInfoIdentifier, title: L("signing.signingIdentifier"))
        add(rows: &rows, dict: dict, key: kSecCodeInfoTeamIdentifier, title: "Team ID")
        add(rows: &rows, dict: dict, key: kSecCodeInfoSource, title: L("signing.signatureSource"))
        add(rows: &rows, dict: dict, key: kSecCodeInfoPlatformIdentifier, title: L("signing.platformBinary"))
        add(rows: &rows, dict: dict, key: kSecCodeInfoMainExecutable, title: L("signing.mainExecutable"))
        add(rows: &rows, dict: dict, key: kSecCodeInfoRuntimeVersion, title: L("signing.runtimeVersion"))

        if let f = dict[kSecCodeInfoFlags as String] as? NSNumber {
            let bits = decodeCSFlags(f.uint32Value)
            rows.append((L("signing.codeSigningFlags"), String(format: "0x%08x", f.uint32Value)))
            rows.append((L("signing.flagDetails"), bits.isEmpty ? L("signing.noKnownFlags") : bits))
        }

        if let uniq = dict[kSecCodeInfoUnique as String] as? Data {
            let hex = uniq.map { String(format: "%02x", $0) }.joined()
            rows.append(("CDHash / Unique", hex))
        }
        if !path.isEmpty { rows.append((L("signing.executablePath"), path)) }

        if let ent = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            let flat = flatten(ent)
            rows.append(("Entitlements", L("signing.totalItems", flat.count)))
            for (k, v) in flat {
                rows.append(("  ↳ \(k)", v))
            }
        } else {
            rows.append(("Entitlements", L("signing.none")))
        }

        return SigningInfo(rows: rows)
    }

    private static func add(rows: inout [(String, String)],
                            dict: [String: Any], key: CFString, title: String) {
        if let v = dict[key as String] {
            rows.append((title, "\(v)"))
        } else {
            rows.append((title, "—"))
        }
    }

    /// CS_* 位值参考 xnu bsd/sys/codesign.h（不同系统版本可能略有差异）
    private static func decodeCSFlags(_ f: UInt32) -> String {
        let defs: [(UInt32, String)] = [
            (0x00000001, "CS_VALID"),
            (0x00000100, "CS_HARD"),
            (0x00000200, "CS_KILL"),
            (0x00000400, "CS_CHECK_EXPIRATION"),
            (0x00000800, "CS_RESTRICT"),
            (0x00001000, "CS_ENFORCEMENT"),
            (0x00002000, "CS_REQUIRE_LV"),
            (0x00010000, "CS_RUNTIME (Hardened Runtime)"),
            (0x04000000, "CS_PLATFORM_BINARY"),
        ]
        return defs.filter { f & $0.0 != 0 }.map { $0.1 }.joined(separator: ", ")
    }

    private static func flatten(_ dict: [String: Any],
                                prefix: String = "") -> [(String, String)] {
        var out: [(String, String)] = []
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let d = v as? [String: Any] {
                out += flatten(d, prefix: key)
            } else if let a = v as? [Any] {
                out.append((key, a.map { "\($0)" }.joined(separator: ", ")))
            } else {
                out.append((key, "\(v)"))
            }
        }
        return out
    }
}
