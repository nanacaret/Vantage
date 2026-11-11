// swift-tools-version:5.9
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "Vantage",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Vantage", targets: ["Vantage"])
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
            ]
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
