// SPDX-License-Identifier: MIT
import CProc
import Darwin
import Foundation

// ---------------------------------------------------------------------
// 系统数据桥：给 MCP 工具用的轻量封装
//
// 这里刻意不依赖 GUI target 里的 ProcBridge / NetBridge —— 那两个类绑着
// AppKit 与偏好设置，而 MCP 服务是纯命令行程序。直接用 CProc 的 C 接口，
// 输出保持 ASCII（MCP 客户端不需要本地化）。
// ---------------------------------------------------------------------

struct ProcInfo {
    let pid: Int32
    let ppid: Int32
    let uid: Int32
    let state: String
    let rss: UInt64
    let vss: UInt64
    let threads: UInt64
    let cpuTimeNS: UInt64
    let startSec: UInt64
    let comm: String
    let cmdline: String
    let exepath: String
}

struct NetIfaceInfo {
    let index: Int32
    let name: String
    let flags: UInt32
    let mtu: Int
    let mac: String
    let type: String
}

struct NetAddrInfo {
    let ifname: String
    let family: String
    let addr: String
    let prefix: Int
}

struct NetRouteInfo {
    let family: String
    let dest: String
    let gateway: String
    let flags: String
    let netif: String
}

struct SysInfo {
    let logicalCPUs: UInt32
    let physicalCPUs: UInt32
    let memTotal: UInt64
    let memUsed: UInt64
    let memFree: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64
    let threadsTotal: UInt64
    let procCount: Int32
    let load1: Double
    let load5: Double
    let load15: Double
}

enum SystemBridge {

    // MARK: 进程

    static func processes() -> (procs: [ProcInfo], sys: SysInfo)? {
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
                    ProcInfo(pid: p.pid, ppid: p.ppid, uid: p.uid,
                             state: String(cString: cproc_state_name(p.status)),
                             rss: p.rss, vss: p.vss, threads: p.threads,
                             cpuTimeNS: p.cpu_user_ns + p.cpu_sys_ns,
                             startSec: p.start_sec,
                             comm: String(cString: cproc_comm(q)),
                             cmdline: String(cString: cproc_cmdline(q)),
                             exepath: String(cString: cproc_exepath(q)))
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

    static func userName(_ uid: Int32) -> String {
        if uid == 0 { return "root" }
        if let pw = getpwuid(uid_t(uid)), let n = pw.pointee.pw_name {
            return String(cString: n)
        }
        return "\(uid)"
    }

    /// 详情页（与 GUI 里 14 个页签同源）。kind 见 DetailKind。
    static func detail(_ kind: DetailKind, pid: Int32) -> [String] {
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

    enum DetailKind: String, CaseIterable {
        case files, env, images, sockets, monitoring, regions, pipes, tty, mach, threads
    }

    static func signal(pid: Int32, sig: Int32) -> Int32 {
        cproc_signal(pid, sig)
    }

    // MARK: 网络

    static func interfaces() -> [NetIfaceInfo] {
        parseLines(cproc_net_ifaces).compactMap { c in
            guard c.count >= 6 else { return nil }
            return NetIfaceInfo(index: Int32(c[0]) ?? 0, name: c[1],
                                flags: UInt32(c[2], radix: 16) ?? 0,
                                mtu: Int(c[3]) ?? 0, mac: c[4], type: c[5])
        }
    }

    static func addresses() -> [NetAddrInfo] {
        parseLines(cproc_net_addrs).compactMap { c in
            guard c.count >= 4 else { return nil }
            return NetAddrInfo(ifname: c[0], family: c[1], addr: c[2],
                               prefix: Int(c[3]) ?? -1)
        }
    }

    static func routes() -> [NetRouteInfo] {
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

extension UInt32 {
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
