// SPDX-License-Identifier: MIT
import Foundation
import Darwin

enum ProcessFilter: Int, CaseIterable {
    case all, mine, system, running, gui

    var title: String {
        switch self {
        case .all:     return L("store.allProcesses")
        case .mine:    return L("store.myProcesses")
        case .system:  return L("store.systemProcesses")
        case .running: return L("store.nonZombie")
        case .gui:     return L("store.guiAppsOnly")
        }
    }
}

enum SortKey: String {
    case name, pid, ppid, tty, user, cpu, mem, threads, ports
    case state, arch, cpuTime, start, cmd
}

final class ProcessStore {

    private(set) var processes: [ProcessSnapshot] = []
    private(set) var system = SystemSnapshot()

    // 系统曲线历史（最多 120 个采样点）
    private(set) var cpuUserHistory: [Double] = []
    private(set) var cpuSysHistory: [Double] = []
    private(set) var memHistory: [Double] = []
    private(set) var systemCPUUser: Double = 0
    private(set) var systemCPUSys: Double = 0

    var filter: ProcessFilter = .all { didSet { notify() } }
    var search: String = "" {
        didSet { updateRegexError(); notify() }
    }
    var treeMode: Bool = true {
        didSet {
            // 手动切树形 / 列表时结束排序循环，清掉表头三角。
            // applySort 内部会置 inSortBatch，避免把刚设好的 phase 又清掉。
            if !inSortBatch {
                sortPhase = 0
                sortIndicatorKey = nil
            }
            notify()
        }
    }
    var sortKey: SortKey = .cpu { didSet { notify() } }
    var ascending: Bool = false { didSet { notify() } }

    /// 表头三态循环：0=树形/无排序指示，1=第一次点击（正序），2=第二次（反序）
    private(set) var sortPhase: Int = 0
    /// 非 nil 时在对应表头画升降序三角
    private(set) var sortIndicatorKey: SortKey?

    private var inSortBatch = false
    private var notifySuspended = false

    var refreshInterval: TimeInterval = 1.0 {
        didSet { if started { schedule() } }
    }

    var onUpdate: (() -> Void)?

    private var previousCPU: [Int32: (u: UInt64, s: UInt64)] = [:]
    private var lastTimestamp: UInt64 = 0

    /// 已退出但仍在宽限期内显示的进程。
    /// 与 processes 分开存：CPU 差分、系统统计、process(withPID:) 都只看
    /// 真正存活的进程，只有生成可见数据源时才把宽限期记录追加进去。
    private struct ExitedRecord {
        var snapshot: ProcessSnapshot
        var remaining: Int
    }
    private var exiting: [Int32: ExitedRecord] = [:]

    /// 当前宽限期内仍可见的退出进程数量（状态栏用）
    var exitedVisibleCount: Int { exiting.count }
    private var timer: Timer?
    private var started = false
    private var generation: UInt64 = 0
    private let queue = DispatchQueue(label: "com.vantage.collect",
                                      qos: .userInitiated)

    /// 启动时套用偏好设置里的默认视图 / 刷新间隔。
    /// 用批量抑制避免 5 个 didSet 各发一次通知、重复 reload。
    func applyDefaults() {
        let p = Preferences.shared
        notifySuspended = true
        treeMode = p.defaultTreeMode
        filter = p.defaultFilter
        sortKey = p.defaultSortKey
        ascending = p.defaultAscending
        sortPhase = 0
        sortIndicatorKey = nil
        refreshInterval = p.refreshInterval
        notifySuspended = false
        notify()
    }

    /// 表头点击的三态变化一次性提交：只发一次通知 → 只 reload 一次。
    func applySort(key: SortKey, ascending asc: Bool, phase: Int,
                   treeMode tree: Bool, indicator: SortKey?) {
        notifySuspended = true
        inSortBatch = true
        sortKey = key
        ascending = asc
        sortPhase = phase
        sortIndicatorKey = indicator
        treeMode = tree
        inSortBatch = false
        notifySuspended = false
        notify()
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: refreshInterval,
                                     repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer = t
    }

    func refresh() {
        generation &+= 1
        let g = generation
        queue.async { [weak self] in
            guard let self = self else { return }
            let collected = ProcBridge.collect()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == g else { return }
                if let c = collected {
                    self.apply(c.procs, sys: c.sys)
                } else {
                    self.notify()
                }
            }
        }
    }

    private func apply(_ newProcs: [ProcessSnapshot], sys: SystemSnapshot) {
        let dtNS: UInt64 = (lastTimestamp > 0 && sys.timestampNS > lastTimestamp)
            ? sys.timestampNS - lastTimestamp : 0
        let dt = Double(dtNS) / 1_000_000_000.0
        let cores = max(1.0, Double(sys.logicalCPUs))

        var updated = newProcs
        var next: [Int32: (u: UInt64, s: UInt64)] = [:]
        var userDelta = 0.0
        var sysDelta = 0.0

        for i in 0..<updated.count {
            let p = updated[i]
            if dt > 0, let old = previousCPU[p.pid] {
                let du = p.cpuUserNS >= old.u ? p.cpuUserNS - old.u : 0
                let ds = p.cpuSysNS  >= old.s ? p.cpuSysNS  - old.s : 0
                // Activity Monitor 口径：单核 100%，不除以核数
                updated[i].cpuPercent = (Double(du + ds) / 1_000_000_000.0) / dt * 100.0
                userDelta += Double(du) / 1_000_000_000.0
                sysDelta  += Double(ds) / 1_000_000_000.0
            } else {
                updated[i].cpuPercent = 0
            }
            next[p.pid] = (p.cpuUserNS, p.cpuSysNS)
        }

        if dt > 0 {
            systemCPUUser = min(100.0, userDelta / (dt * cores) * 100.0)
            systemCPUSys  = min(100.0, sysDelta  / (dt * cores) * 100.0)
        }

        cpuUserHistory.append(systemCPUUser)
        cpuSysHistory.append(systemCPUSys)
        memHistory.append(sys.memTotal > 0
                          ? Double(sys.memUsed) / Double(sys.memTotal) * 100.0
                          : 0)
        trim(&cpuUserHistory)
        trim(&cpuSysHistory)
        trim(&memHistory)

        // updateExited 需要读「上一帧」的 processes，必须在赋值之前调用
        updateExited(alive: updated)
        processes = updated
        system = sys
        previousCPU = next
        lastTimestamp = sys.timestampNS
        notify()
    }

    private func trim(_ a: inout [Double]) {
        let cap = Preferences.shared.historyPoints
        if a.count > cap { a.removeFirst(a.count - cap) }
    }

    private func notify() {
        guard !notifySuspended else { return }
        onUpdate?()
        NotificationCenter.default.post(name: .procStoreDidUpdate, object: self)
    }

    // ---------------------------------------------------------------
    // 已退出进程宽限期
    // ---------------------------------------------------------------

    /// 每帧刷新调用一次（在 `processes` 被本帧结果替换之前）。
    ///
    /// 语义：x = `exitedKeepRefreshes`。进程消失那一帧加入记录，remaining=x；
    /// 之后每帧递减，到 0 移除 —— 也就是从发现退出算起共显示 x 帧。
    /// 计数按「刷新次数」而非秒数，所以改刷新间隔后可见时长会同比变化。
    private func updateExited(alive: [ProcessSnapshot]) {
        let p = Preferences.shared
        guard p.highlightExited, p.exitedKeepRefreshes > 0 else {
            if !exiting.isEmpty { exiting.removeAll() }
            return
        }
        let aliveIDs = Set(alive.map { $0.pid })

        // 1) 已有记录：PID 被复用/进程重新出现 → 直接移除；否则递减一次
        for pid in Array(exiting.keys) {
            if aliveIDs.contains(pid) {
                exiting.removeValue(forKey: pid)
            } else if var rec = exiting[pid] {
                rec.remaining -= 1
                if rec.remaining <= 0 {
                    exiting.removeValue(forKey: pid)
                } else {
                    exiting[pid] = rec
                }
            }
        }

        // 2) 上一帧存活、这一帧消失 → 新记录（本帧不参与上面的递减）
        let x = p.exitedKeepRefreshes
        for old in processes where !aliveIDs.contains(old.pid)
                    && exiting[old.pid] == nil {
            var snap = old
            snap.isExited = true
            snap.exitRemaining = x
            snap.cpuPercent = 0      // 不再参与 CPU 排序/高亮阈值
            exiting[old.pid] = ExitedRecord(snapshot: snap, remaining: x)
        }
    }

    /// 生成数据源时才把宽限期记录追加到存活进程后面。
    /// 退出进程的 ppid 若仍指向存活父进程，树形视图会自然把它挂回去；
    /// 父进程也没了则成为根节点。
    private func visibleSnapshots() -> [ProcessSnapshot] {
        guard !exiting.isEmpty else { return processes }
        var out = processes
        out.reserveCapacity(processes.count + exiting.count)
        for rec in exiting.values {
            var s = rec.snapshot
            s.exitRemaining = rec.remaining
            out.append(s)
        }
        return out
    }

    // ---------------------------------------------------------------
    // 过滤 / 排序 / 树
    // ---------------------------------------------------------------

    /// 当前搜索表达式的编译错误（模式有效 / 字面量模式时为 nil）。
    /// 在 `search` 的 didSet 与 `reapplySearch()` 里就算好：通知发出时
    /// 状态栏已经能读到最新值，不必等主表 filtered() 跑完。
    private(set) var searchRegexError: String?
    /// 编译一次供 filtered() 复用：刷新每帧都会过滤，没必要重复编译正则。
    private var cachedMatcher = SearchMatcher(query: "", mode: .literal)

    private func updateRegexError() {
        let m = SearchMatcher(
            query: search,
            mode: Preferences.shared.searchUseRegex ? .regex : .literal)
        cachedMatcher = m
        searchRegexError = m.isEmpty ? nil : m.errorText
    }

    /// 搜索模式切换后重新过滤一次（search 值没变，didSet 不会触发）。
    func reapplySearch() { updateRegexError(); notify() }

    private func filtered() -> [ProcessSnapshot] {
        let matcher = cachedMatcher
        let me = Int32(getuid())

        return visibleSnapshots().filter { p in
            switch self.filter {
            case .all:     break
            case .mine:    if p.uid != me { return false }
            case .system:  if p.uid != 0 { return false }
            case .running: if p.stateName == "ZOMBIE" { return false }
            case .gui:     if !p.isGUIApp { return false }
            }
            if !matcher.isEmpty {
                // 名称显示可以开关，但搜索始终覆盖应用名、Bundle 本地化名、
                // 原始进程名与可执行文件 basename —— 看到或没看到 raw 名，
                // 都能直接搜 crashpad_handler 这类真实身份。
                // 只有开启本地化名时才去读 Info.plist（AppNameResolver 带缓存）
                let loc = Preferences.shared.useLocalizedAppName
                    ? (p.localizedAppName ?? "") : ""
                // 字段级匹配：正则里的 ^ / $ 作用于单个字段，
                // 而不是被拼成一整行后失配（^WeChat$ 能精确命中名称）。
                let fields = [p.displayLabel, loc, p.displayName,
                              p.rawName, p.name, p.comm, p.cmdline,
                              String(p.pid), p.userName, p.ttyName,
                              p.exepath, p.bundlePath ?? "",
                              p.stateName, p.archName]
                if !matcher.matches(anyOf: fields) { return false }
            }
            return true
        }.sorted { a, b in self.compare(a, b) }
    }

    private func numeric(_ p: ProcessSnapshot) -> Double {
        switch sortKey {
        case .cpu:     return p.cpuPercent
        case .mem:     return Double(p.rss)
        case .threads: return Double(p.threads)
        case .pid:     return Double(p.pid)
        case .ppid:    return Double(p.ppid)
        case .ports:   return Double(p.nfiles)
        case .cpuTime: return Double(p.cpuTimeNS)
        case .start:   return Double(p.startSec) + Double(p.startUSec) / 1_000_000.0
        default:       return 0
        }
    }

    private func textual(_ p: ProcessSnapshot) -> String {
        switch sortKey {
        // 按主名称排序，不把「(raw)」后缀算进去：同一 Bundle 的主进程与
        // helper 仍聚在一起，切换名称显示开关也不会让顺序跳动。
        case .name:  return p.primaryDisplayName
        case .user:  return p.userName
        case .state: return p.stateName
        case .arch:  return p.archName
        case .cmd:   return p.cmdline
        case .tty:   return p.ttyShortName
        default:     return ""
        }
    }

    private func compare(_ a: ProcessSnapshot, _ b: ProcessSnapshot) -> Bool {
        let r: ComparisonResult
        switch sortKey {
        // .tty 之前漏在这里，会掉进 default 的 numeric() 返回 0，
        // 结果整列按 PID 排——「每列可排序」里唯一真正点不动的一列。
        case .name, .user, .state, .arch, .cmd, .tty:
            r = textual(a).localizedCaseInsensitiveCompare(textual(b))
        default:
            let va = numeric(a), vb = numeric(b)
            r = va < vb ? .orderedAscending : (va > vb ? .orderedDescending : .orderedSame)
        }
        if r == .orderedSame {
            return ascending ? a.pid < b.pid : a.pid > b.pid
        }
        return ascending ? (r == .orderedAscending) : (r == .orderedDescending)
    }

    /// 生成 NSOutlineView 的数据源：树模式保留父子层级，列表模式扁平
    func visibleTree() -> [ProcessNode] {
        let list = filtered()
        if !treeMode {
            return list.map { ProcessNode(proc: $0, children: []) }
        }

        var byParent: [Int32: [ProcessSnapshot]] = [:]
        var ids = Set<Int32>()
        for p in list {
            ids.insert(p.pid)
            // ppid == 0 的进程（kernel_task、launchd）本身就是根，
            // 若也塞进 byParent[0] 会变成「自己的子节点」重复显示（截图里
            // 出现两行 kernel_task 就是这个原因）；自引用同样要排除。
            if p.ppid > 0 && p.ppid != p.pid {
                byParent[p.ppid, default: []].append(p)
            }
        }

        var roots = list.filter { $0.ppid <= 0 || !ids.contains($0.ppid) }
        if roots.isEmpty { roots = list }   // 防御：进程链成环或 ppid 自引用

        let cmp: (ProcessSnapshot, ProcessSnapshot) -> Bool = { a, b in
            self.compare(a, b)
        }

        let maxDepth = Preferences.shared.treeMaxDepth
        func build(_ p: ProcessSnapshot, depth: Int,
                   visited: Set<Int32>) -> ProcessNode {
            if depth >= maxDepth || visited.contains(p.pid) {
                return ProcessNode(proc: p, children: [])
            }
            var next = visited
            next.insert(p.pid)
            let kids = (byParent[p.pid] ?? []).sorted(by: cmp)
            let children = kids.map { build($0, depth: depth + 1, visited: next) }
            return ProcessNode(proc: p, children: children)
        }

        return roots.sorted(by: cmp).map {
            build($0, depth: 0, visited: Set<Int32>())
        }
    }

    func process(withPID pid: Int32) -> ProcessSnapshot? {
        processes.first { $0.pid == pid }
    }
}
