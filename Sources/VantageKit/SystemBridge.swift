// SPDX-License-Identifier: MIT
import CProc
import Darwin
import Foundation

// ---------------------------------------------------------------------
// 系统数据桥：给命令行前端（vantage / vantage-mcp）用的轻量封装
//
// 这里刻意不依赖 GUI target 里的 ProcBridge / NetBridge —— 那两个类绑着
// AppKit 与偏好设置，而 CLI / MCP 是纯命令行程序。直接用 CProc 的 C 接口，
// 输出保持 ASCII（命令行不需要 GUI 的本地化表，C 层双语标记另见 Bilingual）。
// ---------------------------------------------------------------------

public struct ProcInfo {
    public let pid: Int32
    public let ppid: Int32
    public let uid: Int32
    public let state: String
    public let rss: UInt64
    public let vss: UInt64
    public let threads: UInt64
    public let cpuTimeNS: UInt64
    public let startSec: UInt64
    public let comm: String
    public let name: String
    public let cmdline: String
    public let exepath: String
    public let tty: String
    public let pgid: Int32
    public let nice: Int32
    /// PROC_PIDTASKINFO 读成功了吗；false 时 rss / vss / threads / cpuTimeNS 都是 0
    /// 但那是「没权限」，不是「真的是 0」
    public let taskinfoOK: Bool
}

public struct NetIfaceInfo {
    public let index: Int32
    public let name: String
    public let flags: UInt32
    public let mtu: Int
    public let mac: String
    public let type: String
}

public struct NetAddrInfo {
    public let ifname: String
    public let family: String
    public let addr: String
    public let prefix: Int
}

public struct NetRouteInfo {
    public let family: String
    public let dest: String
    public let gateway: String
    public let flags: String
    public let netif: String
}

public struct SysInfo {
    public let logicalCPUs: UInt32
    public let physicalCPUs: UInt32
    public let memTotal: UInt64
    public let memUsed: UInt64
    public let memFree: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let threadsTotal: UInt64
    public let procCount: Int32
    public let load1: Double
    public let load5: Double
    public let load15: Double
}

public enum SystemBridge {

    // MARK: 进程

    public static func processes() -> (procs: [ProcInfo], sys: SysInfo)? {
        var raw = cproc_system_t()
        guard cproc_collect(&raw) == 0 else { return nil }
        defer { cproc_free(&raw) }

        var procs: [ProcInfo] = []
        if let items = raw.items, raw.count > 0 {
            let buf = UnsafeBufferPointer(start: UnsafePointer(items),
                                          count: Int(raw.count))
            procs.reserveCapacity(buf.count)
            for i in 0..<buf.count {
                let p = buf[i]
                let info = withUnsafePointer(to: p) { q -> ProcInfo in
                    // 长名称与 comm 相同（没有 BSD 名字时 C 层已回退），
                    // 直接取 comm 的同一份缓存，避免再跨一次指针
                    let comm = String(cString: cproc_comm(q))
                    let long = String(cString: cproc_name(q))
                    return ProcInfo(pid: p.pid, ppid: p.ppid, uid: p.uid,
                                    state: String(cString: cproc_state_name(p.status)),
                                    rss: p.rss, vss: p.vss, threads: p.threads,
                                    cpuTimeNS: p.cpu_user_ns + p.cpu_sys_ns,
                                    startSec: p.start_sec,
                                    comm: comm,
                                    name: long.isEmpty ? comm : long,
                                    cmdline: String(cString: cproc_cmdline(q)),
                                    exepath: String(cString: cproc_exepath(q)),
                                    tty: String(cString: cproc_tty_name(q)),
                                    pgid: Int32(bitPattern: p.pgid),
                                    nice: p.nice,
                                    taskinfoOK: p.taskinfo_ok != 0)
                }
                procs.append(info)
            }
        }
        let sys = SysInfo(logicalCPUs: raw.logical_cpus, physicalCPUs: raw.physical_cpus,
                          memTotal: raw.mem_total, memUsed: raw.mem_used,
                          memFree: raw.mem_free, swapUsed: raw.swap_used,
                          swapTotal: raw.swap_total,
                          threadsTotal: raw.threads_total, procCount: raw.count,
                          load1: raw.load1, load5: raw.load5, load15: raw.load15)
        return (procs, sys)
    }

    public static func userName(_ uid: Int32) -> String {
        if uid == 0 { return "root" }
        // uid 是 int32，但内核里有些进程（例如 0xFFFFFFFF）在 Swift 里是负数；
        // uid_t 是无符号的，必须按位转换而不是数值转换，否则会 trap
        guard uid > 0 else { return "\(UInt32(bitPattern: uid))" }
        if let pw = getpwuid(uid_t(uid)), let n = pw.pointee.pw_name {
            return String(cString: n)
        }
        return "\(uid)"
    }

    /// 详情页（与 GUI 的页签同源）。kind 见 DetailKind。
    public static func detail(_ kind: DetailKind, pid: Int32) -> [String] {
        var lines = cproc_lines_t()
        let rc: Int32
        switch kind {
        case .files:      rc = cproc_open_files(pid, &lines)
        case .env:        rc = cproc_env_vars(pid, &lines)
        case .images:     rc = cproc_dylibs(pid, &lines)
        case .sockets:    rc = cproc_sockets(pid, &lines)
        case .monitoring: rc = cproc_monitoring(pid, &lines)
        case .regions:    rc = cproc_regions(pid, &lines)
        case .pipes:      rc = cproc_pipe_peers(pid, &lines)
        case .tty:        rc = cproc_tty(pid, &lines)
        case .threads:    rc = cproc_threads(pid, &lines)
        case .mach:       rc = cproc_mach_security(pid, &lines)
        case .audit:      rc = cproc_audit_info(pid, &lines)
        }
        guard rc == 0 else { return ["error: rc=\(rc)"] }
        defer { cproc_lines_free(&lines) }
        var out: [String] = []
        out.reserveCapacity(Int(lines.count))
        for i in 0..<Int(lines.count) {
            out.append(String(cString: cproc_line(&lines, Int32(i))))
        }
        return out
    }

    public enum DetailKind: String, CaseIterable {
        case files, env, images, sockets, monitoring, regions, pipes, tty, mach, threads, audit
    }

    public static func signal(pid: Int32, sig: Int32) -> Int32 {
        cproc_signal(pid, sig)
    }

    // MARK: 网络

    public static func interfaces() -> [NetIfaceInfo] {
        parseLines(cproc_net_ifaces).compactMap { c in
            guard c.count >= 6 else { return nil }
            return NetIfaceInfo(index: Int32(c[0]) ?? 0, name: c[1],
                                flags: UInt32(c[2], radix: 16) ?? 0,
                                mtu: Int(c[3]) ?? 0, mac: c[4], type: c[5])
        }
    }

    public static func addresses() -> [NetAddrInfo] {
        parseLines(cproc_net_addrs).compactMap { c in
            guard c.count >= 4 else { return nil }
            return NetAddrInfo(ifname: c[0], family: c[1], addr: c[2],
                               prefix: Int(c[3]) ?? -1)
        }
    }

    public static func routes() -> [NetRouteInfo] {
        parseLines(cproc_net_routes).compactMap { c in
            guard c.count >= 5 else { return nil }
            return NetRouteInfo(family: c[0], dest: c[1], gateway: c[2],
                                flags: c[3], netif: c[4])
        }
    }

    private static func parseLines(
        _ fn: (UnsafeMutablePointer<cproc_lines_t>) -> Int32
    ) -> [[String]] {
        var out = cproc_lines_t()
        guard fn(&out) == 0 else { cproc_lines_free(&out); return [] }
        defer { cproc_lines_free(&out) }
        var rows: [[String]] = []
        rows.reserveCapacity(Int(out.count))
        for i in 0..<Int(out.count) {
            let line = String(cString: cproc_line(&out, Int32(i)))
            rows.append(line.components(separatedBy: "\t"))
        }
        return rows
    }
}

public extension UInt32 {
    /// ifconfig 风格的接口标志串
    var ifFlagsText: String {
        let table: [(Int32, String)] = [
            (IFF_UP, "UP"), (IFF_BROADCAST, "BROADCAST"),
            (IFF_LOOPBACK, "LOOPBACK"), (IFF_POINTOPOINT, "POINTOPOINT"),
            (IFF_RUNNING, "RUNNING"), (IFF_PROMISC, "PROMISC"),
            (IFF_ALLMULTI, "ALLMULTI"), (IFF_MULTICAST, "MULTICAST"),
            (IFF_SIMPLEX, "SIMPLEX"),
        ]
        return table.filter { self & UInt32($0.0) != 0 }
            .map { $0.1 }.joined(separator: ",")
    }
}
