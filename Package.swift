// swift-tools-version:5.9
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "Vantage",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Vantage", targets: ["Vantage"]),
        // MCP（Model Context Protocol）stdio 服务：给 Claude Desktop / Cursor 等
        // 客户端提供「读进程 / 读网络 / 发信号」的工具，不依赖 GUI 是否在跑。
        .executable(name: "vantage-mcp", targets: ["VantageMCP"]),
    ],
    targets: [
        // C 采集层：sysctl / libproc / Mach / IOKit / CoreFoundation
        // IOKit + CoreFoundation 用于性能监控（AppleSMC、IORegistry、磁盘统计、IOReport）
        .target(
            name: "CProc",
            path: "Sources/CProc",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                // Authorization Services：图形界面提权（cproc_auth_*）
                .linkedFramework("Security"),
            ]
        ),
        // MCP stdio 服务（纯命令行，不链接 AppKit）
        .executableTarget(
            name: "VantageMCP",
            dependencies: ["CProc"],
            path: "Sources/VantageMCP"
        ),
        // AppKit 原生 GUI（含 main.swift，必须声明为 executableTarget）
        .executableTarget(
            name: "Vantage",
            dependencies: ["CProc"],
            path: "Sources/Vantage",
            // CGWindowListCopyWindowInfo / CGDisplayBounds 用于「通过窗口定位进程」；
            // ApplicationServices (AXUIElement) 用于「激活指定窗口」
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
