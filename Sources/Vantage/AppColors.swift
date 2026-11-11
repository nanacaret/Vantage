// SPDX-License-Identifier: MIT
import AppKit
import Foundation

extension Notification.Name {
    /// 用户改动配色后发出；各视图 reloadData / 重绘即可，不需要重建窗口。
    static let appColorsDidChange =
        Notification.Name("com.vantage.appColorsDidChange")
}

// ---------------------------------------------------------------------
// 可定制配色
//
// 设计要点：
//  · 未自定义时返回 **系统动态色**（systemRed / linkColor …），自动适配
//    浅色 / 深色模式与辅助功能里的「增加对比度」；
//  · 用户一旦改过，就以 sRGB hex（#RRGGBB 或 #RRGGBBAA）存 UserDefaults，
//    变成固定色，不再随外观变化；单个颜色可单独恢复默认；
//  · 预设只是一组一次性写入的 hex，「系统默认」预设 = 清空所有自定义。
// ---------------------------------------------------------------------

enum AppColorKey: String, CaseIterable {
    case cpuHigh, cpuMedium
    case stateRunning, stateStopped, stateZombie
    case pidLink
    case exitedText, exitedBackground
    case chartUser, chartSystem, chartMemory

    var title: String {
        switch self {
        case .cpuHigh:          return "CPU ≥ 80%"
        case .cpuMedium:        return "CPU ≥ 40%"
        case .stateRunning:     return L("color.running")
        case .stateStopped:     return L("color.stopped")
        case .stateZombie:      return L("color.zombie")
        case .pidLink:          return L("color.pidLink")
        case .exitedText:       return L("color.exitedRowText")
        case .exitedBackground: return L("color.exitedRowBackground")
        case .chartUser:        return L("color.cpuUserCurve")
        case .chartSystem:      return L("color.cpuSystemCurve")
        case .chartMemory:      return L("color.memoryCurve")
        }
    }

    var hint: String {
        switch self {
        case .cpuHigh, .cpuMedium:
            return L("color.thresholdColorsForTheCpu")
        case .stateRunning, .stateStopped, .stateZombie:
            return L("color.theStatusColumnInThe")
        case .pidLink:
            return L("color.pidValuesInDetailTables")
        case .exitedText, .exitedBackground:
            return L("color.rowHighlightDuringThePost")
        case .chartUser, .chartSystem, .chartMemory:
            return L("color.systemOverviewChartAtThe")
        }
    }
}

enum ColorPreset: String, CaseIterable {
    case system, highContrast, warm, cool, mono

    var title: String {
        switch self {
        case .system:       return L("color.systemDefaultAdaptsToLight")
        case .highContrast: return L("color.highContrast")
        case .warm:         return L("color.warm")
        case .cool:         return L("color.cool")
        case .mono:         return L("color.monochromeBlue")
        }
    }

    /// nil 表示「不写入」= 保持系统动态色
    var hexes: [AppColorKey: String]? {
        switch self {
        case .system: return nil
        case .highContrast:
            return [
                .cpuHigh: "#FF2D20", .cpuMedium: "#FFB000",
                .stateRunning: "#00D964", .stateStopped: "#FFB000",
                .stateZombie: "#8A8A8E", .pidLink: "#0A6CFF",
                .exitedText: "#FFFFFF", .exitedBackground: "#D70015",
                .chartUser: "#0066FF", .chartSystem: "#FF8A00",
                .chartMemory: "#8A2BE2",
            ]
        case .warm:
            return [
                .cpuHigh: "#D64545", .cpuMedium: "#E08A2E",
                .stateRunning: "#6E9E4A", .stateStopped: "#E08A2E",
                .stateZombie: "#9A8F86", .pidLink: "#C2703A",
                .exitedText: "#8B2E2E", .exitedBackground: "#F3C9B8C0",
                .chartUser: "#D97736", .chartSystem: "#E3A857",
                .chartMemory: "#A2698F",
            ]
        case .cool:
            return [
                .cpuHigh: "#E0457B", .cpuMedium: "#7A6BD6",
                .stateRunning: "#2FA8A0", .stateStopped: "#7A6BD6",
                .stateZombie: "#7D88A0", .pidLink: "#2E86C1",
                .exitedText: "#7A3E8F", .exitedBackground: "#C3B6E8B0",
                .chartUser: "#2E86C1", .chartSystem: "#48B0A0",
                .chartMemory: "#7A6BD6",
            ]
        case .mono:
            return [
                .cpuHigh: "#1D4ED8", .cpuMedium: "#3B82F6",
                .stateRunning: "#2563EB", .stateStopped: "#60A5FA",
                .stateZombie: "#94A3B8", .pidLink: "#1D4ED8",
                .exitedText: "#1E3A8A", .exitedBackground: "#93C5FD80",
                .chartUser: "#1D4ED8", .chartSystem: "#60A5FA",
                .chartMemory: "#93C5FD",
            ]
        }
    }
}

// MARK: - NSColor ↔ hex

extension NSColor {
    /// 转为 sRGB hex。带 alpha 时用 8 位 (#RRGGBBAA)。
    var px_hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        let a = Int(round(c.alphaComponent * 255))
        if a >= 255 {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    /// 解析 #RGB(不支持) / #RRGGBB / #RRGGBBAA，忽略前导 # 与空白。
    convenience init?(px_hex: String) {
        var s = px_hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        let allowed = Set("0123456789ABCDEF")
        guard s.count == 6 || s.count == 8,
              s.allSatisfy({ allowed.contains($0) }) else { return nil }
        func byte(_ i: Int) -> CGFloat {
            let start = s.index(s.startIndex, offsetBy: i * 2)
            let end = s.index(start, offsetBy: 2)
            return CGFloat(Int(s[start..<end], radix: 16)!) / 255.0
        }
        let alpha: CGFloat = s.count == 8 ? byte(3) : 1.0
        self.init(srgbRed: byte(0), green: byte(1), blue: byte(2),
                  alpha: alpha)
    }
}

// MARK: - 存取

final class AppColors {
    static let shared = AppColors()

    private let d = UserDefaults.standard
    private let prefix = "Vantage.pref.color."
    private let presetKey = "Vantage.pref.colorPreset"

    /// 当前预设的 rawValue，或 "custom"（逐项改过色之后）
    var currentPresetRaw: String {
        d.string(forKey: presetKey) ?? ColorPreset.system.rawValue
    }

    /// 未自定义时的系统动态色（自动适配深浅色）
    private func dynamicDefault(_ key: AppColorKey) -> NSColor {
        switch key {
        case .cpuHigh:          return .systemRed
        case .cpuMedium:        return .systemOrange
        case .stateRunning:     return .systemGreen
        case .stateStopped:     return .systemOrange
        case .stateZombie:      return .secondaryLabelColor
        case .pidLink:          return .linkColor
        case .exitedText:       return .systemRed
        case .exitedBackground: return NSColor.systemRed.withAlphaComponent(0.14)
        case .chartUser:        return .systemBlue
        case .chartSystem:      return .systemOrange
        case .chartMemory:      return .systemPurple
        }
    }

    func color(_ key: AppColorKey) -> NSColor {
        if let hex = d.string(forKey: prefix + key.rawValue),
           let c = NSColor(px_hex: hex) { return c }
        return dynamicDefault(key)
    }

    /// 界面里显示的 hex（未自定义时是动态色在当前外观下的 sRGB 近似）
    func hex(_ key: AppColorKey) -> String { color(key).px_hexString }

    func isCustomized(_ key: AppColorKey) -> Bool {
        d.string(forKey: prefix + key.rawValue) != nil
    }

    @discardableResult
    func set(_ key: AppColorKey, color: NSColor) -> Bool {
        return set(key, hex: color.px_hexString)
    }

    @discardableResult
    func set(_ key: AppColorKey, hex: String) -> Bool {
        guard NSColor(px_hex: hex) != nil else { return false }
        d.set(hex.uppercased(), forKey: prefix + key.rawValue)
        d.set("custom", forKey: presetKey)
        notify()
        return true
    }

    func reset(_ key: AppColorKey) {
        d.removeObject(forKey: prefix + key.rawValue)
        d.set("custom", forKey: presetKey)
        notify()
    }

    func resetAll() {
        for key in AppColorKey.allCases {
            d.removeObject(forKey: prefix + key.rawValue)
        }
        d.set(ColorPreset.system.rawValue, forKey: presetKey)
        notify()
    }

    func applyPreset(_ preset: ColorPreset) {
        for key in AppColorKey.allCases {
            d.removeObject(forKey: prefix + key.rawValue)
        }
        if let hexes = preset.hexes {
            for (key, hex) in hexes { d.set(hex, forKey: prefix + key.rawValue) }
        }
        d.set(preset.rawValue, forKey: presetKey)
        notify()
    }

    func notify() {
        NotificationCenter.default.post(name: .appColorsDidChange, object: self)
    }
}
