// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import CProc

// ---------------------------------------------------------------------
// 特权辅助工具的服务端（`Vantage --touchid-helper`，由 LaunchDaemon 以 root 启动）
//
// 只做三件事：
//   ping     存活探测（顺带回报自身的版本 / 协议号）
//   exec     执行白名单里的系统工具（参数原样交给 execve，不经 shell）
//   relaunch 在用户图形会话里以 root 启动 App（launchctl asuser）
//
// 鉴权分两层，缺一不可：
//
//   1. **身份**：连接方必须是「当前桌面（/dev/console）登录的那个管理员用户」。
//      只看 cdhash 是不够的 —— 任何本地用户都能拿到同一份 App 副本，
//      一个非管理员只要运行它就能借 root 助手提权，等于把系统的
//      管理员门槛拆了。所以这里额外要求 uid == console uid，并且该
//      uid 属于 admin 组。
//   2. **代码**：用审计 pid 取对端代码签名，cdhash 必须与本二进制完全一致。
//      安装时复制的是「App 自己的二进制」，因此这等价于「调用方就是同一份
//      Vantage 构建」—— 换了二进制（升级 / 重建 / 手工替换）都会被拒，
//      客户端据此提示「需要重新安装助手」。
//
// 两条都过不了的连接连请求体都不会读，直接回错误码断开。
// ---------------------------------------------------------------------

/// audit_token_t 的 val[8] 以数组形式取出。
/// val 是 `(UInt32, UInt32, …, UInt32)` 元组，转成数组后交给 C 层的
/// cproc_audit_*（它们用 libbsm 解析，不直接依赖结构布局）。
private extension audit_token_t {
    var tokenVal: [UInt32] {
        let v = val
        return [v.0, v.1, v.2, v.3, v.4, v.5, v.6, v.7]
    }
}

enum TouchIDHelperServer {

    /// exec 白名单：Vantage 需要 root 的全部工具。
    /// （sqlite3 曾在其列，用于 TCC 读写——现在 SQLite 操作全部走内置的
    /// libsqlite3，PermissionReader 直调 sqlite3 C API；killall 同样已无
    /// 调用方，是更早的残留。）
    private static let allowedTools: Set<String> = [
        "/sbin/ifconfig",
        "/sbin/route",
        "/bin/launchctl",
    ]

    /// 管理员组。用名字取更稳妥（极少数机器上 gid 不是 80，但 80 是
    /// 系统创建 admin 组时的固定值；取不到名字再退回 80）。
    private static var adminGID: gid_t {
        if let gr = getgrnam("admin") { return gr.pointee.gr_gid }
        return 80
    }

    /// 正在运行的子进程：不等待，但要持有，避免 Process 释放后收不到状态
    private static var children: [Process] = []
    private static let childLock = NSLock()

    static func run() -> Never {
        guard geteuid() == 0 else {
            log("refusing to run as non-root (euid=\(geteuid()))")
            exit(3)
        }
        // 客户端提前关闭连接时不要让 SIGPIPE 打死守护进程
        signal(SIGPIPE, SIG_IGN)

        // 自身 cdhash 用 SecCodeCopySelf：不依赖磁盘路径，也就避开了
        // 「启动瞬间二进制被替换 → 读到的 cdhash 与正在运行的代码不一致」
        // 这层 TOCTOU。拿不到（未签名）则退回去读自己路径的 cdhash。
        let ownHash = cdhash(ofSelf: ())
            ?? cdhash(ofPath: CommandLine.arguments[0])
            ?? Bundle.main.executablePath.flatMap { cdhash(ofPath: $0) }
        guard let expected = ownHash else {
            log("unsigned helper; cannot verify clients")
            exit(4)
        }

        let path = TouchIDHelper.socketPath
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { exit(5) }
        // 监听 fd 绝不能传给子进程：这里 spawn 的 launchctl asuser 会把
        // App 拉起来（长期运行）——不带 CLOEXEC 的话 GUI 实例会一直握着
        // 监听 socket，卸载后 unlink 掉路径文件也关不干净，而且任何持有
        // 这个 fd 的进程都能对它 accept()。
        fdCloexec(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                _ = strcpy(dst, path)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len)
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else { exit(6) }

        // 任何本地用户都能连（连接后再验身份与签名）；目录 /var/run 只有
        // root 能写，所以别人无法替换 socket 文件本身。
        chmod(path, 0o666)

        log("helper started pid=\(getpid()) proto=\(TouchIDHelperProtocol.version)")

        let queue = DispatchQueue(label: "vantage.helper", attributes: .concurrent)
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                usleep(50_000)
                continue
            }
            // 必须在派发之前打标：连接处理过程中会 spawn 子进程
            // （--tcc-write 自身、launchctl asuser），accept 出来的 fd
            // 不带 CLOEXEC 就会泄露给它们（launchctl asuser 会陪跑到
            // App 退出，连接 fd 就一直被它攥着）。
            fdCloexec(client)
            queue.async {
                handle(client: client, expected: expected)
                close(client)
            }
        }
    }

    // -----------------------------------------------------------------
    // 日志（launchd 把 stderr 落到 /var/log/<label>.log）
    // -----------------------------------------------------------------

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[helper] \(message)\n".utf8))
    }

    // -----------------------------------------------------------------
    // 单个连接
    // -----------------------------------------------------------------

    private static func handle(client: Int32, expected: Data) {
        // 对端身份一律从**审计令牌**取，而不是从 pid 反查。
        //
        // pid 有两处竞态：
        //   1. PID 复用 —— LOCAL_PEERPID 拿到的 pid 在「取回」与「查 cdhash /
        //      查路径」之间，对端可能已退出，pid 被内核分配给另一个完全
        //      不同的进程，于是验的是 A、放行的却是 B；
        //   2. TOCTOU —— 对端在两次查询之间 exec 成别的二进制。
        //
        // LOCAL_PEERTOKEN 是连接建立时由内核签发的 audit_token_t，绑定的是
        // 这条 socket 连接本身，进程退出 / exec / pid 复用都改不了它，配合
        // kSecGuestAttributeAudit 取签名，全程无 pid 参与，竞态不复存在。
        guard let peer = peerAuditToken(client) else {
            deny(client, TouchIDHelperProtocol.Error.badRequest, "no peer token")
            return
        }
        let peerPID = cproc_audit_pid(peer.tokenVal)
        let peerUID = cproc_audit_euid(peer.tokenVal)
        let peerRUID = cproc_audit_ruid(peer.tokenVal)

        // ---- 1. 身份：桌面用户 + 管理员 ----
        // 直接读审计令牌里的有效 uid（audit_token_to_euid），比 getpeereid
        // 更硬：它和连接是同一时刻快照的，不会出现「查完 uid 进程已换人」。
        // root 客户端：它本来就拥有一切权限，助手不会给它多一分权力，
        // 放行只是为了让「以 root 运行的 Vantage」也能 ping / 重装助手
        // （它降权后就是普通用户，身份检查照样生效）。
        if peerUID != 0 {
            guard let console = consoleUser() else {
                deny(client, TouchIDHelperProtocol.Error.noConsole, "no console user")
                return
            }
            guard peerUID == console.uid else {
                deny(client, TouchIDHelperProtocol.Error.notConsole,
                     "peer uid \(peerUID) != console uid \(console.uid)")
                return
            }
            guard isAdmin(uid: peerUID) else {
                deny(client, TouchIDHelperProtocol.Error.notAdmin,
                     "uid \(peerUID) (\(console.name)) is not an admin")
                return
            }
            // 真实 uid 也必须是这个用户：挡住「别人以该用户身份 fork 出来
            // 再 setuid」这类绕行（正常情况下 App 两者相同）。审计令牌里的
            // ruid 与 euid 同源，拿不到 ruid 时才回退到 pid 反查（仅作补充）。
            if peerRUID != 0, peerRUID != console.uid {
                deny(client, TouchIDHelperProtocol.Error.notConsole,
                     "peer ruid \(peerRUID) != console uid \(console.uid)")
                return
            }
            if peerRUID == 0, let ids = procUIDs(pid: peerPID), ids.ruid != 0,
               ids.ruid != console.uid {
                deny(client, TouchIDHelperProtocol.Error.notConsole,
                     "peer ruid \(ids.ruid) != console uid \(console.uid)")
                return
            }
        }

        // ---- 2. 代码：与自身完全一致的构建 ----
        guard peerCDHashMatches(token: peer, expected: expected) else {
            deny(client, TouchIDHelperProtocol.Error.signature,
                 "peer cdhash mismatch pid=\(peerPID)")
            return
        }
        guard let peerExe = peerPath(token: peer) else {
            deny(client, TouchIDHelperProtocol.Error.badRequest, "no peer path")
            return
        }

        guard let data = TouchIDSocket.readFrame(fd: client),
              let req = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              let op = req["op"] as? String else {
            deny(client, TouchIDHelperProtocol.Error.badRequest, "unreadable request")
            return
        }
        let args = req["args"] as? [String: Any] ?? [:]

        switch op {
        case "ping":
            var payload: [String: Any] = [
                "ok": true,
                "pid": getpid(),
                "protocol": TouchIDHelperProtocol.version,
            ]
            let info = TouchIDHelper.installedInfo
            if let version = info["version"], !version.isEmpty {
                payload["version"] = version
            }
            _ = reply(client, payload)

        case "exec":
            guard let argv = args["argv"] as? [String], !argv.isEmpty else {
                deny(client, TouchIDHelperProtocol.Error.badRequest, "empty argv")
                return
            }
            guard isAllowed(argv: argv, clientPath: peerExe) else {
                log("exec denied: \(argv.first ?? "?")")
                deny(client, TouchIDHelperProtocol.Error.notAllowed,
                     "tool not allowed: \(argv[0])")
                return
            }
            let (rc, out) = runAndCapture(argv)
            _ = reply(client, ["ok": rc == 0, "rc": Int(rc), "out": out])

        case "relaunch":
            guard let app = args["app"] as? String,
                  let uid = args["uid"] as? Int, uid > 0,
                  app.hasPrefix("/") else {
                deny(client, TouchIDHelperProtocol.Error.badRequest,
                     "bad relaunch args")
                return
            }
            // 只允许「调用方自己的可执行文件」，且 uid 必须是对端真实拥有者：
            // 这样即便有人拿到合法客户端的签名，也没法让 root 去跑任意程序。
            // 路径要比**规范化**后的（/tmp 与 /private/tmp 是同一处）。
            guard Int(peerUID) == uid,
                  canonical(app) == canonical(peerExe) else {
                log("relaunch denied: app=\(app) peerExe=\(peerExe) uid=\(uid) peerUID=\(peerUID)")
                deny(client, TouchIDHelperProtocol.Error.relaunchDenied,
                     "app does not match the caller")
                return
            }
            let result = relaunch(app: app, uid: uid_t(uid))
            if !result.ok {
                log("relaunch failed: \(result.detail ?? "?")")
            }
            _ = reply(client, ["ok": result.ok,
                               "detail": result.detail ?? "",
                               "error": result.ok ? "" :
                                        TouchIDHelperProtocol.Error.launchFailed])

        case "uninstall":
            // 「谁装的谁能拆」：安装时把发起者 uid 写进 sidecar，只有同一个
            // 用户（且已过上面的桌面用户 + admin + 签名三道门）能让助手自毁。
            // 卸载只减权限，不存在借机提权的可能，所以不需要再来一次密码。
            let info = TouchIDHelper.installedInfo
            guard let raw = info["installer"], let recorded = uid_t(raw),
                  recorded != 0 else {
                deny(client, TouchIDHelperProtocol.Error.notAllowed,
                     "no installer uid recorded")
                return
            }
            guard recorded == peerUID else {
                deny(client, TouchIDHelperProtocol.Error.notAllowed,
                     "installer uid \(recorded) != peer uid \(peerUID)")
                return
            }
            _ = reply(client, ["ok": true])
            log("uninstall requested by uid \(peerUID); removing")
            selfDestruct()

        default:
            deny(client, TouchIDHelperProtocol.Error.badRequest, "unknown op \(op)")
        }
    }

    /// 自毁：删文件 + bootout。
    ///
    /// 删文件全部**进程内**完成（unlink）：正在运行的二进制也能删 —— 内核
    /// 持有旧 inode，进程退出才释放；socket 的路径删掉也不影响已建立的连接
    /// （回复早已写进内核缓冲，客户端照样读得到），所以不再需要 sleep / rm。
    /// 剩下的 bootout 必须交给一个**独立会话**的子进程：launchctl bootout 会把
    /// 本 job 的所有进程一起杀掉，我们不能自己收自己 —— 直接 exec launchctl
    /// （不经 /bin/sh），POSIX_SPAWN_SETSID 让它脱离本会话。
    private static func selfDestruct() {
        for path in [TouchIDHelper.helperPath, TouchIDHelper.plistPath,
                     TouchIDHelper.infoPath, TouchIDHelper.socketPath,
                     TouchIDState.flagPath] {
            unlink(path)
        }
        let domain = "system/\(TouchIDHelper.label)"
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/launchctl"), strdup("bootout"), strdup(domain), nil,
        ]
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/launchctl", nil, &attr, &argv, &envp)
        posix_spawnattr_destroy(&attr)
        for p in argv { free(p) }
        if rc != 0 {
            log("self-destruct spawn failed rc=\(rc)")
        }
    }

    private static func deny(_ fd: Int32, _ code: String, _ why: String) {
        log("deny \(code): \(why)")
        _ = reply(fd, ["ok": false, "error": code])
    }

    private static func reply(_ fd: Int32, _ payload: [String: Any]) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return false }
        return TouchIDSocket.writeFrame(fd: fd, body: body)
    }

    // -----------------------------------------------------------------
    // 鉴权辅助
    // -----------------------------------------------------------------

    /// 当前桌面用户：/dev/console 的属主就是「坐在机器前的那个人」。
    /// 快速用户切换时它也指向前台用户；停在登录窗口时属主是 root，此时
    /// 不该允许任何提权（返回 uid 0 会被上面的 `peerUID != 0` 挡掉）。
    private static func consoleUser() -> (uid: uid_t, name: String)? {
        var st = stat()
        guard stat("/dev/console", &st) == 0 else { return nil }
        let uid = st.st_uid
        guard let pw = getpwuid(uid) else { return (uid, "?") }
        return (uid, String(cString: pw.pointee.pw_name))
    }

    private static func isAdmin(uid: uid_t) -> Bool {
        guard let pw = getpwuid(uid) else { return false }
        let target = adminGID
        var groups = [Int32](repeating: 0, count: 32)
        var count = Int32(groups.count)
        var rc = getgrouplist(pw.pointee.pw_name, Int32(pw.pointee.pw_gid),
                              &groups, &count)
        if rc < 0 {
            // 缓冲区不够：count 已被写成所需数量，重来一次
            groups = [Int32](repeating: 0, count: Int(count))
            var retry = count
            rc = getgrouplist(pw.pointee.pw_name, Int32(pw.pointee.pw_gid),
                              &groups, &retry)
            count = retry
        }
        guard rc >= 0 else { return false }
        return groups.prefix(Int(count)).contains(Int32(target))
    }

    /// 某个进程的可执行文件路径（从审计令牌取，避免 pid 复用竞态）。
    /// proc_pidpath_audittoken 拿到的路径与连接建立时的对端是同一个实体。
    private static func peerPath(token: audit_token_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        var t = token
        let n = proc_pidpath_audittoken(&t, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// 对端的审计令牌（LOCAL_PEERTOKEN）。这是「连接建立时」由内核签发、
    /// 绑定这条 socket 连接的身份快照，进程退出 / pid 复用 / exec 都改不了它。
    private static func peerAuditToken(_ fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len)
        guard rc == 0, len == MemoryLayout<audit_token_t>.size else { return nil }
        return token
    }

    /// 进程的真实 / 有效 uid（拿不到时返回 nil，不因此拒绝）。
    /// 仅在「审计令牌拿不到 ruid」时作为补充回退。
    private static func procUIDs(pid: pid_t) -> (ruid: uid_t, euid: uid_t)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return (uid_t(info.pbi_ruid), uid_t(info.pbi_uid))
    }

    private static func peerCDHashMatches(token: audit_token_t, expected: Data) -> Bool {
        guard let peer = cdhash(ofAuditToken: token) else { return false }
        return peer == expected
    }

    /// 真·规范化路径：`/tmp/x` 与 `/private/tmp/x` 视为同一个文件。
    /// proc_pidpath 返回的是内核眼里的真实路径，而客户端传过来的是
    /// Bundle.main.executablePath（可能是带符号链接的写法）—— 不规范化
    /// 就会出现「明明是同一个文件却判定不相等」。
    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 白名单 + 一个特例：调用方自己的可执行文件，只允许 `--tcc-write` 模式。
    private static func isAllowed(argv: [String], clientPath: String) -> Bool {
        let tool = argv[0]
        if allowedTools.contains(tool) { return true }

        // TCC 写入复用本 App 的隐藏模式：路径必须正是调用方的可执行文件
        guard argv.count >= 2, argv[1] == "--tcc-write" else { return false }
        return canonical(tool) == canonical(clientPath)
    }

    // -----------------------------------------------------------------
    // 执行
    // -----------------------------------------------------------------

    /// 子进程环境白名单 —— 与 `cproc_auth_exec` 的 exec 环境、
    /// `Privilege.runDirect` 同源（C 层单一清单）。
    /// 守护进程本身由 launchd 启动、环境已经很干净，但这里仍显式指定
    /// `Process.environment`（等价于给 posix_spawn 传最小 envp），
    /// 不继承任何东西：既免疫未来新增的 DYLD_* / shell 注入变量，
    /// 也不用去改守护进程的全局 environ（它是并发 accept 的多线程进程）。
    private static let cleanEnvironment = Privilege.cleanEnvironment

    private static func runAndCapture(_ argv: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = cleanEnvironment
        let pipe = Pipe()
        // Foundation 的 pipe() 两端都不带 CLOEXEC。守护进程是并发 accept
        // 的多线程进程：本连接的读端若泄露给**别的连接**正在 spawn 的
        // 子进程，对方 readDataToEndOfFile 会因多出一个写端持有者而收不到
        // EOF。子进程要的 stdout/stderr 由 Process 内部用 dup2 重新落位
        // （dup2 会清掉目标 fd 的 CLOEXEC），这里打标不影响它们。
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
        var text = String(data: data, encoding: .utf8) ?? ""
        if text.count > 64 * 1024 {
            text = String(text.prefix(64 * 1024)) + "…"
        }
        return (p.terminationStatus, text)
    }

    /// 在用户的图形会话里以 root 启动 App，并确认它真的起来了。
    ///
    /// `launchctl asuser` 会把子进程放进目标用户的 bootstrap/Aqua 会话，
    /// 但「命令返回 0」不等于「App 出现」：会话域没加载、二进制被
    /// Gatekeeper 拦下、路径失效都会让它秒退。所以这里等最多 2.5 秒，
    /// 在进程表里找「uid=0 且路径相同」的实例，找不到就把 launchctl 的
    /// 输出一起回给客户端 —— 界面能说出真正的原因，而不是一句「已取消」。
    private static func relaunch(app: String, uid: uid_t)
        -> (ok: Bool, detail: String?) {
        // 日志落在 /private/var/tmp（系统级、粘滞位），**不要**用
        // NSTemporaryDirectory()：守护进程没有「用户临时目录」，
        // 取到的路径常常不可写；而且 root 往用户 /tmp 里写本身就是污染。
        let logPath = "/private/var/tmp/vantage-launchctl-\(getpid())-\(Int(Date().timeIntervalSince1970)).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: logPath) }
        let handle = FileHandle(forWritingAtPath: logPath)
        // 同 runAndCapture：别的连接并发 spawn 的子进程不该继承这把
        // 「可写日志文件的钥匙」。launchctl 的 stdout/stderr 由 Process
        // 用 dup2 落位，不受这里打标影响。
        if let handle = handle { fdCloexec(handle.fileDescriptor) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        // **必须带 --respawn-disclaimed**：launchctl asuser 把 App 拉进
        // 用户 GUI 会话的同时，TCC 的 responsible process 也一路继承到
        // 本助手（LaunchDaemon，没有 FDA）——用户授给 App 的「完全磁盘
        // 访问」会失效，root 实例读 TCC.db / 其他用户目录全被拒。
        // 第一级实例（已在会话里）会用 disclaim 重新 spawn 真正的 App
        // 再退出，第二级 responsible = 自身，FDA 恢复（见 spawn_self.c）。
        p.arguments = ["asuser", String(uid), app,
                       "--respawn-disclaimed", "--drop-uid", String(uid)]
        p.environment = cleanEnvironment
        p.standardOutput = handle ?? FileHandle.nullDevice
        p.standardError = handle ?? FileHandle.nullDevice
        p.terminationHandler = { finished in
            // 从持有数组里摘掉，避免长期运行后堆积
            let pid = finished.processIdentifier
            childLock.lock()
            children.removeAll { $0.processIdentifier == pid }
            childLock.unlock()
        }
        do {
            try p.run()
        } catch {
            try? handle?.close()
            return (false, error.localizedDescription)
        }
        childLock.lock()
        children.append(p)
        childLock.unlock()

        // 确认新实例真的起来了。两条判据取「或」：
        //   · 进程表里出现 uid=0 且路径相同的实例（最直接，但不同权限
        //     层级下 proc_pidinfo 可能看不到别的进程）；
        //   · launchctl 自己还活着 —— asuser 会把子进程陪跑到退出，
        //     它没退出就说明目标用户的会话域找到了、程序已经 exec。
        // 只有在 launchctl **提前退出**（域没加载 / 路径失效）时才算失败，
        // 这样「看不到」不会误判成「没起来」。
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if runningRootProcess(path: app) {
                try? handle?.close()
                log("relaunch ok (process seen): \(app) uid=\(uid)")
                return (true, nil)
            }
            if !p.isRunning { break }
            usleep(80_000)
        }

        if p.isRunning {
            try? handle?.close()
            log("relaunch ok (launchctl alive): \(app) uid=\(uid)")
            return (true, nil)
        }

        try? handle?.close()
        let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, detail.isEmpty
                ? "launchctl exited immediately (status \(p.terminationStatus)) "
                    + "without starting the app"
                : detail)
    }

    /// 进程表里是否已有「这个可执行文件的 root 实例」
    private static func runningRootProcess(path: String) -> Bool {
        let target = canonical(path)
        let maxCount = 4096
        var pids = [pid_t](repeating: 0, count: maxCount)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                  Int32(maxCount * MemoryLayout<pid_t>.size))
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        guard count > 0 else { return false }
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == 0 else { continue }
            var buf = [CChar](repeating: 0, count: 4 * 1024)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            if canonical(String(cString: buf)) == target { return true }
        }
        return false
    }
}
