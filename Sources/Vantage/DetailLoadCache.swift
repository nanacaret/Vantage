// SPDX-License-Identifier: MIT
import Foundation

/// 详情采集结果缓存。
///
/// 之前每次选中进程都会把 13 个页签的数据全部采一遍，其中「镜像」和「映射」
/// 各自做一次完整的 vm_map region 枚举，「Pipe」「监控」各自触发一次全系统
/// pipe FD 扫描，签名校验还要读整个可执行文件。来回点选同一个重 app 时，
/// 这些成本会反复付。缓存按 `(pid, 页)` 存结果，动态页短 TTL、静态页长 TTL。
final class DetailLoadCache {
    static let shared = DetailLoadCache()

    enum Payload {
        case lines([String])
        case pairs([(String, String)])
        case port(UInt32)          // 0 = 已探测，但确实没有 task port
    }

    private struct Key: Hashable {
        let pid: Int32
        let key: String
    }
    private struct Entry {
        let payload: Payload
        let at: TimeInterval
    }

    private let lock = NSLock()
    private var store: [Key: Entry] = [:]

    /// FD / socket / pipe 会随进程运行变化；环境 / 镜像 / 映射 / 签名几乎静态。
    /// 三档时长都来自偏好设置，改动后下一次 get 立即生效。
    private func ttl(_ key: String) -> TimeInterval {
        let p = Preferences.shared
        switch key {
        // windows 会随用户开/关窗口变化，归动态档；不能按静态页缓存 60 秒
        case "files", "sockets", "monitoring", "pipePeers", "windows":
            return Double(p.dynamicTTL)
        case "tty":
            return Double(p.ttyTTL)
        default:
            return Double(p.staticTTL)
        }
    }

    func get(_ key: String, pid: Int32, force: Bool) -> Payload? {
        let k = Key(pid: pid, key: key)
        lock.lock(); defer { lock.unlock() }
        guard !force, let e = store[k],
              Date().timeIntervalSince1970 - e.at < ttl(key) else { return nil }
        return e.payload
    }

    func put(_ payload: Payload, key: String, pid: Int32) {
        // 空结果通常是采集被取消 / 进程刚退出，不缓存，否则 60 秒里一直显示空
        switch payload {
        case .lines(let v): if v.isEmpty { return }
        case .pairs(let v): if v.isEmpty { return }
        case .port: break
        }
        let k = Key(pid: pid, key: key)
        lock.lock(); defer { lock.unlock() }
        store[k] = Entry(payload: payload, at: Date().timeIntervalSince1970)
    }

    func invalidate(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        for k in store.keys where k.pid == pid { store.removeValue(forKey: k) }
    }

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}

/// 所有详情窗口共用一条串行队列。
///
/// C 层的全局 pipe 索引（`g_pipe_index`）由「Pipe 对端」「文件监控」两页共用，
/// 主窗口 + 多个检查器窗口若各自开队列并发采集，会同时重建 / 遍历同一个数组。
/// 共享串行队列既避免数据竞争，也避免 N 个窗口同时各跑一遍全系统 FD 扫描。
enum DetailLoadQueue {
    static let queue = DispatchQueue(label: "com.vantage.detail.shared",
                                     qos: .userInitiated)
}
