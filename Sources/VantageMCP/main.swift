// SPDX-License-Identifier: MIT
import Foundation
import VantageKit

// ---------------------------------------------------------------------
// vantage-mcp —— MCP（Model Context Protocol）stdio 服务
//
// 传输层：stdin/stdout 按行收发 JSON-RPC 2.0（MCP 的 stdio 约定）。
// 只实现 tools 能力：列进程 / 读详情 / 发信号 / 读网卡与路由 / 系统总览。
//
//   { echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'; } | vantage-mcp
//
// 注意：stdout 只能出现协议消息，任何日志都写 stderr，否则客户端会解析失败。
// ---------------------------------------------------------------------

// MARK: - 输出

func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

func writeMessage(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                 options: [.sortedKeys]),
          var text = String(data: data, encoding: .utf8) else { return }
    text += "\n"
    FileHandle.standardOutput.write(Data(text.utf8))
}

func respond(_ id: Any?, _ result: [String: Any]) {
    writeMessage(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
}

func respondError(_ id: Any?, code: Int, _ message: String) {
    writeMessage(["jsonrpc": "2.0", "id": id ?? NSNull(),
                  "error": ["code": code, "message": message]])
}

// MARK: - 格式化小工具

func humanBytes(_ v: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var x = Double(v)
    var i = 0
    while x >= 1024, i < units.count - 1 { x /= 1024; i += 1 }
    return String(format: i == 0 ? "%.0f %@" : "%.1f %@", x, units[i])
}

func humanDuration(_ ns: UInt64) -> String {
    let total = Double(ns) / 1e9
    let h = Int(total) / 3600
    let m = (Int(total) % 3600) / 60
    let s = Int(total) % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                 : String(format: "%d:%02d", m, s)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ",
                                                    count: n - s.count)
}

// MARK: - 工具实现

enum Tools {

    struct Spec {
        let name: String
        let description: String
        let schema: [String: Any]
    }

    static let all: [Spec] = [
        Spec(name: "list_processes",
             description: "List running processes on this Mac (pid, ppid, user, state, RSS, threads, command). "
                        + "Optionally filter by substring on name/command line.",
             schema: [
                "type": "object",
                "properties": [
                    "filter": ["type": "string",
                               "description": "Substring matched against name, cmdline and pid"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200,
                              "description": "Max rows (default 25)"],
                    "sort": ["type": "string",
                             "enum": ["memory", "cpu", "pid", "name"],
                             "description": "Sort key (default memory)"],
                ],
                "additionalProperties": false,
             ]),
        Spec(name: "process_info",
             description: "Show one process: name, pid/ppid, user, state, arch, RSS/VSS, threads, "
                        + "CPU time, start time, executable path and full command line.",
             schema: [
                "type": "object",
                "properties": ["pid": ["type": "integer",
                                       "description": "Process id"]],
                "required": ["pid"],
                "additionalProperties": false,
             ]),
        Spec(name: "process_detail",
             description: "Dump one detail page of a process (same collectors as the app's inspector). "
                        + "kind: files | env | images | sockets | monitoring | regions | pipes | tty | mach | threads.",
             schema: [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer"],
                    "kind": ["type": "string",
                             "enum": SystemBridge.DetailKind.allCases.map { $0.rawValue }],
                ],
                "required": ["pid", "kind"],
                "additionalProperties": false,
             ]),
        Spec(name: "send_signal",
             description: "Send a POSIX signal to a process (TERM, KILL, HUP, STOP, CONT … or a number). "
                        + "Requires the same privileges as /bin/kill; errors are reported verbatim.",
             schema: [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer"],
                    "signal": ["type": "string",
                               "description": "Name (TERM/KILL/HUP/…) or number (15/9/…)"],
                ],
                "required": ["pid", "signal"],
                "additionalProperties": false,
             ]),
        Spec(name: "network_interfaces",
             description: "List network interfaces with flags, MTU, MAC and their IPv4/IPv6 addresses.",
             schema: ["type": "object", "properties": [:] as [String: Any],
                      "additionalProperties": false]),
        Spec(name: "network_routes",
             description: "List the routing table (destination CIDR, gateway, flags, interface).",
             schema: [
                "type": "object",
                "properties": ["family": ["type": "string", "enum": ["inet", "inet6", "all"]]],
                "additionalProperties": false,
             ]),
        Spec(name: "system_stats",
             description: "System overview: CPU counts, memory, swap, load average, process/thread counts.",
             schema: ["type": "object", "properties": [:] as [String: Any],
                      "additionalProperties": false]),
    ]

    static func descriptor(_ s: Spec) -> [String: Any] {
        ["name": s.name, "description": s.description, "inputSchema": s.schema]
    }

    /// 返回 (文本, 是否错误)
    static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        switch name {
        case "list_processes":  return listProcesses(args)
        case "process_info":    return processInfo(args)
        case "process_detail":  return processDetail(args)
        case "send_signal":     return sendSignal(args)
        case "network_interfaces": return interfaces()
        case "network_routes":  return routes(args)
        case "system_stats":    return systemStats()
        default:                return ("unknown tool: \(name)", true)
        }
    }

    // MARK: 进程

    static func listProcesses(_ args: [String: Any]) -> (String, Bool) {
        guard let snap = SystemBridge.processes() else {
            return ("failed to collect process list", true)
        }
        let filter = (args["filter"] as? String)?.lowercased() ?? ""
        let limit = max(1, min(200, (args["limit"] as? Int) ?? 25))
        let sort = (args["sort"] as? String) ?? "memory"

        var rows = snap.procs
        if !filter.isEmpty {
            rows = rows.filter {
                $0.comm.lowercased().contains(filter)
                || $0.cmdline.lowercased().contains(filter)
                || String($0.pid) == filter
            }
        }
        switch sort {
        case "pid":    rows.sort { $0.pid < $1.pid }
        case "name":   rows.sort { $0.comm.localizedCompare($1.comm) == .orderedAscending }
        case "cpu":    rows.sort { $0.cpuTimeNS > $1.cpuTimeNS }
        default:       rows.sort { $0.rss > $1.rss }
        }
        let shown = rows.prefix(limit)

        var out = "\(shown.count) of \(rows.count) processes"
        out += filter.isEmpty ? "" : " (filter: \(filter))"
        out += ", sorted by \(sort)\n"
        out += pad("PID", 7) + pad("PPID", 7) + pad("USER", 12) + pad("STATE", 10)
            + pad("RSS", 10) + pad("THR", 6) + "COMMAND\n"
        for p in shown {
            let cmd = p.cmdline.isEmpty ? p.comm : p.cmdline
            out += pad("\(p.pid)", 7) + pad("\(p.ppid)", 7)
                + pad(SystemBridge.userName(p.uid), 12)
                + pad(p.state, 10)
                // taskinfo 读不到（别人的进程 / SIP 保护）时给 "—"，
                // 0 会被误读成「真的没占内存、没开线程」
                + pad(p.taskinfoOK ? humanBytes(p.rss) : "—", 10)
                + pad(p.taskinfoOK ? "\(p.threads)" : "—", 6)
                // 命令行可能几千字符（Electron 的 --js-flags 之类），
                // 对模型来说前 120 字符足够判断身份
                + (cmd.count > 120 ? String(cmd.prefix(120)) + "…" : cmd) + "\n"
        }
        return (out, false)
    }

    static func processInfo(_ args: [String: Any]) -> (String, Bool) {
        guard let pid = intValue(args["pid"]) else {
            return ("missing required argument: pid", true)
        }
        guard let snap = SystemBridge.processes(),
              let p = snap.procs.first(where: { $0.pid == pid }) else {
            return ("no such process: \(pid)", true)
        }
        let start = Date(timeIntervalSince1970: TimeInterval(p.startSec))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = ""
        out += "name:        \(p.comm)\n"
        out += "pid / ppid:  \(p.pid) / \(p.ppid)\n"
        out += "user:        \(SystemBridge.userName(p.uid)) (\(p.uid))\n"
        out += "state:       \(p.state)\n"
        out += "rss / vss:   " + (p.taskinfoOK
            ? "\(humanBytes(p.rss)) / \(humanBytes(p.vss))"
            : "— (needs root for this process)") + "\n"
        out += "threads:     " + (p.taskinfoOK ? "\(p.threads)" : "—") + "\n"
        out += "cpu time:    " + (p.taskinfoOK ? humanDuration(p.cpuTimeNS) : "—") + "\n"
        out += "started:     \(fmt.string(from: start))\n"
        out += "executable:  \(p.exepath.isEmpty ? "-" : p.exepath)\n"
        out += "command:     \(p.cmdline.isEmpty ? "-" : p.cmdline)\n"
        return (out, false)
    }

    static func processDetail(_ args: [String: Any]) -> (String, Bool) {
        guard let pid = intValue(args["pid"]) else {
            return ("missing required argument: pid", true)
        }
        guard let kindRaw = args["kind"] as? String,
              let kind = SystemBridge.DetailKind(rawValue: kindRaw) else {
            return ("kind must be one of: "
                    + SystemBridge.DetailKind.allCases.map { $0.rawValue }
                        .joined(separator: ", "), true)
        }
        let lines = SystemBridge.detail(kind, pid: pid)
        // 与控制台输出一致：截断超长列表，避免把上下文塞爆
        let cap = 400
        var out = lines.prefix(cap).joined(separator: "\n")
        if lines.count > cap {
            out += "\n… (\(lines.count - cap) more lines truncated)"
        }
        return (out, false)
    }

    static func sendSignal(_ args: [String: Any]) -> (String, Bool) {
        guard let pid = intValue(args["pid"]) else {
            return ("missing required argument: pid", true)
        }
        guard let raw = args["signal"] as? String,
              let sig = signalNumber(raw) else {
            return ("invalid signal: \(args["signal"] ?? "?")", true)
        }
        let rc = SystemBridge.signal(pid: pid, sig: sig)
        if rc == 0 {
            return ("sent signal \(sig) to pid \(pid)", false)
        }
        let err = String(cString: strerror(errno))
        return ("failed to send signal \(sig) to pid \(pid): \(err)", true)
    }

    static func signalNumber(_ s: String) -> Int32? {
        if let n = Int32(s), n > 0, n < 32 { return n }
        let names: [String: Int32] = [
            "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6,
            "KILL": 9, "SEGV": 11, "PIPE": 13, "ALRM": 14, "TERM": 15,
            "USR1": 30, "USR2": 31, "STOP": 17, "TSTP": 18, "CONT": 19,
            "WINCH": 28, "INFO": 29,
        ]
        return names[s.uppercased().replacingOccurrences(of: "SIG", with: "")]
    }

    // MARK: 网络

    static func interfaces() -> (String, Bool) {
        let ifaces = SystemBridge.interfaces()
        guard !ifaces.isEmpty else { return ("no interfaces (or read failed)", true) }
        let addrs = SystemBridge.addresses()
        var out = ""
        for i in ifaces {
            out += "\(i.name)  mtu \(i.mtu)  flags \(i.flags.ifFlagsText)"
            out += i.mac.isEmpty ? "" : "  ether \(i.mac)"
            out += "  [\(i.type)]\n"
            for a in addrs where a.ifname == i.name {
                out += "    \(a.family) \(a.addr)"
                out += a.prefix >= 0 ? "/\(a.prefix)" : ""
                out += "\n"
            }
        }
        return (out, false)
    }

    static func routes(_ args: [String: Any]) -> (String, Bool) {
        let family = (args["family"] as? String) ?? "all"
        let routes = SystemBridge.routes()
        guard !routes.isEmpty else { return ("no routes (or read failed)", true) }
        var out = pad("FAMILY", 8) + pad("DESTINATION", 28) + pad("GATEWAY", 30)
            + pad("FLAGS", 10) + "IFACE\n"
        for r in routes where family == "all" || r.family == family {
            out += pad(r.family, 8) + pad(r.dest, 28) + pad(r.gateway, 30)
                + pad(r.flags, 10) + r.netif + "\n"
        }
        return (out, false)
    }

    static func systemStats() -> (String, Bool) {
        guard let snap = SystemBridge.processes() else {
            return ("failed to collect system stats", true)
        }
        let s = snap.sys
        var out = ""
        out += "cpus:        \(s.logicalCPUs) logical / \(s.physicalCPUs) physical\n"
        out += "memory:      \(humanBytes(s.memUsed)) used of \(humanBytes(s.memTotal))"
        out += "  (\(humanBytes(s.memFree)) free)\n"
        out += "swap:        \(humanBytes(s.swapUsed)) of \(humanBytes(s.swapTotal))\n"
        out += "load:        \(String(format: "%.2f %.2f %.2f", s.load1, s.load5, s.load15))\n"
        out += "processes:   \(s.procCount)\n"
        out += "threads:     \(s.threadsTotal)\n"
        return (out, false)
    }

    private static func intValue(_ v: Any?) -> Int32? {
        if let n = v as? Int { return Int32(exactly: n) }
        if let n = v as? Int32 { return n }
        if let s = v as? String { return Int32(s) }
        return nil
    }
}

// MARK: - JSON-RPC 循环

let serverName = "vantage-mcp"
let serverVersion = "1.0.0"

func handle(_ msg: [String: Any]) {
    let method = msg["method"] as? String ?? ""
    let id = msg["id"]
    let isNotification = (id == nil)
    let params = msg["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        respond(id, [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": serverName, "version": serverVersion],
        ])

    case "notifications/initialized", "notifications/cancelled":
        break                                   // 通知：不回包

    case "ping":
        respond(id, [:])

    case "tools/list":
        respond(id, ["tools": Tools.all.map { Tools.descriptor($0) }])

    case "tools/call":
        guard let name = params["name"] as? String else {
            respondError(id, code: -32602, "missing tool name")
            return
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let (text, isError) = Tools.call(name, args)
        respond(id, [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ])

    default:
        if isNotification { return }            // 未知通知：静默忽略
        respondError(id, code: -32601, "method not found: \(method)")
    }
}

writeStderr("[\(serverName)] ready (stdio JSON-RPC)\n")

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let msg = obj as? [String: Any] else {
        respondError(nil, code: -32700, "parse error")
        continue
    }
    // 支持批量请求（数组）
    if let batch = obj as? [[String: Any]] {
        for m in batch { handle(m) }
    } else {
        handle(msg)
    }
}
