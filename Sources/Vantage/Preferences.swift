// SPDX-License-Identifier: MIT
import Foundation
import AppKit
// cproc_limits_t / cproc_set_limits 来自 CProc.h，cproc_perf_set_interval
// 来自 CPerf.h；两者都在 CProc target 的 publicHeadersPath 下，必须显式导入
// 才能看到这些 C 声明（与 ProcBridge.swift / PerfBridge.swift 一致）。
import CProc

extension Notification.Name {
    /// 偏好设置变更后发出。各模块读最新值即可，不需要重启 App。
    static let preferencesDidChange =
        Notification.Name("com.vantage.preferencesDidChange")
}

/// 所有 limits / 选项集中在这里，由偏好设置界面编辑。
///
/// 分两类：
///  - 采集上限：通过 `cproc_set_limits` 下发给 C 采集层（下一次采集生效）
///  - 界面 / 行为选项：各模块运行时直接读取
/// 每个值都带 clamp，界面填 0 或超大值也不会把采集拖进死循环 / OOM。
final class Preferences {
    static let shared = Preferences()

    private let d = UserDefaults.standard
    private let prefix = "Vantage.pref."

    private func k(_ key: String) -> String { prefix + key }

    private func int(_ key: String, _ def: Int, _ lo: Int, _ hi: Int) -> Int {
        let v = d.object(forKey: k(key)) as? Int ?? def
        return min(max(v, lo), hi)
    }
    private func setInt(_ v: Int, _ key: String, _ lo: Int, _ hi: Int) {
        d.set(min(max(v, lo), hi), forKey: k(key))
    }
    private func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: k(key)) as? Bool ?? def
    }
    private func setBool(_ v: Bool, _ key: String) { d.set(v, forKey: k(key)) }
    private func double(_ key: String, _ def: Double, _ lo: Double, _ hi: Double) -> Double {
        let v = d.object(forKey: k(key)) as? Double ?? def
        return min(max(v, lo), hi)
    }
    private func string(_ key: String, _ def: String) -> String {
        d.string(forKey: k(key)) ?? def
    }

    // ---------------------------------------------------------------
    // 采集上限（下发给 C 层，对应 cproc_limits_t）
    // ---------------------------------------------------------------

    /// 单次 vm_map region 枚举上限。重 app 常有上万条映射，每条 2 次系统调用。
    var maxRegions: Int {
        get { int("maxRegions", 20000, 100, 200000) }
        set { setInt(newValue, "maxRegions", 100, 200000) }
    }
    /// 全系统 pipe 索引缓存时长（毫秒）
    var pipeCacheMs: Int {
        get { int("pipeCacheMs", 2000, 200, 60000) }
        set { setInt(newValue, "pipeCacheMs", 200, 60000) }
    }
    /// KERN_PROCARGS2 缓冲区上限（KiB）
    var argvMaxKB: Int {
        get { int("argvMaxKB", 1024, 4, 16384) }
        set { setInt(newValue, "argvMaxKB", 4, 16384) }
    }
    /// PROC_PIDLISTFDS 缓冲区上限（MiB）
    var fdMaxMB: Int {
        get { int("fdMaxMB", 64, 1, 256) }
        set { setInt(newValue, "fdMaxMB", 1, 256) }
    }
    /// SMC #KEY 枚举上限
    var smcMaxKeys: Int {
        get { int("smcMaxKeys", 65535, 128, 200000) }
        set { setInt(newValue, "smcMaxKeys", 128, 200000) }
    }

    // ---------------------------------------------------------------
    // 采集 / 缓存（Swift 侧）
    // ---------------------------------------------------------------

    /// 进程树最大递归深度，防止 ppid 成环
    var treeMaxDepth: Int {
        get { int("treeMaxDepth", 32, 4, 128) }
        set { setInt(newValue, "treeMaxDepth", 4, 128) }
    }
    /// 性能曲线 / 系统曲线保留的历史点数
    var historyPoints: Int {
        get { int("historyPoints", 120, 30, 600) }
        set { setInt(newValue, "historyPoints", 30, 600) }
    }
    /// 动态详情页缓存（文件 / socket / pipe / 监控），秒
    var dynamicTTL: Int {
        get { int("dynamicTTL", 2, 1, 60) }
        set { setInt(newValue, "dynamicTTL", 1, 60) }
    }
    /// TTY 页缓存，秒
    var ttyTTL: Int {
        get { int("ttyTTL", 5, 1, 120) }
        set { setInt(newValue, "ttyTTL", 1, 120) }
    }
    /// 静态详情页缓存（环境 / 镜像 / 映射 / 签名 / Mach），秒
    var staticTTL: Int {
        get { int("staticTTL", 60, 10, 600) }
        set { setInt(newValue, "staticTTL", 10, 600) }
    }
    /// /usr/bin/sample 采样时长，秒
    var sampleSeconds: Int {
        get { int("sampleSeconds", 3, 1, 30) }
        set { setInt(newValue, "sampleSeconds", 1, 30) }
    }

    // ---------------------------------------------------------------
    // 刷新 / 默认视图
    // ---------------------------------------------------------------

    var refreshInterval: TimeInterval {
        get { double("refreshInterval", 1.0, 0.5, 5.0) }
        set {
            d.set(min(max(newValue, 0.5), 5.0), forKey: k("refreshInterval"))
        }
    }
    var perfIntervalMs: Int {
        get { int("perfIntervalMs", 1000, 500, 5000) }
        set { setInt(newValue, "perfIntervalMs", 500, 5000) }
    }
    var defaultTreeMode: Bool {
        get { bool("defaultTreeMode", true) }
        set { setBool(newValue, "defaultTreeMode") }
    }
    var defaultFilter: ProcessFilter {
        get { ProcessFilter(rawValue: int("defaultFilter", 0, 0, 4)) ?? .all }
        set { setInt(newValue.rawValue, "defaultFilter", 0, 4) }
    }
    var defaultSortKey: SortKey {
        get { SortKey(rawValue: string("defaultSortKey", "cpu")) ?? .cpu }
        set { d.set(newValue.rawValue, forKey: k("defaultSortKey")) }
    }
    var defaultAscending: Bool {
        get { bool("defaultAscending", false) }
        set { setBool(newValue, "defaultAscending") }
    }

    // ---------------------------------------------------------------
    // 行为开关
    // ---------------------------------------------------------------

    /// 详情按页惰性加载；关闭则回到「一次选中采全部 13 页」（用于对比/排错）
    var lazyDetailLoading: Bool {
        get { bool("lazyDetailLoading", true) }
        set { setBool(newValue, "lazyDetailLoading") }
    }
    /// 点击表头排序时自动切到扁平列表（树形下排序只能作用于根/同层，看不出全局顺序）
    var sortAutoFlat: Bool {
        get { bool("sortAutoFlat", true) }
        set { setBool(newValue, "sortAutoFlat") }
    }
    /// 同一列三击循环：排序 → 反序 → 恢复树形；关闭则保持二态正反序
    var sortCycleToTree: Bool {
        get { bool("sortCycleToTree", true) }
        set { setBool(newValue, "sortCycleToTree") }
    }
    /// 表头显示升降序三角
    var showSortIndicator: Bool {
        get { bool("showSortIndicator", true) }
        set { setBool(newValue, "showSortIndicator") }
    }
    /// App 启动即开始性能采样（关闭则只在打开性能窗口时启动）
    var startPerfSampler: Bool {
        get { bool("startPerfSampler", true) }
        set { setBool(newValue, "startPerfSampler") }
    }
    /// 发送任何信号前弹确认框
    var confirmBeforeSignal: Bool {
        get { bool("confirmBeforeSignal", true) }
        set { setBool(newValue, "confirmBeforeSignal") }
    }
    /// 即使关掉上面的总开关，会终止 / 崩溃进程的信号仍强制确认
    var alwaysConfirmDestructive: Bool {
        get { bool("alwaysConfirmDestructive", true) }
        set { setBool(newValue, "alwaysConfirmDestructive") }
    }

    // ---------------------------------------------------------------
    // 进程名称显示
    // ---------------------------------------------------------------

    /// 有 bundle 的进程在显示应用名的同时，追加可执行文件的原始短名。
    /// 默认开：一个 .app 里的 helper（crashpad_handler / XPC / Renderer…）
    /// 与主进程共享 bundle，只显示应用名时无法判断真实身份。
    var showRawNameWithBundle: Bool {
        get { bool("showRawNameWithBundle", true) }
        set { setBool(newValue, "showRawNameWithBundle") }
    }

    /// argv[0] 的名字与真实可执行文件 basename 不同时，在名称列一并标注。
    /// 默认开：/bin/sh 是 /bin/bash 的硬链接、登录 shell 的 -bash、
    /// `exec -a` 自定义名等场景，光看 exe basename 判断不出调用方式。
    /// 与 bundle 的 raw 名共用 rawNameStyle 的包裹格式。
    var showArgv0WhenDifferent: Bool {
        get { bool("showArgv0WhenDifferent", true) }
        set { setBool(newValue, "showArgv0WhenDifferent") }
    }

    /// 主名称改用 Bundle 的本地化显示名（CFBundleDisplayName / CFBundleName）。
    /// 默认关，保持原来的 .app 目录名口径；开启后与 Activity Monitor 一致。
    var useLocalizedAppName: Bool {
        get { bool("useLocalizedAppName", false) }
        set {
            setBool(newValue, "useLocalizedAppName")
            AppNameResolver.invalidate()
        }
    }

    /// raw 名的拼接格式
    var rawNameStyle: RawNameStyle {
        get {
            let v = d.object(forKey: k("rawNameStyle")) as? Int
                ?? RawNameStyle.parentheses.rawValue
            return RawNameStyle(rawValue: v) ?? .parentheses
        }
        set { d.set(newValue.rawValue, forKey: k("rawNameStyle")) }
    }

    // ---------------------------------------------------------------
    // 界面：提示行 / 语言
    // ---------------------------------------------------------------

    /// 详情页是否显示 C 层追加的说明性「提示」行。**默认隐藏** —— 这些
    /// SIP / task port 说明对排错有用，但平时会把有效数据挤到下面。
    /// 直接复用 L10n 的 key，避免偏好窗口与 parse() 读到两份值。
    var showDetailHints: Bool {
        get { L10n.showDetailHints }
        set { L10n.showDetailHints = newValue }
    }

    /// 界面语言（跟随系统 / 简体中文 / English）
    var language: L10n.Language {
        get { L10n.language }
        set { L10n.language = newValue }
    }

    // ---------------------------------------------------------------
    // 右键 / 主菜单里显示的信号
    // ---------------------------------------------------------------

    /// 「发送信号」子菜单里显示哪些信号。存信号编号数组；空数组是合法值
    /// （全部不显示），所以用 `object(forKey:) == nil` 区分「没设过」与「清空」。
    var visibleSignalNumbers: Set<Int32> {
        get {
            guard let raw = d.array(forKey: k("visibleSignals")) else {
                return SignalCatalog.defaultNumbers
            }
            // UserDefaults 读回的是 [Any]（NSNumber），显式取 intValue
            // 比 `as? [Int]` 的桥接更稳。
            let nums = raw.compactMap { ($0 as? NSNumber)?.intValue }
            return Set(nums.map { Int32($0) })
                .intersection(SignalCatalog.all.map { $0.number })
        }
        set {
            d.set(Array(newValue).sorted().map { Int($0) },
                  forKey: k("visibleSignals"))
        }
    }
    /// 强制刷新时同时清空详情缓存
    var refreshInvalidatesDetail: Bool {
        get { bool("refreshInvalidatesDetail", true) }
        set { setBool(newValue, "refreshInvalidatesDetail") }
    }

    // ---------------------------------------------------------------
    // 搜索 / 全局搜索
    // ---------------------------------------------------------------

    /// 搜索框按正则表达式解析（主表、详情页当前页、全局搜索共用同一开关）。
    /// 默认关，保持原来的子串匹配；正则无效时自动回退到字面量并提示。
    var searchUseRegex: Bool {
        get { bool("searchUseRegex", false) }
        set { setBool(newValue, "searchUseRegex") }
    }
    /// 全局搜索是否包含重量级页（镜像 / Pipe 对端 / 内存映射）。
    /// 默认关：这三页对每个进程都要做完整 vm_map 枚举或全系统 FD 扫描，
    /// 对几百个进程全量取样会非常慢。
    var globalSearchHeavyPages: Bool {
        get { bool("globalSearchHeavyPages", false) }
        set { setBool(newValue, "globalSearchHeavyPages") }
    }
    /// 全局搜索一次最多保留多少条数据行；超出即截断并标注。
    var globalSearchMaxRows: Int {
        get { int("globalSearchMaxRows", 50000, 1000, 500000) }
        set { setInt(newValue, "globalSearchMaxRows", 1000, 500000) }
    }

    // ---------------------------------------------------------------
    // 设备树 / 扩展列表
    // ---------------------------------------------------------------

    /// 单次 IORegistry 树枚举的节点上限。Apple Silicon 的 IOService plane
    /// 常有数千节点，超限时截断并标注，避免 UI 卡死。
    var ioregMaxNodes: Int {
        get { int("ioregMaxNodes", 30000, 1000, 200000) }
        set { setInt(newValue, "ioregMaxNodes", 1000, 200000) }
    }
    /// 扩展列表是否额外扫描 /Applications 下 App 内嵌的 .appex /
    /// .systemextension。默认关：目录层级深，扫描明显变慢。
    var scanAppExtensions: Bool {
        get { bool("scanAppExtensions", false) }
        set { setBool(newValue, "scanAppExtensions") }
    }

    // ---------------------------------------------------------------
    // 已退出进程（高亮宽限期）
    // ---------------------------------------------------------------

    /// 是否在进程退出后继续高亮显示一小段时间
    var highlightExited: Bool {
        get { bool("highlightExited", true) }
        set { setBool(newValue, "highlightExited") }
    }
    /// 退出后再保留多少次刷新。默认 3（1 秒刷新 ≈ 可见 3 秒）；0 = 立即移除。
    /// 语义：从「发现退出」那一帧算起，共显示 x 帧，第 x+1 次刷新移除。
    var exitedKeepRefreshes: Int {
        get { int("exitedKeepRefreshes", 3, 0, 20) }
        set { setInt(newValue, "exitedKeepRefreshes", 0, 20) }
    }

    // ---------------------------------------------------------------
    // 下发 / 重置
    // ---------------------------------------------------------------

    private static let allKeys = [
        "maxRegions", "pipeCacheMs", "argvMaxKB", "fdMaxMB", "smcMaxKeys",
        "treeMaxDepth", "historyPoints", "dynamicTTL", "ttyTTL", "staticTTL",
        "sampleSeconds", "refreshInterval", "perfIntervalMs",
        "defaultTreeMode", "defaultFilter", "defaultSortKey",
        "defaultAscending", "lazyDetailLoading", "sortAutoFlat",
        "sortCycleToTree", "showSortIndicator", "startPerfSampler",
        "confirmBeforeSignal", "alwaysConfirmDestructive",
        "refreshInvalidatesDetail", "visibleSignals",
        "highlightExited", "exitedKeepRefreshes",
        "showRawNameWithBundle", "showArgv0WhenDifferent",
        "useLocalizedAppName", "rawNameStyle",
        "showDetailHints", "language",
        "searchUseRegex", "globalSearchHeavyPages", "globalSearchMaxRows",
        "ioregMaxNodes", "scanAppExtensions",
    ]

    /// 把 C 侧字段下发给采集层，并通知各模块刷新运行时选项。
    /// App 启动时调用一次；偏好设置里每次改动后也调用。
    func applyToRuntime() {
        var l = cproc_limits_t()
        l.max_regions    = UInt32(maxRegions)
        l.pipe_cache_ms  = UInt32(pipeCacheMs)
        l.argv_max_bytes = UInt32(argvMaxKB * 1024)
        l.fd_max_bytes   = UInt32(fdMaxMB * 1024 * 1024)
        l.smc_max_keys   = UInt32(smcMaxKeys)
        cproc_set_limits(&l)
        cproc_perf_set_interval(UInt32(perfIntervalMs))
        cproc_ioreg_set_max_nodes(UInt32(ioregMaxNodes))
        NotificationCenter.default.post(name: .preferencesDidChange, object: self)
    }

    /// 恢复出厂设置：删掉所有键再重新下发（getter 自带默认值）
    func reset() {
        for key in Self.allKeys { d.removeObject(forKey: k(key)) }
        // 这两个由 L10n 直接读写，不走 k() 前缀
        d.removeObject(forKey: L10n.languageKey)
        d.removeObject(forKey: L10n.hintsKey)
        AppNameResolver.invalidate()
        applyToRuntime()
        L10n.notifyChanged()
    }
}
