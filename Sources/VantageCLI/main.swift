// SPDX-License-Identifier: MIT
import Foundation
import VantageKit
#if canImport(Darwin)
import Darwin
#endif

// ---------------------------------------------------------------------
// vantage —— 命令行前端
//
// 与 GUI / vantage-mcp 共用同一套采集层（CProc）与数据桥（VantageKit），
// 不依赖 GUI 是否在运行。默认命令是 list，输出对齐的等宽表；`--json`
// 给脚本用。
//
// 设计取舍：
//   * 不做交互式 TUI（那是 GUI 的活），只做「一次调用 → 一份输出」；
//   * 文本面向人、JSON 面向机器，两者字段同名，避免两套词汇；
//   * 语言跟随 LANG（C 层双语标记在这里解码），默认英文。
// ---------------------------------------------------------------------

// MARK: - 输出

let stdout = FileHandle.standardOutput
let stderr = FileHandle.standardError

// 自己的调用名：bundle 里是 Contents/MacOS/bin/vantage，SPM 产物是 vantage-cli。
// 版本行跟着 argv[0] 走，`--version` 不会自称一个用户敲不出来的名字。
let selfName: String = {
    let invoked = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? ""
    return invoked.isEmpty ? "vantage" : invoked
}()

func writeOut(_ s: String) {
    stdout.write(Data(s.utf8))
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    stderr.write(Data((selfName + ": " + message + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    writeOut("""
    vantage — macOS process explorer, from the terminal

    USAGE
      vantage [list] [options]           List processes (default command)
      vantage info <pid> [--json]        One process: identity, memory, CPU, command
      vantage detail <pid> <kind> [-n N] One inspector page, same collector as the GUI
      vantage tree [options]             Process tree
      vantage stats [--json]             System overview (CPU, memory, swap, load)
      vantage net [ifaces|addrs|routes]  Network interfaces / addresses / routes
      vantage signal <pid> <SIG>         Send a signal (TERM, KILL, HUP, 15, 9 …)
      vantage help | --version

    GLOBAL
      --json                 Machine-readable output
      --lang zh|en           Override language (default: follow LANG, else en)
      -h, --help

    LIST / TREE OPTIONS
      -f, --filter PATTERN   Substring match on name, command line and pid
      -u, --user USER        Only this user (name or uid)
      -s, --sort KEY         pid | cpu | mem | threads | name      (default: pid)
      -n, --limit N          Show at most N rows                     (default: all)
      -r, --reverse          Reverse the order
          --wide             Do not truncate the command column

    DETAIL KINDS
      files  env  images  sockets  monitoring  regions  pipes  tty  threads  mach  audit

    EXAMPLES
      vantage -f Chrome -s mem -n 10
      vantage info 1 --json
      vantage detail 501 threads
      vantage tree -f launchd
      vantage signal 1234 TERM

    """)
    exit(0)
}

// MARK: - 参数

struct Options {
    var json = false
    var lang: Bilingual.Language = Bilingual.detectLanguage()
    var filter: String?
    var user: String?
    var sort = "pid"
    var limit: Int?
    var reverse = false
    var wide = false
    var positional: [String] = []
}

func parse(_ argv: [String]) -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) -> String {
        guard i + 1 < argv.count else { fail("\(flag) requires a value", code: 1) }
        i += 1
        return argv[i]
    }
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--json":              o.json = true
        case "-h", "--help":        usage()
        case "-r", "--reverse":     o.reverse = true
        case "--wide":              o.wide = true
        case "-f", "--filter":      o.filter = value(a)
        case "-u", "--user":        o.user = value(a)
        case "-s", "--sort":        o.sort = value(a)
        case "-n", "--limit":
            let v = value(a)
            guard let n = Int(v) else { fail("--limit expects a number", code: 1) }
            o.limit = n
        case "--lang":              guard let l = Bilingual.language(from: value(a))
                                        else { fail("--lang expects zh or en", code: 1) }
                                    o.lang = l
        default:
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                let key = String(a[..<eq]), v = String(a[a.index(after: eq)...])
                switch key {
                case "--filter": o.filter = v
                case "--user":   o.user = v
                case "--sort":   o.sort = v
                case "--limit":
                    guard let n = Int(v) else { fail("--limit expects a number", code: 1) }
                    o.limit = n
                case "--lang":   guard let l = Bilingual.language(from: v)
                                    else { fail("--lang expects zh or en", code: 1) }
                                 o.lang = l
                default: fail("unknown option: \(key)", code: 1)
                }
            } else if a.hasPrefix("-"), a.count > 1, a != "-" {
                fail("unknown option: \(a)", code: 1)
            } else {
                o.positional.append(a)
            }
        }
        i += 1
    }
    return o
}

// MARK: - JSON 辅助

func jsonData(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj,
                                options: [.sortedKeys, .prettyPrinted]))
        ?? Data("{}".utf8)
}

/// JSON 里「读不到」用 null 表示，而不是假的 0
func num(_ ok: Bool, _ v: UInt64) -> Any { ok ? v : NSNull() }

func emitJSON(_ obj: Any) {
    stdout.write(jsonData(obj))
    stdout.write(Data("\n".utf8))
}

func intArg(_ s: String?, _ what: String) -> Int32 {
    guard let s = s, let v = Int32(s) else { fail("\(what) expects a number", code: 1) }
    return v
}

// MARK: - 进程列表

struct Row {
    let p: ProcInfo
    let user: String
    let depth: Int
}

func loadProcesses() -> (procs: [ProcInfo], sys: SysInfo) {
    guard let snap = SystemBridge.processes() else {
        fail("failed to collect process list (sysctl KERN_PROC)")
    }
    return snap
}

func matches(_ p: ProcInfo, needle: String?, user: String?, userName: String) -> Bool {
    if let n = needle?.lowercased(), !n.isEmpty {
        let hit = p.comm.lowercased().contains(n)
            || p.name.lowercased().contains(n)
            || p.cmdline.lowercased().contains(n)
            || String(p.pid) == n
        if !hit { return false }
    }
    if let u = user?.lowercased(), !u.isEmpty {
        if userName.lowercased() != u, String(p.uid) != u { return false }
    }
    return true
}

/// 按 ppid 关系排出「父在前、子随后」的顺序，并给出缩进层级。
func treeOrder(_ procs: [ProcInfo]) -> [Row] {
    let byParent = Dictionary(grouping: procs, by: { $0.ppid })
    var out: [Row] = []
    out.reserveCapacity(procs.count)
    var seen = Set<Int32>()

    func walk(_ p: ProcInfo, depth: Int) {
        guard !seen.contains(p.pid) else { return }
        seen.insert(p.pid)
        out.append(Row(p: p, user: SystemBridge.userName(p.uid), depth: depth))
        for c in (byParent[p.pid] ?? []).sorted(by: { $0.pid < $1.pid }) {
            if c.pid != p.pid { walk(c, depth: depth + 1) }
        }
    }
    // 根：ppid 为 0（kernel_task / launchd）或父进程不在快照里
    let ids = Set(procs.map(\.pid))
    for p in procs.sorted(by: { $0.pid < $1.pid })
    where !ids.contains(p.ppid) || p.ppid == p.pid {
        walk(p, depth: 0)
    }
    for p in procs.sorted(by: { $0.pid < $1.pid }) where !seen.contains(p.pid) {
        walk(p, depth: 0)
    }
    return out
}

func sortedRows(_ rows: [Row], by key: String) -> [Row] {
    switch key {
    // cpu = 累计 CPU 时间（一次采样拿不到瞬时占用率，这一点和 ps 一致）
    case "cpu", "time": return rows.sorted { $0.p.cpuTimeNS > $1.p.cpuTimeNS }
    case "mem", "rss": return rows.sorted { $0.p.rss > $1.p.rss }
    case "threads": return rows.sorted { $0.p.threads > $1.p.threads }
    case "name":    return rows.sorted { $0.p.comm.localizedCompare($1.p.comm) == .orderedAscending }
    case "pid":     return rows.sorted { $0.p.pid < $1.p.pid }
    default:        fail("unknown sort key: \(key) (pid|cpu|mem|threads|name)", code: 1)
    }
}

func cmdList(_ o: Options, tree: Bool) {
    let (procs, _) = loadProcesses()
    var rows: [Row]

    let filterNeedle = o.filter
    if tree {
        let all = treeOrder(procs)
        let hit = all.filter {
            matches($0.p, needle: filterNeedle, user: o.user, userName: $0.user)
        }
        // 树里只留命中行会丢掉层级上下文：把它们的祖先一并带上，
        // 「某个进程挂在谁下面」才看得出来
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var keep = Set<Int32>()
        for r in hit {
            var cur: ProcInfo? = r.p
            while let c = cur, !keep.contains(c.pid) {
                keep.insert(c.pid)
                cur = byPid[c.ppid]
            }
        }
        rows = all.filter { keep.contains($0.p.pid) }
    } else {
        rows = procs.map { Row(p: $0, user: SystemBridge.userName($0.uid), depth: 0) }
            .filter { matches($0.p, needle: filterNeedle, user: o.user, userName: $0.user) }
        rows = sortedRows(rows, by: o.sort)
    }
    if o.reverse { rows.reverse() }
    let total = rows.count
    // 直接敲 `vantage` 时不要刷 700 行；管道 / 重定向时保持全量，脚本不受影响
    let defaultLimit = isatty(STDOUT_FILENO) != 0 ? 40 : nil
    let limit = o.limit ?? defaultLimit
    if let n = limit { rows = Array(rows.prefix(max(0, n))) }
    let hidden = total - rows.count

    if o.json {
        emitJSON(rows.map { r -> [String: Any] in
            var d: [String: Any] = [
                "pid": Int(r.p.pid), "ppid": Int(r.p.ppid), "uid": Int(r.p.uid),
                "user": r.user, "name": r.p.name, "comm": r.p.comm,
                "state": r.p.state, "readable": r.p.taskinfoOK,
                "rss": num(r.p.taskinfoOK, r.p.rss),
                "vss": num(r.p.taskinfoOK, r.p.vss),
                "threads": num(r.p.taskinfoOK, r.p.threads),
                "cpuTimeNS": num(r.p.taskinfoOK, r.p.cpuTimeNS),
                "started": Int(r.p.startSec), "tty": r.p.tty,
                "pgid": Int(r.p.pgid), "nice": Int(r.p.nice),
                "exe": r.p.exepath, "cmdline": r.p.cmdline,
            ]
            if tree { d["depth"] = r.depth }
            return d
        })
        return
    }

    let headers = tree
        ? ["PID", "PPID", "USER", "THR", "MEM", "COMMAND"]
        : ["PID", "PPID", "USER", "STATE", "THR", "MEM", "TIME", "COMMAND"]
    // taskinfo 读不到时（别人的进程 / SIP 保护）显示 "—"：
    // 0 会让人误以为这个进程真的没占内存、没开线程
    let body: [[String]] = rows.map { r in
        let cmd = r.p.cmdline.isEmpty ? r.p.exeFallback : r.p.cmdline
        let thr = r.p.taskinfoOK ? "\(r.p.threads)" : "—"
        let mem = r.p.taskinfoOK ? Human.bytes(r.p.rss) : "—"
        if tree {
            let indent = String(repeating: "  ", count: r.depth)
            return ["\(r.p.pid)", "\(r.p.ppid)", r.user, thr, mem,
                    indent + (r.p.name.isEmpty ? "?" : r.p.name)]
        }
        return ["\(r.p.pid)", "\(r.p.ppid)", r.user, r.p.state,
                thr, mem,
                r.p.taskinfoOK ? Human.duration(r.p.cpuTimeNS) : "—", cmd]
    }
    let cap = o.wide ? nil : 96
    writeOut(TextTable.render(headers: headers, rows: body, lastColumnMax: cap))
    if hidden > 0 {
        // 提示走 stderr，stdout 仍然只有表格，`vantage | grep` 不受影响
        stderr.write(Data("# \(hidden) more processes (use -n N or --json)\n".utf8))
    }
}

extension ProcInfo {
    var exeFallback: String { exepath.isEmpty ? comm : exepath }
}

// MARK: - info

func cmdInfo(_ o: Options) {
    let pid = intArg(o.positional.first, "pid")
    let (procs, _) = loadProcesses()
    guard let p = procs.first(where: { $0.pid == pid }) else {
        fail("no such process: \(pid)")
    }
    let user = SystemBridge.userName(p.uid)

    if o.json {
        emitJSON([
            "pid": Int(p.pid), "ppid": Int(p.ppid), "uid": Int(p.uid), "user": user,
            "name": p.name, "comm": p.comm, "state": p.state,
            "readable": p.taskinfoOK,
            "rss": num(p.taskinfoOK, p.rss),
            "vss": num(p.taskinfoOK, p.vss),
            "threads": num(p.taskinfoOK, p.threads),
            "cpuTimeNS": num(p.taskinfoOK, p.cpuTimeNS),
            "started": Int(p.startSec),
            "tty": p.tty, "pgid": Int(p.pgid), "nice": Int(p.nice),
            "exe": p.exepath, "cmdline": p.cmdline,
        ])
        return
    }
    let fields: [(String, String)] = [
        ("name", p.name),
        ("pid / ppid", "\(p.pid) / \(p.ppid)"),
        ("user", "\(user) (\(p.uid))"),
        ("state", p.state),
        ("rss / vss", p.taskinfoOK
            ? "\(Human.bytes(p.rss)) / \(Human.bytes(p.vss))"
            : "— (needs root for this process)"),
        ("threads", p.taskinfoOK ? "\(p.threads)" : "—"),
        ("cpu time", p.taskinfoOK ? Human.duration(p.cpuTimeNS) : "—"),
        ("started", Human.date(p.startSec)),
        ("tty / pgid", "\(p.tty) / \(p.pgid)"),
        ("nice", "\(p.nice)"),
        ("executable", p.exepath.isEmpty ? "-" : p.exepath),
        ("command", p.cmdline.isEmpty ? "-"
            : (o.wide ? p.cmdline : TextTable.clip(p.cmdline, 300))),
    ]
    let w = fields.map { TextTable.width($0.0) }.max() ?? 0
    for (k, v) in fields {
        writeOut(TextTable.pad(k, w) + "  " + v + "\n")
    }
}

// MARK: - detail

func cmdDetail(_ o: Options) {
    guard o.positional.count >= 2 else {
        fail("usage: vantage detail <pid> <kind>  (kinds: "
             + SystemBridge.DetailKind.allCases.map(\.rawValue).joined(separator: " ") + ")",
             code: 1)
    }
    let pid = intArg(o.positional[0], "pid")
    // 兼容 GUI 页签的叫法
    let alias: [String: String] = ["dylibs": "images", "pipepeers": "pipes",
                                   "mach-security": "mach"]
    let raw = o.positional[1].lowercased()
    guard let kind = SystemBridge.DetailKind(rawValue: alias[raw] ?? raw) else {
        fail("unknown kind: \(o.positional[1])  (kinds: "
             + SystemBridge.DetailKind.allCases.map(\.rawValue).joined(separator: " ") + ")",
             code: 1)
    }

    let lines = SystemBridge.detail(kind, pid: pid)
    var rows = lines.map { Bilingual.fields(of: $0, o.lang) }
    var hints: [String] = []
    if let first = rows.first, first.first == "__hint__" {
        rows.removeFirst()
    }
    rows.removeAll { r in
        if r.first == "__hint__" { hints.append(r.dropFirst().joined(separator: " ")); return true }
        return false
    }

    // 采集失败时 C 层第一行就是「错误」，没有表头；有些采集器（audit）会
    // 先给表头再给错误行，所以按「任意一行是错误行」判断退出码
    func isErrorRow(_ r: [String]) -> Bool { r.first == "错误" || r.first == "Error" }
    let hadError = rows.contains(where: isErrorRow)
    let isError = rows.first.map(isErrorRow) ?? false
    let headers = isError ? [] : (rows.first ?? [])
    var data = isError ? rows : Array(rows.dropFirst())
    var truncated = 0
    if let n = o.limit, data.count > n {
        truncated = data.count - n
        data = Array(data.prefix(n))
    }

    if o.json {
        var obj: [String: Any] = [
            "pid": Int(pid), "kind": kind.rawValue,
            "error": isError,
            "headers": headers,
            "rows": data,
            "hints": hints,
            "truncated": truncated,
        ]
        obj["total"] = data.count + truncated
        emitJSON(obj)
        return
    }
    if isError {
        for r in rows { writeOut(r.joined(separator: "\t") + "\n") }
        exit(2)                     // 采集失败：脚本应当能靠退出码判断
    }
    guard !data.isEmpty else {
        writeOut("(no rows)\n")
        for h in hints { writeOut("# " + h + "\n") }
        return
    }
    // 路径 / 映射文件列可以很长：默认裁到 100 列，--wide 放开
    writeOut(TextTable.render(headers: headers, rows: data,
                              lastColumnMax: o.wide ? nil : 100))
    if truncated > 0 {
        writeOut("# \(truncated) more rows not shown (--limit \(data.count))\n")
    }
    for h in hints { writeOut("# " + h + "\n") }
    // 表头 + 错误行的页（audit 之类）：内容照出，但退出码要能反映失败
    if hadError { exit(2) }
}

// MARK: - stats / net

func cmdStats(_ o: Options) {
    let (_, s) = loadProcesses()
    if o.json {
        emitJSON([
            "logicalCPUs": s.logicalCPUs, "physicalCPUs": s.physicalCPUs,
            "memTotal": s.memTotal, "memUsed": s.memUsed, "memFree": s.memFree,
            "swapUsed": s.swapUsed, "swapTotal": s.swapTotal,
            "processes": s.procCount, "threads": s.threadsTotal,
            "load1": s.load1, "load5": s.load5, "load15": s.load15,
        ])
        return
    }
    let fields: [(String, String)] = [
        ("cpus", "\(s.logicalCPUs) logical / \(s.physicalCPUs) physical"),
        ("memory", "\(Human.bytes(s.memUsed)) used of \(Human.bytes(s.memTotal))"
                 + "  (\(Human.bytes(s.memFree)) free)"),
        ("swap", "\(Human.bytes(s.swapUsed)) of \(Human.bytes(s.swapTotal))"),
        ("load", String(format: "%.2f %.2f %.2f", s.load1, s.load5, s.load15)),
        ("processes", "\(s.procCount)"),
        ("threads", "\(s.threadsTotal)"),
    ]
    let w = fields.map { TextTable.width($0.0) }.max() ?? 0
    for (k, v) in fields { writeOut(TextTable.pad(k, w) + "  " + v + "\n") }
}

func cmdNet(_ o: Options) {
    let what = o.positional.first?.lowercased() ?? "ifaces"
    switch what {
    case "ifaces", "interfaces", "if":
        let ifaces = SystemBridge.interfaces()
        let addrs = SystemBridge.addresses()
        if o.json {
            emitJSON(ifaces.map { i -> [String: Any] in
                ["index": Int(i.index), "name": i.name,
                 "flags": i.flags.ifFlagsText, "mtu": i.mtu, "mac": i.mac,
                 "type": i.type,
                 "addresses": addrs.filter { $0.ifname == i.name }.map {
                     ["family": $0.family, "addr": $0.addr, "prefix": $0.prefix]
                 }]
            })
            return
        }
        guard !ifaces.isEmpty else { fail("no interfaces (or read failed)") }
        writeOut(TextTable.render(
            headers: ["IFACE", "TYPE", "MTU", "MAC", "FLAGS", "ADDRESSES"],
            rows: ifaces.map { i in
                let list = addrs.filter { $0.ifname == i.name }.map {
                    $0.addr + ($0.prefix >= 0 ? "/\($0.prefix)" : "")
                }
                return [i.name, i.type, "\(i.mtu)", i.mac,
                        i.flags.ifFlagsText,
                        TextTable.clip(list.joined(separator: " "), 60)]
            }))
    case "addrs", "addresses":
        let addrs = SystemBridge.addresses()
        if o.json {
            emitJSON(addrs.map { ["ifname": $0.ifname, "family": $0.family,
                                  "addr": $0.addr, "prefix": $0.prefix] })
            return
        }
        writeOut(TextTable.render(headers: ["IFACE", "FAMILY", "ADDRESS", "PREFIX"],
                                  rows: addrs.map { [$0.ifname, $0.family, $0.addr,
                                                     "\($0.prefix)"] }))
    case "routes", "route":
        let routes = SystemBridge.routes()
        if o.json {
            emitJSON(routes.map { ["family": $0.family, "destination": $0.dest,
                                   "gateway": $0.gateway, "flags": $0.flags,
                                   "interface": $0.netif] })
            return
        }
        writeOut(TextTable.render(headers: ["FAMILY", "DESTINATION", "GATEWAY", "FLAGS", "IFACE"],
                                  rows: routes.map { [$0.family, $0.dest, $0.gateway,
                                                      $0.flags, $0.netif] }))
    default:
        fail("unknown net section: \(what) (ifaces|addrs|routes)", code: 1)
    }
}

// MARK: - signal

func signalNumber(_ raw: String) -> Int32? {
    if let n = Int32(raw), n > 0, n < 32 { return n }
    let name = raw.uppercased().replacingOccurrences(of: "SIG", with: "")
    let table: [String: Int32] = [
        "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6,
        "KILL": 9, "SEGV": 11, "PIPE": 13, "ALRM": 14, "TERM": 15,
        "STOP": 17, "TSTP": 18, "CONT": 19, "WINCH": 28, "INFO": 29,
        "USR1": 30, "USR2": 31,
    ]
    return table[name]
}

func cmdSignal(_ o: Options) {
    guard o.positional.count >= 2 else {
        fail("usage: vantage signal <pid> <SIGNAME|NUMBER>", code: 1)
    }
    let pid = intArg(o.positional[0], "pid")
    // kill(0, sig) 会把信号发给**整个进程组**，kill(-1, …) 更是全系统；
    // 这里必须拦死，别的错误都可以交给内核报。
    guard pid > 0 else {
        fail("refusing to signal pid \(pid): 0 means the whole process group, negative means all processes",
             code: 1)
    }
    guard let sig = signalNumber(o.positional[1]) else {
        fail("unknown signal: \(o.positional[1])", code: 1)
    }
    let rc = SystemBridge.signal(pid: pid, sig: sig)
    guard rc == 0 else {
        fail("failed to send \(sig) to \(pid): \(String(cString: strerror(errno)))")
    }
    if o.json {
        emitJSON(["pid": Int(pid), "signal": Int(sig), "ok": true])
    } else {
        writeOut("sent \(sig) to \(pid)\n")
    }
}

// MARK: - 入口

let argv = Array(CommandLine.arguments.dropFirst())

// 子命令可以是第一个非选项参数（`vantage info 123`），也可以被全局开关前置
// （`vantage --json list`）。但 `-f Vantage` 这种「选项 + 值」里的值不是子命令，
// 所以只认白名单里的名字，其余一律当 list 的参数。
let knownCommands: Set<String> = [
    "list", "ls", "ps", "tree", "pstree", "info", "show", "detail", "cat",
    "stats", "stat", "net", "signal", "kill", "help", "version",
]
let valueFlags: Set<String> = ["-f", "--filter", "-u", "--user", "-s", "--sort",
                               "-n", "--limit", "--lang"]
var command = "list"
var rest: [String] = []
var sawCommand = false
var expectValue = false
for a in argv {
    if expectValue {
        rest.append(a)
        expectValue = false
        continue
    }
    if a.hasPrefix("-") {
        rest.append(a)
        // `--lang=zh` 自带值，不需要再吃下一个 token
        if valueFlags.contains(a) { expectValue = true }
        continue
    }
    if !sawCommand {
        guard knownCommands.contains(a.lowercased()) else {
            fail("unknown command: \(a)\n       did you mean `vantage list -f \(a)`?  (see `vantage help`)",
                 code: 1)
        }
        command = a.lowercased()
        sawCommand = true
        continue
    }
    rest.append(a)
}
if command == "default" { command = "list" }
if argv.contains("--version") || command == "version" {
    writeOut("\(selfName) \(BuildVersion.marketing)\n")
    exit(0)
}
if argv.contains("-h") || argv.contains("--help") || command == "help" || command == "--help" {
    usage()
}

let opts = parse(rest)

switch command {
case "list", "ls", "ps":   cmdList(opts, tree: false)
case "tree", "pstree":     cmdList(opts, tree: true)
case "info", "show":       cmdInfo(opts)
case "detail", "cat":      cmdDetail(opts)
case "stats", "stat":      cmdStats(opts)
case "net":                cmdNet(opts)
case "signal", "kill":     cmdSignal(opts)
default:
    fail("unknown command: \(command)  (try `vantage help`)", code: 1)
}
