// SPDX-License-Identifier: MIT
import CProc
import Darwin
import Foundation

// ---------------------------------------------------------------------
// 系统网络信息：C 层 net_info.c 的数据模型 + 命令拼装
//
// 读取（网卡 / 地址 / 路由）走 C 层，不需要 root；
// 修改（up/down、MTU、增删 IP、增删路由）走 /sbin/ifconfig 与 /sbin/route，
// 由 Privilege 统一提权，参数在这里做**严格校验**后再拼。
// ---------------------------------------------------------------------

// MARK: - 数据模型

struct NetIface {
    let index: Int32
    let name: String
    let flags: UInt32
    let mtu: Int
    let mac: String
    let type: String

    var isUp: Bool { flags & UInt32(IFF_UP) != 0 }
    var isRunning: Bool { flags & UInt32(IFF_RUNNING) != 0 }
    var isLoopback: Bool { flags & UInt32(IFF_LOOPBACK) != 0 }
    var isPointToPoint: Bool { flags & UInt32(IFF_POINTOPOINT) != 0 }

    /// ifconfig 风格的大写标志串，例如 "UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST"
    var flagText: String {
        let table: [(Int32, String)] = [
            (IFF_UP, "UP"), (IFF_BROADCAST, "BROADCAST"),
            (IFF_DEBUG, "DEBUG"), (IFF_LOOPBACK, "LOOPBACK"),
            (IFF_POINTOPOINT, "POINTOPOINT"), (IFF_NOTRAILERS, "NOTRAILERS"),
            (IFF_RUNNING, "RUNNING"), (IFF_NOARP, "NOARP"),
            (IFF_PROMISC, "PROMISC"), (IFF_ALLMULTI, "ALLMULTI"),
            (IFF_MULTICAST, "MULTICAST"), (IFF_SIMPLEX, "SIMPLEX"),
        ]
        return table.filter { flags & UInt32($0.0) != 0 }
            .map { $0.1 }.joined(separator: ",")
    }
}

struct NetAddr {
    let ifname: String
    let family: String          // inet / inet6 / link
    let addr: String
    let prefix: Int
    let netmask: String
    let peer: String
    let scope: UInt32

    var isIPv6: Bool { family == "inet6" }
}

struct NetRoute {
    let family: String          // inet / inet6
    let dest: String            // 已带前缀：10.0.0.0/24、::/0
    let gateway: String
    let flags: String
    let netif: String
    let expire: Int

    var isIPv6: Bool { family == "inet6" }
    var isDefault: Bool { dest.hasPrefix("0.0.0.0/0") || dest.hasPrefix("::/0") }
}

// MARK: - 读取

enum NetBridge {

    static func ifaces() -> [NetIface] {
        lines(cproc_net_ifaces).compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 6 else { return nil }
            return NetIface(
                index: Int32(c[0]) ?? 0,
                name: String(c[1]),
                flags: UInt32(c[2], radix: 16) ?? 0,
                mtu: Int(c[3]) ?? 0,
                mac: String(c[4]),
                type: String(c[5]))
        }
    }

    static func addrs() -> [NetAddr] {
        lines(cproc_net_addrs).compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 7 else { return nil }
            return NetAddr(
                ifname: String(c[0]),
                family: String(c[1]),
                addr: String(c[2]),
                prefix: Int(c[3]) ?? -1,
                netmask: String(c[4]),
                peer: String(c[5]),
                scope: UInt32(c[6]) ?? 0)
        }
    }

    static func routes() -> [NetRoute] {
        lines(cproc_net_routes).compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 6 else { return nil }
            return NetRoute(
                family: String(c[0]),
                dest: String(c[1]),
                gateway: String(c[2]),
                flags: String(c[3]),
                netif: String(c[4]),
                expire: Int(c[5]) ?? 0)
        }
    }

    /// 一次取走 C 层的 cproc_lines_t（自动释放）
    private static func lines(
        _ fn: (UnsafeMutablePointer<cproc_lines_t>) -> Int32
    ) -> [String] {
        var out = cproc_lines_t()
        guard fn(&out) == 0 else {
            cproc_lines_free(&out)
            return []
        }
        defer { cproc_lines_free(&out) }
        var result: [String] = []
        result.reserveCapacity(Int(out.count))
        for i in 0..<Int(out.count) {
            result.append(String(cString: cproc_line(&out, Int32(i))))
        }
        return result
    }
}

// MARK: - 校验
//
// 所有会进入命令行的用户输入都必须先过这一关。注意 ifconfig / route 的参数
// 最终会被 Privilege 拼进 `sh -c`（为了拿到 stderr），所以「看起来像路径」
// 这种宽松判断是不够的：只接受能通过 inet_pton 的地址、纯数字前缀、合法网卡名。

enum NetValidate {

    static func isIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &a) == 1 }
    }

    static func isIPv6(_ s: String) -> Bool {
        // 允许 fe80::1%en0 这种带 scope 的写法
        let core = s.split(separator: "%", maxSplits: 1).first.map(String.init) ?? s
        var a = in6_addr()
        return core.withCString { inet_pton(AF_INET6, $0, &a) == 1 }
    }

    /// 网卡名：真实存在（或至少形如 en0 / utun12 / bridge0）才放行
    static func isIfaceName(_ s: String, known: Set<String>) -> Bool {
        guard known.contains(s) else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// "10.0.0.0/24" / "default" / "2001:db8::/64" → (地址, 前缀, 族)
    static func parseDestination(_ raw: String)
        -> (address: String, prefix: Int, isV6: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.lowercased() == "default" { return ("0.0.0.0", 0, false) }
        if s.lowercased() == "default6" { return ("::", 0, true) }

        let parts = s.split(separator: "/", maxSplits: 1,
                            omittingEmptySubsequences: false)
        let addr = String(parts[0])
        if isIPv4(addr) {
            let bits = parts.count > 1 ? Int(parts[1]) : nil
            let prefix = bits ?? 32
            guard (0...32).contains(prefix) else { return nil }
            return (addr, prefix, false)
        }
        if isIPv6(addr) {
            let bits = parts.count > 1 ? Int(parts[1]) : nil
            let prefix = bits ?? 128
            guard (0...128).contains(prefix) else { return nil }
            return (addr, prefix, true)
        }
        return nil
    }

    /// 前缀 → 点分掩码（ifconfig 的 netmask 参数）
    static func dottedMask(_ prefix: Int) -> String {
        let p = max(0, min(32, prefix))
        let m: UInt32 = p == 0 ? 0 : (UInt32.max << (32 - p)) & UInt32.max
        return "\((m >> 24) & 0xff).\((m >> 16) & 0xff).\((m >> 8) & 0xff).\(m & 0xff)"
    }

    /// 网关：IPv4 / IPv6（可带 %en0）/ 网卡名
    static func isGateway(_ s: String, known: Set<String>) -> Bool {
        isIPv4(s) || isIPv6(s) || isIfaceName(s, known: known)
    }
}

// MARK: - 修改

enum NetAdmin {

    static let ifconfigPath = "/sbin/ifconfig"
    static let routePath = "/sbin/route"

    /// 开关网卡：ifconfig en0 up / down
    static func setLink(iface: String, up: Bool) -> (rc: Int32, output: String) {
        Privilege.run(tool: ifconfigPath, args: [iface, up ? "up" : "down"])
    }

    /// ifconfig en0 mtu 1400
    static func setMTU(iface: String, mtu: Int) -> (rc: Int32, output: String) {
        Privilege.run(tool: ifconfigPath, args: [iface, "mtu", "\(mtu)"])
    }

    /// 增加地址：
    ///   v4 → ifconfig en0 inet 1.2.3.4 netmask 255.255.255.0 alias
    ///   v6 → ifconfig en0 inet6 2001:db8::1 prefixlen 64 alias
    static func addAddress(iface: String, address: String, prefix: Int,
                           isV6: Bool) -> (rc: Int32, output: String) {
        if isV6 {
            return Privilege.run(tool: ifconfigPath,
                                 args: [iface, "inet6", address,
                                        "prefixlen", "\(prefix)", "alias"])
        }
        return Privilege.run(tool: ifconfigPath,
                             args: [iface, "inet", address,
                                    "netmask", NetValidate.dottedMask(prefix),
                                    "alias"])
    }

    /// 删除地址（ifconfig 的 -alias 形式；主地址通常会被内核拒绝，错误原样回显）
    static func removeAddress(iface: String, address: String,
                              isV6: Bool) -> (rc: Int32, output: String) {
        if isV6 {
            return Privilege.run(tool: ifconfigPath,
                                 args: [iface, "inet6", address, "-alias"])
        }
        return Privilege.run(tool: ifconfigPath,
                             args: [iface, "-alias", address])
    }

    /// 增加路由：
    ///   route -n add default 192.168.1.1
    ///   route -n add -net 10.0.0.0/24 192.168.1.1
    ///   route -n add -inet6 2001:db8::/64 fe80::1%en0
    ///   route -n add -host 1.2.3.4 192.168.1.1
    ///   route -n add default -interface utun8        （网关写网卡名时）
    static func addRoute(address: String, prefix: Int, isV6: Bool,
                         gateway: String,
                         reject: Bool) -> (rc: Int32, output: String) {
        var args = ["-n", "add"]
        if isV6 { args.append("-inet6") }
        args.append(contentsOf: destinationArgs(address: address,
                                                prefix: prefix,
                                                isV6: isV6))
        // 网关只写了网卡名（en0 / utun8）时，route 要求 -interface 前缀；
        // 直接写成裸名字会被当成主机名解析而失败。
        if NetValidate.isIPv4(gateway) || NetValidate.isIPv6(gateway) {
            args.append(gateway)
        } else {
            args.append(contentsOf: ["-interface", gateway])
        }
        if reject { args.append("-reject") }
        return Privilege.run(tool: routePath, args: args)
    }

    /// 删除路由。
    /// **必须优先带上网关**：`route delete default` 会删掉内核匹配到的第一条
    /// 默认路由 —— 有多条默认路由时（VPN + 物理网卡）删的往往不是用户选的那条。
    /// 只有网关不是 IP（ARP 项的 MAC、link#N）时才退回「只按目标删」。
    static func deleteRoute(address: String, prefix: Int, isV6: Bool,
                            gateway: String?) -> (rc: Int32, output: String) {
        var args = ["-n", "delete"]
        if isV6 { args.append("-inet6") }
        args.append(contentsOf: destinationArgs(address: address,
                                                prefix: prefix,
                                                isV6: isV6))

        let gw = (gateway ?? "").trimmingCharacters(in: .whitespaces)
        let gwIsIP = NetValidate.isIPv4(gw) || NetValidate.isIPv6(gw)
        if gwIsIP {
            var withGateway = args
            withGateway.append(gw)
            let first = Privilege.run(tool: routePath, args: withGateway)
            if first.rc == 0 { return first }
        }
        let plain = Privilege.run(tool: routePath, args: args)
        if plain.rc == 0 { return plain }
        // 网关是网卡名（link 路由）时用 -interface 再试一次
        if !gwIsIP, !gw.isEmpty, gw != "-" {
            var viaIface = args
            viaIface.append(contentsOf: ["-interface", gw])
            let third = Privilege.run(tool: routePath, args: viaIface)
            if third.rc == 0 { return third }
        }
        return plain
    }

    private static func destinationArgs(address: String, prefix: Int,
                                        isV6: Bool) -> [String] {
        let maxBits = isV6 ? 128 : 32
        if prefix == 0 && (address == "0.0.0.0" || address == "::") {
            return ["default"]
        }
        if prefix == maxBits {
            return ["-host", address]
        }
        return ["-net", "\(address)/\(prefix)"]
    }
}
