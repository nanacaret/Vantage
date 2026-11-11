// SPDX-License-Identifier: MIT
import Foundation
import CProc

struct ProcessSnapshot {
    let pid: Int32
    let ppid: Int32
    let uid: Int32
    let gid: Int32
    let nice: Int32
    let priority: Int32
    let status: UInt32
    let flags: UInt32
    let translated: UInt32
    let pgid: UInt32

    let startSec: UInt64
    let startUSec: UInt64
    let rss: UInt64
    let vss: UInt64
    let cpuUserNS: UInt64
    let cpuSysNS: UInt64
    let threads: UInt64
    let faults: UInt64
    let pageins: UInt64
    let cowFaults: UInt64
    let csw: UInt64
    let msgSent: UInt64
    let msgRecv: UInt64
    let sysMach: UInt64
    let sysUnix: UInt64
    let nfiles: UInt64

    // 控制终端（BSD 层，不需要 task port）
    let ttyDev: UInt32
    let ttyTpgid: UInt32
    let ttyPgid: UInt32
    let ttyJobc: UInt32

    let comm: String
    let name: String
    let cmdline: String
    let exepath: String
    let ttyName: String

    // 由 ProcessStore 在差分计算后写入
    var cpuPercent: Double = 0
    var hostARM64: Bool = false

    /// 该进程已从系统进程表消失，当前处于「退出宽限期」内（仍显示在列表中）。
    /// ProcessStore 只在生成可见数据源时克隆并置位，存活进程永远为 false。
    var isExited: Bool = false
    /// 还剩多少次刷新会被移除（用于「状态」列显示）
    var exitRemaining: Int = 0

    /// ps 风格：有控制终端时显示短设备名（ttys001），否则 ??
    var ttyShortName: String {
        guard ttyDev != 0, ttyDev != 0xffff_ffff else { return "??" }
        return (ttyName as NSString).lastPathComponent
    }

    var hasTTY: Bool { ttyDev != 0 && ttyDev != 0xffff_ffff }

    /// 前台 / 后台 / 无终端
    var ttyJobState: String {
        guard hasTTY else { return L("model.noTerminal") }
        guard ttyTpgid != 0, ttyTpgid != 0xffff_ffff else { return L("model.noForegroundGroup") }
        return ttyPgid == ttyTpgid ? L("model.foreground") : L("model.background")
    }

    var cpuTimeNS: UInt64 { cpuUserNS + cpuSysNS }

    var stateName: String { String(cString: cproc_state_name(status)) }

    var userName: String { UserNameCache.shared.name(uid) }

    var isGUIApp: Bool { exepath.contains(".app/Contents/") }

    /// 可执行文件路径所在的 .app bundle（用于取应用图标）
    var bundlePath: String? {
        guard let r = exepath.range(of: ".app/", options: .backwards) else { return nil }
        guard let end = exepath.index(r.lowerBound, offsetBy: 3,
                                      limitedBy: exepath.endIndex) else { return nil }
        return String(exepath[...end])
    }

    /// Bundle / 应用名（不带 .app 后缀）。没有 bundle 时退回 BSD 短名。
    /// 这是主表显示的名称，供图标缓存、树内排序等使用。
    var displayName: String {
        if let b = bundlePath {
            let n = (b as NSString).lastPathComponent
            return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
        }
        if !name.isEmpty { return name }
        if !comm.isEmpty { return comm }
        return "pid \(pid)"
    }

    // ---------------------------------------------------------------
    // 「显示名 vs 真实身份」
    //
    // 同一个 .app 里的 helper（crashpad_handler、XPC、Renderer…）与本进程
    // 共享 bundlePath，只显示 displayName 时全叫「WeChat」。rawName 取可执行
    // 文件名（不受 p_comm 的 16 字符截断影响），用来在名称列同时标注真实身份。
    // ---------------------------------------------------------------

    /// 可执行文件的文件名，例如 crashpad_handler / WeChat / Safari
    var executableName: String {
        guard !exepath.isEmpty else { return "" }
        let n = (exepath as NSString).lastPathComponent
        return n.isEmpty || n == "/" ? "" : n
    }

    /// 原始进程名：优先可执行文件名，再退 BSD 长名 / p_comm 短名
    var rawName: String {
        if !executableName.isEmpty { return executableName }
        if !name.isEmpty { return name }
        if !comm.isEmpty { return comm }
        return ""
    }

    /// Bundle 的本地化显示名（CFBundleDisplayName / CFBundleName），带缓存。
    /// 未开启偏好时不会调用，避免无谓读 plist。
    var localizedAppName: String? {
        guard let b = bundlePath else { return nil }
        return AppNameResolver.localizedName(forBundlePath: b)
    }

    /// 主名称：可选使用真正的本地化名，否则仍是原来的 Bundle / 短名
    var primaryDisplayName: String {
        if Preferences.shared.useLocalizedAppName,
           let n = localizedAppName, !n.isEmpty { return n }
        return displayName
    }

    /// 主表 / 菜单 / 确认框统一使用的名称。
    /// 开启「同时显示原始名」且该进程有 bundle、raw 与主名不同时才追加，
    /// 所以 Safari 主进程仍是「Safari」，不会变成「Safari (Safari)」。
    var displayLabel: String {
        let primary = primaryDisplayName
        guard Preferences.shared.showRawNameWithBundle,
              bundlePath != nil else { return primary }
        let raw = rawName
        guard !raw.isEmpty,
              raw.localizedCaseInsensitiveCompare(primary) != .orderedSame else { return primary }
        return primary + Preferences.shared.rawNameStyle.wrap(raw)
    }

    var archName: String {
        if hostARM64 {
            return translated != 0 ? "Intel (Rosetta 2)" : "Apple Silicon"
        }
        return "Intel"
    }

    var isSystemProcess: Bool { uid == 0 }
    var isStopped: Bool { stateName == "STOPPED" }
}

struct SystemSnapshot {
    var timestampNS: UInt64 = 0
    var logicalCPUs: UInt32 = 1
    var physicalCPUs: UInt32 = 1
    var hostARM64: Bool = false

    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0
    var memFree: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    var threadsTotal: UInt64 = 0
    var procCount: Int32 = 0
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
}

/// NSOutlineView 的树节点（用 class 以便保持对象身份）
final class ProcessNode: NSObject {
    let proc: ProcessSnapshot
    let children: [ProcessNode]
    init(proc: ProcessSnapshot, children: [ProcessNode]) {
        self.proc = proc
        self.children = children
        super.init()
    }
}
