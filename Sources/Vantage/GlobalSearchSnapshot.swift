// SPDX-License-Identifier: MIT
import Foundation

// ---------------------------------------------------------------------
// 全局搜索：固定快照 + 对所有进程取样
//
// 与主表搜索的区别：主表只搜「当前这一帧」的进程字段，且每 1 秒刷新一次，
// 输入关键字时结果会漂移。全局搜索在打开的那一刻拍一份 ProcessSnapshot
// 数组（值类型，天然独立），之后**所有采集与匹配都只针对这份快照**；
// 进程退出、新进程启动、主表过滤条件变化都不会改变结果集。
//
// 「尝试对所有进程取样」= 对快照里的每个 PID 逐页调用已有的详情采集入口，
// 复用 DetailLoadCache（命中就不重复付系统调用），失败 / 无数据都如实记入
// failures，不静默跳过。重活（vm_map 枚举、全系统 pipe 索引）默认不采，
// 由偏好开关决定是否加入，避免对几百个进程做几十万次系统调用。
//
// 采集与详情页共用 DetailLoadQueue 串行队列：C 层 g_pipe_index 是全局
// 静态变量且无锁，不能并发访问。但一次性把几百个进程塞进单个 block 会让
// 详情页的惰性采集排队几十秒，所以改成「每批 4 个进程」分片提交，
// 详情页最多等一批，不会被饿死。
// ---------------------------------------------------------------------

/// 一条可搜索的数据行。rawLine 保留 C 层原文（可能带双语标记），
/// fields / displayLine 是按当前界面语言解析后的版本。
struct GlobalSearchEntry {
    let pid: Int32
    let processName: String
    let sourceKey: String
    /// 对应检查器里的页签 index；nil = 只属于主表字段，跳到概览页
    let tabIndex: Int?
    let rawLine: String
    var fields: [String]
    var displayLine: String
}

struct GlobalSearchFailure {
    let pid: Int32
    let processName: String
    let sourceKey: String
    /// 本地化用的短码，不是最终显示文本
    let reasonKey: String
}

/// 一个采集来源（对应检查器里的一个页，或主表字段）
private struct GlobalSearchSource {
    let key: String
    let tabIndex: Int?
    let heavy: Bool
    /// 该页第一行表头的中文首列（与 DetailTabViewController.parse 的 titles 同源）。
    /// 采样时据此丢掉表头 —— 否则「FD / Type / Open Flags / Path」会变成一条可搜结果，
    /// 每个进程都来一遍，纯噪音。nil = 这个来源没有表头（主表字段 / 代码签名）。
    var header: String? = nil
    let load: (Int32, ProcessSnapshot) -> DetailLoadCache.Payload?
}

private enum GlobalSearchSources {
    /// 页签 index 与 DetailTabViewController.viewDidLoad 的顺序一一对应
    static func all(includeHeavy: Bool) -> [GlobalSearchSource] {
        var out: [GlobalSearchSource] = [
            GlobalSearchSource(key: "process", tabIndex: nil, heavy: false) { _, p in
                .lines(Self.processLines(p))
            },
        ]
        func c(_ key: String, _ tab: Int, _ header: String,
               _ kind: ProcBridge.DetailKind) -> GlobalSearchSource {
            GlobalSearchSource(key: key, tabIndex: tab, heavy: false, header: header) { pid, _ in
                .lines(ProcBridge.detail(kind, pid: pid))
            }
        }
        // 页签下标统一取自 DetailTab，避免插页签后这里静默错位
        out.append(c("files",       DetailTab.files.rawValue, "FD", .openFiles))
        out.append(c("env",         DetailTab.env.rawValue, "变量", .environment))
        out.append(c("sockets",     DetailTab.sockets.rawValue, "FD", .sockets))
        out.append(c("monitoring",  DetailTab.monitoring.rawValue, "FD", .monitoring))
        out.append(c("tty",         DetailTab.tty.rawValue, "项目", .tty))
        out.append(c("mach",        DetailTab.mach.rawValue, "项目", .machSecurity))
        out.append(c("audit",       DetailTab.audit.rawValue, "项目", .audit))
        out.append(GlobalSearchSource(key: "windows",
                                      tabIndex: DetailTab.windows.rawValue,
                                      heavy: false, header: "窗口号") { pid, _ in
            .lines(WindowLocator.detailLines(for: pid))
        })
        out.append(GlobalSearchSource(key: "signing",
                                      tabIndex: DetailTab.signing.rawValue,
                                      heavy: false) { pid, p in
            .pairs(SigningReader.read(pid: pid, path: p.exepath).rows)
        })

        if includeHeavy {
            func h(_ key: String, _ tab: Int, _ header: String,
                   _ kind: ProcBridge.DetailKind) -> GlobalSearchSource {
                GlobalSearchSource(key: key, tabIndex: tab, heavy: true, header: header) { pid, _ in
                    .lines(ProcBridge.detail(kind, pid: pid))
                }
            }
            out.append(h("dylibs",     DetailTab.dylibs.rawValue, "加载地址", .dylibs))
            // 线程清单要为每个进程逐线程调 proc_pidinfo，跟 vm_map 枚举一样
            // 归到「重活」：只在偏好里打开重活页时才参与全局搜索。
            out.append(h("threads",    DetailTab.threads.rawValue, "TID", .threads))
            out.append(h("pipePeers",  DetailTab.pipePeers.rawValue, "FD", .pipePeers))
            out.append(h("regions",    DetailTab.regions.rawValue, "起始地址", .regions))
        }
        return out
    }

    /// 主表字段 / 身份信息：不需要任何系统调用，直接由快照构造。
    /// 分成多行，正则 ^...$ 也能精确命中单个字段。
    static func processLines(_ p: ProcessSnapshot) -> [String] {
        let loc = Preferences.shared.useLocalizedAppName
            ? (p.localizedAppName ?? "") : ""
        let rows = [
            "\(p.pid)\t\(p.ppid)\t\(p.uid)\t\(p.userName)",
            "\(p.displayLabel)\t\(loc)\t\(p.displayName)",
            "\(p.rawName)\t\(p.name)\t\(p.comm)\t\(p.bundleExecutableName)",
            p.argv0,
            p.cmdline,
            p.exepath,
            p.bundlePath ?? "",
            p.bundleRoleText ?? "",
            "\(p.ttyName)\t\(p.ttyShortName)\t\(p.stateName)\t\(p.archName)",
            "\(p.rss)\t\(p.vss)\t\(p.threads)\t\(p.nfiles)",
        ]
        return rows.filter { !$0.isEmpty }
    }
}

final class GlobalSearchSession {

    let capturedAt: Date
    let processCount: Int
    /// 本次是否采了重活页（regions / threads / pipes / dylibs）；写进快照文件
    let includeHeavyPages: Bool
    /// 从文件导入时为文件名，本次现场采集时为 nil
    let importedFrom: String?
    private let processes: [ProcessSnapshot]

    /// 只在主线程读写：后台每完成一批就切一块增量交给主队列追加。
    private(set) var entries: [GlobalSearchEntry] = []
    private(set) var failures: [GlobalSearchFailure] = []
    private(set) var processed: Int = 0
    private(set) var finished = false
    private(set) var cancelledByUser = false
    private(set) var truncated = false

    private var cancelled = false
    private let stateLock = NSLock()

    /// 主线程回调：进度（已处理进程数 / 总数）、完成
    var onProgress: ((Int, Int) -> Void)?
    var onFinish: (() -> Void)?

    /// 每页最多保留的行数。regions 一页就能上万行，不设限会淹没结果。
    private static let perSourceCap = 2000
    /// 每批进程数：越大吞吐量越高，但详情页排队越久
    private static let batchSize = 4

    private struct Config {
        let maxRows: Int
        let epoch: UInt64
    }
    /// 批次间传递的可变状态，全部只在后台 block 内使用（值类型，无共享竞态）
    private struct BatchState {
        let sources: [GlobalSearchSource]
        var rowCount: Int
        var truncated: Bool
        var processed: Int
    }

    init(snapshot: [ProcessSnapshot], processCount: Int) {
        self.capturedAt = Date()
        self.processes = snapshot
        self.processCount = processCount
        self.includeHeavyPages = Preferences.shared.globalSearchHeavyPages
        self.importedFrom = nil
    }

    /// 从快照文件恢复：不再重采样，直接把行灌进来（界面表现为「已完成」）。
    /// rawLine 原样保留，所以切换界面语言后仍能按新语言重新解析。
    init(imported file: GlobalSearchSnapshotFile, name: String) {
        self.capturedAt = file.capturedAt
        self.processes = []
        self.processCount = file.processCount
        self.includeHeavyPages = file.includeHeavyPages
        self.importedFrom = name
        self.entries = file.entries.map { e in
            let text = L10n.resolveCText(e.rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = text.components(separatedBy: "\t")
            return GlobalSearchEntry(pid: e.pid, processName: e.processName,
                                     sourceKey: e.sourceKey, tabIndex: e.tabIndex,
                                     rawLine: e.rawLine, fields: fields,
                                     displayLine: fields.joined(separator: "  "))
        }
        self.failures = file.failures.map { f in
            GlobalSearchFailure(pid: f.pid, processName: f.processName,
                                sourceKey: f.sourceKey, reasonKey: f.reasonKey)
        }
        self.processed = file.processCount
        self.finished = true
        self.truncated = file.truncated
        self.cancelledByUser = file.cancelledByUser
    }

    /// 导出用：把当前内存里的行原样拍成文件模型（不再重采样）。
    func snapshotFile(appVersion: String, host: String, os: String)
        -> GlobalSearchSnapshotFile {
        GlobalSearchSnapshotFile(
            appVersion: appVersion, host: host, os: os,
            capturedAt: capturedAt, processCount: processCount,
            includeHeavyPages: includeHeavyPages,
            truncated: truncated, cancelledByUser: cancelledByUser,
            entries: entries.map {
                .init(pid: $0.pid, processName: $0.processName,
                      sourceKey: $0.sourceKey, tabIndex: $0.tabIndex,
                      rawLine: $0.rawLine)
            },
            failures: failures.map {
                .init(pid: $0.pid, processName: $0.processName,
                      sourceKey: $0.sourceKey, reasonKey: $0.reasonKey)
            })
    }

    func cancel() {
        stateLock.lock(); cancelled = true; stateLock.unlock()
    }

    private func isCancelled() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    func start() {
        let cfg = Config(
            maxRows: Preferences.shared.globalSearchMaxRows,
            epoch: ProcBridge.beginDetailEpoch())
        let st = BatchState(
            sources: GlobalSearchSources.all(
                includeHeavy: Preferences.shared.globalSearchHeavyPages),
            rowCount: 0, truncated: false, processed: 0)
        scheduleBatch(from: 0, state: st, config: cfg)
    }

    /// 一批只处理 batchSize 个进程，完成后回主队列合并增量、再排下一批。
    /// 详情页此时提交的采集最多排在这一批之后，不会被几百个进程饿死。
    private func scheduleBatch(from start: Int, state: BatchState,
                               config: Config) {
        DetailLoadQueue.queue.async { [weak self] in
            guard let self = self else { return }
            // epoch 是 thread-local，队列不保证固定线程，每批都要重新 mark
            ProcBridge.markDetailEpoch(config.epoch)

            let wasCancelled = self.isCancelled()
            let end = wasCancelled ? start
                : min(start + Self.batchSize, self.processes.count)
            var st = state
            var newEntries: [GlobalSearchEntry] = []
            var newFailures: [GlobalSearchFailure] = []

            if !wasCancelled {
                for i in start..<end {
                    if self.isCancelled() { break }
                    let p = self.processes[i]
                    for src in st.sources {
                        if self.isCancelled() || st.rowCount >= config.maxRows {
                            st.truncated = true
                            break
                        }

                        let payload: DetailLoadCache.Payload?
                        if src.key == "process" {
                            payload = src.load(p.pid, p)
                        } else if let hit = DetailLoadCache.shared.get(
                                    src.key, pid: p.pid, force: false) {
                            payload = hit
                        } else {
                            payload = src.load(p.pid, p)
                            if let pl = payload {
                                DetailLoadCache.shared.put(
                                    pl, key: src.key, pid: p.pid)
                            }
                        }

                        guard let pl = payload else {
                            newFailures.append(GlobalSearchFailure(
                                pid: p.pid, processName: p.displayLabel,
                                sourceKey: src.key,
                                reasonKey: "collectionFailed"))
                            continue
                        }
                        var lines: [String]
                        switch pl {
                        case .lines(let v):   lines = v
                        case .pairs(let v):   lines = v.map { "\($0.0)\t\($0.1)" }
                        case .port(let port): lines = ["\(port)"]
                        }
                        // 表头（列名）和 __hint__ 提示行不是数据：放进结果里每个进程
                        // 都会贡献一条可搜的噪音行，跟 GUI 里「默认隐藏提示」保持一致。
                        if let header = src.header, let first = lines.first,
                           L10n.cFieldZh(first.components(separatedBy: "\t").first ?? "")
                            == header {
                            lines.removeFirst()
                        }
                        if lines.contains(where: { $0.hasPrefix(L10n.hintTag) }) {
                            lines.removeAll { $0.hasPrefix(L10n.hintTag) }
                        }
                        // 过滤完空空如也（页签本来就没内容）不算失败 —— 记成 failure
                        // 会让「显示失败」里堆满 tty / env 这种常态空页。
                        guard !lines.isEmpty else { continue }

                        if lines.count > Self.perSourceCap { st.truncated = true }
                        for raw in lines.prefix(Self.perSourceCap) {
                            if st.rowCount >= config.maxRows {
                                st.truncated = true
                                break
                            }
                            let text = L10n.resolveCText(raw)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if text.isEmpty { continue }
                            let fields = text.components(separatedBy: "\t")
                            newEntries.append(GlobalSearchEntry(
                                pid: p.pid, processName: p.displayLabel,
                                sourceKey: src.key, tabIndex: src.tabIndex,
                                rawLine: raw, fields: fields,
                                displayLine: fields.joined(separator: "  ")))
                            st.rowCount += 1
                        }
                    }
                    st.processed = i + 1
                    if st.rowCount >= config.maxRows { st.truncated = true; break }
                }
            }

            let more = !wasCancelled && !self.isCancelled()
                && end < self.processes.count
                && st.rowCount < config.maxRows
            let e = newEntries, f = newFailures
            let done = st.processed
            let truncatedNow = st.truncated

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.entries.append(contentsOf: e)
                self.failures.append(contentsOf: f)
                self.processed = done
                self.truncated = truncatedNow
                self.onProgress?(done, self.processCount)
                if more {
                    self.scheduleBatch(from: end, state: st, config: config)
                } else {
                    self.finish(wasCancelled: wasCancelled || self.isCancelled())
                }
            }
        }
    }

    private func finish(wasCancelled: Bool) {
        finished = true
        cancelledByUser = wasCancelled
        onFinish?()
    }

    /// 界面语言切换后按新语言重新解析所有行（只动主线程上的数组）。
    func reparseForLanguage() {
        for i in entries.indices {
            let text = L10n.resolveCText(entries[i].rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = text.components(separatedBy: "\t")
            entries[i].fields = fields
            entries[i].displayLine = fields.joined(separator: "  ")
        }
    }

    /// 来源 key → 本地化显示名（窗口层调用 L()）
    static func sourceTitle(_ key: String) -> String {
        L("gs.source.\(key)")
    }
}
