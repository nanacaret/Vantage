// SPDX-License-Identifier: MIT
import Foundation
import CProc

// ---------------------------------------------------------------------
// IORegistry 数据层：C 层输出 ASCII 结构行，Swift 只解析与建模。
//
// 不直接 import IOKit 的原因：CFMutableDictionary / Unmanaged<CFTypeRef>
// 在新版 SDK 的 Swift 桥接行为不稳定（`as? CFArray` 会编译报错），而 C 层
// 用纯 CoreFoundation C API 提取属性最稳，也和工程「C 采集 → 扁平行 →
// Swift 界面」的既有架构一致。
// ---------------------------------------------------------------------

struct IORegNode {
    let index: Int
    let parent: Int
    let depth: Int
    let entryID: UInt64
    let name: String
    let className: String
    let bundleID: String
    let personalityBundleID: String
    let ioClass: String
    let providerClass: String
    let clientPID: Int32?
    let clientName: String
    /// string / number / audit —— UI 用来标注 PID 的可信来源
    let clientSource: String
    let path: String

    /// 节点属性里能找到的驱动 bundle id（顶层优先，其次 IOPersonality）
    var driverBundleID: String {
        let a = dashToEmpty(bundleID)
        return a.isEmpty ? dashToEmpty(personalityBundleID) : a
    }
    var driverClass: String { dashToEmpty(ioClass) }
    var provider: String { dashToEmpty(providerClass) }
    var hasClient: Bool { clientPID != nil && clientPID! > 0 }

    private func dashToEmpty(_ s: String) -> String { s == "-" ? "" : s }
}

struct IORegProperty {
    let key: String
    let type: String
    let value: String
}

struct IORegTree {
    var nodes: [IORegNode] = []
    var truncated = false
    var plane: String = "IOService"

    /// parentIndex → 子节点 index（-1 表示根）
    var children: [Int: [Int]] = [:]

    mutating func index() {
        children = [:]
        for n in nodes { children[n.parent, default: []].append(n.index) }
    }
}

struct IORegProperties {
    var rows: [IORegProperty] = []
    var truncated = false
    var error: String?
}

enum IORegistryBrowser {

    /// 常见 registry plane。某个 plane 不存在时树为空，UI 会提示。
    static let planes = [
        "IOService", "IODeviceTree", "IOPower", "IOUSB",
        "IOACPIPlane", "IOFireWire", "IOAudioCodecEngine",
    ]

    /// 专用串行队列：树枚举有几百~几千次 IOKit 调用，不能落在主线程。
    static let queue = DispatchQueue(label: "com.vantage.ioreg", qos: .userInitiated)

    private static func collect(_ l: inout cproc_lines_t) -> [String] {
        guard l.count > 0, l.lines != nil else { return [] }
        var out: [String] = []
        out.reserveCapacity(Int(l.count))
        for i in 0..<Int(l.count) {
            out.append(String(cString: cproc_line(&l, Int32(i))))
        }
        return out
    }

    /// 在新一轮采集前调用，让上一轮枚举尽快从检查点退出。
    static func beginEpoch() -> UInt64 { ProcBridge.beginDetailEpoch() }
    static func markEpoch(_ e: UInt64) { ProcBridge.markDetailEpoch(e) }
    static func cancelEpoch(_ e: UInt64) { ProcBridge.cancelDetailEpoch(e) }

    static func tree(plane: String) -> IORegTree {
        var l = cproc_lines_t()
        let rc = plane.withCString { cproc_ioreg_tree($0, &l) }
        var t = IORegTree(plane: plane)
        guard rc == 0 else { return t }
        defer { cproc_lines_free(&l) }
        let raw = collect(&l)
        for line in raw {
            let f = line.components(separatedBy: "\t")
            if f.first == "META" {
                if f.count > 2 { t.truncated = (f[2] == "1") }
                continue
            }
            guard f.first == "NODE", f.count >= 15 else { continue }
            let hex = f[4].hasPrefix("0x") ? String(f[4].dropFirst(2)) : f[4]
            let pid = Int32(f[11]) ?? 0
            let n = IORegNode(
                index: Int(f[1]) ?? 0,
                parent: Int(f[2]) ?? -1,
                depth: Int(f[3]) ?? 0,
                entryID: UInt64(hex, radix: 16) ?? 0,
                name: f[5],
                className: f[6],
                bundleID: f[7],
                personalityBundleID: f[8],
                ioClass: f[9],
                providerClass: f[10],
                clientPID: pid > 0 ? pid : nil,
                clientName: f[12],
                clientSource: f[13],
                path: f[14])
            t.nodes.append(n)
        }
        t.index()
        return t
    }

    static func properties(path: String) -> IORegProperties {
        var l = cproc_lines_t()
        let rc = path.withCString { cproc_ioreg_properties($0, &l) }
        var out = IORegProperties()
        guard rc == 0 else { return out }
        defer { cproc_lines_free(&l) }
        let raw = collect(&l)
        for line in raw {
            let f = line.components(separatedBy: "\t")
            if f.first == "PMETA" {
                if f.count > 2 { out.truncated = (f[2] == "1") }
                continue
            }
            if f.first == "ERROR" {
                if f.count > 1 { out.error = f[1] }
                continue
            }
            guard f.first == "PROP", f.count >= 4 else { continue }
            out.rows.append(IORegProperty(key: f[1], type: f[2], value: f[3]))
        }
        return out
    }
}
