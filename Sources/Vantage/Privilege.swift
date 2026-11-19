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
// ---------------------------------------------------------------------

enum Privilege {

    /// 当前进程是否已经是 root
    static var isRoot: Bool { geteuid() == 0 }

    /// 复用的授权引用：系统会缓存凭据（默认 5 分钟），连续操作不再重复弹框
    private static var authRef: UnsafeMutableRawPointer?

    /// errno 是否属于「权限不足」——这类错误才值得提示提权
    static func isPermissionError(_ err: Int32) -> Bool {
        err == EPERM || err == EACCES
    }

    // -----------------------------------------------------------------
    // 授权
    // -----------------------------------------------------------------

    /// 申请「以 root 执行」权限。第一次调用会弹系统授权对话框；
    /// 凭据在有效期内复用，重复调用直接成功。
    @discardableResult
    static func authorize() -> Bool {
        if isRoot { return true }
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
            return false
        }
        return true
    }

    /// 释放授权凭据（退出前调用，避免凭据被继续缓存）
    static func releaseAuthorization() {
        if let ref = authRef {
            cproc_auth_free(ref)
            authRef = nil
        }
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
            return false
        }
        guard authorize() else { return false }

        // 不再传参数：子进程用 geteuid()==0 自行判断身份，
        // 少了参数解析就少了「传错一个开关就起不来」的可能。
        let rc = withCArgs([]) { argv in
            cproc_auth_exec(authRef, exe, argv, nil)
        }
        return rc == 0
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
    /// - 否则：先申请授权（弹框），再以 root 跑 `/bin/sh -c "… 2>&1"`，
    ///   这样 stderr 的错误文本也能回显到界面上。
    ///
    /// 参数由调用方严格校验（IP / 前缀 / MTU / 网卡名），这里只做 shell 转义，
    /// 不拼接任何未经检查的用户输入。
    static func run(tool: String, args: [String]) -> (rc: Int32, output: String) {
        if isRoot {
            return runDirect(tool: tool, args: args)
        }
        guard authorize(), let ref = authRef else {
            return (-1, L("priv.authorizationCancelled"))
        }
        let command = ([tool] + args).map(shellQuote).joined(separator: " ")
            + " 2>&1"
        var outPtr: UnsafeMutablePointer<CChar>?
        let rc = withCArgs(["-c", command]) { argv in
            cproc_auth_exec(ref, "/bin/sh", argv, &outPtr)
        }
        var text = ""
        if let p = outPtr {
            text = String(cString: p)
            free(p)
        }
        return (rc, text)
    }

    /// 已提权时的直接执行（也用于读命令，例如不带参数的 `ifconfig`）
    private static func runDirect(tool: String, args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
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

    /// 单引号转义：`it's` → `'it'\''s'`。只用于我们自己拼的命令行。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

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
