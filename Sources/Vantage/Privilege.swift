// SPDX-License-Identifier: MIT
import AppKit
import CProc
import Darwin
import Foundation

// ---------------------------------------------------------------------
// 提权（以 root 运行）
//
// 走 macOS 图形界面的标准做法：Authorization Services。
// `AuthorizationCreate` + 申请 `system.privilege.admin` 会弹出系统自己的
// 「Vantage 想要进行更改」对话框（用登录密码 / Touch ID），拿到授权后
// `AuthorizationExecuteWithPrivileges` 以真实 uid=0 启动子进程。
//
// 不用 sudo / osascript 的原因：
//   · sudo 需要终端且要求调用方已配好 sudoers，GUI 里根本不可用；
//   · `osascript -e 'do shell script … with administrator privileges'` 会
//     借道 AppleScript 弹框，要求「自动化」权限，且子进程身份是 osascript；
//   · Authorization Services 是系统原生、无额外权限、无第三方依赖的路径，
//     也是 Vantage 这种「本地开发、不装 privileged helper」项目最合适的选择。
//
// C 层包装见 auth_exec.c —— AuthorizationExecuteWithPrivileges 在新 SDK 里
// 对 Swift 标了 unavailable，只能在 C 里调用。
//
// 可选的 Touch ID 路径见 TouchIDAuth.swift：偏好里开启并安装特权辅助工具后，
// 身份验证改为 LAContext（指纹 / Apple Watch），root 操作交给常驻守护进程执行，
// 不再弹密码框。默认关闭，未安装助手时行为与上面完全一致。
// ---------------------------------------------------------------------

enum Privilege {

    /// 当前进程是否已经是 root
    static var isRoot: Bool { geteuid() == 0 }

    /// 提权重启时通过命令行带过来的原始 uid。
    /// AuthorizationExecuteWithPrivileges 启动的子进程 real uid 也是 0，
    /// 光看 ruid/euid 区分不出「从普通用户提权上来的」，所以显式传递。
    private(set) static var dropTargetUID: uid_t?

    static func noteLaunchArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--drop-uid"), i + 1 < args.count,
              let uid = uid_t(args[i + 1]) else { return }
        dropTargetUID = uid
    }

    /// 可以降权回去的目标 uid（nil = 真·root 登录，无法降权）
    static var dropUID: uid_t? {
        guard isRoot else { return nil }
        if getuid() != geteuid() { return getuid() }
        return dropTargetUID
    }

    /// 复用的授权引用：系统会缓存凭据（默认 5 分钟），连续操作不再重复弹框
    private static var authRef: UnsafeMutableRawPointer?

    /// errno 是否属于「权限不足」——这类错误才值得提示提权
    static func isPermissionError(_ err: Int32) -> Bool {
        err == EPERM || err == EACCES
    }

    // -----------------------------------------------------------------
    // 提权失败的原因（给界面用）
    // -----------------------------------------------------------------

    /// 保护下面这些「跨线程读写的小状态」（提权失败原因、凭据时间戳）
    private static let stateLock = NSLock()
    private static var escalationError: String?

    /// 最近一次提权失败的原因（nil = 成功 / 还没试过）。
    /// 之前的实现只返回 Bool，界面只能笼统地说「已取消提权」，
    /// 把「助手版本不一致」「助手没在跑」这类可操作的信息都丢掉了。
    static var lastEscalationError: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return escalationError
    }

    static func setEscalationError(_ message: String?) {
        stateLock.lock()
        escalationError = message
        stateLock.unlock()
    }

    // -----------------------------------------------------------------
    // 授权
    // -----------------------------------------------------------------

    /// 系统授权凭据的取得时间。
    ///
    /// 用途只有一个：**刚用密码授权过就不要再要指纹**。典型场景是开启
    /// Touch ID —— 安装助手时刚输过管理员密码，紧接着点「以 root 运行」
    /// 又来一次指纹，纯属多余（凭据本身还有效）。
    private static var authAcquiredAt: Date? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _authAcquiredAt }
        set { stateLock.lock(); _authAcquiredAt = newValue; stateLock.unlock() }
    }
    private static var _authAcquiredAt: Date?

    /// 系统凭据大约 5 分钟有效，复用窗口留 1 分钟余量，避免拿过期凭据
    /// 去 exec 时突然弹出一个密码框
    private static let authReuseWindow: TimeInterval = 4 * 60

    /// 手上有没有「刚拿到、还能用」的系统授权凭据
    static var hasFreshSystemCredential: Bool {
        stateLock.lock()
        let at = _authAcquiredAt
        stateLock.unlock()
        guard authRef != nil, let at = at else { return false }
        return Date().timeIntervalSince(at) < authReuseWindow
    }

    /// 现在该走指纹，还是复用手上的密码凭据
    private static var prefersTouchID: Bool {
        !hasFreshSystemCredential && TouchIDAuth.isActive
    }

    /// 申请「以 root 执行」权限。第一次调用会弹系统授权对话框；
    /// 凭据在有效期内复用，重复调用直接成功。
    @discardableResult
    static func authorize(useTouchID: Bool = true) -> Bool {
        if isRoot { return true }
        // 刚输过密码（凭据还能用）：直接复用，别让用户再按一次指纹
        if hasFreshSystemCredential { return true }
        // 指纹路径：会话已解锁就直接通过；否则先验证一次
        if useTouchID, TouchIDAuth.isActive {
            if TouchIDAuth.isSessionUnlocked { return true }
            return TouchIDAuth.unlock(reason: L("priv.touchIDReason"))
        }
        if authRef == nil {
            var ref: UnsafeMutableRawPointer?
            guard cproc_auth_create(&ref) == 0, let created = ref else {
                return false
            }
            authRef = created
        }
        guard let ref = authRef else { return false }
        let rc = cproc_auth_request_exec(ref)
        if rc != 0 {
            // 用户取消 / 密码错误：丢掉这个 ref，下次重新申请
            cproc_auth_free(ref)
            authRef = nil
            authAcquiredAt = nil
            return false
        }
        // 成功即刷新时间戳：系统凭据每次使用后会重新计时
        authAcquiredAt = Date()
        notifyPrivilegeChanged()
        return true
    }

    /// 释放授权凭据（退出前调用，避免凭据被继续缓存）
    static func releaseAuthorization() {
        if let ref = authRef {
            cproc_auth_free(ref)
            authRef = nil
        }
        authAcquiredAt = nil
        TouchIDAuth.lockSession()
    }

    /// 当前进程是否还缓存着可用的提权凭据（含指纹解锁的会话）。
    /// 「锁」按钮据此显示开 / 关。
    static var hasCachedAuthorization: Bool {
        authRef != nil || TouchIDAuth.isSessionUnlocked
    }

    /// 手动吊销缓存的授权：下一次需要 root 的操作会重新弹系统授权框。
    /// 凭据本身有 5 分钟有效期，但用户往往希望立刻作废（例如把机器借给别人）。
    static func revokeAuthorization() {
        releaseAuthorization()
        notifyPrivilegeChanged()
    }

    /// 提权状态变化通知。**必须在主线程发**：
    /// 观察者（主窗口的锁按钮）会直接改 AppKit 控件（图片 / contentTintColor），
    /// 从后台线程改视图会让 CoreAutoLayout 抛异常并 abort —— 预授权与安装
    /// helper 都发生在后台线程，这条曾经直接把进程打死。
    static func notifyPrivilegeChanged() {
        let post = {
            NotificationCenter.default.post(name: .vantagePrivilegeDidChange,
                                            object: nil)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    /// 锁按钮的三态
    enum LockState { case root, unlocked, locked }

    static var lockState: LockState {
        if isRoot { return .root }
        return hasCachedAuthorization ? .unlocked : .locked
    }

    /// 是否可以原地降权（root 且知道要回到哪个用户）
    static var canDropToUser: Bool { dropUID != nil }

    /// 降权回登录用户：setgid / initgroups / setuid 一起做，
    /// 这样真实、有效、保存的 uid 都变成用户，进程不可能再回到 root。
    @discardableResult
    static func dropToUser() -> Bool {
        guard let target = dropUID, target != 0 else { return false }
        if let pw = getpwuid(target) {
            setgid(pw.pointee.pw_gid)
            initgroups(pw.pointee.pw_name, Int32(pw.pointee.pw_gid))
        }
        guard setuid(target) == 0 else { return false }
        releaseAuthorization()
        dropTargetUID = nil
        notifyPrivilegeChanged()
        return true
    }

    // -----------------------------------------------------------------
    // 以 root 重启自己
    // -----------------------------------------------------------------

    /// 把本进程重启为 root（提权按钮的动作）。
    /// 成功返回 true —— 调用方随后应尽快退出当前实例，避免出现两个窗口。
    @discardableResult
    static func relaunchAsRoot() -> Bool {
        guard !isRoot else { return false }
        guard let exe = Bundle.main.executablePath,
              FileManager.default.isExecutableFile(atPath: exe) else {
            setEscalationError(L("priv.noExecutablePath"))
            return false
        }
        // 刚输过密码（凭据还有效）：直接走系统授权那一路，一个框都不弹
        if hasFreshSystemCredential {
            return authExecute(exe)
        }
        // 指纹路径：让守护进程在用户会话里以 root 启动本 App，
        // 完全不弹密码框。授权验证已在 authenticate 里完成。
        if TouchIDAuth.isActive {
            guard authorize() else {
                setEscalationError(L("priv.cancelled"))
                return false
            }
            let result = TouchIDHelper.relaunch(appPath: exe, uid: getuid())
            if result.ok { return true }
            // 指纹这条路走不通（助手版本不一致 / 没在跑 / 会话对不上）：
            // 记下原因，然后回落到系统密码框 —— 至少这次提权还能成，
            // 界面再把「为什么没用上指纹」说清楚。
            setEscalationError(result.error)
            guard authorize(useTouchID: false) else {
                // 用户把密码框也关了：这时候「已取消」才是准确的说法
                setEscalationError(L("priv.cancelled"))
                return false
            }
            return authExecute(exe)
        }

        guard authorize() else {
            setEscalationError(L("priv.cancelled"))
            return false
        }
        return authExecute(exe)
    }

    /// Authorization Services 那一路：拿到凭据后以 root 重新 exec 自己。
    /// 不再传参数：子进程用 geteuid()==0 自行判断身份，
    /// 少了参数解析就少了「传错一个开关就起不来」的可能。
    /// 把当前用户的 uid 传给 root 实例：它据此提供「降权为用户」。
    private static func authExecute(_ exe: String) -> Bool {
        let rc = withCArgs(["--drop-uid", String(getuid())]) { argv in
            cproc_auth_exec(authRef, exe, argv, nil)
        }
        return rc == 0
    }

    /// `--respawn-disclaimed` 隐藏模式的入口。
    ///
    /// 助手拉起的路径是 `launchctl asuser <uid> <app> --respawn-disclaimed`：
    /// 第一级实例已经在用户的 GUI 会话里，但没有 TCC 授权 —— 它的
    /// responsible process 是助手（LaunchDaemon，没有 FDA）。这里立刻用
    /// `cproc_spawn_disclaimed` 重新 spawn 真正的 App 并退出；第二级实例
    /// responsible = 自己，TCC 按 App 自身身份判权，FDA 恢复生效，
    /// 而 GUI 会话从第一级继承，窗口照常。
    ///
    /// 返回给 main.swift 作为退出码：0 = 已交接，非 0 = spawn 失败。
    static func respawnDisclaimed() -> Int32 {
        guard let exe = Bundle.main.executablePath
                ?? CommandLine.arguments.first else {
            return 1
        }
        // 第一级是 helper 以 root 拉起的，--drop-uid 由 noteLaunchArguments
        // 解析过；拿不到就按当前 uid 兜底（root 登录场景）。
        let uid = dropTargetUID ?? getuid()
        let rc = cproc_spawn_disclaimed(exe, uid)
        if rc != 0 {
            // stderr 已由 launchctl 重定向到助手的日志文件，写这里能看到
            FileHandle.standardError.write(
                Data("respawn-disclaimed failed rc=\(rc) exe=\(exe)\n".utf8))
        }
        return rc == 0 ? 0 : 1
    }

    // -----------------------------------------------------------------
    // 以 root 执行固定路径的系统工具
    // -----------------------------------------------------------------

    /// 进程表里是否已经有「同一个可执行文件」的 root 实例。
    ///
    /// 用来判断提权后的新进程到底起没起来 —— `AuthorizationExecuteWithPrivileges`
    /// 不给我们 pid，也不能靠固定延时猜。走 C 层已有的全量快照（每秒都在采），
    /// 比另开 `proc_listpids` + `proc_pidpath` 一套接口更省事，也顺带校验了
    /// uid == 0，避免把「另一个普通实例」误判成提权成功。
    static func otherInstanceRunning(exe: String, excluding pid: pid_t) -> Bool {
        guard !exe.isEmpty, let snap = ProcBridge.collect() else { return false }
        return snap.procs.contains {
            $0.pid != pid && $0.uid == 0 && $0.exepath == exe
        }
    }

    /// 执行 `/sbin/ifconfig`、`/sbin/route` 这类工具并返回 (状态, 输出)。
    /// - 已经是 root：直接 fork/exec，不弹框；
    /// - 否则：先申请授权（弹框），再以 root **直接 exec 工具本身** ——
    ///   不经 /bin/sh（参数原样进 argv，不存在转义 / 注入问题），stderr
    ///   由 C 层接管（cproc_auth_exec 会临时把 fd 2 指到管道上）一并回传。
    ///
    /// 参数由调用方严格校验（IP / 前缀 / MTU / 网卡名）。
    static func run(tool: String, args: [String],
                    useTouchID: Bool = true) -> (rc: Int32, output: String) {
        if isRoot {
            return runDirect(tool: tool, args: args)
        }
        if useTouchID, prefersTouchID {
            guard authorize() else {
                return (-1, L("priv.authorizationCancelled"))
            }
            return TouchIDHelper.exec(argv: [tool] + args)
        }
        guard authorize(useTouchID: useTouchID), let ref = authRef else {
            return (-1, L("priv.authorizationCancelled"))
        }
        var outPtr: UnsafeMutablePointer<CChar>?
        let rc = withCArgs(args) { argv in
            cproc_auth_exec(ref, tool, argv, &outPtr)
        }
        var text = ""
        if let p = outPtr {
            text = String(cString: p)
            free(p)
        }
        return (rc, text)
    }

    /// 直接以 root 执行一个可执行文件（不经 /bin/sh）。
    /// 用于调用「本 App 自己的隐藏子命令」，参数不经过 shell 解析。
    static func runAsRoot(tool: String, args: [String],
                          useTouchID: Bool = true) -> (rc: Int32, output: String) {
        if isRoot { return runDirect(tool: tool, args: args) }
        if useTouchID, prefersTouchID {
            guard authorize() else {
                return (-1, L("priv.authorizationCancelled"))
            }
            return TouchIDHelper.exec(argv: [tool] + args)
        }
        guard authorize(useTouchID: useTouchID), let ref = authRef else {
            return (-1, L("priv.authorizationCancelled"))
        }
        var outPtr: UnsafeMutablePointer<CChar>?
        let rc = withCArgs(args) { argv in
            cproc_auth_exec(ref, tool, argv, &outPtr)
        }
        var text = ""
        if let p = outPtr {
            text = String(cString: p)
            free(p)
        }
        return (rc, text)
    }

    /// 三条 spawn 路径共用的最小环境（单一清单在 C 层：`cproc_clean_environ`，
    /// `cproc_auth_exec` 的 environ 替换用的也是它）。条目：PATH（收紧到系统
    /// 目录）与 LANG=C。**刻意不设 HOME / TMPDIR**：前者写死 /var/root 会把
    /// 普通用户实例的 TCC.db / LaunchAgents 路径带偏；后者 macOS 的临时目录
    /// 根本不看这个变量（NSTemporaryDirectory/confstr 按 euid 给出私有的
    /// /var/folders/.../T），写死 /private/var/tmp 反而是 0777 共享目录。
    static let cleanEnvironment: [String: String] = {
        var buf = [CChar](repeating: 0, count: 1024)
        var env: [String: String] = [:]
        guard cproc_clean_environ(&buf, buf.count) == 0 else { return env }
        for line in String(cString: buf).split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return env
    }()

    /// 直接执行一个可执行文件（参数原样传 argv，不经 shell）。
    /// 已经是 root 时的执行路径，也是 `--helper-install` / `--helper-uninstall`
    /// / `--tcc-write` 这些隐藏子模式里跑 launchctl 的路径。
    static func runDirect(tool: String, args: [String]) -> (rc: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        // 与 cproc_auth_exec 同源的最小环境（C 层单一清单）。虽然现在的
        // 子进程都不经 shell、注入面很小，但 DYLD_* 这类动态链接器变量
        // 在 exec 时仍会被读，统一掐掉成本为零。
        p.environment = cleanEnvironment
        let pipe = Pipe()
        // Foundation 的 pipe() 不带 CLOEXEC：这段代码在 --helper-install
        // 子模式里以 root 运行，会连续 spawn launchctl，别让管道端点泄露
        // 给它们（子进程的 stdout/stderr 由 Process 用 dup2 重新落位，
        // dup2 会清掉目标 fd 的 CLOEXEC，打标不影响重定向）。
        fdCloexec(pipe.fileHandleForReading.fileDescriptor)
        fdCloexec(pipe.fileHandleForWriting.fileDescriptor)
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // -----------------------------------------------------------------
    // 工具
    // -----------------------------------------------------------------

    /// 把 Swift 字符串数组转成以 NULL 结尾的 char *[] 交给 C
    private static func withCArgs<T>(
        _ args: [String],
        _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> T
    ) -> T {
        // C 侧签名是 const char *const argv[]，所以传的是「常量指针数组」；
        // strdup 出来的内存单独保留，函数返回前统一 free。
        let owned: [UnsafeMutablePointer<CChar>] = args.map { strdup($0) }
        defer { for p in owned { free(p) } }
        var argv: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        argv.append(nil)
        return argv.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
