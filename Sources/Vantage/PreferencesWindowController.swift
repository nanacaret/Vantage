// SPDX-License-Identifier: MIT
import AppKit

// ---------------------------------------------------------------------
// 偏好设置窗口（⌘,）
//
// 三个页签：
//  · 通用：采集上限、缓存、刷新、排序与行为（滚动表单）
//  · 样式：已退出进程高亮 + 全部可定制配色
//  · 信号：菜单信号勾选 + 发送前确认策略
//
// 页签切换用 NSSegmentedControl + 三个常驻 NSScrollView（改 isHidden），
// 不碰 NSTabView / NSTabViewItem：没有 delegate、没有 item 插入、没有
// index 越界。注意：偏好窗口曾出现的无消息 SIGTRAP **不是 Tab 造成的**，
// 而是本文件 reloadValues() 里字典字面量写了重复 key（Swift 运行时检查
// 直接 brk）。所以 nums / checks 一律用元组数组而非 [Tag: X] 字典字面量。
// ---------------------------------------------------------------------

final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {

    static let shared = PreferencesWindowController()

    /// 窗口下限。两段式行布局在 560pt 宽度下说明文字仍有 320pt 以上，
    /// 再窄就只能靠频繁换行 + 竖向滚动。
    private static let minWindowSize = NSSize(width: 560, height: 460)

    private enum Tag: Int {
        // 数值
        case maxRegions = 100, pipeCacheMs, argvMaxKB, fdMaxMB, smcMaxKeys
        case treeMaxDepth, historyPoints, dynamicTTL, ttyTTL, staticTTL
        case sampleSeconds
        case exitedKeepRefreshes = 111
        case globalSearchMaxRows = 112
        case ioregMaxNodes = 113
        // 弹出菜单
        case refreshInterval = 200, perfIntervalMs, defaultFilter, defaultSortKey
        case colorPreset = 204
        // 开关
        case defaultTreeMode = 300, defaultAscending, lazyDetailLoading
        case sortAutoFlat, sortCycleToTree, showSortIndicator
        case startPerfSampler, confirmBeforeSignal, refreshInvalidatesDetail
        case highlightExited = 309
        case alwaysConfirmDestructive = 310
        case showRawNameWithBundle = 311
        case useLocalizedAppName = 312
        case showDetailHints = 313
        case searchUseRegex = 314
        case globalSearchHeavyPages = 315
        case scanAppExtensions = 316
        case showArgv0WhenDifferent = 317
        case touchIDAuth = 318
        // 弹出菜单段 200–204 已占满，名称格式 / 语言另起一段
        case rawNameStyle = 205
        case language = 206
        case tabsLayout = 207, classicPerRow
    }

    /// 样式页控件的 tag 段，避开上面的 Tag 段；信号页 checkbox 用信号编号 1–31
    private static let colorWellTagBase = 1000
    private static let hexFieldTagBase = 2000
    private static let colorResetTagBase = 3000
    private static let signalCheckTagBase = 4000

    /// 设置分页。原来「通用」一页塞了 9 组、二十多项，滚动条长得离谱；
    /// 按用途拆开后每组都能在一屏内看完。
    enum Pane: Int, CaseIterable {
        case general, interface, data, search, privilege, appearance, signals

        var titleKey: String {
            switch self {
            case .general:    return "pref.nav.general"
            case .interface:  return "pref.nav.interface"
            case .data:       return "pref.nav.data"
            case .search:     return "pref.nav.search"
            case .privilege:  return "pref.nav.privilege"
            case .appearance: return "pref.nav.appearance"
            case .signals:    return "pref.nav.signals"
            }
        }
    }

    private let footer = NSStackView()
    private var currentPane = 0
    private var paneStacks: [NSStackView] = []
    private var paneScrolls: [NSScrollView] = []
    private let paneContainer = NSView()

    /// 页签条与检查器共用（自动折行 / 固定每行 / 左侧竖排）
    private let tabBar = TabStripView()
    private var barHorizontal: [NSLayoutConstraint] = []
    private var barVertical: [NSLayoutConstraint] = []
    private var barWidth: NSLayoutConstraint?
    private var rootMinWidth: NSLayoutConstraint?
    private var appliedMode: TabStripView.Mode?

    /// helper 当前往哪个 stack 里加行。用普通 Optional 而非 IUO ——
    /// buildUI 里若任何一步提前返回，IUO 的隐式解包会直接 SIGTRAP 且
    /// 不打印任何消息，正是这类「打开设置页立刻崩溃」最难查的形态。
    private var activeStack: NSStackView?

    private var numberFields: [Int: NSTextField] = [:]
    private var checkboxes: [Int: NSButton] = [:]
    private var popups: [Int: NSPopUpButton] = [:]
    private var colorWells: [Int: NSColorWell] = [:]
    private var hexFields: [Int: NSTextField] = [:]
    private var signalChecks: [Int32: NSButton] = [:]
    private let signalCountLabel = UI.label("", size: 10,
                                            color: .secondaryLabelColor)
    private let previewLabel = UI.wrappingLabel("", size: 11)
    /// 通用页「进程名称显示」的实时预览行
    private let namePreviewLabel = UI.wrappingLabel("", size: 11)
    private let statusLabel = UI.label(L("pref.appliedImmediatelyNoRestartNeeded"), size: 10,
                                       color: .secondaryLabelColor)
    /// 「提权与安全」段的状态行（助手是否就绪 / 硬件是否支持）
    private let touchIDStatusLabel = UI.wrappingLabel("", size: 10,
                                                      color: .secondaryLabelColor)
    /// 已开启但助手缺失 / 未运行时出现：重新安装（不动偏好本身）
    private let touchIDRepairButton = NSButton(frame: .zero)
    private var l10nObserver: NSObjectProtocol?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("pref.preferences")
        w.minSize = Self.minWindowSize
        // AppKit 会在首次布局时把窗口收成 contentView 的 fittingSize；
        // minSize 只管用户拖拽，contentMinSize 才能挡住这次自动收缩。
        w.contentMinSize = Self.minWindowSize
        // 偏好窗口不参与 macOS「重新打开窗口」的状态恢复：恢复是异步的，
        // 会在 showWindow 之后把窗口覆盖成某个旧版本存下的窄 frame，
        // 让刚 clamp 过的宽度又缩回去（且每次启动都复现）。
        w.isRestorable = false
        w.center()
        // 与主窗口一致：FrameAutosaveName 在当前 SDK 是 String 别名，
        // 直接传字符串，不做 NSWindow.FrameAutosaveName(...) 类型构造。
        // V2：旧的一行式布局可能把窗口存成 412pt 宽（低于 minSize），
        // 换名让那份额外狭窄的 frame 失效，首次打开回到 660×760 默认值。
        w.setFrameAutosaveName("VantagePreferencesV2")
        super.init(window: w)
        buildUI()
        // 用 block observer 而非 target/selector：relocalizeSelf() 是无参方法，
        // NotificationCenter 的 selector 形式要求带一个 Notification 参数，
        // 用零参 selector 会在通知派发时变成无法识别的消息。
        l10nObserver = NotificationCenter.default.addObserver(
            forName: .languageDidChange, object: nil, queue: .main) {
            [weak self] _ in self?.relocalizeSelf()
        }
    }

    // 返回 nil 而非 fatalError：万一 AppKit 走 nib 解档路径也只是初始化失败，
    // 不会触发无消息的 SIGTRAP（本窗口始终由 init() 手动创建）。
    required init?(coder: NSCoder) { return nil }

    deinit {
        if let o = l10nObserver { NotificationCenter.default.removeObserver(o) }
    }

    override func showWindow(_ sender: Any?) {
        reloadValues()
        // 静态控件（section 标题、hint、按钮名、popup 选项、窗口标题）在
        // buildUI 时生成一次；每次打开按当前语言就地转换，重开即生效。
        relocalizeSelf()
        rebuildLanguagePopup()
        super.showWindow(sender)
        // 放在 showWindow 之后：frame autosave 是在首次 orderFront 时才恢复的，
        // 之前 clamp 会被恢复出来的旧尺寸覆盖。
        clampToMinSize()
        window?.makeKeyAndOrderFront(nil)
        // frame autosave 的恢复是异步的（在首次 orderFront 之后才落地会
        // 把刚 clamp 过的宽度覆盖回去）。再补一次，确保「左侧竖排」的
        // 760pt 下限不被旧 frame 顶掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.clampToMinSize()
        }
        AppActivate.front()
    }

    /// setFrameAutosaveName 会恢复上次的 frame；旧版本可能存过比 minSize
    /// 还窄的尺寸（当时一行式布局横向溢出，用户把窗口拉得很窄）。恢复后
    /// 再套一次下限，避免每次打开都是「一列文字 + 大量竖向滚动」。
    /// 左侧竖排时页签条吃掉约 120pt，[标题 + 控件] 两列在 560pt 下会把
    /// 说明文字压成每行十几个字、复选框标题还会被截尾。所以该模式下把
    /// 窗口下限抬到 760pt（切回横向再降回来）。
    private var effectiveMinSize: NSSize {
        let wide = Preferences.shared.tabsStyle == .left
        return NSSize(width: wide ? 760 : Self.minWindowSize.width,
                      height: Self.minWindowSize.height)
    }

    private func clampToMinSize() {
        guard let w = window else { return }
        let minSize = effectiveMinSize
        // contentViewController 赋值等路径可能改写 window.minSize，这里补回。
        rootMinWidth?.constant = minSize.width
        w.minSize = minSize
        w.contentMinSize = minSize
        var f = w.frame
        guard f.width < minSize.width || f.height < minSize.height else { return }
        f.size.width = max(f.width, minSize.width)
        f.size.height = max(f.height, minSize.height)
        w.setFrame(f, display: false)
    }

    /// 语言切换后把本窗口已显示的中文 key / 英文译文转成当前语言。
    private func relocalizeSelf() {
        guard let w = window else { return }
        w.title = L10n.convertDisplayed(w.title)
        if let v = w.contentView { L10n.relocalize(v) }
        // 名称预览是动态拼接的，重新生成一次
        syncNamePreview()
        // Touch ID 状态行同样是动态文案
        refreshTouchIDStatus()
        // 页签标题也按新语言重建（宽度会变，条形要重排）
        applyTabStyle(force: true)
    }

    /// 语言下拉按枚举重建一次。
    ///
    /// 旧实现只靠 convertDisplayed 就地换标题，而 NSPopUpButton 继承自
    /// NSButton，relocalize 里给 popup 设 .title 等于「追加一个菜单项」，
    /// 于是每切一次语言就多出几条「简体中文」，选中它们还会映射到
    /// 错误的 rawValue（index 越界 → fallback 到 .system/English）。
    private func rebuildLanguagePopup() {
        guard let p = popups[Tag.language.rawValue] else { return }
        let sel = L10n.language.rawValue
        p.removeAllItems()
        p.addItems(withTitles: L10n.Language.allCases.map { $0.title })
        p.selectItem(at: min(max(sel, 0), p.numberOfItems - 1))
    }

    // -----------------------------------------------------------------
    // 布局
    // -----------------------------------------------------------------

    private func makeStack(_ s: NSStackView) {
        s.orientation = .vertical
        s.spacing = 8
        s.distribution = .fill
        s.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        s.translatesAutoresizingMaskIntoConstraints = false
    }

    /// 把 stack 包进一个 NSScrollView。documentView 只给「顶部 + 左边 + 宽度」，
    /// 高度由 NSStackView 的 intrinsicContentSize 决定；不要再加 trailing。
    private func makeScroll(document: NSStackView) -> NSScrollView {
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // 翻转后内容始终从顶部开始：某一页比窗口矮时（例如「搜索」只有
        // 四项）不会整页掉到底部。
        scroll.contentView = FlippedClipView()
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor,
                                              constant: 12),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor,
                                          constant: 8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor,
                                            constant: -24),
        ])
        return scroll
    }

    private func buildUI() {
        guard let window = self.window else { return }

        paneStacks = Pane.allCases.map { _ in
            let s = NSStackView()
            makeStack(s)
            return s
        }
        buildPanes()

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        paneScrolls = paneStacks.map { makeScroll(document: $0) }
        for v in paneScrolls {
            v.translatesAutoresizingMaskIntoConstraints = false
            paneContainer.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
                v.topAnchor.constraint(equalTo: paneContainer.topAnchor),
                v.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
            ])
        }

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] index in self?.applyTab(index) }

        // ---- 底部（所有页共用） ----
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.distribution = .fill
        let resetBtn = UI.button(L("pref.restoreDefaults"), target: self,
                                 action: #selector(resetClicked))
        let doneBtn = UI.button(L("pref.done"), target: self,
                                action: #selector(doneClicked))
        doneBtn.keyEquivalent = "\r"
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addView(statusLabel, in: .leading)
        footer.addView(resetBtn, in: .trailing)
        footer.addView(doneBtn, in: .trailing)
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 8, right: 14)

        // 直接用 contentView，不用 contentViewController：后者会按 root.view
        // 的 fittingSize 反过来把窗口收窄（实测 660 → 412），而偏好行的
        // 说明文字需要窗口宽度才能排成两行。
        // 显式给一个非零 frame：contentView 为 zero frame 时，首次布局会
        // 把窗口收缩到子视图的最小 fittingSize。
        let rootView = NSView(frame: window.contentLayoutRect)
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView
        // 首次布局时 AppKit 会把窗口收到内容的最小 fittingSize（412pt）。
        // 在 contentView 上加一条 required 下限，Auto Layout 就不会允许
        // 窗口比 560pt 更窄。
        // 直接改这条约束的 constant（而不是只改 window.minSize）：首次布局
        // 时 AppKit 会把窗口收成 contentView 的 fittingSize，光设
        // contentMinSize 挡不住；把内容的最小宽度本身抬上去才稳。
        rootMinWidth = rootView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minWindowSize.width)
        rootMinWidth?.isActive = true
        rootView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 420).isActive = true
        rootView.addSubview(tabBar)
        rootView.addSubview(paneContainer)
        rootView.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 38),
        ])

        applyTabStyle(force: true)
        applyTab(0)
        reloadValues()
        // 工具栏 / 全局搜索窗口切换「.*」时，本窗口的 checkbox 也要跟上
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchModeChanged(_:)),
            name: .searchModeDidChange, object: nil)
        // 在本窗口里改「页签排布」要立刻换布局（也要让检查器跟着变）
        NotificationCenter.default.addObserver(
            forName: .preferencesDidChange, object: nil, queue: .main) {
                [weak self] _ in self?.applyTabStyle()
        }
    }

    // -----------------------------------------------------------------
    // 分页内容
    // -----------------------------------------------------------------

    private func buildPanes() {
        activeStack = paneStacks[Pane.general.rawValue]
        buildGeneralTab()
        activeStack = paneStacks[Pane.interface.rawValue]
        buildInterfaceTab()
        activeStack = paneStacks[Pane.data.rawValue]
        buildDataTab()
        activeStack = paneStacks[Pane.search.rawValue]
        buildSearchTab()
        activeStack = paneStacks[Pane.privilege.rawValue]
        buildPrivilegeTab()
        activeStack = paneStacks[Pane.appearance.rawValue]
        buildStyleTab()
        activeStack = paneStacks[Pane.signals.rawValue]
        buildSignalTab()
        activeStack = nil
    }

    /// 通用：刷新与默认视图 + 排序与行为
    private func buildGeneralTab() {
        section(L("pref.refreshDefaultView"), L("pref.appliedToTheMainWindow"))
        popup(.refreshInterval, L("pref.processListRefresh"), [L("pref.s5"), L("pref.s6"), L("pref.s7"), L("pref.s8")],
              hint: L("pref.periodicRefreshIntervalOfThe"))
        popup(.perfIntervalMs, L("pref.samplingInterval"),
              [L("pref.s9"), L("pref.s10"), L("pref.s11"), L("pref.s12")],
              hint: L("pref.intervalOfTheCLayer"))
        popup(.defaultFilter, L("pref.defaultFilter"), ProcessFilter.allCases.map { $0.title },
              hint: L("pref.processFilterAppliedAtLaunch"))
        popup(.defaultSortKey, L("pref.defaultInTreeSort"),
              ["% CPU", L("pref.processName"), "PID", L("pref.memory"), L("pref.threads"), "FD", L("pref.startTime")],
              hint: L("pref.sortKeyForRootNodes"))
        check(.defaultTreeMode, L("pref.useTreeViewAtLaunch"),
              hint: L("pref.offStartsInFlatList"))
        check(.defaultAscending, L("pref.defaultAscending"), hint: L("pref.initialDirectionForTheDefault"))

        section(L("pref.sortingBehavior"), L("pref.threeStateHeaderCycleClick"))
        check(.sortAutoFlat, L("pref.switchToFlatListWhen"),
              hint: L("pref.inTreeModeSortingOnly"))
        check(.sortCycleToTree, L("pref.thirdClickOnAColumn"),
              hint: L("pref.offGivesTheUsualTwo"))
        check(.showSortIndicator, L("pref.showSortDirectionTriangleIn"),
              hint: L("pref.customDrawnTriangleNoSystem"))
        check(.lazyDetailLoading, L("pref.lazyPerTabDetailLoading"),
              hint: L("pref.offRestoresTheOldCollect"))
        check(.startPerfSampler, L("pref.startPerformanceSamplingAtLaunch"),
              hint: L("pref.offStartsSamplingOnlyWhen"))
        check(.refreshInvalidatesDetail, L("pref.rAlsoInvalidatesDetailCache"),
              hint: L("pref.offMakesRRefreshOnly"))
    }

    /// 界面：语言 / 提示行 / 页签排布 + 进程名称显示
    private func buildInterfaceTab() {
        section(L("pref.interface"), L("pref.uiLanguageForMenusWindow"))
        check(.showDetailHints, L("pref.showHintRowsInDetail"),
              hint: L("pref.hideExplanatoryHintRowsAppended"))
        popup(.language, L("pref.language"),
              L10n.Language.allCases.map { $0.title },
              hint: L("pref.followSystemSimplifiedChineseEnglish"))
        // 两种布局：左侧竖排（默认）/ 经典（横向多行）。原来的「每行几个」
        // 只对横向有意义，拆成独立一行、只在经典布局下可改。
        popup(.tabsLayout, L("pref.tabsLayout"),
              [L("pref.tabsLayoutLeft"), L("pref.tabsLayoutClassic")],
              hint: L("pref.tabsLayoutHint"))
        popup(.classicPerRow, L("pref.classicPerRow"),
              [L("pref.tabsLayoutAuto")] + (2...15).map { "\($0)" },
              hint: L("pref.classicPerRowHint"))

        section(L("pref.processNameDisplay"),
                L("pref.helpersXpcServicesAndRenderers"))
        check(.showRawNameWithBundle, L("pref.showRawProcessNameAlongside"),
              hint: L("pref.onlyAppendedForProcessesWith"))
        check(.showArgv0WhenDifferent, L("pref.showArgv0WhenDifferent"),
              hint: L("pref.argv0Hint"))
        check(.useLocalizedAppName, L("pref.useTheBundleSLocalized"),
              hint: L("pref.readsCFBundleDisplayNameCFBundleNameFromIn"))
        popup(.rawNameStyle, L("pref.rawNameFormat"),
              RawNameStyle.allCases.map { $0.title },
              hint: L("pref.onlyAffectsTheAppendedBracket"))

        namePreviewLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        namePreviewLabel.alignment = .left
        namePreviewLabel.drawsBackground = true
        namePreviewLabel.backgroundColor = .controlBackgroundColor
        namePreviewLabel.isBezeled = false
        namePreviewLabel.isEditable = false
        namePreviewLabel.translatesAutoresizingMaskIntoConstraints = false
        namePreviewLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        addFullWidth(namePreviewLabel)
        addFullWidth(makeHintRow(L("pref.previewHowTheNameColumn")))
        syncNamePreview()
    }

    /// 数据与缓存：采集上限 + 详情缓存 + 设备树 / 扩展
    private func buildDataTab() {
        section(L("pref.collectionLimits"), L("pref.takesEffectOnTheNext"))
        number(.maxRegions,   L("pref.vmRegionCap"), unit: L("pref.items"),
               hint: L("pref.maxVmRegionsEnumeratedPer"))
        number(.pipeCacheMs,  L("pref.pipeIndexCache"), unit: "ms",
               hint: L("pref.howLongTheSystemWide"))
        number(.argvMaxKB,    L("pref.commandLineBuffer"), unit: "KiB",
               hint: L("pref.upperBoundForTheKern"))
        number(.fdMaxMB,      L("pref.fdListBuffer"), unit: "MiB",
               hint: L("pref.upperBoundForTheProc"))
        number(.smcMaxKeys,   L("pref.smcKeyCap"), unit: L("pref.keys"),
               hint: L("pref.upperBoundForSmcKey"))

        section(L("pref.detailsCache"), L("pref.withPerTabLazyLoading"))
        number(.treeMaxDepth, L("pref.maxProcessTreeDepth"), unit: L("pref.layer"),
               hint: L("pref.recursionGuardForCyclicPpid"))
        number(.historyPoints, L("pref.historyPoints"), unit: L("pref.pts"),
               hint: L("pref.numberOfSamplesRetainedBy"))
        number(.dynamicTTL,   L("pref.dynamicTabCache"), unit: L("pref.s"),
               hint: L("pref.openFilesNetworkFileMonitoring"))
        number(.ttyTTL,       L("pref.ttyTabCache"), unit: L("pref.s2"), hint: L("pref.controllingTerminalAndSessionInfo"))
        number(.staticTTL,    L("pref.staticTabCache"), unit: L("pref.s3"),
               hint: L("pref.environmentImagesMappingsSigningMach"))
        number(.sampleSeconds, L("pref.sampleDuration"), unit: L("pref.s4"),
               hint: L("pref.durationOfAUsrBin"))

        section(L("pref.devicesExtensions"), L("pref.devicesExtensionsHint"))
        number(.ioregMaxNodes, L("pref.ioregMaxNodes"),
               unit: L("pref.items"), hint: L("pref.ioregMaxNodesHint"))
        check(.scanAppExtensions, L("pref.scanAppExtensions"),
              hint: L("pref.scanAppExtensionsHint"))
    }

    /// 搜索
    private func buildSearchTab() {
        section(L("pref.search"), L("pref.searchHint"))
        check(.searchUseRegex, L("pref.regexSearchMode"),
              hint: L("pref.regexSearchModeHint"))
        check(.globalSearchHeavyPages, L("pref.globalSearchHeavyPages"),
              hint: L("pref.globalSearchHeavyPagesHint"))
        number(.globalSearchMaxRows, L("pref.globalSearchMaxRows"),
               unit: L("pref.rows"), hint: L("pref.globalSearchMaxRowsHint"))
    }

    /// 提权与安全
    private func buildPrivilegeTab() {
        section(L("pref.privilege"), L("pref.privilegeHint"))
        check(.touchIDAuth, L("pref.touchIDAuth"), hint: L("pref.touchIDAuthHint"))
        // 这一项不是纯偏好：勾选会安装 root LaunchDaemon，去掉会卸载，
        // 所以接管动作、不走通用的 toggleChanged。
        if let cb = checkboxes[Tag.touchIDAuth.rawValue] {
            cb.target = self
            cb.action = #selector(touchIDToggled(_:))
        }
        touchIDStatusLabel.font = NSFont.systemFont(ofSize: 10)
        touchIDStatusLabel.textColor = .secondaryLabelColor
        touchIDStatusLabel.lineBreakMode = .byWordWrapping
        // 与其它行的说明文字一样，从控件列开始（而不是贴着窗口左边）
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Metric.labelWidth).isActive = true
        touchIDRepairButton.title = L("priv.touchIDRepair")
        touchIDRepairButton.bezelStyle = .rounded
        touchIDRepairButton.controlSize = .small
        touchIDRepairButton.font = NSFont.systemFont(ofSize: 10)
        touchIDRepairButton.target = self
        touchIDRepairButton.action = #selector(repairTouchIDClicked(_:))
        touchIDRepairButton.setContentHuggingPriority(.defaultHigh,
                                                      for: .horizontal)
        let statusRow = NSStackView(views: [spacer, touchIDStatusLabel,
                                            touchIDRepairButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = Metric.gap
        statusRow.alignment = .top
        addFullWidth(statusRow)
        refreshTouchIDStatus()
    }

    // -----------------------------------------------------------------
    // 页签条
    // -----------------------------------------------------------------

    /// 「每行几个」只对经典（横向）布局有意义；左侧竖排时置灰，
    /// 免得用户改了一个当前不生效的值还以为没反应。
    private func syncTabLayoutControls() {
        let classic = Preferences.shared.tabsStyle != .left
        popups[Tag.classicPerRow.rawValue]?.isEnabled = classic
    }

    /// 横向折行 / 左侧竖排两套约束之间切换（与检查器同一实现思路）。
    private func applyTabStyle(force: Bool = false) {
        guard let root = window?.contentView else { return }
        let mode = Preferences.shared.tabStripMode
        if !force, let m = appliedMode, m == mode { return }
        appliedMode = mode

        NSLayoutConstraint.deactivate(barHorizontal)
        NSLayoutConstraint.deactivate(barVertical)
        barWidth?.isActive = false
        barWidth = nil

        tabBar.configure(titles: Pane.allCases.map { L($0.titleKey) }, mode: mode)
        tabBar.select(currentPane)

        // 窗口下限跟着模式走；已经比下限窄就当场长到下限
        if let w = window {
            let minSize = effectiveMinSize
            rootMinWidth?.constant = minSize.width
            w.minSize = minSize
            w.contentMinSize = minSize
            if w.frame.width < minSize.width {
                var f = w.frame
                f.size.width = minSize.width
                w.setFrame(f, display: true)
            }
        }

        switch mode {
        case .vertical:
            let w = tabBar.widthAnchor.constraint(equalToConstant: tabBar.columnWidth)
            barWidth = w
            barVertical = [
                tabBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
                tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                constant: 8),
                tabBar.bottomAnchor.constraint(equalTo: footer.topAnchor,
                                               constant: -4),
                w,
                paneContainer.leadingAnchor.constraint(equalTo: tabBar.trailingAnchor,
                                                       constant: 8),
                paneContainer.topAnchor.constraint(equalTo: root.topAnchor,
                                                  constant: 10),
                paneContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                paneContainer.bottomAnchor.constraint(equalTo: footer.topAnchor),
            ]
            NSLayoutConstraint.activate(barVertical)

        case .horizontal:
            barHorizontal = [
                tabBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
                tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                constant: 12),
                tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                 constant: -12),
                paneContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor,
                                                  constant: 10),
                paneContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                paneContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                paneContainer.bottomAnchor.constraint(equalTo: footer.topAnchor),
            ]
            NSLayoutConstraint.activate(barHorizontal)
        }
    }

    /// 切页：所有 pane 常驻，只改 isHidden —— 没有 NSTabView、没有 delegate、
    /// 没有 index 越界（本项目在 macOS 26 上踩过 NSTabView 的内部断言）。
    private func applyTab(_ index: Int) {
        guard index >= 0, index < paneScrolls.count else { return }
        currentPane = index
        for (i, v) in paneScrolls.enumerated() { v.isHidden = (i != index) }
        tabBar.select(index)
    }

    @objc private func searchModeChanged(_ n: Notification) {
        checkboxes[Tag.searchUseRegex.rawValue]?.state =
            Preferences.shared.searchUseRegex ? .on : .off
    }

    // -----------------------------------------------------------------
    // 样式页
    // -----------------------------------------------------------------

    private func buildStyleTab() {
        section(L("pref.exitedProcesses"),
                L("pref.afterAProcessLeavesThe"))
        check(.highlightExited, L("pref.highlightExitedProcesses"),
              hint: L("pref.whenOffAProcessDisappears"))
        number(.exitedKeepRefreshes, L("pref.keepRefreshCount"), unit: L("pref.times"),
               hint: L("pref.defaultAtASRefresh"))

        section(L("pref.colors"),
                L("pref.useTheSystemColorPicker"))
        let presetTitles = ColorPreset.allCases.map { $0.title } + [L("pref.customEditedIndividually")]
        popup(.colorPreset, L("pref.colorPreset"), presetTitles,
              hint: L("pref.choosingAppliesAWholePalette"))

        // 分组小标题（纯文字行）；数组显式标注类型，避免 leading-dot 推断歧义
        groupLabel(L("pref.statusMetrics"))
        let statusKeys: [AppColorKey] = [.cpuHigh, .cpuMedium,
                                        .stateRunning, .stateStopped,
                                        .stateZombie, .pidLink]
        for key in statusKeys { colorRow(key) }
        groupLabel(L("pref.exitedProcessHighlight"))
        colorRow(.exitedText)
        colorRow(.exitedBackground)
        groupLabel(L("pref.systemCurve"))
        let chartKeys: [AppColorKey] = [.chartUser, .chartSystem, .chartMemory]
        for key in chartKeys { colorRow(key) }

        // 预览条
        previewLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        previewLabel.alignment = .left
        previewLabel.drawsBackground = true
        previewLabel.isBezeled = false
        previewLabel.isEditable = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        addFullWidth(previewLabel)
        addFullWidth(makeHintRow(L("pref.previewHowAnExitedRow")))

        let resetColors = UI.button(L("pref.resetColorsToDefault"), target: self,
                                    action: #selector(resetColorsClicked))
        resetColors.translatesAutoresizingMaskIntoConstraints = false
        resetColors.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addView(resetColors, in: .leading)
        row.addView(UI.label(L("pref.clearAllCustomColorsAnd"), size: 10,
                             color: .tertiaryLabelColor), in: .trailing)
        addFullWidth(row)
        syncColorControls()
    }

    // -----------------------------------------------------------------
    // 信号页
    // -----------------------------------------------------------------

    private func buildSignalTab() {
        section(L("pref.menuSignals"),
                L("pref.checkedSignalsAppearInThe"))

        // 批量按钮
        let allBtn = UI.button(L("pref.selectAll"), target: self,
                               action: #selector(selectAllSignals(_:)))
        let defBtn = UI.button(L("pref.commonOnlyDefault"), target: self,
                               action: #selector(defaultSignals(_:)))
        let noneBtn = UI.button(L("pref.selectNone"), target: self,
                                action: #selector(noSignals(_:)))
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        for b in [allBtn, defBtn, noneBtn] {
            b.font = NSFont.systemFont(ofSize: 11)
            buttonRow.addView(b, in: .leading)
        }
        buttonRow.addView(signalCountLabel, in: .trailing)
        addFullWidth(buttonRow)

        section(L("pref.confirmBeforeSending"), L("pref.signalsAreSentViaKill"))
        check(.confirmBeforeSignal, L("pref.confirmBeforeSendingAnySignal"),
              hint: L("pref.includingNotificationSignalsSuchAs"))
        check(.alwaysConfirmDestructive, L("pref.alwaysConfirmDestructiveSignals"),
              hint: L("pref.evenWithTheSwitchAbove"))

        for group in SignalGroup.allCases {
            groupLabel(group.title)
            for def in SignalCatalog.all where def.group == group {
                signalRow(def)
            }
        }
        syncSignalControls()
    }

    private func signalRow(_ def: SignalDef) {
        let b = NSButton(checkboxWithTitle: "", target: self,
                         action: #selector(signalCheckChanged(_:)))
        b.tag = Self.signalCheckTagBase + Int(def.number)
        b.font = NSFont.systemFont(ofSize: 11)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        signalChecks[def.number] = b

        let name = UI.label(def.prefTitle, size: 11, weight: .medium,
                            monospaced: true)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let note: String
        switch def.severity {
        case .destructive: note = L("pref.defaultActionTerminatesCrashes")
        case .control:     note = L("pref.changesRunState")
        case .harmless:    note = ""
        }
        let hint = UI.wrappingLabel(def.summary + note, size: 10,
                                    color: .tertiaryLabelColor)
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.defaultLow,
                                                     for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addView(b, in: .leading)
        row.addView(name, in: .center)
        row.addView(hint, in: .trailing)
        addFullWidth(row)
    }

    private func syncSignalControls() {
        let set = Preferences.shared.visibleSignalNumbers
        for (num, b) in signalChecks {
            b.state = set.contains(num) ? .on : .off
        }
        signalCountLabel.stringValue = L("pref.selected", set.count, SignalCatalog.all.count)
    }

    private func setVisibleSignals(_ set: Set<Int32>) {
        Preferences.shared.visibleSignalNumbers = set
        syncSignalControls()
        statusLabel.stringValue = L("pref.menuWillShowSignals", set.count)
    }

    @objc private func signalCheckChanged(_ sender: NSButton) {
        let num = Int32(sender.tag - Self.signalCheckTagBase)
        guard SignalCatalog.def(number: num) != nil else { return }
        var set = Preferences.shared.visibleSignalNumbers
        if sender.state == .on { set.insert(num) } else { set.remove(num) }
        setVisibleSignals(set)
    }

    @objc private func selectAllSignals(_ sender: Any?) {
        setVisibleSignals(Set(SignalCatalog.all.map { $0.number }))
    }

    @objc private func defaultSignals(_ sender: Any?) {
        setVisibleSignals(SignalCatalog.defaultNumbers)
    }

    @objc private func noSignals(_ sender: Any?) {
        setVisibleSignals([])
    }

    /// 供菜单里的「配置菜单信号…」直接跳到本页
    func selectSignalTab() {
        applyTab(Pane.signals.rawValue)
        reloadValues()
    }

    private func groupLabel(_ text: String) {
        let t = UI.label(text, size: 11, weight: .semibold,
                         color: .secondaryLabelColor)
        t.translatesAutoresizingMaskIntoConstraints = false
        t.heightAnchor.constraint(equalToConstant: 20).isActive = true
        addFullWidth(t)
    }

    private func makeHintRow(_ text: String) -> NSView {
        UI.wrappingLabel(text, size: 10, color: .tertiaryLabelColor)
    }

    private func colorRow(_ key: AppColorKey) {
        let idx = AppColorKey.allCases.firstIndex(of: key)!

        // macOS 13+ 用 Apple 推荐的 init(style:)；旧系统回退 init(frame:)。
        // 避免新版 AppKit 上旧构造器的内部状态差异。
        let well: NSColorWell
        if #available(macOS 13.0, *) {
            well = NSColorWell(style: .default)
        } else {
            well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        }
        well.tag = Self.colorWellTagBase + idx
        well.target = self
        well.action = #selector(colorWellChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorWells[idx] = well

        let hex = NSTextField(frame: .zero)
        hex.tag = Self.hexFieldTagBase + idx
        hex.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        hex.alignment = .left
        hex.isEditable = true
        hex.isBezeled = true
        hex.bezelStyle = .roundedBezel
        hex.delegate = self
        hex.translatesAutoresizingMaskIntoConstraints = false
        hex.widthAnchor.constraint(equalToConstant: 96).isActive = true
        hexFields[idx] = hex

        let reset = UI.button("↺", target: self,
                              action: #selector(resetColorClicked(_:)))
        reset.tag = Self.colorResetTagBase + idx
        reset.toolTip = L("pref.resetThisItemToThe")
        reset.translatesAutoresizingMaskIntoConstraints = false
        reset.widthAnchor.constraint(equalToConstant: 26).isActive = true

        addFullWidth(makeRow(key.title, controls: [well, hex, reset],
                             hint: key.hint))
    }

    // -----------------------------------------------------------------
    // 通用行构造（activeStack 决定加到哪一页）
    // -----------------------------------------------------------------

    /// 行内两列的固定尺寸：左列标题、右列控件起点。
    /// 行宽在 560pt 的最小窗口下仍有约 500pt，说明文字可用 320pt 以上。
    private enum Metric {
        static let labelWidth: CGFloat = 168
        static let gap: CGFloat = 10
    }

    private func addFullWidth(_ v: NSView) {
        guard let stack = activeStack else { return }
        stack.addView(v, in: .bottom)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                 constant: -32).isActive = true
    }

    private func section(_ title: String, _ hint: String) {
        let t = UI.label(title, size: 13, weight: .semibold)
        let h = UI.wrappingLabel(hint, size: 10, color: .secondaryLabelColor)
        let box = NSStackView()
        box.orientation = .vertical
        box.spacing = 2
        // 默认 alignment 是 centerX：标题与说明会各自居中，看着像整段
        // 漂浮在页中间。统一左对齐，和下面的行起点齐平。
        box.alignment = .leading
        t.alignment = .left
        box.addView(t, in: .bottom)
        box.addView(h, in: .bottom)
        let wrap = NSView()
        wrap.addSubview(box)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            box.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 8),
            box.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        addFullWidth(wrap)
        wrap.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
    }

    /// 偏好行的两段式布局：第一行「标题 + 控件」，第二行说明文字（缩进到
    /// 控件列下）按可用宽度换行。之前把说明挤在控件右侧、且 NSTextField
    /// 单行截尾，长描述既不换行又会把 documentView 撑宽，窗口里就出现了
    /// 横向滚动 / 左侧被裁掉。
    private func makeRow(_ labelText: String, controls: [NSView],
                         hint: String) -> NSView {
        let label = UI.wrappingLabel(labelText, size: 11, weight: .medium,
                                     alignment: .right)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Metric.labelWidth).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let controlBox = NSStackView()
        controlBox.orientation = .horizontal
        controlBox.spacing = 6
        controlBox.alignment = .centerY
        controlBox.distribution = .fill
        for c in controls { controlBox.addView(c, in: .leading) }
        controlBox.translatesAutoresizingMaskIntoConstraints = false
        controlBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlBox.setContentCompressionResistancePriority(.defaultLow,
                                                           for: .horizontal)

        let top = NSStackView()
        top.orientation = .horizontal
        top.spacing = Metric.gap
        top.alignment = .centerY
        top.distribution = .fill
        top.addView(label, in: .leading)
        top.addView(controlBox, in: .trailing)
        top.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .vertical
        row.spacing = 1
        row.alignment = .leading
        row.addView(top, in: .top)
        top.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true

        if !hint.isEmpty {
            let hintLabel = UI.wrappingLabel(hint, size: 10,
                                             color: .tertiaryLabelColor)
            // 用显式约束而不是 NSStackView 的 gravity：短说明在 trailing
            // gravity 下会被推到最右边，长说明才从控件列开始，视觉上不齐。
            let hintRow = NSView()
            hintRow.translatesAutoresizingMaskIntoConstraints = false
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            hintRow.addSubview(hintLabel)
            NSLayoutConstraint.activate([
                hintLabel.leadingAnchor.constraint(
                    equalTo: hintRow.leadingAnchor,
                    constant: Metric.labelWidth + Metric.gap),
                hintLabel.trailingAnchor.constraint(equalTo: hintRow.trailingAnchor),
                hintLabel.topAnchor.constraint(equalTo: hintRow.topAnchor),
                hintLabel.bottomAnchor.constraint(equalTo: hintRow.bottomAnchor),
            ])
            row.addView(hintRow, in: .bottom)
            hintRow.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        return row
    }

    private func number(_ tag: Tag, _ title: String, unit: String,
                        hint: String) {
        let f = NSTextField(frame: .zero)
        f.tag = tag.rawValue
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        f.alignment = .right
        f.isEditable = true
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.delegate = self
        let nf = NumberFormatter()
        nf.numberStyle = .none
        nf.allowsFloats = false
        nf.minimum = NSNumber(value: 0)
        nf.maximum = NSNumber(value: 1_000_000)
        nf.usesGroupingSeparator = false
        f.formatter = nf
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: 88).isActive = true

        let u = UI.label(unit, size: 10, color: .secondaryLabelColor)
        numberFields[tag.rawValue] = f
        addFullWidth(makeRow(title, controls: [f, u], hint: hint))
    }

    private func check(_ tag: Tag, _ title: String, hint: String) {
        let b = NSButton(checkboxWithTitle: title, target: self,
                         action: #selector(toggleChanged(_:)))
        b.tag = tag.rawValue
        b.font = NSFont.systemFont(ofSize: 11)
        b.translatesAutoresizingMaskIntoConstraints = false
        // 不再固定 186：长标题可以按需要占宽，窄窗口下由压缩抵抗兜底
        b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        b.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        checkboxes[tag.rawValue] = b
        addFullWidth(makeRow("", controls: [b], hint: hint))
    }

    private func popup(_ tag: Tag, _ title: String, _ items: [String],
                       hint: String) {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.tag = tag.rawValue
        p.addItems(withTitles: items)
        p.target = self
        p.action = #selector(popupChanged(_:))
        p.font = NSFont.systemFont(ofSize: 11)
        p.translatesAutoresizingMaskIntoConstraints = false
        p.widthAnchor.constraint(equalToConstant: 210).isActive = true
        popups[tag.rawValue] = p
        addFullWidth(makeRow(title, controls: [p], hint: hint))
    }

    // -----------------------------------------------------------------
    // 值同步
    // -----------------------------------------------------------------

    private func reloadValues() {
        let p = Preferences.shared
        // 刻意用「元组数组」而不是 [Tag: X] 字典字面量：
        // Swift 字典字面量里写重 key 是**运行时** trap（无消息 SIGTRAP），
        // 编译期不报错；数组里重复只是多赋值一次，永远不会崩。
        let nums: [(Tag, Int)] = [
            (.maxRegions, p.maxRegions), (.pipeCacheMs, p.pipeCacheMs),
            (.argvMaxKB, p.argvMaxKB), (.fdMaxMB, p.fdMaxMB),
            (.smcMaxKeys, p.smcMaxKeys), (.treeMaxDepth, p.treeMaxDepth),
            (.historyPoints, p.historyPoints), (.dynamicTTL, p.dynamicTTL),
            (.ttyTTL, p.ttyTTL), (.staticTTL, p.staticTTL),
            (.sampleSeconds, p.sampleSeconds),
            (.exitedKeepRefreshes, p.exitedKeepRefreshes),
            (.globalSearchMaxRows, p.globalSearchMaxRows),
            (.ioregMaxNodes, p.ioregMaxNodes),
        ]
        for (tag, v) in nums { numberFields[tag.rawValue]?.stringValue = "\(v)" }

        let checks: [(Tag, Bool)] = [
            (.defaultTreeMode, p.defaultTreeMode),
            (.defaultAscending, p.defaultAscending),
            (.lazyDetailLoading, p.lazyDetailLoading),
            (.sortAutoFlat, p.sortAutoFlat),
            (.sortCycleToTree, p.sortCycleToTree),
            (.showSortIndicator, p.showSortIndicator),
            (.startPerfSampler, p.startPerfSampler),
            (.confirmBeforeSignal, p.confirmBeforeSignal),
            (.refreshInvalidatesDetail, p.refreshInvalidatesDetail),
            (.highlightExited, p.highlightExited),
            (.alwaysConfirmDestructive, p.alwaysConfirmDestructive),
            (.showRawNameWithBundle, p.showRawNameWithBundle),
            (.showArgv0WhenDifferent, p.showArgv0WhenDifferent),
            (.useLocalizedAppName, p.useLocalizedAppName),
            (.showDetailHints, p.showDetailHints),
            (.searchUseRegex, p.searchUseRegex),
            (.globalSearchHeavyPages, p.globalSearchHeavyPages),
            (.scanAppExtensions, p.scanAppExtensions),
            (.touchIDAuth, p.touchIDAuth),
        ]
        for (tag, v) in checks {
            checkboxes[tag.rawValue]?.state = v ? .on : .off
        }

        let intervals: [TimeInterval] = [0.5, 1.0, 2.0, 5.0]
        popups[Tag.refreshInterval.rawValue]?.selectItem(at:
            intervals.firstIndex { abs($0 - p.refreshInterval) < 0.01 } ?? 1)
        let msValues = [500, 1000, 2000, 5000]
        popups[Tag.perfIntervalMs.rawValue]?.selectItem(at:
            msValues.firstIndex(of: p.perfIntervalMs) ?? 1)
        popups[Tag.defaultFilter.rawValue]?.selectItem(at: p.defaultFilter.rawValue)
        let sortKeys: [SortKey] = [.cpu, .name, .pid, .mem, .threads, .ports, .start]
        popups[Tag.defaultSortKey.rawValue]?.selectItem(at:
            sortKeys.firstIndex(of: p.defaultSortKey) ?? 0)
        popups[Tag.rawNameStyle.rawValue]?.selectItem(at: p.rawNameStyle.rawValue)
        popups[Tag.language.rawValue]?.selectItem(at: p.language.rawValue)
        // 布局：0 = 左侧竖排，1 = 经典（横向）
        popups[Tag.tabsLayout.rawValue]?.selectItem(
            at: p.tabsStyle == .left ? 0 : 1)
        // 经典每行：0 = 自动折行；N 个 → 第 N-1 项
        let perRow = p.detailTabsPerRow
        popups[Tag.classicPerRow.rawValue]?.selectItem(
            at: perRow == 0 ? 0 : min(max(perRow, 2), 15) - 1)
        syncTabLayoutControls()

        syncColorControls()
        syncSignalControls()
        syncNamePreview()
    }

    /// 通用页名称预览：主进程不追加、helper 追加 raw 名、
    /// /bin/sh（argv[0] 为 sh，规范 exe 为 bash）追加 argv[0] 名。
    private func syncNamePreview() {
        let p = Preferences.shared
        let main = p.useLocalizedAppName ? L("pref.weChat") : "WeChat"
        let helper = p.showRawNameWithBundle
            ? main + p.rawNameStyle.wrap("crashpad_handler") : main
        let argv0Case = p.showArgv0WhenDifferent
            ? "bash" + p.rawNameStyle.wrap("sh") : "bash"
        // 三者互不相同：bundle 名 / 实际 exe / argv[0] 都不同。
        // 此时两个括注不能同款，第二个要用「以 X 调用」区分。
        var allDifferent = "Visual Studio Code"
        let hasRaw = p.showRawNameWithBundle
        if hasRaw { allDifferent += p.rawNameStyle.wrap("Electron") }
        if p.showArgv0WhenDifferent {
            allDifferent += hasRaw
                ? " " + L("model.argv0Alias", "Code")
                : p.rawNameStyle.wrap("Code")
        }
        namePreviewLabel.stringValue =
            L("pref.namePreview", main, helper, argv0Case, allDifferent)
    }

    /// 把 AppColors 的当前值同步到色块、hex 框、预设下拉与预览条
    private func syncColorControls() {
        let C = AppColors.shared
        for (idx, key) in AppColorKey.allCases.enumerated() {
            colorWells[idx]?.color = C.color(key)
            hexFields[idx]?.stringValue = C.hex(key)
            hexFields[idx]?.toolTip = C.isCustomized(key)
                ? L("pref.customColorClickToReset") : L("pref.systemDefaultAdaptsToLight")
        }
        let raw = C.currentPresetRaw
        if let i = ColorPreset.allCases.firstIndex(where: { $0.rawValue == raw }) {
            popups[Tag.colorPreset.rawValue]?.selectItem(at: i)
        } else {
            popups[Tag.colorPreset.rawValue]?.selectItem(at: ColorPreset.allCases.count)
        }
        previewLabel.stringValue =
            L("pref.exitedProcessExampleStatusExited")
        previewLabel.textColor = C.color(.exitedText)
        previewLabel.backgroundColor = C.color(.exitedBackground)
    }

    // -----------------------------------------------------------------
    // 编辑 → 即时应用
    // -----------------------------------------------------------------

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }

        // hex 输入行（tag 段 2000+）
        if f.tag >= Self.hexFieldTagBase {
            let idx = f.tag - Self.hexFieldTagBase
            guard idx >= 0, idx < AppColorKey.allCases.count else { return }
            let key = AppColorKey.allCases[idx]
            if AppColors.shared.set(key, hex: f.stringValue) {
                syncColorControls()
                statusLabel.stringValue = L("pref.colorUpdated", key.title)
            } else {
                f.stringValue = AppColors.shared.hex(key)   // 非法 hex 回退
                statusLabel.stringValue = L("pref.colorMustBeRrggbbOr")
            }
            return
        }

        guard let tag = Tag(rawValue: f.tag) else { return }
        let v = Int(f.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        let p = Preferences.shared
        switch tag {
        case .maxRegions:    p.maxRegions = v
        case .pipeCacheMs:   p.pipeCacheMs = v
        case .argvMaxKB:     p.argvMaxKB = v
        case .fdMaxMB:       p.fdMaxMB = v
        case .smcMaxKeys:    p.smcMaxKeys = v
        case .treeMaxDepth:  p.treeMaxDepth = v
        case .historyPoints: p.historyPoints = v
        case .dynamicTTL:    p.dynamicTTL = v
        case .ttyTTL:        p.ttyTTL = v
        case .staticTTL:     p.staticTTL = v
        case .sampleSeconds: p.sampleSeconds = v
        case .exitedKeepRefreshes: p.exitedKeepRefreshes = v
        case .globalSearchMaxRows: p.globalSearchMaxRows = v
        case .ioregMaxNodes: p.ioregMaxNodes = v
        default: return
        }
        // 回写 clamp 后的真实值，让用户看到实际生效的数
        f.stringValue = "\(currentNumber(tag))"
        applied()
    }

    private func currentNumber(_ tag: Tag) -> Int {
        let p = Preferences.shared
        switch tag {
        case .maxRegions:    return p.maxRegions
        case .pipeCacheMs:   return p.pipeCacheMs
        case .argvMaxKB:     return p.argvMaxKB
        case .fdMaxMB:       return p.fdMaxMB
        case .smcMaxKeys:    return p.smcMaxKeys
        case .treeMaxDepth:  return p.treeMaxDepth
        case .historyPoints: return p.historyPoints
        case .dynamicTTL:    return p.dynamicTTL
        case .ttyTTL:        return p.ttyTTL
        case .staticTTL:     return p.staticTTL
        case .sampleSeconds: return p.sampleSeconds
        case .exitedKeepRefreshes: return p.exitedKeepRefreshes
        case .globalSearchMaxRows: return p.globalSearchMaxRows
        case .ioregMaxNodes: return p.ioregMaxNodes
        default: return 0
        }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let tag = Tag(rawValue: sender.tag) else { return }
        let on = sender.state == .on
        let p = Preferences.shared
        switch tag {
        case .defaultTreeMode:          p.defaultTreeMode = on
        case .defaultAscending:         p.defaultAscending = on
        case .lazyDetailLoading:        p.lazyDetailLoading = on
        case .sortAutoFlat:             p.sortAutoFlat = on
        case .sortCycleToTree:          p.sortCycleToTree = on
        case .showSortIndicator:        p.showSortIndicator = on
        case .startPerfSampler:         p.startPerfSampler = on
        case .confirmBeforeSignal:      p.confirmBeforeSignal = on
        case .refreshInvalidatesDetail: p.refreshInvalidatesDetail = on
        case .highlightExited:          p.highlightExited = on
        case .alwaysConfirmDestructive: p.alwaysConfirmDestructive = on
        case .showRawNameWithBundle:    p.showRawNameWithBundle = on
        case .showArgv0WhenDifferent:   p.showArgv0WhenDifferent = on
        case .useLocalizedAppName:      p.useLocalizedAppName = on
        case .showDetailHints:          p.showDetailHints = on
            // 提示行是详情页数据的一部分，清缓存后当前页立即重采
            NotificationCenter.default.post(name: .procDetailForceRefresh, object: nil)
        case .searchUseRegex:           p.searchUseRegex = on
            // 主表 / 详情表 / 全局搜索窗口都会收到，各自按新语义重新过滤
            NotificationCenter.default.post(name: .searchModeDidChange, object: self)
        case .globalSearchHeavyPages:   p.globalSearchHeavyPages = on
        case .scanAppExtensions:       p.scanAppExtensions = on
        default: return
        }
        syncNamePreview()
        applied()
    }

    // -----------------------------------------------------------------
    // Touch ID 提权（安装 / 卸载 root 辅助工具）
    // -----------------------------------------------------------------

    @objc private func touchIDToggled(_ sender: NSButton) {
        let want = sender.state == .on
        if !want { disableTouchID(sender); return }
        enableTouchID(sender)
    }

    /// 开关的语义：**只有真的装好/卸干净了才动偏好**。
    /// 之前是先写偏好、失败再回滚，于是出现「装失败了但开关还亮着」——
    /// 界面说已启用、提权却仍在输密码，用户无从判断到底成没成。
    private func enableTouchID(_ sender: NSButton) {
        let (ok, title) = TouchIDAuth.availability()
        guard ok else {
            sender.state = .off
            let a = NSAlert()
            a.messageText = L("priv.touchIDUnavailableTitle")
            a.informativeText = L("priv.touchIDUnavailableBody")
            a.addButton(withTitle: L("app.ok"))
            a.runModal()
            return
        }

        let confirm = NSAlert()
        confirm.messageText = L("priv.touchIDInstallTitle", title)
        confirm.informativeText = L("priv.touchIDInstallBody", title)
        confirm.addButton(withTitle: L("priv.touchIDInstallAction"))
        confirm.addButton(withTitle: L("app.cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else {
            sender.state = .off
            return
        }

        sender.isEnabled = false
        sender.state = .on
        touchIDStatusLabel.stringValue = L("priv.touchIDInstalling")
        // 安装要经 Authorization Services 提权（这一次仍是密码），
        // 走后台避免把偏好窗口冻住。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TouchIDHelper.install()
            DispatchQueue.main.async {
                sender.isEnabled = true
                if result.ok {
                    sender.state = .on
                } else {
                    // 失败就把开关弹回 off，并尝试收拾残留（文件已装但守护
                    // 进程没起来时「重新安装」按钮仍然可用，所以只把偏好关掉）。
                    sender.state = .off
                    self?.presentHelperError(L("priv.touchIDInstallFailed"),
                                             result.message)
                }
                self?.refreshTouchIDStatus()
                NotificationCenter.default.post(
                    name: .vantagePrivilegeDidChange, object: nil)
            }
        }
    }

    private func disableTouchID(_ sender: NSButton) {
        // 既没装助手、也没有机器级标记：没什么可拆的，直接关掉开关。
        // （只判断 isInstalled 不够：助手被手动删掉后标记文件还在，
        //  这时仍需要一次提权把标记清掉，否则开关会「自己弹回来」。）
        guard TouchIDHelper.isInstalled || TouchIDState.isEnabled else {
            sender.state = .off
            refreshTouchIDStatus()
            return
        }
        let confirm = NSAlert()
        confirm.messageText = L("priv.touchIDUninstallTitle")
        confirm.informativeText = L("priv.touchIDUninstallBody")
        confirm.addButton(withTitle: L("priv.touchIDUninstallAction"))
        confirm.addButton(withTitle: L("app.cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else {
            sender.state = .on     // 取消：偏好没动过，也不用改
            return
        }
        sender.isEnabled = false
        touchIDStatusLabel.stringValue = L("priv.touchIDUninstalling")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TouchIDHelper.uninstall()
            DispatchQueue.main.async {
                sender.isEnabled = true
                if result.ok {
                    sender.state = .off
                } else {
                    // 卸载失败：助手还在，偏好就得保持 on，否则界面与
                    // 实际状态不一致（下次提权还会走指纹）
                    sender.state = .on
                    self?.presentHelperError(L("priv.touchIDUninstallFailed"),
                                             result.message)
                }
                self?.refreshTouchIDStatus()
                NotificationCenter.default.post(
                    name: .vantagePrivilegeDidChange, object: nil)
            }
        }
    }

    /// 「重新安装」：不改开关的意图，只重跑一次安装流程。
    /// 成功即视为「已启用」（用户点它的目的就是把指纹修好）。
    @objc private func repairTouchIDClicked(_ sender: Any?) {
        guard touchIDRepairButton.isEnabled else { return }
        touchIDRepairButton.isEnabled = false
        touchIDStatusLabel.stringValue = L("priv.touchIDInstalling")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TouchIDHelper.install()
            DispatchQueue.main.async {
                self?.touchIDRepairButton.isEnabled = true
                if !result.ok {
                    self?.presentHelperError(
                        L("priv.touchIDInstallFailed"), result.message)
                }
                self?.refreshTouchIDStatus()
                Privilege.notifyPrivilegeChanged()
            }
        }
    }

    private func presentHelperError(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: L("app.ok"))
        a.runModal()
    }

    /// 状态行：硬件是否支持、助手是否装好、是否连得上
    private func refreshTouchIDStatus() {
        touchIDStatusLabel.stringValue = TouchIDAuth.statusText()
        touchIDStatusLabel.textColor = TouchIDAuth.isActive
            ? .secondaryLabelColor : .tertiaryLabelColor
        if let cb = checkboxes[Tag.touchIDAuth.rawValue] {
            cb.state = Preferences.shared.touchIDAuth ? .on : .off
        }
        // 开关是开的、但助手没装 / 版本对不上 / 没在跑时，给一个「重新安装」
        touchIDRepairButton.isHidden = !TouchIDAuth.needsRepair
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let tag = Tag(rawValue: sender.tag) else { return }
        let i = sender.indexOfSelectedItem
        let p = Preferences.shared
        switch tag {
        case .refreshInterval:
            p.refreshInterval = [0.5, 1.0, 2.0, 5.0][max(0, min(i, 3))]
            AppContext.shared.store.refreshInterval = p.refreshInterval
            AppContext.shared.mainWindow?.syncToolbar()
        case .perfIntervalMs:
            p.perfIntervalMs = [500, 1000, 2000, 5000][max(0, min(i, 3))]
        case .defaultFilter:
            p.defaultFilter = ProcessFilter(rawValue: max(0, min(i, 4))) ?? .all
        case .defaultSortKey:
            let keys: [SortKey] = [.cpu, .name, .pid, .mem, .threads, .ports, .start]
            p.defaultSortKey = keys[max(0, min(i, keys.count - 1))]
        case .rawNameStyle:
            p.rawNameStyle = RawNameStyle(rawValue: i) ?? .parentheses
            syncNamePreview()
        case .language:
            p.language = L10n.Language(rawValue: i) ?? .system
            // 界面文字分布在十几个控制器里，其中不少是建视图时取一次、
            // 原地改不到（自定义绘制 / 缓存数组 / 未加载的页），就地刷新
            // 一定会留下中英混排。所以改完偏好直接重启一次，保证全一致。
            if !AppRelaunch.restart() {
                // root 实例没法用 open 重启：退回就地刷新，并说明原因
                relocalizeSelf()
                rebuildLanguagePopup()
                statusLabel.stringValue = L("pref.languageNeedsRestart")
            } else {
                return      // 0.35s 后就退出了，不必再走 applied()
            }
        case .tabsLayout:
            // 0 = 左侧竖排；1 = 经典（沿用已选的每行个数，没选过就自动）
            p.tabsStyle = i == 0
                ? .left
                : (p.detailTabsPerRow > 0 ? .fixed : .auto)
            syncTabLayoutControls()
            // 本窗口先自己换布局，别等通知绕一圈（检查器也会收到同一通知）
            applyTabStyle(force: true)
        case .classicPerRow:
            // 0 = 自动折行；i ≥ 1 → 每行 i+1 个
            p.detailTabsPerRow = i == 0 ? 0 : min(max(i + 1, 2), 15)
            if p.tabsStyle != .left {
                p.tabsStyle = p.detailTabsPerRow > 0 ? .fixed : .auto
            }
            applyTabStyle(force: true)
        case .colorPreset:
            // 最后一项是「自定义」占位，点它不改任何颜色
            guard i >= 0, i < ColorPreset.allCases.count else {
                syncColorControls()
                return
            }
            AppColors.shared.applyPreset(ColorPreset.allCases[i])
            syncColorControls()
            statusLabel.stringValue = L("pref.presetApplied", ColorPreset.allCases[i].title)
            return                      // 颜色通知已发，不必再发 preferencesDidChange
        default: return
        }
        applied()
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) {
        let idx = sender.tag - Self.colorWellTagBase
        guard idx >= 0, idx < AppColorKey.allCases.count else { return }
        let key = AppColorKey.allCases[idx]
        if AppColors.shared.set(key, color: sender.color) {
            syncColorControls()
            statusLabel.stringValue = L("pref.colorUpdated2", key.title)
        }
    }

    @objc private func resetColorClicked(_ sender: NSButton) {
        let idx = sender.tag - Self.colorResetTagBase
        guard idx >= 0, idx < AppColorKey.allCases.count else { return }
        let key = AppColorKey.allCases[idx]
        AppColors.shared.reset(key)
        syncColorControls()
        statusLabel.stringValue = L("pref.colorReset", key.title)
    }

    @objc private func resetColorsClicked(_ sender: Any?) {
        AppColors.shared.resetAll()
        syncColorControls()
        statusLabel.stringValue = L("pref.allColorsResetToDefaults")
    }

    private func applied() {
        Preferences.shared.applyToRuntime()
        statusLabel.stringValue = L("pref.appliedTakesEffectImmediately")
    }

    @objc private func resetClicked(_ sender: Any?) {
        // 恢复默认会把语言改回「跟随系统」；语言变了就重启一次，
        // 否则界面会停在「一半旧语言、一半新语言」的状态。
        let oldLanguage = Preferences.shared.language
        Preferences.shared.reset()
        AppColors.shared.resetAll()     // 配色用独立 key 段，reset() 不覆盖
        reloadValues()
        applyTabStyle(force: true)
        AppContext.shared.store.refreshInterval = Preferences.shared.refreshInterval
        AppContext.shared.mainWindow?.syncToolbar()
        statusLabel.stringValue = L("pref.defaultsRestoredInclColors")
        if Preferences.shared.language != oldLanguage, AppRelaunch.restart() {
            return
        }
    }

    @objc private func doneClicked(_ sender: Any?) {
        // 结束当前编辑，确保最后一个输入框的值被提交
        window?.makeFirstResponder(nil)
        close()
    }
}
