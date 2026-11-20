// SPDX-License-Identifier: MIT
import AppKit
import Darwin
import Foundation
import LocalAuthentication
import Security

// ---------------------------------------------------------------------
// Touch ID 提权（可选）
//
// 为什么需要特权辅助工具：Authorization Services 的对话框只会给密码
// 输入框（SecurityAgent 不向第三方开放生物识别）。要用指纹，就得自己
// 完成「验证身份 → 执行特权操作」两步：
//
//   1. 本进程（用户会话，能访问 Touch ID）用 LAContext 做人脸/指纹验证；
//   2. 一个常驻 root 守护进程执行固定的几个特权操作。
//
// 守护进程不可能自己弹指纹框（它不在用户的 Aqua 会话里），所以它信任
// 「调用方就是 Vantage 本体」—— 通过审计 pid 取代码签名，比对 cdhash
// 与自身完全一致才受理。这样任何别的程序（哪怕同用户）连上来也会被拒。
//
// 安装是可选项：偏好里手动开启后，才通过 Authorization Services（此时
// 仍是一次密码）把本二进制复制到 /Library/PrivilegedHelperTools 并注册
// 一个 LaunchDaemon。之后每次提权改为指纹确认，不再问密码。
//
// 关闭开关或点「卸载」会 bootout 并删除守护进程。
// ---------------------------------------------------------------------

enum TouchIDAuth {

    /// 会话解锁的有效期。只存在于内存，进程退出即失效。
    private static let sessionTTL: TimeInterval = 5 * 60

    private static let lock = NSLock()
    private static var unlockedAt: Date?
    private static var cachedAvailability: (at: Date, ok: Bool, title: String)?

    // -----------------------------------------------------------------
    // 以「真实用户」的身份调用生物识别
    // -----------------------------------------------------------------
    //
    // 关键点：macOS 的生物识别是**按 effective uid** 判定的（不是 ruid）。
    // 以 root 运行的进程（euid=0）去问 LAContext，一律得到
    // 「没有可用 Touch ID / 没有录入指纹」—— 哪怕同一个用户明明录过指纹。
    // sudo 那类 setuid 程序的做法就是：保存 ruid → 需要特权时 seteuid(0)
    // → 调指纹前再 seteuid(ruid)（见 sudo 的 touchid_exec.c）。
    //
    // 我们的 root 实例是从普通用户提权上来的：ruid=euid=0，但 **suid=0**，
    // 所以 seteuid(用户) 之后还能 seteuid(0) 切回来。这里在调用期间临时
    // 切到用户身份（连 egid 一起），结束后立刻恢复。

    private static let euidLock = NSLock()

    /// 在「真实用户」的 effective uid 下执行 body（已是普通进程时直接执行）。
    private static func asUser<T>(_ body: () -> T) -> T {
        // euid 已经切下去了（嵌套调用）或本来就不是 root：直接跑
        guard geteuid() == 0, let target = Privilege.dropUID, target != 0,
              let pw = getpwuid(target) else { return body() }
        euidLock.lock()
        defer { euidLock.unlock() }
        let userGID = pw.pointee.pw_gid
        _ = setegid(userGID)           // 失败不致命，uid 才是判据
        guard seteuid(target) == 0 else {
            _ = setegid(0)
            return body()
        }
        let result = body()
        // suid 仍是 0，切回 root 一定成功；万一失败说明进程身份已经丢了，
        // 只能如实报告，不做补救（继续降权运行比假装是 root 安全）
        if seteuid(0) == 0 {
            _ = setegid(0)
        } else {
            NSLog("Vantage: could not restore root euid after Touch ID (errno %d)",
                  errno)
        }
        return result
    }

    // -----------------------------------------------------------------
    // 硬件能力
    // -----------------------------------------------------------------

    /// 是否有可用的生物识别（Touch ID / Apple Watch 解锁）。
    /// 结果缓存 10 秒：偏好页会反复问。
    static func availability() -> (ok: Bool, title: String) {
        lock.lock()
        if let c = cachedAvailability,
           Date().timeIntervalSince(c.at) < 10 {
            lock.unlock()
            return (c.ok, c.title)
        }
        lock.unlock()

        let (ok, title) = asUser { () -> (Bool, String) in
            let ctx = LAContext()
            var error: NSError?
            let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                           error: &error)
            var title = "Touch ID"
            switch ctx.biometryType {
            case .touchID: title = "Touch ID"
            case .opticID: title = "Optic ID"
            default:       title = "Touch ID"
            }
            return (ok, title)
        }
        lock.lock()
        cachedAvailability = (Date(), ok, title)
        lock.unlock()
        return (ok, title)
    }

    static var isSupported: Bool { availability().ok }

    // -----------------------------------------------------------------
    // 验证
    // -----------------------------------------------------------------

    /// 同步等待一次生物识别验证（调用方不要在主线程上等）。
    /// 整个「询问 → 等用户按手印」的过程都要在用户身份下进行：
    /// 中途切回 root 会让系统认为调用方换人了。
    static func authenticate(reason: String) -> Bool {
        asUser {
            let ctx = LAContext()
            // 允许用登录密码回退，避免手指潮湿时彻底走不通
            ctx.localizedFallbackTitle = L("priv.touchIDFallback")
            var error: NSError?
            guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                        error: &error) else { return false }
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: reason) { success, _ in
                ok = success
                sem.signal()
            }
            // 指纹框没有超时概念（用户可以一直不碰），但系统自身会等很久；
            // 给 60 秒上限，超时就当取消，避免调用线程永久挂住。
            _ = sem.wait(timeout: .now() + 60)
            return ok
        }
    }

    /// 会话是否已解锁（刚验证过，减少连续操作反复按指纹）
    static var isSessionUnlocked: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = unlockedAt else { return false }
        guard Date().timeIntervalSince(at) < sessionTTL else {
            unlockedAt = nil
            return false
        }
        return true
    }

    /// 验证一次并解锁会话
    @discardableResult
    static func unlock(reason: String) -> Bool {
        guard authenticate(reason: reason) else { return false }
        lock.lock()
        unlockedAt = Date()
        lock.unlock()
        Privilege.notifyPrivilegeChanged()
        return true
    }

    static func lockSession() {
        lock.lock()
        unlockedAt = nil
        lock.unlock()
        Privilege.notifyPrivilegeChanged()
    }

    // -----------------------------------------------------------------
    // 是否走指纹路径
    // -----------------------------------------------------------------

    /// 偏好开启、硬件可用、辅助工具已装好且与当前构建一致
    static var isActive: Bool {
        guard Preferences.shared.touchIDAuth else { return false }
        guard isSupported else { return false }
        return TouchIDHelper.problem == nil
    }

    /// 偏好开着、但现在用不了指纹提权的原因（nil = 一切正常）。
    /// 状态行与「立即提权」前的检查共用同一份判断，避免两处走偏。
    static var unavailableReason: String? {
        guard Preferences.shared.touchIDAuth else { return nil }
        guard isSupported else { return L("priv.touchIDUnavailable") }
        return TouchIDHelper.problem
    }

    /// 偏好开着、但助手需要重装（版本 / 构建不一致，或没在运行）
    static var needsRepair: Bool {
        guard Preferences.shared.touchIDAuth, isSupported,
              !Privilege.isRoot else { return false }
        guard TouchIDHelper.isInstalled else { return true }
        return TouchIDHelper.problem != nil
    }

    /// 给偏好页 / 锁定按钮用的一句话状态
    static func statusText() -> String {
        let (ok, title) = availability()
        guard Preferences.shared.touchIDAuth else { return L("priv.touchIDOff") }
        guard ok else { return L("priv.touchIDUnavailable") }
        if let problem = TouchIDHelper.problem { return problem }
        return L("priv.touchIDReady", title)
    }
}

// ---------------------------------------------------------------------
// 协议版本 / 错误码（客户端与守护进程共用的常量）
// ---------------------------------------------------------------------

enum TouchIDHelperProtocol {

    /// 线路协议版本。请求/响应的结构或语义一变就要 +1：
    /// 旧助手 + 新客户端（或反之）会被识别成「版本不一致」，提示重装，
    /// 而不是让两边按不同约定各说各话。
    static let version = 2

    /// 守护进程拒绝请求时的机器可读原因（不含文案，翻译在客户端）
    enum Error {
        static let signalDrop = "bad-signal"
        static let notRoot = "not-root"
        static let signature = "signature"
        static let notConsole = "not-console"
        static let notAdmin = "not-admin"
        static let noConsole = "no-console"
        static let badRequest = "bad-request"
        static let notAllowed = "not-allowed"
        static let relaunchDenied = "relaunch-denied"
        static let launchFailed = "launch-failed"
    }
}

// ---------------------------------------------------------------------
// 「是否启用 Touch ID 提权」是机器级状态
//
// 装的是 root LaunchDaemon，跟当前登录的是哪个用户无关；存进 UserDefaults
// 会落进各自用户的偏好域 —— 普通用户开启后，提权出来的 root 实例读的是
// /var/root 的偏好，于是设置页显示「未启用」（但助手明明在跑）。
// 所以真正的判据是 /Library 下一个所有用户都可读的标记文件，由安装 /
// 卸载（都在 root 子模式里**进程内**完成，不经 shell）负责增删。
// ---------------------------------------------------------------------

enum TouchIDState {
    static let dirPath = "/Library/Application Support/io.github.nanacaret.Vantage"
    static let flagPath = dirPath + "/touchid.enabled"

    static var isEnabled: Bool {
        if FileManager.default.fileExists(atPath: flagPath) { return true }
        // 升级路径：旧版本只装了助手、没有标记文件。助手文件在
        // /Library/PrivilegedHelperTools（0644，所有用户可读），
        // 所以 root 实例也能据此判断「已启用」，下次安装会把标记补上。
        return TouchIDHelper.isInstalled
    }

    /// 落盘「已启用」标记（安装的最后一步，由 root 子模式进程内完成）：
    /// 建目录 + 建空文件 + 定权限 / 属主。返回 false = 没写上（不阻断安装：
    /// isEnabled 此时回落到「助手是否装着」，但调用方会在输出里说明）。
    @discardableResult
    static func markInstalled() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
        } catch { return false }
        if chmod(dirPath, 0o755) != 0 || chown(dirPath, 0, 0) != 0 { return false }
        if !fm.fileExists(atPath: flagPath) {
            guard fm.createFile(atPath: flagPath, contents: nil,
                                attributes: [.posixPermissions: 0o644]) else {
                return false
            }
        }
        if chmod(flagPath, 0o644) != 0 || chown(flagPath, 0, 0) != 0 { return false }
        return true
    }
}

// ---------------------------------------------------------------------
// 特权辅助工具：安装 / 卸载 / 客户端
// ---------------------------------------------------------------------

enum TouchIDHelper {

    static let label = "io.github.nanacaret.Vantage.helper"
    static let helperPath = "/Library/PrivilegedHelperTools/" + label
    static let plistPath = "/Library/LaunchDaemons/" + label + ".plist"
    static let socketPath = "/var/run/" + label + ".sock"

    /// 安装时写下的「这份副本是谁」：版本号 / 协议 / cdhash。
    /// 只是给人看的说明（真正的判据始终是 cdhash + 协议号），
    /// 有了它才能提示「装的是 1.1.0、现在是 1.2.0」而不是一句「不匹配」。
    static let infoPath = helperPath + ".info"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
            && FileManager.default.fileExists(atPath: plistPath)
    }

    /// 当前 App 的版本串（无 bundle 时为空，此时只比 cdhash）
    static var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? ""
        if short.isEmpty { return build }
        if build.isEmpty || build == short { return short }
        return "\(short) (\(build))"
    }

    /// 安装时写下的 sidecar（`key=value` 逐行）
    static var installedInfo: [String: String] {
        guard let text = try? String(contentsOfFile: infoPath, encoding: .utf8)
        else { return [:] }
        var dict: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            dict[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return dict
    }

    /// 安装时记录的 App 版本（未知时为空）
    static var installedVersionText: String {
        installedInfo["version"] ?? ""
    }

    /// cdhash 的十六进制写法（没有签名时为空串）
    static func hex(_ data: Data?) -> String {
        guard let data = data else { return "" }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    static func infoText(installer: uid_t) -> String {
        """
        version=\(appVersionText)
        protocol=\(TouchIDHelperProtocol.version)
        cdhash=\(hex(cdhash(ofPath: Bundle.main.executablePath ?? "")))
        installer=\(installer)
        installed=\(ISO8601DateFormatter().string(from: Date()))
        """
    }

    /// 「发起安装的那个用户」——由助手记下来，之后只有他能免密码卸载。
    /// root 实例（提权上来的）要记原始用户，否则记成 0 就没人能免密码拆了。
    static var installerUID: uid_t { Privilege.dropUID ?? getuid() }

    /// 安装的副本是否就是当前这份二进制（重建后 cdhash 会变）
    static var matchesCurrentBuild: Bool {
        guard let mine = cdhash(ofPath: Bundle.main.executablePath ?? ""),
              let theirs = cdhash(ofPath: helperPath) else { return false }
        return mine == theirs
    }

    /// 「装的是 X、当前是 Y」那句提示。
    /// 老助手没有 sidecar（装它的时候还没这个功能），此时只能说「不一致」。
    static func staleHelperText() -> String {
        let current = appVersionText.isEmpty
            ? L("priv.touchIDUnknownVersion") : appVersionText
        guard !installedVersionText.isEmpty else {
            return L("priv.touchIDStaleHelperUnknown", current)
        }
        // 版本号一样、二进制不同（本地重新构建最常见）：
        // 「装的是 1.1.0，当前是 1.1.0」看着像没毛病，得换个说法
        if installedVersionText == current {
            return L("priv.touchIDStaleBuild", current)
        }
        return L("priv.touchIDStaleHelper", installedVersionText, current)
    }

    /// 装好的副本 vs 当前 App：返回一句人能看懂的不一致说明（nil = 一致）。
    /// 判据三条，任何一条不满足都要重装：cdhash、协议号、版本号。
    static var versionMismatch: String? {
        guard isInstalled else { return nil }
        if !matchesCurrentBuild { return staleHelperText() }
        if let proto = installedInfo["protocol"], let n = Int(proto),
           n != TouchIDHelperProtocol.version {
            return L("priv.touchIDStaleProtocol", proto,
                     String(TouchIDHelperProtocol.version))
        }
        let recorded = installedVersionText
        let mine = appVersionText
        if !recorded.isEmpty, !mine.isEmpty, recorded != mine,
           installedInfo["version"] != nil {
            return L("priv.touchIDStaleHelper", recorded, mine)
        }
        return nil
    }

    /// 助手不可用的原因（nil = 可用）。按「装没装 → 版本 → 在不在跑」排查。
    /// 已经是 root 时用不到助手（也不需要它来提权），直接算可用。
    static var problem: String? {
        if geteuid() == 0 { return nil }
        guard isInstalled else {
            return L("priv.touchIDNotInstalled", TouchIDAuth.availability().title)
        }
        if let mismatch = versionMismatch { return mismatch }
        switch probe() {
        case .ok:
            return nil
        case .failure(let code):
            switch code {
            case TouchIDHelperProtocol.Error.signature:
                // 二进制被换掉了（重建 / 手动替换），cdhash 检查没通过
                return staleHelperText()
            case TouchIDHelperProtocol.Error.notAdmin:
                return L("priv.touchIDPeerNotAdmin")
            case TouchIDHelperProtocol.Error.notConsole,
                 TouchIDHelperProtocol.Error.noConsole:
                return L("priv.touchIDPeerNotConsole")
            default:
                return L("priv.touchIDHelperDown")
            }
        }
    }

    /// 装好了、版本也对得上（还没连上试过）
    static var isUsable: Bool { isInstalled && versionMismatch == nil }

    // -----------------------------------------------------------------
    // 安装 / 卸载
    // -----------------------------------------------------------------

    /// 安装（需要一次管理员授权）。把当前二进制复制到
    /// /Library/PrivilegedHelperTools，并注册 LaunchDaemon。
    ///
    /// 实际安装动作由「以 root 运行的本二进制」在 `--helper-install`
    /// 子模式里**进程内**完成（performInstall）：mkdir / 复制 / chmod /
    /// chown / 写 plist 与 sidecar 全是文件系统调用，不依赖 cat / chmod /
    /// chown / install(1) / sh 这些外部命令，也没有 heredoc / 转义 / trap。
    /// 唯一保留的外部命令是 launchctl（bootstrap / bootout / enable 没有
    /// 公开 API 替代），以 argv 直呼、不经 shell。
    ///
    /// **不在临时目录里中转**：root 直接从原始可执行文件路径复制
    /// （root 往用户/共享的 /tmp 写文件本身是污染，且 root 的
    /// NSTemporaryDirectory() 并不总是可写）。
    static func install() -> (ok: Bool, message: String) {
        guard let exe = Bundle.main.executablePath else {
            return (false, L("perm.writeNoHelper"))
        }
        let r = Privilege.runAsRoot(tool: exe,
                                    args: ["--helper-install",
                                           String(installerUID)],
                                    useTouchID: false)
        guard r.rc == 0 else {
            return (false, r.output.isEmpty ? "rc=\(r.rc)" : r.output)
        }
        // launchd 启动进程是异步的：给最多 3 秒把 socket 建起来，
        // 免得刚装完就报「助手没在运行」。
        guard waitUntilReady() else {
            // 起不来时区分「进程没起来」和「起来了但拒绝我们」：
            // 后者是身份问题（非管理员 / 不是桌面用户），重装多少次都没用，
            // 必须让用户看到真正的原因。
            if case .failure(let code) = probe() {
                switch code {
                case TouchIDHelperProtocol.Error.notAdmin:
                    return (false, L("priv.touchIDPeerNotAdmin"))
                case TouchIDHelperProtocol.Error.notConsole,
                     TouchIDHelperProtocol.Error.noConsole:
                    return (false, L("priv.touchIDPeerNotConsole"))
                case TouchIDHelperProtocol.Error.signature:
                    return (false, staleHelperText())
                default:
                    break
                }
            }
            return (false, L("priv.touchIDHelperNotStarting"))
        }
        return (true, L("priv.touchIDInstalled"))
    }

    /// `--helper-install` 子模式（以 root 运行；参数：发起安装的用户 uid）。
    /// 返回 0 = 成功；失败原因打到 stderr，由调用方（经 fd 2 接管）原样收到。
    ///
    /// 全部落盘走「同目录 O_EXCL 临时文件 → fd 上定权限/属主 → 校验 →
    /// 原子 rename」：
    ///   · 最终路径上永远不会出现半成品或权限不对的中间态（临时文件 0600
    ///     起步、在 root-only 目录里，定稿权限都在 fd 上做完才 rename）；
    ///   · 没有「目标不存在」窗口 —— rename 原子替换，旧文件在位直到新
    ///     文件就绪，launchd / KeepAlive 任何时刻来加载都拿得到完整文件；
    ///   · **bootout 放到最后**：文件替换失败时旧守护进程还在跑，升级失败
    ///     不会把一个可用安装弄没；
    ///   · 校验用 cdhash + 长度比对源二进制 —— 比 SecStaticCodeCheckValidity
    ///     更贴合目的：这份拷贝必须与当前构建逐位一致，而不是「是个有效
    ///     签名就行」。
    static func performInstall(installerUID: uid_t) -> Int32 {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("not root\n".utf8))
            return 1
        }
        guard let exe = Bundle.main.executablePath,
              FileManager.default.isExecutableFile(atPath: exe) else {
            FileHandle.standardError.write(Data("no executable\n".utf8))
            return 1
        }

        func fail(_ message: String) -> Int32 {
            // 最终路径上要么是完整的旧版、要么是完整的新版（原子 rename
            // 保证），这里不需要也不应该再做删除清理。
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            return 2
        }

        /// 同目录临时文件（0600 起步）→ 写入 → fchmod/fchown（fd 上做、
        /// 返回值检查）→ fsync → validate(tmp) → rename 原子上位。
        /// 任何一步失败：只 unlink 临时文件，path 分毫未动。
        @discardableResult
        func atomicWrite(_ path: String, data: Data, mode: mode_t,
                         validate: ((String) -> Bool)? = nil) -> Bool {
            let dir = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let tmp = dir + "/." + name
                + ".tmp-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"

            let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return false }

            var ok = true
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var written = 0
                while ok, written < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: written),
                                  raw.count - written)
                    if n <= 0 { ok = false } else { written += n }
                }
            }
            if ok, fchmod(fd, mode) != 0 { ok = false }
            if ok, fchown(fd, 0, 0) != 0 { ok = false }
            if ok, fsync(fd) != 0 { ok = false }     // 元数据一并落盘再 rename
            close(fd)
            if ok, let validate = validate, !validate(tmp) { ok = false }
            if ok, rename(tmp, path) != 0 { ok = false }
            if !ok { unlink(tmp) }
            return ok
        }

        // 1. 目标目录（0755 root:wheel）
        let helperDir = (helperPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: helperDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            if chmod(helperDir, 0o755) != 0 || chown(helperDir, 0, 0) != 0 {
                return fail("chmod/chown \(helperDir): errno \(errno)")
            }
        } catch {
            return fail("mkdir \(helperDir): \(error)")
        }

        // 2. 二进制：读到内存 → 临时文件 → fd 定权限 → 校验 → 原子 rename。
        //    旧的守护进程（若有）持有旧 inode，rename 不影响它继续运行。
        guard let exeData = try? Data(contentsOf: URL(fileURLWithPath: exe)) else {
            return fail("read \(exe)")
        }
        let srcSize = (try? FileManager.default.attributesOfItem(
            atPath: exe)[.size]) as? UInt64
        let verify: (String) -> Bool = { tmp in
            let newSize = (try? FileManager.default.attributesOfItem(
                atPath: tmp)[.size]) as? UInt64
            guard let a = srcSize, let b = newSize, a == b else { return false }
            return cdhash(ofPath: tmp) == cdhash(ofPath: exe)
        }
        guard atomicWrite(helperPath, data: exeData, mode: 0o755,
                          validate: verify) else {
            return fail("replace \(helperPath)")
        }

        // 3. LaunchDaemon plist + 版本 sidecar（0644 root:wheel，同样原子替换）
        guard atomicWrite(plistPath, data: Data(launchdPlist().utf8),
                          mode: 0o644) else {
            return fail("write \(plistPath)")
        }
        guard atomicWrite(infoPath,
                          data: Data(infoText(installer: installerUID).utf8),
                          mode: 0o644) else {
            return fail("write \(infoPath)")
        }

        // 4. 文件全部就绪后才下线旧守护进程、注册新版。这一步之后失败时
        //    文件是完整一致的，界面走「助手没起来 → 重装」的既有路径。
        _ = Privilege.runDirect(tool: "/bin/launchctl",
                                args: ["bootout", "system/\(label)"])
        let boot = Privilege.runDirect(tool: "/bin/launchctl",
                                       args: ["bootstrap", "system", plistPath])
        guard boot.rc == 0 else {
            return fail("launchctl bootstrap: \(boot.output)")
        }
        _ = Privilege.runDirect(tool: "/bin/launchctl",
                                args: ["enable", "system/\(label)"])

        // 5. 机器级「已启用」标记（最后一步）。失败不阻断安装：isEnabled 会
        //    回落到「助手是否装着」，但把原因回给调用方看。
        if !TouchIDState.markInstalled() {
            FileHandle.standardError.write(Data(
                "warning: enabled-flag not written (state falls back to isInstalled)\n".utf8))
        }

        print("installed")
        return 0
    }

    /// 卸载：**装它的那个用户不需要密码**，其他人仍需管理员授权。
    ///
    /// 走助手自己：它会核对 sidecar 里记的 `installer` uid，对上就直接删文件 +
    /// bootout（它自己会随之退出）。卸载只减权限，不存在借机提权的可能，
    /// 所以这里不需要再来一次身份验证。
    static func uninstall() -> (ok: Bool, message: String) {
        if selfUninstall() {
            TouchIDAuth.lockSession()
            return (true, L("priv.touchIDUninstalled"))
        }
        // 换了用户 / 助手没在跑 / 是没记录 installer 的老版本：回落到授权。
        // 同样走本二进制的 root 子模式，进程内 unlink，不经 shell。
        guard let exe = Bundle.main.executablePath else {
            return (false, L("perm.writeNoHelper"))
        }
        let r = Privilege.runAsRoot(tool: exe, args: ["--helper-uninstall"],
                                    useTouchID: false)
        guard r.rc == 0 else {
            return (false, r.output.isEmpty ? "rc=\(r.rc)" : r.output)
        }
        TouchIDAuth.lockSession()
        return (true, L("priv.touchIDUninstalled"))
    }

    /// `--helper-uninstall` 子模式（以 root 运行）：bootout + unlink，全进程内。
    static func performUninstall() -> Int32 {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("not root\n".utf8))
            return 1
        }
        _ = Privilege.runDirect(tool: "/bin/launchctl",
                                args: ["bootout", "system/\(label)"])
        for p in [helperPath, plistPath, infoPath, socketPath] { unlink(p) }
        unlink(TouchIDState.flagPath)
        print("removed")
        return 0
    }

    /// 请助手自毁（免密码路径）。成功 = 文件已经不在。
    private static func selfUninstall() -> Bool {
        guard isInstalled else { return true }
        guard let resp = call(op: "uninstall", args: [:]),
              (resp["ok"] as? Bool) == true else { return false }
        // 守护进程是异步删文件的：等它把 helper / plist 都删掉
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !isInstalled { return true }
            usleep(100_000)
        }
        return !isInstalled
    }

    /// LaunchDaemon 的描述文件（内部可见：安装与自检都用）
    static func launchdPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperPath)</string>
                <string>--touchid-helper</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ThrottleInterval</key><integer>5</integer>
            <key>StandardErrorPath</key>
            <string>/var/log/\(label).log</string>
        </dict>
        </plist>
        """
    }

    // -----------------------------------------------------------------
    // 客户端
    // -----------------------------------------------------------------

    /// 探测结果：`failure` 带的是守护进程给的原因码（见 TouchIDHelperProtocol.Error）
    enum Probe {
        case ok
        case failure(String)
    }

    /// 请求一个特权操作。op: exec / relaunch / ping
    static func call(op: String, args: [String: Any]) -> [String: Any]? {
        let req: [String: Any] = ["op": op, "args": args]
        return TouchIDSocket.request(req)
    }

    /// ping 一次并区分「连不上」和「被拒」
    static func probe() -> Probe {
        guard let resp = call(op: "ping", args: [:]) else {
            // 连不上：守护进程没在跑（被 bootout / 崩溃后还没起来）
            return .failure("unreachable")
        }
        if (resp["ok"] as? Bool) == true { return .ok }
        return .failure(resp["error"] as? String
                        ?? TouchIDHelperProtocol.Error.badRequest)
    }

    /// 以 root 执行（不经 shell，参数原样传给 execve）
    static func exec(argv: [String]) -> (rc: Int32, output: String) {
        guard let resp = call(op: "exec", args: ["argv": argv]) else {
            return (-1, L("priv.touchIDHelperUnreachable"))
        }
        let rc = Int32(resp["rc"] as? Int ?? -1)
        return (rc, resp["out"] as? String ?? "")
    }

    /// 以 root 在用户图形会话里重新启动 App（提权后的主路径）。
    /// 失败时带回一句可直接显示的原因 —— 之前的版本只回 Bool 并从 nil
    /// 回复里读不到任何东西，于是所有失败都显示成「已取消提权」。
    static func relaunch(appPath: String, uid: uid_t) -> (ok: Bool, error: String?) {
        guard let resp = call(op: "relaunch",
                              args: ["app": appPath, "uid": Int(uid)]) else {
            return (false, L("priv.touchIDHelperUnreachable"))
        }
        if (resp["ok"] as? Bool) == true { return (true, nil) }
        let code = resp["error"] as? String ?? TouchIDHelperProtocol.Error.launchFailed
        switch code {
        case TouchIDHelperProtocol.Error.notAdmin:
            return (false, L("priv.touchIDPeerNotAdmin"))
        case TouchIDHelperProtocol.Error.notConsole,
             TouchIDHelperProtocol.Error.noConsole:
            return (false, L("priv.touchIDPeerNotConsole"))
        case TouchIDHelperProtocol.Error.signature:
            return (false, L("priv.touchIDHelperMismatchShort"))
        default:
            let detail = resp["detail"] as? String ?? ""
            return (false, detail.isEmpty
                ? L("priv.touchIDRelaunchFailed", code)
                : L("priv.touchIDRelaunchFailed", "\(code): \(detail)"))
        }
    }

    /// 轮询等待守护进程可连接（最多 3 秒）
    static func waitUntilReady(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ping() { return true }
            usleep(120_000)
        } while Date() < deadline
        return false
    }

    static func ping() -> Bool {
        if case .ok = probe() { return true }
        return false
    }
}

// ---------------------------------------------------------------------
// UNIX 域套接字的长度前缀 JSON 帧
// ---------------------------------------------------------------------

/// 给 fd 打上 FD_CLOEXEC：exec 时（posix_spawn / AuthorizationExecuteWith-
/// Privileges 内部的 fork+exec 都遵守它）自动关闭，防止把套接字、管道
/// 泄露给子进程。macOS 的 socket()/pipe()/open() 都**不会**自动设这一位，
/// 必须显式调用。
func fdCloexec(_ fd: Int32) {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

enum TouchIDSocket {

    static func request(_ payload: [String: Any],
                        path: String = TouchIDHelper.socketPath) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // App 里随时可能并发起提权子进程（AEXP fork 继承全部 fd），
        // 不设 CLOEXEC 的话这条到 root 守护进程的连接会被泄露给
        // ifconfig / launchctl 之类的 root 子进程。
        fdCloexec(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                _ = strcpy(dst, path)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len) == 0
            }
        }
        guard ok else { return nil }

        // 超时：守护进程若卡住，界面不能跟着卡死
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))

        guard let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return nil }
        guard writeFrame(fd: fd, body: body) else { return nil }
        guard let reply = readFrame(fd: fd) else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    static func writeFrame(fd: Int32, body: Data) -> Bool {
        var len = UInt32(body.count).bigEndian
        var packet = withUnsafeBytes(of: &len) { Data($0) }
        packet.append(body)
        return packet.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent),
                              raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    static func readFrame(fd: Int32) -> Data? {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        guard readExactly(fd: fd, into: &lenBuf, count: 4) else { return nil }
        // 逐字节拼，不用 load(as:)：Array<UInt8> 的缓冲区不保证 4 字节对齐，
        // 未对齐的 load 在 arm64 上会直接崩。
        let len = (UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16)
            | (UInt32(lenBuf[2]) << 8) | UInt32(lenBuf[3])
        guard len > 0, len < 32 * 1024 * 1024 else { return nil }
        var body = [UInt8](repeating: 0, count: Int(len))
        guard readExactly(fd: fd, into: &body, count: Int(len)) else {
            return nil
        }
        return Data(body)
    }

    private static func readExactly(fd: Int32, into buf: inout [UInt8],
                                    count: Int) -> Bool {
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress!.advanced(by: got), count - got)
            }
            if n <= 0 { return false }
            got += n
        }
        return true
    }
}

// ---------------------------------------------------------------------
// cdhash 工具
// ---------------------------------------------------------------------

/// 取一个 Mach-O / App 的 cdhash（代码签名的唯一摘要）。
/// 只用于「装好的 helper 是否还是当前这份二进制」和「调用方是不是自己」。
func cdhash(ofPath path: String) -> Data? {
    guard !path.isEmpty else { return nil }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL,
                                      [], &code) == errSecSuccess,
          let staticCode = code else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode,
                                        SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoUnique as String] as? Data
}

/// 取某个连接的 cdhash（审计令牌 → guest code）。
/// 令牌绑定的是连接本身，没有 pid 复用 / TOCTOU 竞态。这也正是守护进程
/// 鉴权改用审计令牌、彻底放弃 pid 反查的原因。
func cdhash(ofAuditToken token: audit_token_t) -> Data? {
    var guest: SecCode?
    // kSecGuestAttributeAudit 的 value 是 audit_token_t（按字节打包成 CFData）。
    var t = token
    let value = Data(bytes: &t, count: MemoryLayout<audit_token_t>.size)
    let attrs: [String: Any] = [kSecGuestAttributeAudit as String: value]
    guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [],
                                         &guest) == errSecSuccess,
          let code = guest else { return nil }
    return cdhash(ofCode: code)
}

/// 取「我自己」这个正在运行的进程的 cdhash。
/// SecCodeCopySelf 返回的是运行中的动态代码，比按路径读磁盘文件更可靠：
/// 避开了「启动后二进制被替换」时路径查询与真实代码不一致的竞态。
func cdhash(ofSelf: Void = ()) -> Data? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let selfCode = code else {
        return nil
    }
    return cdhash(ofCode: selfCode)
}

/// 从任意 SecCode 提取 cdhash（运行中的代码先换出静态代码再取签名信息）。
private func cdhash(ofCode code: SecCode) -> Data? {
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let target = staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(target,
                                        SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoUnique as String] as? Data
}
