// SPDX-License-Identifier: MIT
import Foundation
import CProc

// 与 CPerf.h 的 CPERF_VALID_* 位定义保持一致。
// 不用 C 宏导入值，避免不同 SDK 下 (1ULL << n) 被推断成 Int32 造成歧义。
enum PerfValid: UInt64 {
    case cpu        = 1
    case cores      = 2
    case mem        = 4
    case disk       = 8
    case net        = 16
    case power      = 32
    case freq       = 64
    case temp       = 128
    case sysPower   = 256
    case fan        = 512
    case dvfs       = 1024
    case thermal    = 2048
    case soc        = 4096
    case residency  = 8192
    case tiers      = 16384
}

// CPerf.h 里 temp_source 是 uint32_t，Swift 侧导入为 UInt32。
// 这些常量必须显式写成 UInt32 才能用作 switch 的 expression pattern，
// 否则会被推断成 Int，与 UInt32 的 switch subject 不匹配。
enum PerfTempSource {
    static let none: UInt32 = 0
    static let smc: UInt32  = 1
    static let hid: UInt32  = 2
    static let pmu: UInt32  = 3   // PMU tdie：非核心热点，绝对值偏低
}

// CPerf.h 里 power_source 同样是 uint32_t。
enum PerfPowerSource {
    static let none: UInt32         = 0
    static let clpc: UInt32         = 1
    static let energyModel: UInt32  = 2
}

struct PerfSnapshot {
    let valid: UInt64
    let timestampNS: UInt64

    let cpuUserPct: Double
    let cpuSysPct: Double
    let cpuIdlePct: Double
    let cpuTotalPct: Double
    let pCorePct: Double
    let eCorePct: Double

    let cpuFreqMHz: Double
    let gpuFreqMHz: Double
    let cpuActiveRatio: Double
    let gpuActiveRatio: Double
    let pFreqMaxMHz: UInt32
    let eFreqMaxMHz: UInt32
    let mFreqMaxMHz: UInt32
    let gpuFreqMaxMHz: UInt32

    let eFreqMHz: Double
    let pFreqMHz: Double
    let mFreqMHz: Double
    let eActiveRatio: Double
    let pActiveRatio: Double
    let mActiveRatio: Double
    let tierCount: UInt32

    let cpuPowerW: Double
    let gpuPowerW: Double
    let anePowerW: Double
    let dramPowerW: Double
    let socPowerW: Double
    let sysPowerW: Double

    let cpuTempC: Double
    let gpuTempC: Double
    let maxTempC: Double
    let fanRPM: Double
    let thermalPressure: UInt32
    let tempSource: UInt32
    let matchedEnergyChannels: UInt32
    let matchedStateChannels: UInt32
    let powerSource: UInt32

    let diskReadBPS: Double
    let diskWriteBPS: Double
    let diskIOPS: Double
    let netRxBPS: Double
    let netTxBPS: Double

    let memUsed: UInt64
    let memTotal: UInt64
    let memWired: UInt64
    let memCompressed: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64

    let pCores: UInt32
    let eCores: UInt32
    let gpuCores: UInt32
    let nperflevels: UInt32

    let socName: String
    let status: String

    init?() {
        var r = cproc_perf_values_t()
        guard cproc_perf_latest(&r) == 0 else { return nil }

        valid = r.valid
        timestampNS = r.timestamp_ns

        cpuUserPct = r.cpu_user_pct
        cpuSysPct = r.cpu_sys_pct
        cpuIdlePct = r.cpu_idle_pct
        cpuTotalPct = r.cpu_total_pct
        pCorePct = r.p_core_pct
        eCorePct = r.e_core_pct

        cpuFreqMHz = r.cpu_freq_mhz
        gpuFreqMHz = r.gpu_freq_mhz
        cpuActiveRatio = r.cpu_active_ratio
        gpuActiveRatio = r.gpu_active_ratio
        pFreqMaxMHz = r.p_freq_max_mhz
        eFreqMaxMHz = r.e_freq_max_mhz
        mFreqMaxMHz = r.m_freq_max_mhz
        gpuFreqMaxMHz = r.gpu_freq_max_mhz

        eFreqMHz = r.e_freq_mhz
        pFreqMHz = r.p_freq_mhz
        mFreqMHz = r.m_freq_mhz
        eActiveRatio = r.e_active_ratio
        pActiveRatio = r.p_active_ratio
        mActiveRatio = r.m_active_ratio
        tierCount = r.tier_count

        cpuPowerW = r.cpu_power_w
        gpuPowerW = r.gpu_power_w
        anePowerW = r.ane_power_w
        dramPowerW = r.dram_power_w
        socPowerW = r.soc_power_w
        sysPowerW = r.sys_power_w

        cpuTempC = r.cpu_temp_c
        gpuTempC = r.gpu_temp_c
        maxTempC = r.max_temp_c
        fanRPM = r.fan_rpm
        thermalPressure = r.thermal_pressure
        tempSource = r.temp_source
        matchedEnergyChannels = r.matched_energy_channels
        matchedStateChannels = r.matched_state_channels
        powerSource = r.power_source

        diskReadBPS = r.disk_read_bps
        diskWriteBPS = r.disk_write_bps
        diskIOPS = r.disk_iops
        netRxBPS = r.net_rx_bps
        netTxBPS = r.net_tx_bps

        memUsed = r.mem_used
        memTotal = r.mem_total
        memWired = r.mem_wired
        memCompressed = r.mem_compressed
        swapUsed = r.swap_used
        swapTotal = r.swap_total

        pCores = r.p_cores
        eCores = r.e_cores
        gpuCores = r.gpu_cores
        nperflevels = r.nperflevels

        socName = String(cString: cproc_perf_soc_name())
        status = String(cString: cproc_perf_status())
    }

    func has(_ flag: PerfValid) -> Bool { (valid & flag.rawValue) != 0 }
}

/// C 层逐通道原始诊断（每次采样刷新，读取时加锁拷贝）。
enum PerfDiagnostics {
    static var text: String { String(cString: cproc_perf_diagnostics()) }
}

extension Notification.Name {
    static let perfDidUpdate = Notification.Name("com.vantage.perfDidUpdate")
}

/// 性能采样历史。C 层在自己的 pthread 上连续采样，这里只按时间戳去重并保留曲线。
final class PerformanceStore {

    static let shared = PerformanceStore()

    private(set) var history: [PerfSnapshot] = []
    private(set) var latest: PerfSnapshot?
    private var timer: Timer?
    private var lastTimestamp: UInt64 = 0
    private var maxPoints: Int { Preferences.shared.historyPoints }

    var onUpdate: (() -> Void)?

    func start(intervalMs: UInt32? = nil) {
        guard timer == nil else { return }
        let ms = intervalMs ?? UInt32(Preferences.shared.perfIntervalMs)
        _ = cproc_perf_start(ms)
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 0.2
        timer = t
        poll()
    }

    func setInterval(_ ms: UInt32) { cproc_perf_set_interval(ms) }

    func stop() {
        timer?.invalidate()
        timer = nil
        cproc_perf_stop()
    }

    private func poll() {
        guard let s = PerfSnapshot(), s.timestampNS != lastTimestamp else { return }
        lastTimestamp = s.timestampNS
        latest = s
        history.append(s)
        if history.count > maxPoints { history.removeFirst(history.count - maxPoints) }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onUpdate?()
            NotificationCenter.default.post(name: .perfDidUpdate, object: self)
        }
    }

    func series(_ keyPath: (PerfSnapshot) -> Double) -> [Double] {
        history.map(keyPath)
    }

    var isAppleSilicon: Bool { cproc_perf_is_apple_silicon() != 0 }
}

// ---------------------------------------------------------------------
// 格式化
// ---------------------------------------------------------------------

enum PerfFmt {
    /// 无效数据一律显示「—」，绝不用 0 冒充"传感器读不到"
    static func orDash(_ valid: Bool, _ value: String) -> String {
        valid ? value : "—"
    }

    static func watts(_ v: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", v)
    }

    static func temp(_ v: Double) -> String { String(format: "%.1f", v) }

    static func mhz(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.2f GHz", v / 1000.0)
                  : String(format: "%.0f MHz", v)
    }

    static func rate(_ bytesPerSec: Double) -> String {
        let mb = bytesPerSec / 1_000_000.0
        if mb >= 1000 { return String(format: "%.2f GB/s", mb / 1000.0) }
        if mb >= 1    { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", bytesPerSec / 1000.0)
    }

    // macmon / Activity Monitor 用 1024 进制（实际是 GiB/MiB，界面标 GB/MB）。
    // 铁证：同一时刻 Swap 用 10^9 显示 4.52 GB，用 2^30 显示 4.21 GB，
    // macmon 正是 4.21。分子分母用同一套单位，百分比才对得上。
    static func bytes(_ v: UInt64) -> String {
        let gib = 1024.0 * 1024.0 * 1024.0
        let g = Double(v) / gib
        return g >= 1 ? String(format: "%.2f GB", g)
                      : String(format: "%.0f MB", Double(v) / (1024.0 * 1024.0))
    }

    static func iops(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1fk", v / 1000.0) : String(format: "%.0f", v)
    }

    static func pressure(_ level: UInt32) -> String {
        switch level {
        case 0: return L("bridge.nominalNominal")
        case 1: return L("bridge.fair")
        case 2: return L("bridge.seriousSerious")
        case 3: return L("bridge.criticalCritical")
        default: return L("bridge.unknown")
        }
    }
}
