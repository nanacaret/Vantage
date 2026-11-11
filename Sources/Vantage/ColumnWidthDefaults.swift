// SPDX-License-Identifier: MIT
import Foundation

// ---------------------------------------------------------------------
// 默认列宽方案
//
// 列宽是按 identifier 持久化到 UserDefaults 的：用户拖过的宽度优先于默认值。
// 因此「把默认宽度调小」对已经存过宽度的用户不会生效。这里用一个 schema
// 版本号做一次性迁移：默认值方案变更时，清掉旧的保存值一次，之后用户
// 自己拖的宽度照常保留、不再被清。
//
// 菜单「视图 → 重置列宽为默认」也复用同一套清理逻辑，随时可手动恢复。
// ---------------------------------------------------------------------

enum ColumnWidthDefaults {
    /// 当前默认列宽方案版本；改动默认值时 +1
    static let schema = 2
    static let schemaKey = "Vantage.columnWidthSchema"

    static let processPrefix = "Vantage.processColumnWidth."
    static let detailPrefix  = "Vantage.detail."

    /// App 启动时、任何窗口/视图加载之前调用一次。
    static func migrateIfNeeded() {
        let d = UserDefaults.standard
        guard d.integer(forKey: schemaKey) != schema else { return }
        clearSavedWidths()
        d.set(schema, forKey: schemaKey)
    }

    /// 清掉所有保存的列宽，但保留 schema 版本（由调用方负责写入）。
    static func clearSavedWidths() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys {
            if key.hasPrefix(processPrefix) { d.removeObject(forKey: key) }
            // 详情表：Vantage.detail.<tab>.col<N>.width
            if key.hasPrefix(detailPrefix),
               key.contains(".col"), key.hasSuffix(".width") {
                d.removeObject(forKey: key)
            }
        }
    }

    /// 「重置列宽为默认」：清值 + 写回当前版本号 + 通知已加载的视图重排。
    static func reset() {
        let d = UserDefaults.standard
        clearSavedWidths()
        d.set(schema, forKey: schemaKey)
        NotificationCenter.default.post(name: .columnWidthsShouldReset, object: nil)
    }
}

extension Notification.Name {
    static let columnWidthsShouldReset =
        Notification.Name("com.vantage.columnWidthsShouldReset")
}
