// SPDX-License-Identifier: MIT
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 必须在任何窗口/视图 loadView 之前：默认列宽方案变更时清掉旧的
        // 持久化宽度一次，否则用户永远看不到新的默认值。
        ColumnWidthDefaults.migrateIfNeeded()
        buildMainMenu()
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChanged),
            name: .languageDidChange, object: nil)

        let wc = MainWindowController()
        AppContext.shared.mainWindow = wc

        // 关键：在 didFinishLaunching 里同步 orderFront 时，App 往往还没完成
        // 激活 / run loop 还没转起来，窗口会「创建了但没显示」（isVisible 为
        // true 却看不到）。放到主队列下一圈再显示，并先校正 frame。
        DispatchQueue.main.async {
            wc.ensureWindowVisible()
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            wc.window?.orderFrontRegardless()
            AppActivate.front()
            AppContext.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // ---------------------------------------------------------------
    // 菜单
    // ---------------------------------------------------------------

    private func buildMainMenu() {
        let main = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(item(L("menu.aboutVantage"),
                             #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        appMenu.addItem(withTitle: L("menu.preferences"), action: #selector(preferencesAction),
                        keyEquivalent: ",").target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(item(L("menu.hideVantage"), #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(item(L("menu.quitVantage"), #selector(NSApplication.terminate(_:)), "q"))
        // 系统动作交给响应链 / NSApplication；自定义「偏好设置」保留 target=self
        for mi in appMenu.items
            where mi.action != #selector(preferencesAction) { mi.target = nil }

        // 文件
        main.addItem(menu(L("menu.file"), [
            item(L("menu.refreshNow"), #selector(refreshAction), "r"),
            sep(),
            item(L("menu.openInspector"), #selector(inspectorAction), "i"),
            item(L("menu.performanceMonitor"), #selector(performanceAction), "p"),
            item(L("menu.revealInFinder"), #selector(revealAction), ""),
            item(L("menu.sampleProcess"), #selector(sampleAction), ""),
        ]))

        // 编辑：补齐 AppKit 标准编辑项。手写 NSApplication（无故事板）时
        // 系统不会自动创建这些菜单项，缺了「复制 ⌘C」= 键盘快捷键完全无效，
        // 只剩 NSTextView 右键菜单里自带的「复制」可用。
        main.addItem(menu(L("menu.edit"), [
            item(L("menu.focusSearch"), #selector(focusSearchAction), "f"),
            item(L("menu.globalSearch"), #selector(globalSearchAction), "f",
                 [.command, .shift]),
            sep(),
            responderItem(L("menu.undo"), ResponderAction.undo, "z"),
            responderItem(L("menu.redo"), ResponderAction.redo, "z",
                          [.command, .shift]),
            sep(),
            responderItem(L("menu.cut"), ResponderAction.cut, "x"),
            // 「复制」用自定义分发：选中文字走系统 copy:，没选中文字时
            // 沿响应链复制表格选中行，见 ClipboardSupport.swift。
            item(L("menu.copy"), #selector(copyAction), "c"),
            responderItem(L("menu.paste"), ResponderAction.paste, "v"),
            responderItem(L("menu.selectAll"), ResponderAction.selectAll, "a"),
            sep(),
            item(L("menu.copyPid"), #selector(copyPIDAction), ""),
            item(L("menu.copyFullCommandLine"), #selector(copyCmdAction), ""),
        ]))

        // 视图
        let intervalMenu = NSMenu()
        for (title, value) in [(L("menu.s"), 0.5), (L("menu.s2"), 1.0),
                               (L("menu.s3"), 2.0), (L("menu.s4"), 5.0)] {
            let mi = NSMenuItem(title: title,
                                action: #selector(intervalAction(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.tag = Int(value * 10)
            intervalMenu.addItem(mi)
        }
        let intervalItem = NSMenuItem(title: L("menu.refreshInterval"), action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu

        let viewItems: [NSMenuItem] = [
            item(L("menu.treeView"), #selector(treeAction), "1"),
            item(L("menu.listView"), #selector(listAction), "2"),
            sep(),
            item(L("menu.allProcesses"), #selector(filterAllAction), ""),
            item(L("menu.myProcesses"), #selector(filterMineAction), ""),
            item(L("menu.systemProcesses"), #selector(filterSystemAction), ""),
            item(L("menu.guiAppsOnly"), #selector(filterGUIAction), ""),
            sep(),
            intervalItem,
            sep(),
            item(L("menu.resetColumnWidthsToDefault"), #selector(resetColumnWidthsAction), ""),
        ]
        main.addItem(menu(L("menu.view"), viewItems))

        // 进程
        main.addItem(menu(L("menu.process"), [
            item(L("menu.locateProcessByWindow"), #selector(locateByWindowAction), "l",
                 [.option, .command]),
            item(L("menu.windowList"), #selector(windowListAction), ""),
            NSMenuItem.separator(),
            item(L("menu.quitProcessSigterm"), #selector(terminateAction), "k",
                 [.option, .command]),
            item(L("menu.forceQuitSigkill"), #selector(forceTerminateAction), "k",
                 [.option, .command, .shift]),
            item(L("menu.pauseResume"), #selector(suspendAction), "p", [.option, .command]),
            NSMenuItem.separator(),
            signalMenuItem(),
        ]))

        // 窗口
        let windowItems: [NSMenuItem] = [
            item(L("menu.mainWindow"), #selector(showMainWindowAction), "0"),
            item(L("menu.performanceMonitor2"), #selector(performanceAction), ""),
            item(L("menu.windowList2"), #selector(windowListAction), ""),
            item(L("menu.globalSearch2"), #selector(globalSearchAction), ""),
            item(L("menu.deviceBrowser2"), #selector(deviceBrowserAction), "b",
                 [.command, .option]),
            item(L("menu.extensionsBrowser2"), #selector(extensionsBrowserAction),
                 "e", [.command, .option]),
            NSMenuItem.separator(),
            item(L("menu.minimized"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("menu.close"), #selector(NSWindow.performClose(_:)), "w"),
        ]
        // NSApplication / NSWindow 的标准动作交给响应链，自定义动作保留 target
        for mi in windowItems {
            if mi.action == #selector(NSWindow.performMiniaturize(_:)) ||
               mi.action == #selector(NSWindow.performClose(_:)) {
                mi.target = nil
            }
        }
        main.addItem(menu(L("menu.window"), windowItems))

        NSApp.mainMenu = main
    }

    /// 主菜单里的「发送信号 ▸」。子菜单内容每次展开时按偏好重建。
    private func signalMenuItem() -> NSMenuItem {
        let mi = NSMenuItem(title: L("menu.sendSignal"), action: nil, keyEquivalent: "")
        let sub = NSMenu(title: L("menu.sendSignal2"))
        sub.delegate = SignalMenuUpdater.shared
        mi.submenu = sub
        return mi
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        mi.keyEquivalentModifierMask = mods
        return mi
    }

    /// target = nil → AppKit 沿响应链找第一响应者（NSTextView / field editor /
    /// NSTableView）。action 用 `ResponderAction` 里的 NSSelectorFromString
    /// 常量：运行时构造、无编译警告，也不依赖不同 SDK 里标准动作声明在
    /// NSResponder / NSText / NSStandardKeyBindingResponding 的哪个位置。
    private func responderItem(_ title: String, _ action: Selector,
                               _ key: String,
                               _ mods: NSEvent.ModifierFlags = .command)
        -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = nil
        mi.keyEquivalentModifierMask = mods
        return mi
    }

    @objc private func copyAction(_ sender: Any?) {
        Clipboard.copy(sender)
    }

    private func sep() -> NSMenuItem { NSMenuItem.separator() }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let mi = NSMenuItem()
        let m = NSMenu(title: title)
        for i in items { m.addItem(i) }
        mi.submenu = m
        return mi
    }

    // ---------------------------------------------------------------
    // 菜单动作
    // ---------------------------------------------------------------

    @objc private func refreshAction(_ sender: Any?) {
        AppContext.shared.store.refresh()
        if Preferences.shared.refreshInvalidatesDetail {
            NotificationCenter.default.post(name: .procDetailForceRefresh, object: nil)
        }
    }

    @objc private func preferencesAction(_ sender: Any?) {
        PreferencesWindowController.shared.showWindow(nil)
    }

    @objc private func showMainWindowAction(_ sender: Any?) {
        AppContext.shared.revealMainWindow()
    }

    @objc private func windowListAction(_ sender: Any?) {
        WindowListWindowController.shared.showWindow(nil)
    }

    /// SystemInformer 风格：直接进入准星选取，隐藏本 App 的窗口以免遮挡
    @objc private func locateByWindowAction(_ sender: Any?) {
        var hide: [NSWindow] = []
        if let w = AppContext.shared.mainWindow?.window { hide.append(w) }
        if let w = WindowListWindowController.shared.window, w.isVisible {
            hide.append(w)
        }
        WindowPicker.shared.begin(
            hiding: hide,
            onPick: { pid in
                AppContext.shared.locateProcess(pid)
            },
            onCancel: {
                AppContext.shared.revealMainWindow()
            })
    }

    @objc private func inspectorAction(_ sender: Any?) {
        guard let pid = AppContext.shared.selectedPID else { return }
        AppContext.shared.showInspector(for: pid)
    }

    @objc private func performanceAction(_ sender: Any?) {
        PerformanceWindowController.shared.showWindow(nil)
    }

    @objc private func revealAction(_ sender: Any?) {
        AppContext.shared.revealInFinder()
    }

    @objc private func sampleAction(_ sender: Any?) {
        AppContext.shared.sampleProcess()
    }

    @objc private func focusSearchAction(_ sender: Any?) {
        AppContext.shared.mainWindow?.focusSearch()
    }

    /// ⌘⇧F：独立全局搜索窗口。打开时拍进程快照并对所有 PID 取样，
    /// 之后只在这份固定快照里过滤，不随主表刷新漂移。
    @objc private func globalSearchAction(_ sender: Any?) {
        GlobalSearchWindowController.shared.showWindow(nil)
    }

    /// ⌘⌥B：IORegistry 设备树（含 driver bundle / client PID）
    @objc private func deviceBrowserAction(_ sender: Any?) {
        DeviceBrowserWindowController.shared.showWindow(nil)
    }

    /// ⌘⌥E：系统所有 extension / driver bundle
    @objc private func extensionsBrowserAction(_ sender: Any?) {
        ExtensionsWindowController.shared.showWindow(nil)
    }

    @objc private func copyPIDAction(_ sender: Any?) {
        AppContext.shared.copyPID()
    }

    @objc private func copyCmdAction(_ sender: Any?) {
        AppContext.shared.copyCommandLine()
    }

    /// 语言切换：L() 是运行时读取，新建/刷新的文字立刻变；这里补齐
    /// 已存在的静态控件（菜单重建、窗口标题、按钮/标签/列头就地转换），
    /// 再让详情页按新语言重采一次（C 层文本在 parse() 时翻译）。
    @objc private func languageChanged(_ note: Notification) {
        buildMainMenu()
        for w in NSApp.windows {
            w.title = L10n.convertDisplayed(w.title)
            if let v = w.contentView { L10n.relocalize(v) }
        }
        NotificationCenter.default.post(name: .procDetailForceRefresh, object: nil)
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }

    /// 「视图 → 重置列宽为默认」：清掉所有保存宽度，通知已加载的表格重排。
    /// 之后用户再拖的宽度照常持久化，不会被自动清掉。
    @objc private func resetColumnWidthsAction(_ sender: Any?) {
        ColumnWidthDefaults.reset()
    }

    @objc private func treeAction(_ sender: Any?) {
        AppContext.shared.store.treeMode = true
        AppContext.shared.mainWindow?.syncToolbar()
    }

    @objc private func listAction(_ sender: Any?) {
        AppContext.shared.store.treeMode = false
        AppContext.shared.mainWindow?.syncToolbar()
    }

    @objc private func filterAllAction(_ sender: Any?) {
        AppContext.shared.store.filter = .all
        AppContext.shared.mainWindow?.syncToolbar()
    }

    @objc private func filterMineAction(_ sender: Any?) {
        AppContext.shared.store.filter = .mine
        AppContext.shared.mainWindow?.syncToolbar()
    }

    @objc private func filterSystemAction(_ sender: Any?) {
        AppContext.shared.store.filter = .system
        AppContext.shared.mainWindow?.syncToolbar()
    }

    @objc private func filterGUIAction(_ sender: Any?) {
        AppContext.shared.store.filter = .gui
        AppContext.shared.mainWindow?.syncToolbar()
    }

    @objc private func intervalAction(_ sender: NSMenuItem) {
        let v = Double(sender.tag) / 10.0
        AppContext.shared.store.refreshInterval = max(0.5, v)
    }

    @objc private func terminateAction(_ sender: Any?) {
        AppContext.shared.terminate(force: false)
    }

    @objc private func forceTerminateAction(_ sender: Any?) {
        AppContext.shared.terminate(force: true)
    }

    @objc private func suspendAction(_ sender: Any?) {
        AppContext.shared.toggleSuspend()
    }
}
