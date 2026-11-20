// SPDX-License-Identifier: MIT
import AppKit
import Darwin
import Foundation

// ---------------------------------------------------------------------
// 启动项 / 后台任务
//
// launchd 的落盘位置决定了「什么时候以谁的身份运行」：
//   /System/Library/LaunchDaemons   系统守护进程（只读，Apple 自带）
//   /System/Library/LaunchAgents    系统代理（登录后按用户运行，Apple 自带）
//   /Library/LaunchDaemons          第三方守护进程（开机即运行，root）
//   /Library/LaunchAgents           第三方代理（任意用户登录后运行）
//   ~/Library/LaunchAgents          单个用户的代理
//   /Library/StartupItems           旧式启动项（10.10 起已废弃，仍可能出现）
//
// 「是否在跑」不看 plist，而看 launchd 域里有没有这个 label：
// `launchctl print system` / `launchctl print gui/<uid>` 的 services 表
// 一行给出 PID + label，一次调用就能覆盖整个域（比逐个 `launchctl list` 快）。
//
// 用户家目录走 getpwent()：libc 的这个入口在 macOS 上就是 opendirectoryd
// （DirectoryService）的客户端，能拿到本地账户和绑定的目录账户的
// NFSHomeDirectory —— 不需要自己拼 dscl 命令。
// ---------------------------------------------------------------------

struct LaunchItem {
    enum Kind: String {
        case daemon, agent, startupItem

        var title: String {
            switch self {
            case .daemon:      return L("launch.kindDaemon")
            case .agent:       return L("launch.kindAgent")
            case .startupItem: return L("launch.kindStartupItem")
            }
        }
    }

    let label: String
    let kind: Kind
    /// 作用域展示名：系统 / 当前用户 / 具体用户名
    let scope: String
    /// 运行这个条目的 launchd 域（system / gui/<uid>）
    let domain: String
    let uid: uid_t
    let program: String
    let trigger: String
    let path: String
    /// 是否在 launchd 里注册过
    let loaded: Bool
    /// 已注册且正在运行的 pid（0 = 已注册未运行）
    let pid: pid_t
    /// plist 的 Disabled 键或 launchd 的 disabled 数据库
    let disabled: Bool
    /// 排序用：系统 0 / 所有用户 1 / 当前用户 2 / 其他用户 3
    let scopeRank: Int
    /// 原始 plist（详情面板要把每一关键出来）
    let raw: [String: Any]

    /// 可写（/System 下的由 SIP 保护，只读展示）
    var isEditable: Bool { !path.hasPrefix("/System/") }

    /// Apple 自带（不提供卸载/禁用入口，避免把系统弄坏）
    var isApple: Bool {
        path.hasPrefix("/System/") || label.hasPrefix("com.apple.")
    }

    var stateText: String {
        if disabled { return L("launch.stateDisabled") }
        if !loaded { return L("launch.stateNotLoaded") }
        if pid > 0 { return L("launch.stateRunning", Int(pid)) }
        return L("launch.stateLoaded")
    }

    var row: [String] { [scope, label, kind.title, program, trigger,
                         stateText, path] }

    // -----------------------------------------------------------------
    // 详情（右侧 / 下方面板）
    //
    // 列表只能看出「有个守护进程叫 com.foo.bar」，真正判断它做什么要看
    // plist：程序 + 参数、触发条件、运行身份、日志路径、Mach 服务名。
    // 这里把 plist 摊平成「项目 / 值」，键名保持原样（技术字段翻译反而更难查）。
    // -----------------------------------------------------------------

    func detailRows() -> [(String, String)] {
        var used: Set<String> = []
        var out: [(String, String)] = []

        func add(_ key: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return }
            out.append((key, v))
        }

        func take(_ key: String) {
            used.insert(key)
            add(key, Self.text(raw[key]))
        }

        add(L("launch.detScope"), "\(scope)  ·  \(domain)")
        add(L("launch.detType"), kind.title)
        add(L("launch.detState"), stateText)
        add(L("launch.detPath"), path)

        // 程序与参数分开列，参数逐条编号（判断「到底在跑什么」最有用）
        if let args = raw["ProgramArguments"] as? [Any] {
            used.insert("ProgramArguments")
            let list = args.map { Self.text($0) }
            if let first = list.first { add(L("launch.detProgram"), first) }
            for (i, a) in list.enumerated() where i > 0 {
                add("  \(L("launch.detArg")) \(i)", a)
            }
        }
        if raw["Program"] != nil { take("Program") }
        if raw["BundleProgram"] != nil { take("BundleProgram") }

        // 触发条件：结构化的展开，别塞成一行 JSON
        if let v = raw["KeepAlive"] {
            used.insert("KeepAlive")
            add("KeepAlive", Self.describe(v))
        }
        for key in ["StartInterval", "StartCalendarInterval", "WatchPaths",
                    "QueueDirectories", "Sockets", "MachServices",
                    "RunAtLoad", "LaunchEvents", "ProcessType",
                    "LimitLoadToSessionType", "SessionCreate",
                    "LowPriorityIO", "Nice", "AbandonProcessGroup",
                    "EnableTransactions", "ThrottleInterval",
                    "ExitTimeOut", "TimeOut"] {
            if raw[key] != nil { take(key) }
        }

        // 运行身份与工作目录
        for key in ["UserName", "GroupName", "InitGroups", "Umask",
                    "WorkingDirectory", "RootDirectory"] {
            if raw[key] != nil { take(key) }
        }

        // 日志与重定向
        for key in ["StandardOutPath", "StandardErrorPath",
                    "StandardInPath", "EnvironmentVariables"] {
            if raw[key] != nil { take(key) }
        }

        // 剩下的键全部展开，保证「plist 里有什么这里就看得到什么」
        for key in raw.keys.sorted() where !used.contains(key) {
            let v = raw[key]
            if let d = v as? [String: Any] {
                for (k, sub) in Self.flatten(d, prefix: key).sorted(by: { $0.0 < $1.0 }) {
                    add(k, sub)
                }
            } else {
                add(key, Self.text(v))
            }
        }
        return out
    }

    /// 标量 / 数组 / 字典 → 一行文本
    private static func text(_ v: Any?) -> String {
        switch v {
        case nil:            return ""
        case let b as Bool:  return b ? "true" : "false"
        case let s as String: return s
        case let a as [Any]:
            return a.map { text($0) }.joined(separator: ", ")
        case let d as [String: Any]:
            return flatten(d).map { "\($0.0)=\($0.1)" }
                .sorted().joined(separator: " · ")
        default:             return "\(v!)"
        }
    }

    /// KeepAlive / 字典类键的人话解释
    private static func describe(_ v: Any) -> String {
        if let b = v as? Bool { return b ? "true" : "false" }
        guard let d = v as? [String: Any] else { return text(v) }
        return flatten(d).sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: " · ")
    }

    private static func flatten(_ d: [String: Any], prefix: String = "")
        -> [(String, String)] {
        var out: [(String, String)] = []
        for (k, v) in d {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let sub = v as? [String: Any] {
                // MachServices 常见 `"com.foo" => true`：值也一并给出来
                if sub.isEmpty {
                    out.append((key, ""))
                } else {
                    out += flatten(sub, prefix: key)
                }
            } else if let arr = v as? [Any] {
                out.append((key, arr.map { text($0) }.joined(separator: ", ")))
            } else {
                out.append((key, text(v)))
            }
        }
        return out
    }
}

enum LaunchItemsReader {

    // -----------------------------------------------------------------
    // 目录
    // -----------------------------------------------------------------

    private static let systemDaemons = "/System/Library/LaunchDaemons"
    private static let systemAgents = "/System/Library/LaunchAgents"
    private static let localDaemons = "/Library/LaunchDaemons"
    private static let localAgents = "/Library/LaunchAgents"
    private static let startupItems = "/Library/StartupItems"
    private static let systemStartupItems = "/System/Library/StartupItems"

    /// 一个待扫描的目录
    private struct Directory {
        let path: String
        let kind: LaunchItem.Kind
        /// 归属用户；nil = 系统域（daemon）或「所有用户」（agent 目录）
        let owner: (uid: uid_t, name: String)?
        let scopeTitle: String
        let domain: String
        /// 目录是否属于「当前用户」（决定作用域文案）
        let isCurrentUser: Bool
        /// 排序权重：守护进程 0 / 本机代理 1 / 当前用户 2 / 其他用户 3
        let rank: Int
    }

    // -----------------------------------------------------------------
    // 主入口
    // -----------------------------------------------------------------

    /// 扫描全部启动项。
    /// - 普通权限：系统目录 + 当前用户目录
    /// - root：额外扫描所有用户家目录里的 LaunchAgents
    static func scan() -> [LaunchItem] {
        let dirs = directories()
        var items: [LaunchItem] = []

        // 每个域只查一次 launchd 状态
        var domains: [String: [String: pid_t]] = [:]
        for d in dirs where domains[d.domain] == nil {
            domains[d.domain] = loadedServices(domain: d.domain)
        }
        // 禁用状态（label → true）按作用域分别读
        var disabledMaps: [uid_t: Set<String>] = [:]
        for d in dirs {
            if disabledMaps[d.owner?.uid ?? 0] == nil {
                disabledMaps[d.owner?.uid ?? 0] =
                    disabledLabels(uid: d.owner?.uid)
            }
        }

        for d in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(
                atPath: d.path)) ?? []
            for file in files.sorted() {
                guard file.hasSuffix(".plist") || d.kind == .startupItem else {
                    continue
                }
                let full = d.path + "/" + file
                if d.kind == .startupItem {
                    items.append(startupItem(full, file: file, dir: d))
                    continue
                }
                guard let item = launchdItem(full, dir: d,
                                             status: domains[d.domain] ?? [:],
                                             disabled: disabledMaps[d.owner?.uid ?? 0] ?? [])
                else { continue }
                items.append(item)
            }
        }

        // 系统 → 所有用户 → 当前用户 → 其他用户；同作用域按 label 排
        return items.sorted { a, b in
            if a.scopeRank != b.scopeRank { return a.scopeRank < b.scopeRank }
            if a.scope != b.scope { return a.scope < b.scope }
            if a.label != b.label { return a.label < b.label }
            return a.path < b.path
        }
    }

    // -----------------------------------------------------------------
    // 目录清单
    // -----------------------------------------------------------------

    private static func directories() -> [Directory] {
        let me = getuid()
        let myName = NSUserName()
        var out: [Directory] = [
            Directory(path: systemDaemons, kind: .daemon, owner: nil,
                      scopeTitle: L("launch.scopeSystem"), domain: "system",
                      isCurrentUser: false, rank: 0),
            Directory(path: localDaemons, kind: .daemon, owner: nil,
                      scopeTitle: L("launch.scopeSystem"), domain: "system",
                      isCurrentUser: false, rank: 0),
            Directory(path: systemAgents, kind: .agent, owner: nil,
                      scopeTitle: L("launch.scopeAllUsers"), domain: "system",
                      isCurrentUser: false, rank: 1),
            Directory(path: localAgents, kind: .agent, owner: nil,
                      scopeTitle: L("launch.scopeAllUsers"), domain: "system",
                      isCurrentUser: false, rank: 1),
        ]

        // 当前用户的代理：始终显示（普通权限就能读自己的家目录）
        out.append(Directory(
            path: NSHomeDirectory() + "/Library/LaunchAgents",
            kind: .agent, owner: (me, myName),
            scopeTitle: L("launch.scopeCurrentUser"),
            domain: "gui/\(me)", isCurrentUser: true, rank: 2))

        // 已提权：按 DirectoryService 的家目录列出其他用户
        if Privilege.isRoot {
            for user in allUsers() where user.uid != me {
                out.append(Directory(
                    path: user.home + "/Library/LaunchAgents",
                    kind: .agent, owner: (user.uid, user.name),
                    scopeTitle: user.name,
                    domain: "gui/\(user.uid)", isCurrentUser: false, rank: 3))
            }
        }

        // 旧式启动项（很少见，存在时才加）
        for (dir, scope) in [(startupItems, L("launch.scopeSystem")),
                             (systemStartupItems, L("launch.scopeSystem"))] {
            if FileManager.default.fileExists(atPath: dir) {
                out.append(Directory(path: dir, kind: .startupItem,
                                     owner: nil, scopeTitle: scope,
                                     domain: "system", isCurrentUser: false,
                                     rank: 0))
            }
        }
        return out
    }

    /// 所有「有真实家目录」的用户（getpwent → opendirectoryd）
    private static func allUsers() -> [(uid: uid_t, name: String, home: String)] {
        var out: [(uid_t, String, String)] = []
        setpwent()
        while let pw = getpwent() {
            let home = String(cString: pw.pointee.pw_dir)
            let name = String(cString: pw.pointee.pw_name)
            let uid = pw.pointee.pw_uid
            // 系统账户（_windowserver、_spotlight…）家的 /var/empty 没有意义
            guard uid >= 500 || home.hasPrefix("/Users/") else { continue }
            guard !home.isEmpty, home != "/", home != "/var/empty" else {
                continue
            }
            out.append((uid, name, home))
        }
        endpwent()
        return out
            .filter { FileManager.default.fileExists(
                atPath: $0.2 + "/Library/LaunchAgents") }
            .map { (uid: $0.0, name: $0.1, home: $0.2) }
    }

    // -----------------------------------------------------------------
    // plist 解析
    // -----------------------------------------------------------------

    private static func launchdItem(_ path: String, dir: Directory,
                                    status: [String: pid_t],
                                    disabled: Set<String>) -> LaunchItem? {
        guard let dict = plist(path) else { return nil }
        guard let label = dict["Label"] as? String, !label.isEmpty else {
            return nil
        }

        var program = ""
        if let p = dict["Program"] as? String {
            program = p
        } else if let args = dict["ProgramArguments"] as? [Any],
                  let first = args.first as? String {
            program = first
        } else if dir.kind == .agent {
            // 只声明了 MachServices / Sockets 的代理没有程序路径
            program = dict["BundleProgram"] as? String ?? ""
        }
        if program.isEmpty { program = dict["BundleProgram"] as? String ?? "" }

        let pid = status[label] ?? 0
        let inPlistDisabled = (dict["Disabled"] as? Bool) ?? false

        return LaunchItem(
            label: label,
            kind: dir.kind,
            scope: dir.scopeTitle,
            domain: dir.domain,
            uid: dir.owner?.uid ?? 0,
            program: program,
            trigger: triggerText(dict),
            path: path,
            loaded: status[label] != nil,
            pid: pid,
            disabled: inPlistDisabled || disabled.contains(label),
            scopeRank: scopeRank(of: dir),
            raw: dict)
    }

    /// 旧式 StartupItems：一个目录里放同名可执行文件 + StartupParameters.plist
    private static func startupItem(_ path: String, file: String,
                                    dir: Directory) -> LaunchItem {
        let params = plist(path + "/StartupParameters.plist")
        let label = (params?["Description"] as? String) ?? file
        return LaunchItem(label: label, kind: .startupItem, scope: dir.scopeTitle,
                          domain: dir.domain, uid: 0, program: path + "/" + file,
                          trigger: "StartupItem", path: path, loaded: false,
                          pid: 0, disabled: false, scopeRank: 0,
                          raw: params ?? [:])
    }

    private static func scopeRank(of dir: Directory) -> Int { dir.rank }

    private static func plist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? [String: Any]
    }

    /// 把各种触发条件压成一行
    private static func triggerText(_ d: [String: Any]) -> String {
        var parts: [String] = []
        if (d["RunAtLoad"] as? Bool) == true { parts.append("RunAtLoad") }
        if let keep = d["KeepAlive"] {
            if let b = keep as? Bool, b { parts.append("KeepAlive") }
            else if keep is [String: Any] {
                parts.append(L("launch.triggerKeepAliveCond"))
            }
        }
        if let n = d["StartInterval"] as? Int {
            parts.append(L("launch.triggerEvery", n))
        }
        if d["StartCalendarInterval"] != nil {
            parts.append(L("launch.triggerCalendar"))
        }
        if d["WatchPaths"] != nil { parts.append("WatchPaths") }
        if d["QueueDirectories"] != nil { parts.append("QueueDirectories") }
        if d["Sockets"] != nil { parts.append("Sockets") }
        if d["MachServices"] != nil { parts.append("MachServices") }
        if let t = d["ProcessType"] as? String { parts.append(t) }
        if (d["Disabled"] as? Bool) == true { parts.append("Disabled") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // -----------------------------------------------------------------
    // launchd 状态
    // -----------------------------------------------------------------

    /// 解析 `launchctl print <domain>` 的 services 表：label → pid。
    /// 表格每行形如 `   22152   (pe)  com.apple.assetsubscriptiond`。
    static func loadedServices(domain: String) -> [String: pid_t] {
        guard let text = runLaunchctl(["print", domain]) else { return [:] }
        var out: [String: pid_t] = [:]
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("services = {") { inside = true; continue }
            guard inside else { continue }
            if trimmed == "}" { break }
            // 形如 `   22152   (pe)\tcom.apple.assetsubscriptiond`：
            // 列之间既有空格也有 tab，flags 还可能占两列（`0  M  D  label`），
            // 所以按「第一列是 pid、最后一列是 label」解析，中间全当 flags。
            let cols = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 2, let pid = pid_t(cols[0]),
                  let label = cols.last else { continue }
            out[String(label)] = pid
        }
        return out
    }

    /// launchd 的禁用数据库：/var/db/com.apple.xpc.launchd/disabled.<uid>.plist
    /// （system 域是 disabled.system.plist）。读不到就当没有。
    static func disabledLabels(uid: uid_t?) -> Set<String> {
        let path = "/var/db/com.apple.xpc.launchd/"
            + (uid == nil ? "disabled.system.plist" : "disabled.\(uid!).plist")
        guard let d = plist(path) else { return [] }
        return Set(d.compactMap { key, value in
            (value as? Bool) == true ? key : nil
        })
    }

    // -----------------------------------------------------------------
    // 写操作（加载 / 卸载 / 启用 / 禁用）
    // -----------------------------------------------------------------

    enum Action {
        case load, unload, enable, disable

        var title: String {
            switch self {
            case .load:    return L("launch.load")
            case .unload:  return L("launch.unload")
            case .enable:  return L("launch.enable")
            case .disable: return L("launch.disable")
            }
        }
    }

    /// 执行一次 launchctl 子命令。system 域需要 root，这里统一走
    /// Privilege.run（已 root 直接执行，否则弹系统授权框）。
    static func perform(_ action: Action, on item: LaunchItem)
        -> (rc: Int32, output: String) {
        let label = item.label
        switch action {
        case .load:
            return Privilege.run(tool: "/bin/launchctl",
                                 args: ["bootstrap", item.domain, item.path])
        case .unload:
            return Privilege.run(tool: "/bin/launchctl",
                                 args: ["bootout", "\(item.domain)/\(label)"])
        case .enable:
            return Privilege.run(tool: "/bin/launchctl",
                                 args: ["enable", "\(item.domain)/\(label)"])
        case .disable:
            return Privilege.run(tool: "/bin/launchctl",
                                 args: ["disable", "\(item.domain)/\(label)"])
        }
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
