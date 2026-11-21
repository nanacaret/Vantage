// SPDX-License-Identifier: MIT
import AppKit
import CoreFoundation
import CProc
import Darwin
import Foundation
import Security
import SQLite3

// ---------------------------------------------------------------------
// 权限页
//
// 三路信息源：
//   1. 代码签名里的 entitlements（Security.framework）——「声明了哪些权限」
//   2. TCC.db 的 access 表（用户级 + 系统级）——「实际被授予 / 拒绝什么」
//   3. SIP 状态 + task port 能力——「当前还能读 / 改到什么程度」
//
// TCC.db 受 SIP / TCC 自己保护：没有「完全磁盘访问」时读不到。这里只读
// 系统正式路径，读不到就在界面上明确提示，并给出直达设置面板的右键入口 ——
// 不读任何「副本」，避免把过期数据当成真实授权。
//
// SIP 状态不调用 csrutil：见 sip.c，优先问内核（csr_get_active_config）。
// 写入（授予 / 撤销）只在 SIP 文件系统保护关闭时开放，见 canWriteTCC；
// 写库用 SQLite3 系统库，非 root 时启动本二进制的隐藏 --tcc-write 模式。
// ---------------------------------------------------------------------

/// TCC access 表的一行
struct TCCRecord {
    let service: String
    let client: String
    let clientType: Int
    let authValue: Int
    let authReason: Int
    let lastModified: Int
    /// 这条记录所在的数据库（系统级 / 用户级），写回时用同一个文件
    let isSystem: Bool

    var dbPath: String {
        isSystem ? PermissionReader.systemTCCPath : PermissionReader.userTCCPath
    }
}

struct SipStatus {
    var readable: Bool
    /// 内核活动配置位图：位为 1 = 该项保护被放开；0 = SIP 完全开启
    var active: UInt32
    /// true = 来自 csr_get_active_config；false = 文件标志探测的近似值
    var fromAPI: Bool

    static let knownMask: UInt32 = 0x0000_0FFF   // 公开的 12 个 CSR_ALLOW_* 位
    private static let allowUnrestrictedFS: UInt32 = 0x0000_0002
    private static let allowTaskForPid: UInt32 = 0x0000_0004
    private static let allowKernelDebugger: UInt32 = 0x0000_0008

    var enabled: Bool { active == 0 }
    var fullyDisabled: Bool { (active & Self.knownMask) == Self.knownMask }
    var custom: Bool { !enabled && !fullyDisabled }
    /// 文件系统保护（关闭后 root 才能改 TCC.db 这类受保护文件）
    var filesystemProtections: Bool { active & Self.allowUnrestrictedFS == 0 }
    var debuggingRestricted: Bool { active & Self.allowKernelDebugger == 0 }
    var taskForPidAllowed: Bool { active & Self.allowTaskForPid != 0 }

    /// 是否允许写 TCC.db
    var canWriteTCC: Bool { readable && !filesystemProtections }
}

/// 权限页的一行；TCC 行额外带上数据库记录，供右键「授予 / 撤销」使用
struct PermissionRow {
    let category: String
    let name: String
    let state: String
    let detail: String
    let source: String
    var record: TCCRecord?
    var service: String?
}

struct PermissionReport {
    var rows: [PermissionRow]
    var sip: SipStatus
    /// 有一条 TCC 数据库可读（否则整页只剩 entitlement / SIP 信息）
    var tccReadable: Bool
}

/// TCC 数据库写入（SQLite3 系统库，参数绑定）
enum TCCStore {

    /// 写入 / 更新一条授权。INSERT OR REPLACE 依赖 access 表的主键
    /// (service, client, client_type, indirect_object_identifier)。
    static func write(dbPath: String, service: String, client: String,
                      clientType: Int, allow: Bool) -> (rc: Int32, message: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if db != nil { sqlite3_close(db) }
            return (SQLITE_CANTOPEN, msg)
        }
        defer { sqlite3_close(handle) }
        // tccd 可能正持有这个库：给 3 秒锁等待，避免误报 SQLITE_BUSY
        sqlite3_busy_timeout(handle, 3000)

        let sql = """
        INSERT OR REPLACE INTO access
            (service, client, client_type, auth_value, auth_reason,
             auth_version, indirect_object_identifier, last_modified)
        VALUES (?, ?, ?, ?, 2, 1, 'UNUSED', CAST(strftime('%s','now') AS INTEGER));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              let st = stmt else {
            return (sqlite3_errcode(handle),
                    String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(st) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(st, 1, service, -1, transient)
        sqlite3_bind_text(st, 2, client, -1, transient)
        sqlite3_bind_int(st, 3, Int32(clientType))
        sqlite3_bind_int(st, 4, allow ? 2 : 0)

        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE else {
            return (rc, String(cString: sqlite3_errmsg(handle)))
        }
        return (SQLITE_OK, "")
    }

    /// 隐藏的 root 写库模式（由 writeTCC 经 Authorization Services 启动）。
    /// 参数：dbPath service client clientType allow
    static func runHelper(_ args: [String]) -> Int32 {
        guard args.count >= 5 else {
            print("usage: --tcc-write <db> <service> <client> <clientType> <allow>")
            return 2
        }
        guard Privilege.isRoot else {
            print("must run as root")
            return 3
        }
        let allow = args[4] == "1"
        let (rc, message) = write(dbPath: args[0], service: args[1],
                                  client: args[2],
                                  clientType: Int(args[3]) ?? 0, allow: allow)
        print(rc == SQLITE_OK ? "ok" : message)
        return rc == SQLITE_OK ? 0 : 1
    }
}

enum PermissionReader {

    static let systemTCCPath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// 用户级 TCC.db。App 以 root 重启后 NSHomeDirectory() 会变成 /var/root，
    /// 那样读的是 root 自己的库（几乎总是空的），所以要取「控制台用户」的家目录。
    static var userTCCPath: String {
        userHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    }

    static func userHomeDirectory() -> String {
        guard geteuid() == 0 else { return NSHomeDirectory() }
        var st = stat()
        if stat("/dev/console", &st) == 0, let pw = getpwuid(st.st_uid) {
            let home = String(cString: pw.pointee.pw_dir)
            if !home.isEmpty, home != "/" { return home }
        }
        return NSHomeDirectory()
    }

    // -----------------------------------------------------------------
    // 缓存：右键菜单需要把「表格里的一行」映射回 TCC 记录，
    // 这里保留最近一次采集结果（按 pid）。
    // -----------------------------------------------------------------
    private static let cacheLock = NSLock()
    private static var lastReports: [Int32: PermissionReport] = [:]
    /// 插入顺序，超过上限时淘汰最早的那个（字典本身无序）
    private static var reportOrder: [Int32] = []
    private static let reportLimit = 16

    static func cachedReport(pid: Int32) -> PermissionReport? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return lastReports[pid]
    }

    private static func store(_ r: PermissionReport, pid: Int32) {
        cacheLock.lock()
        if lastReports[pid] == nil { reportOrder.append(pid) }
        lastReports[pid] = r
        while reportOrder.count > reportLimit {
            let old = reportOrder.removeFirst()
            lastReports.removeValue(forKey: old)
        }
        cacheLock.unlock()
    }

    // -----------------------------------------------------------------
    // 采集入口
    // -----------------------------------------------------------------

    static func report(pid: Int32, path: String) -> PermissionReport {
        var rows: [PermissionRow] = []
        // SIP 与 task port 不在本页显示：SIP 移到「系统信息」窗口，
        // task port 已在概览页；这里只保留「这个进程自己的权限」。
        let sip = SipStatus.current

        rows += entitlementRows(pid: pid, path: path)

        let ids = identities(pid: pid, path: path)
        let (tccRows, readable) = tccRows(ids: ids)
        rows += tccRows

        let rep = PermissionReport(rows: rows, sip: sip, tccReadable: readable)
        store(rep, pid: pid)
        return rep
    }

    /// 表格 .lines 负载：不输出表头（表头由 Swift 侧按当前语言给）。
    static func lines(_ r: PermissionReport) -> [String] {
        r.rows.map {
            // 权限名 / 详情里可能带路径或 entitlements 值，Tab 与换行会破坏分列
            [$0.category, $0.name, $0.state, $0.detail, $0.source]
                .map(TSV.field).joined(separator: "\t")
        }
    }

    // -----------------------------------------------------------------
    // SIP
    // -----------------------------------------------------------------

    private static let sipLock = NSLock()
    private static var sipCached: SipStatus?

    private static func sipStatusNow() -> SipStatus {
        var active: UInt32 = 0
        var fromAPI: Int32 = 0
        // SIP 配置只能在重启时改变，取到一次就一直用
        guard cproc_sip_config(&active, &fromAPI) == 0 else {
            return SipStatus(readable: false, active: 0, fromAPI: false)
        }
        return SipStatus(readable: true, active: active, fromAPI: fromAPI != 0)
    }

    /// SIP 明细行（「系统信息」窗口用；权限页不再显示）
    static func sipInformation() -> [PermissionRow] { sipRows(SipStatus.current) }

    static func sipRows(_ s: SipStatus) -> [PermissionRow] {
        guard s.readable else {
            return [PermissionRow(
                category: L("perm.catSip"), name: L("perm.sipStatus"),
                state: L("perm.stateUnknown"), detail: L("perm.sipUnreadable"),
                source: L("perm.sipSourceProbe"))]
        }
        let source = s.fromAPI ? L("perm.sipSourceAPI") : L("perm.sipSourceProbe")
        let raw = L("perm.sipRaw", String(format: "0x%08x", s.active))

        let state: String
        if s.enabled { state = L("perm.stateEnabled") }
        else if s.fullyDisabled { state = L("perm.stateDisabled") }
        else { state = L("perm.stateCustom") }

        var rows = [PermissionRow(
            category: L("perm.catSip"), name: L("perm.sipStatus"),
            state: state, detail: raw, source: source)]

        rows.append(PermissionRow(
            category: L("perm.catSip"), name: L("perm.sipFilesystem"),
            state: s.filesystemProtections ? L("perm.stateEnabled")
                                           : L("perm.stateDisabled"),
            detail: s.canWriteTCC ? L("perm.sipWritable") : L("perm.sipReadOnly"),
            source: source))

        rows.append(PermissionRow(
            category: L("perm.catSip"), name: L("perm.sipDebugging"),
            state: s.debuggingRestricted ? L("perm.stateEnabled")
                                          : L("perm.stateDisabled"),
            detail: raw, source: source))

        rows.append(PermissionRow(
            category: L("perm.catSip"), name: L("perm.sipTaskPort"),
            state: s.taskForPidAllowed ? L("perm.sipTaskAllowed")
                                        : L("perm.sipTaskRestricted"),
            detail: raw, source: source))
        return rows
    }

    // -----------------------------------------------------------------
    // entitlements
    // -----------------------------------------------------------------

    private static func entitlementRows(pid: Int32, path: String) -> [PermissionRow] {
        guard let ent = SigningReader.entitlements(pid: pid, path: path),
              !ent.isEmpty else {
            return [PermissionRow(
                category: L("perm.catEntitlement"), name: "—",
                state: L("perm.stateDeclared"),
                detail: L("perm.noEntitlements"),
                source: L("perm.entitlementSource"))]
        }
        let flat = flatten(ent).sorted { $0.0 < $1.0 }
        return flat.map { (key, value) in
            PermissionRow(category: L("perm.catEntitlement"), name: key,
                          state: L("perm.stateDeclared"), detail: value,
                          source: L("perm.entitlementSource"))
        }
    }

    private static func flatten(_ dict: [String: Any],
                                prefix: String = "") -> [(String, String)] {
        var out: [(String, String)] = []
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let d = v as? [String: Any] {
                out += flatten(d, prefix: key)
            } else if let a = v as? [Any] {
                out.append((key, a.map { scalar($0) }.joined(separator: ", ")))
            } else {
                out.append((key, scalar(v)))
            }
        }
        return out
    }

    /// entitlement 里的布尔值是 CFBoolean → NSNumber，直接 "\(v)" 会变成 1 / 0
    private static func scalar(_ v: Any) -> String {
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return n.boolValue ? "true" : "false"
        }
        return "\(v)"
    }

    // -----------------------------------------------------------------
    // TCC
    // -----------------------------------------------------------------

    private struct Identities {
        var paths: Set<String>
        var bundleIDs: Set<String>
        /// 新建记录时优先用 bundle id，没有就用路径
        var preferred: (client: String, type: Int)?
    }

    private static func identities(pid: Int32, path: String) -> Identities {
        var paths = Set<String>()
        var bundleIDs = Set<String>()

        func addPath(_ p: String) {
            guard !p.isEmpty else { return }
            paths.insert(p)
            // 解析符号链接与 /private 前缀差异（TCC 里两种都可能出现）
            if let r = realpath(p, nil) {
                paths.insert(String(cString: r))
                free(r)
            }
            if p.hasPrefix("/var/") { paths.insert("/private" + p) }
            if p.hasPrefix("/tmp/") { paths.insert("/private" + p) }
        }
        addPath(path)

        // 进程所属 .app（含 helper 时的宿主 app）
        var url = URL(fileURLWithPath: path)
        while url.path != "/" && !url.path.isEmpty {
            if url.pathExtension == "app" {
                addPath(url.path)
                if let b = Bundle(url: url)?.bundleIdentifier {
                    bundleIDs.insert(b)
                }
            }
            url.deleteLastPathComponent()
        }

        // 签名标识符（未签名 app 只有这一项可能是 TCC 的 client）
        if let ident = SigningReader.signingIdentifier(pid: pid, path: path) {
            bundleIDs.insert(ident)
        }

        var preferred: (String, Int)?
        if let b = bundleIDs.first(where: { $0.contains(".") }) {
            preferred = (b, 0)
        } else if !path.isEmpty {
            preferred = (path, 1)
        }
        return Identities(paths: paths, bundleIDs: bundleIDs, preferred: preferred)
    }

    private static func tccRows(ids: Identities) -> ([PermissionRow], Bool) {
        // 只读系统正式路径。TCC.db 受 SIP / TCC 自己保护，没有「完全磁盘
        // 访问」时 open 会失败 —— 这时明确提示去授权，不拿任何副本来凑数。
        let scopes: [(system: Bool, path: String)] = [
            (true, systemTCCPath),
            (false, userTCCPath),
        ]

        var matched: [TCCRecord] = []
        var anyReadable = false
        for s in scopes {
            guard let table = query(s.path, isSystem: s.system) else { continue }
            anyReadable = true
            for row in table {
                guard matches(row, ids: ids), let rec = record(from: row) else {
                    continue
                }
                matched.append(rec)
            }
        }

        guard anyReadable else {
            return ([PermissionRow(
                category: L("perm.catTcc"), name: L("perm.tccDatabase"),
                state: L("perm.tccNoAccess"), detail: L("perm.tccFDAHint"),
                source: "TCC.db")], false)
        }

        // 没有 bundle id 也没有路径（例如 kernel_task）：拿不到 client 身份，
        // 匹配不出任何记录，再列一屏「未请求」只会误导。
        guard ids.preferred != nil || !ids.paths.isEmpty else {
            return ([PermissionRow(
                category: L("perm.catTcc"), name: L("perm.tccDatabase"),
                state: L("perm.stateUnknown"), detail: L("perm.tccNoClient"),
                source: "TCC.db")], anyReadable)
        }

        var rows: [PermissionRow] = []
        var seen = Set<String>()

        // 1) 已有记录：按服务目录顺序排，未知服务排在后面
        let order = serviceCatalog.map { $0.0 }
        matched.sort { a, b in
            let ia = order.firstIndex(of: a.service) ?? Int.max
            let ib = order.firstIndex(of: b.service) ?? Int.max
            if ia != ib { return ia < ib }
            return a.service < b.service
        }
        for rec in matched {
            let key = "\(rec.service)|\(rec.client)|\(rec.isSystem)"
            if seen.contains(key) { continue }
            seen.insert(key)
            rows.append(tccRow(rec, service: rec.service))
        }

        // 没有记录的服务不再逐条列出（一屏「未请求」没有信息量）；
        // 一条记录都没有时给一行汇总，至少说明「确实没授权过」。
        if rows.isEmpty {
            rows.append(PermissionRow(
                category: L("perm.catTcc"), name: L("perm.tccDatabase"),
                state: L("perm.tccNoRecords"),
                detail: "", source: L("perm.tccSourceUser")))
        }

        return (rows, true)
    }

    private static func tccRow(_ rec: TCCRecord, service: String) -> PermissionRow {
        let state: String
        switch rec.authValue {
        case 2: state = L("perm.stateAllowed")
        case 0: state = L("perm.stateDenied")
        case 3: state = L("perm.stateLimited")
        default: state = L("perm.stateUnknownValue", String(rec.authValue))
        }

        var bits: [String] = []
        bits.append(L("perm.tccClient", rec.client))
        bits.append(L("perm.tccReason", reasonText(rec.authReason)))
        if rec.lastModified > 0 {
            let d = Date(timeIntervalSince1970: TimeInterval(rec.lastModified))
            bits.append(L("perm.tccModified",
                          DateFormatter.localizedString(from: d,
                                                        dateStyle: .short,
                                                        timeStyle: .short)))
        }

        let source = rec.isSystem ? L("perm.tccSourceSystem")
                                  : L("perm.tccSourceUser")
        return PermissionRow(category: L("perm.catTcc"),
                             name: displayName(for: rec.service),
                             state: state,
                             detail: bits.joined(separator: " · "),
                             source: source,
                             record: rec, service: rec.service)
    }

    private static func reasonText(_ reason: Int) -> String {
        switch reason {
        case 0: return L("perm.tccReasonUnknown", "0")
        case 1: return L("perm.tccReasonSystem")
        case 2: return L("perm.tccReasonUser")
        case 3: return L("perm.tccReasonServicePolicy")
        case 4: return L("perm.tccReasonSystemPolicy")
        case 5: return L("perm.tccReasonPrompt")
        case 6: return L("perm.tccReasonPrompt")
        default: return L("perm.tccReasonUnknown", String(reason))
        }
    }

    /// access 表的一行（列名 → 文本）→ 结构化记录
    private static func record(from row: [String: String]) -> TCCRecord? {
        guard let service = row["service"], let client = row["client"] else {
            return nil
        }
        func int(_ key: String) -> Int { Int(row[key] ?? "") ?? 0 }
        return TCCRecord(service: service,
                         client: client,
                         clientType: int("client_type"),
                         authValue: int("auth_value"),
                         authReason: int("auth_reason"),
                         lastModified: int("last_modified"),
                         isSystem: row["__system"] == "1")
    }

    private static func matches(_ row: [String: String], ids: Identities) -> Bool {
        guard let client = row["client"] else { return false }
        let type = Int(row["client_type"] ?? "0") ?? 0
        if type == 0 {
            return ids.bundleIDs.contains(client)
        }
        // client_type == 1：绝对路径；realpath 归一化后比较
        if ids.paths.contains(client) { return true }
        if let r = realpath(client, nil) {
            defer { free(r) }
            return ids.paths.contains(String(cString: r)) ||
                ids.paths.contains(client)
        }
        return false
    }

    /// 读 access 表。返回「列名 → 文本值」，对 schema 版本差异
    /// （auth_value 等新列）免疫。打不开（权限 / 文件不在）返回 nil。
    private static func query(_ path: String, isSystem: Bool) -> [[String: String]]? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK,
              let handle = db else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(handle) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT * FROM access", -1, &stmt, nil)
                == SQLITE_OK, let s = stmt else { return nil }
        defer { sqlite3_finalize(s) }

        let cols = Int(sqlite3_column_count(s))
        var names: [String] = []
        names.reserveCapacity(cols)
        for i in 0..<cols {
            names.append(String(cString: sqlite3_column_name(s, Int32(i))))
        }

        var out: [[String: String]] = []
        while sqlite3_step(s) == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<cols {
                if sqlite3_column_type(s, Int32(i)) == SQLITE_NULL { continue }
                if let c = sqlite3_column_text(s, Int32(i)) {
                    row[names[i]] = String(cString: c)
                }
            }
            guard row["service"] != nil, row["client"] != nil else { continue }
            row["__system"] = isSystem ? "1" : "0"
            out.append(row)
        }
        return out
    }

    /// 新建 TCC 记录时会用到的 client 标识（有 bundle id 用 bundle id）
    static func preferredClient(pid: Int32, path: String) -> String? {
        identities(pid: pid, path: path).preferred?.client
    }

    // -----------------------------------------------------------------
    // 写回（授予 / 撤销）
    // -----------------------------------------------------------------

    /// 把某服务对某进程的授权改成「允许 / 拒绝」。
    ///
    /// 写库走 SQLite3 系统库（与读取同一套 API，不拼 SQL 字符串、不调
    /// /usr/bin/sqlite3）。当前不是 root 时，通过 Authorization Services
    /// 以 root 启动本可执行文件的隐藏模式 `--tcc-write` 去写：
    /// 同一个二进制、同样的签名，不需要额外的 helper target。
    static func writeTCC(service: String, record: TCCRecord?,
                         pid: Int32, path: String, allow: Bool) -> (ok: Bool, text: String) {
        guard SipStatus.current.canWriteTCC else {
            return (false, L("perm.writeBlockedBySip"))
        }

        let client: String
        let clientType: Int
        let dbPath: String
        if let r = record {
            client = r.client
            clientType = r.clientType
            dbPath = r.dbPath
        } else {
            let ids = identities(pid: pid, path: path)
            guard let pref = ids.preferred else {
                return (false, L("perm.writeNoClient"))
            }
            client = pref.client
            clientType = pref.type
            dbPath = userTCCPath
        }

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return (false, L("perm.writeNoDatabase", dbPath))
        }

        if Privilege.isRoot {
            let (rc, message) = TCCStore.write(dbPath: dbPath, service: service,
                                               client: client,
                                               clientType: clientType, allow: allow)
            return rc == SQLITE_OK
                ? (true, L("perm.writeSucceeded", dbPath))
                : (false, L("perm.writeFailed", message))
        }

        guard let exe = Bundle.main.executablePath else {
            return (false, L("perm.writeNoHelper"))
        }
        let (rc, output) = Privilege.runAsRoot(
            tool: exe,
            args: ["--tcc-write", dbPath, service, client,
                   String(clientType), allow ? "1" : "0"])
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if rc == 0 { return (true, L("perm.writeSucceeded", dbPath)) }
        return (false, L("perm.writeFailed",
                         detail.isEmpty ? "rc=\(rc)" : detail))
    }

    // -----------------------------------------------------------------
    // TCC 服务目录（常见项；未列出的服务用原始标识符显示）
    // -----------------------------------------------------------------

    private static let serviceCatalog: [(String, String)] = [
        ("kTCCServiceCamera", "perm.svc.camera"),
        ("kTCCServiceMicrophone", "perm.svc.microphone"),
        ("kTCCServiceScreenCapture", "perm.svc.screenCapture"),
        ("kTCCServiceAccessibility", "perm.svc.accessibility"),
        ("kTCCServiceAppleEvents", "perm.svc.appleEvents"),
        ("kTCCServiceLocation", "perm.svc.location"),
        ("kTCCServiceAddressBook", "perm.svc.contacts"),
        ("kTCCServiceCalendar", "perm.svc.calendars"),
        ("kTCCServiceReminders", "perm.svc.reminders"),
        ("kTCCServicePhotos", "perm.svc.photos"),
        ("kTCCServicePhotosAdd", "perm.svc.photosAddOnly"),
        ("kTCCServiceSystemPolicyAllFiles", "perm.svc.fullDiskAccess"),
        ("kTCCServiceSystemPolicyAppBundles", "perm.svc.appManagement"),
        ("kTCCServiceSystemPolicyDesktopFolder", "perm.svc.desktop"),
        ("kTCCServiceSystemPolicyDocumentsFolder", "perm.svc.documents"),
        ("kTCCServiceSystemPolicyDownloadsFolder", "perm.svc.downloads"),
        ("kTCCServiceListenEvent", "perm.svc.listenEvent"),
        ("kTCCServicePostEvent", "perm.svc.postEvent"),
        ("kTCCServiceBluetoothAlways", "perm.svc.bluetooth"),
        ("kTCCServiceMediaLibrary", "perm.svc.mediaLibrary"),
        ("kTCCServiceDeveloperTool", "perm.svc.developerTool"),
        ("kTCCServiceSpeechRecognition", "perm.svc.speechRecognition"),
        ("kTCCServiceMotion", "perm.svc.motion"),
        ("kTCCServiceUserTracking", "perm.svc.userTracking"),
    ]

    /// 尚未写入数据库的常见服务（右键「授予其他权限」子菜单用）
    static func grantableServices(excluding used: Set<String>)
        -> [(service: String, name: String)] {
        serviceCatalog.filter { !used.contains($0.0) }
            .map { (service: $0.0, name: displayName(for: $0.0)) }
    }

    /// 服务标识符 → 当前语言的可读名称（未知服务原样返回）
    static func displayName(for service: String) -> String {
        if let key = serviceCatalog.first(where: { $0.0 == service })?.1 {
            return L(key)
        }
        return service
    }
}

// ---------------------------------------------------------------------
// SIP 状态（只能在重启时改变：取到一次就缓存）
// ---------------------------------------------------------------------

extension SipStatus {
    static var current: SipStatus {
        PermissionReader.cachedSip()
    }
}

extension PermissionReader {
    /// SIP 配置只能在重启时改变：取到一次就一直缓存，不必反复问内核。
    fileprivate static func cachedSip() -> SipStatus {
        sipLock.lock()
        if let c = sipCached {
            sipLock.unlock()
            return c
        }
        sipLock.unlock()

        let s = sipStatusNow()
        sipLock.lock()
        sipCached = s
        sipLock.unlock()
        return s
    }
}
