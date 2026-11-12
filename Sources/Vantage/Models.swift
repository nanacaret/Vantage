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
    /// Mach-O 架构切片位掩码（CProc.h 的 CPROC_ARCH_*）；0 = 读不到文件头
    let execArchs: UInt32
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
    /// KERN_PROCARGS2 里的原始 argv[0]（可能与规范可执行路径不同）
    let argv0: String
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

    /// argv[0] 的文件名部分（不含目录）。保留登录 shell 的前导 `-`，
    /// 因为那正是 argv[0] 与原名不同的地方；完整值在 tooltip / 概览页可见。
    var argv0Name: String {
        guard !argv0.isEmpty else { return "" }
        /* C 层缓冲区 1024 字节；长度贴顶说明已被截断，半截 basename 反而误导，
         * 完整（截断）值仍可在 tooltip / 概览页查看。 */
        guard argv0.utf8.count < 1020 else { return "" }
        let n = (argv0 as NSString).lastPathComponent
        return n.isEmpty || n == "/" ? argv0 : n
    }

    /// 「argv[0] 与 bin 不同」是否值得在名称列追加。
    /// 比较基准是真实可执行文件的 basename（无 exepath 时退回 rawName），
    /// 同时排除与主名、raw 名重复，避免出现 `bash (bash)` 这类自扰。
    var showsArgv0Name: Bool {
        guard Preferences.shared.showArgv0WhenDifferent else { return false }
        let a = argv0Name
        guard !a.isEmpty else { return false }
        let bin = executableName.isEmpty ? rawName : executableName
        for s in [bin, primaryDisplayName, rawName] {
            if !s.isEmpty,
               a.localizedCaseInsensitiveCompare(s) == .orderedSame { return false }
        }
        return true
    }

    /// Info.plist 里 bundle 声明的主可执行文件名。
    /// 与 bundle 目录名、实际 exepath 的 basename、argv[0] 是四个独立事实：
    /// 例如 Visual Studio Code.app 声明 Electron、实际 exe 也是 Electron，
    /// 但通过 symlink 调用时 argv[0] 可以是 Code。
    var bundleExecutableName: String {
        guard let b = bundlePath else { return "" }
        return AppNameResolver.bundleExecutable(forBundlePath: b) ?? ""
    }

    /// 当前可执行文件是否就是该 bundle 声明的主程序（否则是 helper / 子组件）。
    /// helper 常常与 bundle 同名显示、却完全是另一个二进制，这正是需要标注的原因。
    var isBundleMainExecutable: Bool {
        guard let b = bundlePath,
              !bundleExecutableName.isEmpty,
              !executableName.isEmpty else { return false }
        let suffix = "/Contents/MacOS/" + bundleExecutableName
        return exepath == (b + suffix) || exepath.hasSuffix(suffix)
    }

    /// 有 bundle 时给出「主程序 / helper」；没有 bundle 时返回 nil。
    var bundleRoleText: String? {
        guard bundlePath != nil else { return nil }
        if bundleExecutableName.isEmpty { return L("model.bundleRoleUnknown") }
        return isBundleMainExecutable
            ? L("model.bundleRoleMain") : L("model.bundleRoleHelper")
    }

    /// 名称列的 hover 说明：把四个名字分开列，不再让人靠括号猜哪个是哪个。
    var identitySummary: String {
        L("model.identityTooltip",
          displayName.isEmpty ? "—" : displayName,
          bundleExecutableName.isEmpty ? "—" : bundleExecutableName,
          executableName.isEmpty ? "—" : executableName,
          argv0Name.isEmpty ? "—" : argv0Name)
    }

    /// 主表 / 菜单 / 确认框统一使用的名称。
    /// 两段追加相互独立：
    ///  - raw：有 bundle 且可执行短名与主名不同（helper 的真实身份）
    ///  - argv[0]：与 bin 不同（硬链接 /bin/sh→/bin/bash、exec -a、-bash…）
    ///
    /// 关键组合：bundle、exe、argv[0] 三者互不相同时，如果两个括注都用同一
    /// 格式，读起来是 `Visual Studio Code (Electron) (Code)`，分不出哪个是
    /// 可执行文件、哪个只是调用名。所以只有 argv[0] 单独出现时才沿用
    /// rawNameStyle；与 raw 并列时改用文字标签（「以 X 调用」/「as X」）。
    var displayLabel: String {
        let primary = primaryDisplayName
        let p = Preferences.shared
        var label = primary
        var appendedRaw = false
        if p.showRawNameWithBundle, bundlePath != nil {
            let raw = rawName
            if !raw.isEmpty,
               raw.localizedCaseInsensitiveCompare(primary) != .orderedSame {
                label += p.rawNameStyle.wrap(raw)
                appendedRaw = true
            }
        }
        if showsArgv0Name {
            label += appendedRaw
                ? " " + L("model.argv0Alias", argv0Name)
                : p.rawNameStyle.wrap(argv0Name)
        }
        return label
    }

    /// 与 CProc.h 的 CPROC_ARCH_* 一一对应。这里用 Swift 本地常量而不是
    /// 直接引用 C 宏，是为了不依赖 Clang importer 对 `0x0008u` 这类宏的
    /// 类型推断；生成器的静态校验会核对两边数值完全一致。
    private enum ArchBits {
        static let x86: UInt32      = 0x0001
        static let x86_64: UInt32   = 0x0002
        static let arm: UInt32      = 0x0004
        static let arm64: UInt32    = 0x0008
        static let arm64_32: UInt32 = 0x0010
        static let ppc: UInt32      = 0x0020
        static let ppc64: UInt32    = 0x0040
        static let arm64e: UInt32   = 0x0100
        static let other: UInt32    = 0x8000
    }

    // ---------------------------------------------------------------
    // 架构（Activity Monitor「种类」列的语义）：先看可执行文件本身含哪些
    // Mach-O slice，再把「运行时经 Rosetta」作为附加标注。
    //
    // 旧实现只看 host_arm64 + pbi_flags，而 pbi_flags 里并不存在公开的
    // Rosetta 位；兜底的 0x2000 其实是 PROC_FLAG_PSUGID（setuid 提权），
    // 于是 /usr/bin/sudo 这类通用二进制被整批显示成 "Intel (Rosetta 2)"。
    // ---------------------------------------------------------------

    private var archArmBits: UInt32 {
        ArchBits.arm64 | ArchBits.arm64e |
        ArchBits.arm64_32 | ArchBits.arm
    }

    private var archX86Bits: UInt32 {
        ArchBits.x86 | ArchBits.x86_64
    }

    private var archPPCBits: UInt32 {
        ArchBits.ppc | ArchBits.ppc64
    }

    var archName: String {
        let a = execArchs
        let base: String
        if a == 0 {
            // 读不到 Mach-O 头（脚本 / 受保护路径 / 进程已退出）：只说主机类别，
            // 不猜 Rosetta，也不把「未知」伪装成某种架构。
            base = hostARM64 ? L("model.arch.appleSilicon") : L("model.arch.intel")
        } else if (a & archArmBits) != 0 && (a & archX86Bits) != 0 {
            base = L("model.arch.universal")
        } else if (a & archArmBits) != 0 {
            base = L("model.arch.appleSilicon")
        } else if (a & ArchBits.x86_64) != 0 {
            base = L("model.arch.intel")
        } else if (a & ArchBits.x86) != 0 {
            base = L("model.arch.intel32")
        } else if (a & archPPCBits) != 0 {
            base = L("model.arch.powerPC")
        } else {
            base = L("model.arch.other")
        }
        return translated != 0
            ? base + " (" + L("model.arch.rosetta2") + ")" : base
    }

    /// 具体 slice 列表，例如 `arm64e + x86_64`。列宽只放得下主类别时用它补充。
    var archSlices: String {
        let a = execArchs
        var parts: [String] = []
        if a & ArchBits.arm64e != 0 { parts.append("arm64e") }
        else if a & ArchBits.arm64 != 0 { parts.append("arm64") }
        if a & ArchBits.arm64_32 != 0 { parts.append("arm64_32") }
        if a & ArchBits.arm != 0 { parts.append("armv7") }
        if a & ArchBits.x86_64 != 0 { parts.append("x86_64") }
        if a & ArchBits.x86 != 0 { parts.append("i386") }
        if a & ArchBits.ppc64 != 0 { parts.append("ppc64") }
        if a & ArchBits.ppc != 0 { parts.append("ppc") }
        if a & ArchBits.other != 0 { parts.append(L("model.arch.other")) }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    /// 主表架构列的 hover 说明：把「二进制」与「运行时」分开讲清楚。
    var archTooltip: String {
        if execArchs == 0 { return L("model.arch.tooltipUnknown") }
        var s = L("model.arch.tooltipSlices", archSlices)
        if translated != 0 {
            s += "\n" + L("model.arch.tooltipRosetta")
        } else if (execArchs & archArmBits) != 0 &&
                    (execArchs & archX86Bits) != 0 {
            s += "\n" + L("model.arch.tooltipUniversal")
        }
        return s
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
