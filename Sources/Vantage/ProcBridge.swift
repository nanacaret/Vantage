// SPDX-License-Identifier: MIT
import Foundation
import CProc

enum ProcBridge {

    // -----------------------------------------------------------------
    // 进程字符串驻留
    //
    // 每次刷新都要为每个进程取 6 个 C 字符串（comm / name / cmdline /
    // exepath / argv0 / tty）。600+ 进程 × 每秒一次 = 每秒四千次
    // `String(cString:)`，而其中 99% 的内容与上一帧完全相同。
    // 这里以 (pid, startSec) 为键缓存，用 strcmp 与上一帧的 String 比较，
    // 只有真的变了才新建 —— 命中时只是把已有的 String 引用返回（COW，零分配）。
    // -----------------------------------------------------------------
    private struct ProcStrings {
        var gen: UInt64
        var start: UInt64
        var comm: String
        var name: String
        var cmdline: String
        var exepath: String
        var argv0: String
        var tty: String
    }

    private static let stringsLock = NSLock()
    private static var stringsByPID: [Int32: ProcStrings] = [:]
    private static var stringsGen: UInt64 = 0

    /// 与已驻留的 String 逐字节比较（不新建 String）
    @inline(__always)
    private static func same(_ s: String, _ c: UnsafePointer<CChar>?) -> Bool {
        guard let c = c else { return s.isEmpty }
        return s.withCString { strcmp($0, c) == 0 }
    }

    /// 调用方必须已持有 stringsLock
    @inline(__always)
    private static func intern(pid: Int32, start: UInt64, gen: UInt64,
                               comm: UnsafePointer<CChar>?,
                               name: UnsafePointer<CChar>?,
                               cmdline: UnsafePointer<CChar>?,
                               exepath: UnsafePointer<CChar>?,
                               argv0: UnsafePointer<CChar>?,
                               tty: UnsafePointer<CChar>?) -> ProcStrings {
        if var e = stringsByPID[pid], e.start == start {
            // comm / name / tty 基本都 <=15 字节，Swift 的 small-string 优化
            // 本来就不分配堆内存，再驻留反而多出 strcmp + 字典的开销。
            e.comm = comm.map { String(cString: $0) } ?? ""
            e.name = name.map { String(cString: $0) } ?? ""
            e.tty = tty.map { String(cString: $0) } ?? ""
            if !same(e.cmdline, cmdline) {
                e.cmdline = cmdline.map { String(cString: $0) } ?? ""
            }
            if !same(e.exepath, exepath) {
                e.exepath = exepath.map { String(cString: $0) } ?? ""
            }
            if !same(e.argv0, argv0) { e.argv0 = argv0.map { String(cString: $0) } ?? "" }
            e.gen = gen
            stringsByPID[pid] = e
            return e
        }
        let e = ProcStrings(
            gen: gen, start: start,
            comm: comm.map { String(cString: $0) } ?? "",
            name: name.map { String(cString: $0) } ?? "",
            cmdline: cmdline.map { String(cString: $0) } ?? "",
            exepath: exepath.map { String(cString: $0) } ?? "",
            argv0: argv0.map { String(cString: $0) } ?? "",
            tty: tty.map { String(cString: $0) } ?? "")
        stringsByPID[pid] = e
        return e
    }

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

        // 整个循环持锁：一次取锁比每进程取锁 600 次便宜，
        // 也让「清理过期条目」与「写入新条目」在同一临界区里完成。
        stringsLock.lock()
        stringsGen &+= 1
        let gen = stringsGen
        defer {
            // 清掉本帧没出现过的 pid（进程退出后不再占内存）
            var kept: [Int32: ProcStrings] = [:]
            kept.reserveCapacity(stringsByPID.count)
            for (pid, e) in stringsByPID where e.gen == gen { kept[pid] = e }
            stringsByPID = kept
            stringsLock.unlock()
        }

        for i in 0..<buf.count {
            let p = buf[i]
            var snap = withUnsafePointer(to: p) { q -> ProcessSnapshot in
                let str = intern(pid: p.pid, start: p.start_sec, gen: gen,
                                 comm: cproc_comm(q), name: cproc_name(q),
                                 cmdline: cproc_cmdline(q),
                                 exepath: cproc_exepath(q),
                                 argv0: cproc_argv0(q),
                                 tty: cproc_tty_name(q))
                return ProcessSnapshot(
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
                    comm: str.comm,
                    name: str.name,
                    cmdline: str.cmdline,
                    exepath: str.exepath,
                    argv0: str.argv0,
                    ttyName: str.tty
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
        case regions, pipePeers, tty, threads   // 完全不依赖 task port

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
            case .threads:      return "threads"
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
        case .threads:      rc = cproc_threads(pid, &lines)
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
