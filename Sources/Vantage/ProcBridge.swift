// SPDX-License-Identifier: MIT
import Foundation
import CProc

enum ProcBridge {

    static func collect() -> (procs: [ProcessSnapshot], sys: SystemSnapshot)? {
        var raw = cproc_system_t()
        guard cproc_collect(&raw) == 0 else { return nil }
        defer { cproc_free(&raw) }

        guard let items = raw.items, raw.count > 0 else {
            return ([], SystemSnapshot())
        }

        let buf = UnsafeBufferPointer(start: UnsafePointer(items),
                                      count: Int(raw.count))
        var procs: [ProcessSnapshot] = []
        procs.reserveCapacity(buf.count)

        for i in 0..<buf.count {
            let p = buf[i]
            var snap = withUnsafePointer(to: p) { q -> ProcessSnapshot in
                ProcessSnapshot(
                    pid: p.pid,
                    ppid: p.ppid,
                    uid: p.uid,
                    gid: p.gid,
                    nice: p.nice,
                    priority: p.priority,
                    status: p.status,
                    flags: p.flags,
                    translated: p.translated,
                    execArchs: p.exec_archs,
                    pgid: p.pgid,
                    startSec: p.start_sec,
                    startUSec: p.start_usec,
                    rss: p.rss,
                    vss: p.vss,
                    cpuUserNS: p.cpu_user_ns,
                    cpuSysNS: p.cpu_sys_ns,
                    threads: p.threads,
                    faults: p.faults,
                    pageins: p.pageins,
                    cowFaults: p.cow_faults,
                    csw: p.csw,
                    msgSent: p.msg_sent,
                    msgRecv: p.msg_recv,
                    sysMach: p.sys_mach,
                    sysUnix: p.sys_unix,
                    nfiles: p.nfiles,
                    ttyDev: p.tty_dev,
                    ttyTpgid: p.tty_tpgid,
                    ttyPgid: p.tty_pgid,
                    ttyJobc: p.tty_jobc,
                    comm: String(cString: cproc_comm(q)),
                    name: String(cString: cproc_name(q)),
                    cmdline: String(cString: cproc_cmdline(q)),
                    exepath: String(cString: cproc_exepath(q)),
                    argv0: String(cString: cproc_argv0(q)),
                    ttyName: String(cString: cproc_tty_name(q))
                )
            }
            snap.hostARM64 = raw.host_arm64 != 0
            procs.append(snap)
        }

        let sys = SystemSnapshot(
            timestampNS: raw.timestamp_ns,
            logicalCPUs: raw.logical_cpus,
            physicalCPUs: raw.physical_cpus,
            hostARM64: raw.host_arm64 != 0,
            memTotal: raw.mem_total,
            memUsed: raw.mem_used,
            memFree: raw.mem_free,
            memWired: raw.mem_wired,
            memCompressed: raw.mem_compressed,
            swapUsed: raw.swap_used,
            swapTotal: raw.swap_total,
            threadsTotal: raw.threads_total,
            procCount: raw.count,
            load1: raw.load1,
            load5: raw.load5,
            load15: raw.load15
        )
        return (procs, sys)
    }

    enum DetailKind {
        case openFiles, environment, dylibs, sockets, monitoring, machSecurity
        case regions, pipePeers, tty   // 完全不依赖 task port

        var cacheKey: String {
            switch self {
            case .openFiles:    return "files"
            case .environment:  return "env"
            case .dylibs:       return "dylibs"
            case .sockets:      return "sockets"
            case .monitoring:   return "monitoring"
            case .machSecurity: return "mach"
            case .regions:      return "regions"
            case .pipePeers:    return "pipePeers"
            case .tty:          return "tty"
            }
        }
    }

    // 详情采集的取消标记：切换进程 / 页签时中止已在跑的长循环
    static func beginDetailEpoch() -> UInt64 { cproc_detail_begin_epoch() }
    static func markDetailEpoch(_ e: UInt64) { cproc_detail_mark_epoch(e) }
    static func cancelDetailEpoch(_ e: UInt64) { cproc_detail_cancel_epoch(e) }
    static func detailAborted() -> Bool { cproc_detail_aborted() != 0 }

    /// 返回原始行（字段以 '\t' 分隔）
    static func detail(_ kind: DetailKind, pid: Int32) -> [String] {
        var lines = cproc_lines_t()
        let rc: Int32
        switch kind {
        case .openFiles:    rc = cproc_open_files(pid, &lines)
        case .environment:  rc = cproc_env_vars(pid, &lines)
        case .dylibs:       rc = cproc_dylibs(pid, &lines)
        case .sockets:      rc = cproc_sockets(pid, &lines)
        case .monitoring:   rc = cproc_monitoring(pid, &lines)
        case .machSecurity: rc = cproc_mach_security(pid, &lines)
        case .regions:      rc = cproc_regions(pid, &lines)
        case .pipePeers:    rc = cproc_pipe_peers(pid, &lines)
        case .tty:          rc = cproc_tty(pid, &lines)
        }
        guard rc == 0 else { return [L("bridge.collectionFailedRc", rc)] }
        defer { cproc_lines_free(&lines) }

        var out: [String] = []
        out.reserveCapacity(Int(lines.count))
        for i in 0..<Int(lines.count) {
            out.append(String(cString: cproc_line(&lines, Int32(i))))
        }
        return out
    }

    static func taskPort(_ pid: Int32) -> UInt32? {
        var port: UInt32 = 0
        guard cproc_task_port(pid, &port) == 0 else { return nil }
        return port
    }

    static func signal(_ pid: Int32, _ sig: Int32) -> Int32 {
        cproc_signal(pid, sig)
    }

    /// 手动「立即刷新」时清掉 Mach-O 架构缓存：App 升级 / 二进制被替换后
    /// 不用等 60 秒 TTL 就能看到新的架构组合。
    static func flushExecArchCache() { cproc_exec_archs_flush() }
}
