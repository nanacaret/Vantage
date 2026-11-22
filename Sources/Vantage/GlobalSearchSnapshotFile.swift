// SPDX-License-Identifier: MIT
import Compression
import Foundation

// ---------------------------------------------------------------------
// 全局搜索快照的文件格式 + 差分
//
// 快照（GlobalSearchSession）本来就是「某一刻的全量取样结果」，天生适合
// 存成文件：排查现场抓一份、发给别人打开、或者两台机器 / 两个时间点对比。
// 这里只依赖 Foundation，不碰 AppKit —— 方便单独编译测试（见 docs）。
//
// 文件是 UTF-8 JSON，默认再套一层 gzip（`.json.gz`）：一次 5 万行的快照
// 裸 JSON 约 5 MB、缩进版 15 MB，gzip 后 300–500 KB —— 发邮件、丢 issue 都现实。
// 读的时候按文件头 1f 8b 自动识别，所以 `.json`（未压缩）也能导入。
//
// JSON 内容：
//   * 外层字段记录来源（版本 / 主机 / 系统 / 拍摄时间 / 是否含重活页 /
//     是否被截断 / 是否被取消），这些决定了「这份数据能代表什么」；
//   * entries 保留 C 层原文 rawLine（含双语标记），语言切换时重新解析，
//     所以同一份文件在中英文界面下都能正确显示；
//   * failures 一起存：某进程采集失败是事实的一部分，导入后不该凭空消失。
//
// 差分按「pid + 来源」分组比较行集合：同一 pid 同一来源下，新增的行算 +，
// 消失的行算 −；只在一边出现的 pid 单独记一条「进程出现 / 消失」，不再把它
// 所有行都刷成 +/−（否则一次重启就是几千行噪音）。
// ---------------------------------------------------------------------

/// 导出格式。存成 Int 进 UserDefaults，所以顺序别改（新增只能往后加）。
enum GlobalSearchSnapshotFormat: Int, CaseIterable {
    /// `.json.gz`：默认，体积约为裸 JSON 的 1/5
    case gzip = 0
    /// `.json`：未压缩，方便 jq / 人看
    case json = 1

    var fileExtension: String {
        switch self {
        case .gzip: return "json.gz"
        case .json: return "json"
        }
    }
}

struct GlobalSearchSnapshotFile: Codable {

    /// 文件自识别标记；导入时校验，避免把随便一个 JSON 当快照。
    static let formatID = "vantage.globalsearch.snapshot"
    /// 格式版本。新增字段请保持向后兼容（用 optional），破坏性改动才 +1。
    static let currentVersion = 1

    struct Entry: Codable {
        var pid: Int32
        var processName: String
        var sourceKey: String
        /// 对应检查器页签；nil = 主表字段
        var tabIndex: Int?
        /// C 层原文，含双语标记，显示时再按当前语言解析
        var rawLine: String
    }

    struct Failure: Codable {
        var pid: Int32
        var processName: String
        var sourceKey: String
        /// 本地化短码，不是最终文本
        var reasonKey: String
    }

    var format: String
    var version: Int
    /// 导出时刻（与 capturedAt 不同：导入再导出时 capturedAt 不变）
    var createdAt: Date
    /// 导出端版本，例如 "Vantage 1.2.5"
    var appVersion: String
    var host: String
    var os: String
    /// 快照拍摄时刻（界面上的「拍摄于 …」就是它）
    var capturedAt: Date
    var processCount: Int
    var includeHeavyPages: Bool
    var truncated: Bool
    var cancelledByUser: Bool
    var entries: [Entry]
    var failures: [Failure]

    init(createdAt: Date = Date(), appVersion: String, host: String, os: String,
         capturedAt: Date, processCount: Int, includeHeavyPages: Bool,
         truncated: Bool, cancelledByUser: Bool,
         entries: [Entry], failures: [Failure]) {
        self.format = Self.formatID
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.host = host
        self.os = os
        self.capturedAt = capturedAt
        self.processCount = processCount
        self.includeHeavyPages = includeHeavyPages
        self.truncated = truncated
        self.cancelledByUser = cancelledByUser
        self.entries = entries
        self.failures = failures
    }

    /// 文件里没有这些字段时给人看的说明，用于「导入后状态行」
    var provenanceText: String {
        var parts = [appVersion, host]
        if !os.isEmpty { parts.append(os) }
        if includeHeavyPages { parts.append("heavy") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - 读写

enum GlobalSearchSnapshotIO {

    /// 只描述「为什么读不进来」，文案由界面层翻译（这个文件不依赖 L()）。
    enum LoadError: Error {
        case notSnapshot
        case tooNew(Int)
        case unreadable(String)
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func encode(_ snapshot: GlobalSearchSnapshotFile,
                       compress: Bool = true) throws -> Data {
        let json = try encoder().encode(snapshot)
        return compress ? Gzip.compress(json) : json
    }

    static func decode(_ data: Data) throws -> GlobalSearchSnapshotFile {
        var json = data
        if Gzip.isGzip(data) {
            guard let plain = Gzip.decompress(data) else {
                throw LoadError.unreadable("gzip payload is corrupt")
            }
            json = plain
        }
        let file: GlobalSearchSnapshotFile
        do {
            file = try decoder().decode(GlobalSearchSnapshotFile.self, from: json)
        } catch {
            // JSON 坏 / 字段缺失都归到「不是快照」，比把 Decodable 的原文
            // （一堆 codingPath）甩给用户友好
            throw LoadError.unreadable(error.localizedDescription)
        }
        guard file.format == GlobalSearchSnapshotFile.formatID else {
            throw LoadError.notSnapshot
        }
        guard file.version <= GlobalSearchSnapshotFile.currentVersion else {
            throw LoadError.tooNew(file.version)
        }
        return file
    }

    static func load(from url: URL) throws -> GlobalSearchSnapshotFile {
        try decode(try Data(contentsOf: url))
    }

    /// 写文件：扩展名是 `.json` 就写裸 JSON（方便 jq / 人看），其余一律 gzip。
    static func write(_ snapshot: GlobalSearchSnapshotFile, to url: URL) throws {
        let compress = url.pathExtension.lowercased() != "json"
        try encode(snapshot, compress: compress).write(to: url, options: .atomic)
    }

    /// `vantage-snapshot-20261122-021530.json.gz`：按拍摄时间命名，同目录不打架。
    /// 扩展名跟随偏好里的默认保存格式（`Preferences.snapshotSaveFormat` 传进来，
    /// 这个文件不依赖 Preferences，保持可单独编译）。
    static func defaultFileName(capturedAt: Date,
                                format: GlobalSearchSnapshotFormat = .gzip) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "vantage-snapshot-\(f.string(from: capturedAt)).\(format.fileExtension)"
    }
}

// MARK: - 差分

enum GlobalSearchDiff {

    enum Kind {
        /// 基线有、当前没有的行
        case removed
        /// 当前有、基线没有的行
        case added
        /// 只在当前快照里出现的进程
        case appeared
        /// 只在基线里出现的进程
        case gone
    }

    struct Row {
        let kind: Kind
        let pid: Int32
        let processName: String
        let sourceKey: String
        /// C 层原文（appeared / gone 为空，由界面用本地化文案填）
        let text: String
    }

    struct Summary {
        let rows: [Row]
        let added: Int
        let removed: Int
        let appeared: Int
        let gone: Int
        /// 行数超过上限被截断
        let truncated: Bool

        var isEmpty: Bool {
            added == 0 && removed == 0 && appeared == 0 && gone == 0
        }
    }

    /// 比较两份快照：`baseline` 是旧的那份，`current` 是新的那份。
    /// 行比较用 rawLine 原文（跟界面语言无关），显示时再解析。
    static func compute(baseline: GlobalSearchSnapshotFile,
                        current: GlobalSearchSnapshotFile,
                        maxRows: Int = 5000) -> Summary {
        typealias Lines = [String: Set<String>]
        func index(_ file: GlobalSearchSnapshotFile)
            -> (lines: [Int32: Lines], names: [Int32: String]) {
            var lines: [Int32: Lines] = [:]
            var names: [Int32: String] = [:]
            lines.reserveCapacity(file.entries.count)
            for e in file.entries {
                lines[e.pid, default: [:]][e.sourceKey, default: []].insert(e.rawLine)
                if names[e.pid] == nil { names[e.pid] = e.processName }
            }
            return (lines, names)
        }

        let old = index(baseline)
        let new = index(current)
        var rows: [Row] = []
        var added = 0, removed = 0, appeared = 0, gone = 0
        var truncated = false

        // pid 升序：结果稳定，导出的 diff 也能直接 diff
        let pids = Set(old.lines.keys).union(new.lines.keys).sorted()
        outer: for pid in pids {
            let before = old.lines[pid]
            let after = new.lines[pid]

            if before == nil {
                appeared += 1
                rows.append(Row(kind: .appeared, pid: pid,
                                processName: new.names[pid] ?? "",
                                sourceKey: "process", text: ""))
                if rows.count >= maxRows { truncated = true; break }
                continue
            }
            if after == nil {
                gone += 1
                rows.append(Row(kind: .gone, pid: pid,
                                processName: old.names[pid] ?? "",
                                sourceKey: "process", text: ""))
                if rows.count >= maxRows { truncated = true; break }
                continue
            }

            let sources = Set(before!.keys).union(after!.keys).sorted()
            let name = new.names[pid] ?? old.names[pid] ?? ""
            for source in sources {
                let b = before![source] ?? []
                let a = after![source] ?? []
                if b == a { continue }
                for line in b.subtracting(a).sorted() {
                    removed += 1
                    rows.append(Row(kind: .removed, pid: pid, processName: name,
                                    sourceKey: source, text: line))
                    if rows.count >= maxRows { truncated = true; break outer }
                }
                for line in a.subtracting(b).sorted() {
                    added += 1
                    rows.append(Row(kind: .added, pid: pid, processName: name,
                                    sourceKey: source, text: line))
                    if rows.count >= maxRows { truncated = true; break outer }
                }
            }
        }

        return Summary(rows: rows, added: added, removed: removed,
                       appeared: appeared, gone: gone, truncated: truncated)
    }
}

// MARK: - gzip

/// 最小 gzip 容器。Compression 框架的 `COMPRESSION_ZLIB` 输出是**裸 deflate**，
/// 外面补 10 字节头 + CRC32/ISIZE 尾就是标准 `.gz`（`gzip -t` / `gunzip` 都能处理，
/// 实测通过），所以不需要链 libz，也不用第三方依赖。
enum Gzip {

    static let magic: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 18 && data.prefix(2).elementsEqual([0x1f, 0x8b])
    }

    static func compress(_ data: Data) -> Data {
        var out = Data(magic)
        guard !data.isEmpty else {
            out.append(contentsOf: trailer(crc: 0, size: 0))
            return out
        }
        // deflate 最坏情况略大于输入，直接给足空间，一次调用即可
        var buffer = Data(count: data.count + 64 * 1024)
        let written = buffer.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        // 编码失败（几乎不可能）就返回原 JSON：读回来的时候按文件头识别，
        // 裸 JSON 也能导入，不会出现「写了个坏 gz」。
        guard written > 0 else { return data }
        out.append(buffer.prefix(written))
        out.append(contentsOf: trailer(crc: crc32(data),
                                       size: UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    static func decompress(_ data: Data) -> Data? {
        guard isGzip(data), let body = deflatePayload(data) else { return nil }
        let bytes = [UInt8](data.suffix(4))
        let isize = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        var capacity = Int(isize)
        if capacity == 0 { capacity = max(1024, body.count * 4) }
        while capacity <= 1 << 30 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                body.withUnsafeBytes { src -> Int in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                        src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                let plain = Data(out.prefix(written))
                // CRC 对不上说明文件坏了（截断 / 传输损坏），宁可报错也别导入脏数据
                let bytes = [UInt8](data.suffix(8))
                let crc = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                    | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                guard crc32(plain) == crc else { return nil }
                return plain
            }
            capacity *= 2
        }
        return nil
    }

    /// 跳过 gzip 头（含 FEXTRA / FNAME / FCOMMENT / FHCRC），只留 deflate 数据。
    private static func deflatePayload(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18 else { return nil }
        var i = 10
        let flags = bytes[3]
        if flags & 0x04 != 0 {                       // FEXTRA
            guard i + 2 <= bytes.count else { return nil }
            i += 2 + (Int(bytes[i]) | Int(bytes[i + 1]) << 8)
        }
        if flags & 0x08 != 0 {                       // FNAME
            while i < bytes.count && bytes[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x10 != 0 {                       // FCOMMENT
            while i < bytes.count && bytes[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }              // FHCRC
        guard i >= 10, bytes.count - 8 > i else { return nil }
        return Data(bytes[i..<(bytes.count - 8)])
    }

    private static func trailer(crc: UInt32, size: UInt32) -> [UInt8] {
        var c = crc.littleEndian, s = size.littleEndian
        return withUnsafeBytes(of: &c) { Array($0) } + withUnsafeBytes(of: &s) { Array($0) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(b)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
