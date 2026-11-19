// SPDX-License-Identifier: MIT
import AppKit
import Foundation

// ---------------------------------------------------------------------
// AppleScript 支持
//
// 三个组成部分：
//   1. Resources/Vantage.sdef   术语表（命令名、参数、返回类型）
//   2. Info.plist               NSAppleScriptEnabled + OSAScriptingDefinition
//   3. 本文件                   命令实现
//
// 实现有**两条路**，都指向同一批数据：
//   · NSScriptCommand 子类：sdef 里用 <cocoa class="…"/> 绑定，由
//     NSScriptSuiteRegistry 派发。类名必须用 @objc(裸类名) 固定，
//     否则 Swift 会带上模块前缀，sdef 里就找不到。
//   · NSAppleEventManager 直连：用四字符码（class=Vntg，id=LstP …）注册
//     handler。**这条路是必需的** —— 本 App 用自己写的 main.swift 调
//     `NSApp.run()`（不走 NSApplicationMain），实测只靠 sdef 映射时
//     任何事件（连标准 quit）都会回 -10004，加上直连 handler 后正常。
//
// 数据取 GUI 已采好的快照，不额外跑一遍 sysctl。
// ---------------------------------------------------------------------

final class ScriptHandlers: NSObject {

    static let shared = ScriptHandlers()

    /// 四字符码 → OSType（事件类 / 事件 ID / 参数关键字都用它）
    static func code(_ s: String) -> AEEventClass {
        var v: UInt32 = 0
        for u in s.utf8.prefix(4) { v = (v << 8) | UInt32(u) }
        return AEEventClass(v)
    }

    /// 在 applicationDidFinishLaunching 里调用一次
    static func install() {
        let m = NSAppleEventManager.shared()
        let pairs: [(String, Selector)] = [
            ("LstP", #selector(handleListProcesses(_:withReplyEvent:))),
            ("InfP", #selector(handleProcessInfo(_:withReplyEvent:))),
            ("QitP", #selector(handleQuitProcess(_:withReplyEvent:))),
            ("LstI", #selector(handleListInterfaces(_:withReplyEvent:))),
            ("LstR", #selector(handleListRoutes(_:withReplyEvent:))),
        ]
        for (id, sel) in pairs {
            m.setEventHandler(shared, andSelector: sel,
                              forEventClass: code("Vntg"),
                              andEventID: code(id))
        }
    }

    // MARK: 事件 handler

    @objc func handleListProcesses(_ event: NSAppleEventDescriptor,
                                   withReplyEvent reply: NSAppleEventDescriptor) {
        Self.setList(processLines(), on: reply)
    }

    @objc func handleProcessInfo(_ event: NSAppleEventDescriptor,
                                 withReplyEvent reply: NSAppleEventDescriptor) {
        let pid = event.paramDescriptor(forKeyword: keyDirectObject)?.int32Value ?? 0
        Self.setList(infoLines(pid: pid), on: reply)
    }

    @objc func handleQuitProcess(_ event: NSAppleEventDescriptor,
                                 withReplyEvent reply: NSAppleEventDescriptor) {
        let pid = event.paramDescriptor(forKeyword: keyDirectObject)?.int32Value ?? 0
        let sig = event.paramDescriptor(forKeyword: Self.code("sigl"))?.stringValue
            ?? "TERM"
        reply.setParam(NSAppleEventDescriptor(string: quitProcess(pid: pid, signal: sig)),
                       forKeyword: keyDirectObject)
    }

    @objc func handleListInterfaces(_ event: NSAppleEventDescriptor,
                                    withReplyEvent reply: NSAppleEventDescriptor) {
        Self.setList(interfaceLines(), on: reply)
    }

    @objc func handleListRoutes(_ event: NSAppleEventDescriptor,
                                withReplyEvent reply: NSAppleEventDescriptor) {
        Self.setList(routeLines(), on: reply)
    }

    private static func setList(_ strings: [String],
                                on reply: NSAppleEventDescriptor) {
        let list = NSAppleEventDescriptor.list()
        for (i, s) in strings.enumerated() {
            list.insert(NSAppleEventDescriptor(string: s), at: i + 1)
        }
        reply.setParam(list, forKeyword: keyDirectObject)
    }

    // MARK: 数据（handler 与 NSScriptCommand 共用）

    func processLines() -> [String] {
        AppContext.shared.store.processes.map {
            "\($0.pid)\t\($0.ppid)\t\($0.userName)\t\($0.stateName)\t"
                + "\($0.rss)\t\($0.threads)\t\($0.primaryDisplayName)"
        }
    }

    func infoLines(pid: Int32) -> [String] {
        guard let p = AppContext.shared.store.process(withPID: pid) else {
            return ["error: no such process \(pid)"]
        }
        return [
            "pid: \(p.pid)", "ppid: \(p.ppid)",
            "name: \(p.primaryDisplayName)", "user: \(p.userName)",
            "state: \(p.stateName)", "rss: \(p.rss)", "threads: \(p.threads)",
            "executable: \(p.exepath)", "command: \(p.cmdline)",
        ]
    }

    func quitProcess(pid: Int32, signal: String) -> String {
        guard pid > 0 else { return "error: a PID is required" }
        guard let sig = Self.signalNumber(signal) else {
            return "error: unknown signal \(signal)"
        }
        let rc = ProcBridge.signal(pid, sig)
        return rc == 0 ? "sent signal \(sig) to \(pid)"
                       : "error: \(String(cString: strerror(errno)))"
    }

    func interfaceLines() -> [String] {
        let addrs = NetBridge.addrs()
        var out: [String] = []
        for i in NetBridge.ifaces() {
            var line = "\(i.name)\tmtu \(i.mtu)\t\(i.flagText)"
            if !i.mac.isEmpty { line += "\t\(i.mac)" }
            out.append(line)
            for a in addrs where a.ifname == i.name {
                out.append("\t\(a.family)\t\(a.addr)\t\(a.prefix)")
            }
        }
        return out
    }

    func routeLines() -> [String] {
        NetBridge.routes().map {
            "\($0.family)\t\($0.dest)\t\($0.gateway)\t\($0.flags)\t\($0.netif)"
        }
    }

    static func signalNumber(_ s: String) -> Int32? {
        if let n = Int32(s), n > 0, n < 32 { return n }
        let names: [String: Int32] = [
            "HUP": 1, "INT": 2, "QUIT": 3, "ABRT": 6, "KILL": 9,
            "TERM": 15, "STOP": 17, "CONT": 19, "USR1": 30, "USR2": 31,
        ]
        return names[s.uppercased().replacingOccurrences(of: "SIG", with: "")]
    }
}

// MARK: - sdef 绑定（<cocoa class="…"/>）

@objc(ListProcessesCommand)
final class ListProcessesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptHandlers.shared.processLines()
    }
}

@objc(ProcessInfoCommand)
final class ProcessInfoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let pid = (directParameter as? NSNumber)?.int32Value else {
            scriptErrorString = "a PID is required"
            scriptErrorNumber = -1721
            return nil
        }
        return ScriptHandlers.shared.infoLines(pid: pid)
    }
}

@objc(QuitProcessCommand)
final class QuitProcessCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let pid = (directParameter as? NSNumber)?.int32Value, pid > 0 else {
            scriptErrorString = "a PID is required"
            scriptErrorNumber = -1721
            return nil
        }
        let raw = (evaluatedArguments?["signal"] as? String) ?? "TERM"
        let text = ScriptHandlers.shared.quitProcess(pid: pid, signal: raw)
        if text.hasPrefix("error:") {
            scriptErrorString = text
            scriptErrorNumber = -1
            return nil
        }
        return text
    }
}

@objc(ListInterfacesCommand)
final class ListInterfacesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptHandlers.shared.interfaceLines()
    }
}

@objc(ListRoutesCommand)
final class ListRoutesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptHandlers.shared.routeLines()
    }
}
