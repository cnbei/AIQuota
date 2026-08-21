import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var settings: TokenStepSettings = .defaults
    @Published private(set) var isRefreshing = false
    @Published private(set) var autostartEnabled = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isRefreshingCodexQuota = false
    @Published private(set) var quotas: [QuotaProviderID: ProviderQuota] = [:]
    @Published private(set) var cursorCodeSignal: CursorCodeSignal?
    @Published private(set) var cursorCodeSignalError: String?
    @Published private(set) var isRefreshingTokenRank = false
    @Published private(set) var tokenRank: TokenRankLeaderboard?
    @Published private(set) var agentWorkRankIdentity: AgentWorkRankIdentity?
    @Published private(set) var tokenRankError: String?
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var updateDownloadProgress = 0.0
    @Published private(set) var updateInstallStatus = L("准备更新")
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var lastUpdateCheckAt: Date?
    @Published private(set) var updateDownloadedURL: URL?
    @Published private(set) var tokenIslandAvailable = TokenIslandDisplayDetector.isAvailable
    @Published private(set) var showsUsageRecalibrationNotice = false
    @Published private(set) var isSyncingUsage = false
    @Published private(set) var lastUsageSyncAt: Date?
    @Published var usageSyncError: String?
    @Published var usageExportError: String?
    @Published private(set) var lastUsageExportAt: Date?
    @Published var historyDeviceFilter: HistoryDeviceFilter = .all
    @Published var lastError: String?
    @Published var isQuotaPinned = false
    @Published var kimiAuthHint: String?

    private var timer: Timer?
    private var foregroundTimer: Timer?
    private var foregroundRefreshSurfaces = Set<String>()
    private var pendingRefreshAfterCurrent = false
    private var pendingForcedRefresh = false
    private var lastQuotaRefreshAttemptAt: Date?
    private var lastCursorUsageRefreshAttemptAt: Date?
    private var lastRankRefreshAttemptAt: Date?
    private var lastAutomaticUsageRefreshAttemptAt: Date?
    private var lastUsageObservedAt: Date?
    private var lastUsageSyncAttemptAt: Date?
    private var ledgerSnapshot: UsageSnapshot = .empty
    private var localHistoryDaily: [DailyUsage] = []
    private var remoteMachines: [UsageSyncService.MachineUsageFile] = UsageSyncService.loadCachedOthersMachines()
    private var isRefreshingCursorUsage = false
    private let usageSourceWatcher = UsageSourceWatcher()

    init() {
        load()
        refreshIfSnapshotIsStale()
        applyDefaultAutostartIfNeeded()
        configureTimer()
        usageSourceWatcher.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshForSourceChange()
            }
        }
        startUsageSourceWatcher()
        refreshCodexQuota()
        refreshTokenRank()
        refreshUsageSync()
        scheduleDeferredUpdateCheck()
    }

    deinit {
        timer?.invalidate()
        foregroundTimer?.invalidate()
        usageSourceWatcher.stop()
    }

    var today: DailyUsage {
        let key = DateFormatter.tokenStepDay.string(from: Date())
        return snapshot.daily.last(where: { $0.date == key })
            ?? DailyUsage(date: key, tools: [:], totalTokens: 0, cost: 0)
    }

    var todayAgentWork: DailyAgentWork {
        let key = DateFormatter.tokenStepDay.string(from: Date())
        return agentWork(for: key)
    }

    var sevenDayAgentAverage: Int {
        sevenDayAgentAverage(endingAt: DateFormatter.tokenStepDay.string(from: Date()))
    }

    var progress: Double {
        guard settings.dailyGoalTokens > 0 else { return 0 }
        return Double(today.totalTokens) / Double(settings.dailyGoalTokens)
    }

    var todayLap: TokenStepLapProgress {
        TokenStepLapProgress(tokens: today.totalTokens, goal: settings.dailyGoalTokens)
    }

    var monthAverage: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let endDate = calendar.startOfDay(for: Date())
        let values = (0..<30).map { offset -> Int in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: endDate) else {
                return 0
            }
            let key = DateFormatter.tokenStepDay.string(from: date)
            return snapshot.daily.last(where: { $0.date == key })?.totalTokens ?? 0
        }
        return values.reduce(0, +) / 30
    }

    var goalDays: Int {
        snapshot.daily.filter { $0.totalTokens >= settings.dailyGoalTokens }.count
    }

    var goalStreak: GoalStreak {
        GoalStreak.compute(
            daily: snapshot.daily,
            goal: settings.dailyGoalTokens,
            today: DateFormatter.tokenStepDay.string(from: Date())
        )
    }

    var visibleHistoryRows: [DailyUsage] {
        Array(historyDaily.reversed())
    }

    var historyDevices: [SyncedMachineLedger] {
        let identity = UsageSyncService.loadOrCreateMachineIdentity()
        let local = SyncedMachineLedger(
            machineId: identity.id,
            machineName: identity.name,
            fileSlug: identity.fileSlug,
            isLocal: true,
            daily: localHistoryDaily
        )
        let remotes = remoteMachines.map { SyncedMachineLedger(remote: $0) }
        return [local, cursorAccountLedger].compactMap { $0 } + remotes
    }

    private var cursorAccountLedger: SyncedMachineLedger? {
        guard settings.cursorQuotaEnabled,
              let cache = CursorUsageService.readCache()
        else {
            return nil
        }
        let daily = CursorUsageService.accountDeviceDaily(from: cache.days)
        guard !daily.isEmpty else { return nil }
        return SyncedMachineLedger(
            machineId: CursorUsageService.accountDeviceID,
            machineName: L("Cursor 账号"),
            fileSlug: CursorUsageService.accountDeviceID,
            isLocal: false,
            daily: daily
        )
    }

    var showsHistoryDeviceChart: Bool {
        settings.usageSyncEnabled
    }

    var historyDaily: [DailyUsage] {
        guard showsHistoryDeviceChart else { return snapshot.daily }
        return HistoryDevicePresentation.filteredDaily(machines: historyDevices, filter: historyDeviceFilter)
    }

    var historyTotals: UsageTotals {
        guard showsHistoryDeviceChart else { return snapshot.totals }
        return HistoryDevicePresentation.totals(from: historyDaily)
    }

    var historyToolUsages: [ToolUsage] {
        guard showsHistoryDeviceChart else { return snapshot.tools }
        return HistoryDevicePresentation.toolUsages(from: historyDaily)
    }

    var historyModelUsages: [ModelUsage] {
        guard showsHistoryDeviceChart else { return snapshot.models }
        return HistoryDevicePresentation.modelUsages(from: historyDaily)
    }

    var historyDeviceStats: [DeviceUsageStat] {
        HistoryDevicePresentation.deviceStats(from: HistoryDevicePresentation.selectedMachines(
            historyDevices,
            filter: historyDeviceFilter
        ))
    }

    var historyDeviceBars: [DailyDeviceBar] {
        HistoryDevicePresentation.deviceBars(
            machines: historyDevices,
            filter: historyDeviceFilter
        )
    }

    func setHistoryDeviceFilter(_ filter: HistoryDeviceFilter) {
        historyDeviceFilter = filter
        sanitizeHistoryDeviceFilter()
    }

    var shouldShowTokenIsland: Bool {
        settings.tokenIslandPlacement != .menuBar
            && TokenIslandDisplayDetector.isAvailable(for: settings.tokenIslandPlacement, size: TokenIslandWindowPresenter.collapsedSize)
    }

    var tokenIslandStatus: String {
        switch settings.tokenIslandPlacement {
        case .menuBar:
            return L("菜单栏模式")
        case .automatic:
            return shouldShowTokenIsland ? L("自动：刘海旁") : L("自动：菜单栏")
        case .notchLeft:
            return shouldShowTokenIsland ? L("刘海左侧") : L("菜单栏模式")
        case .notchRight:
            return shouldShowTokenIsland ? L("刘海右侧") : L("菜单栏模式")
        }
    }

    var tokenIslandStatusDetail: String {
        if shouldShowTokenIsland {
            return L("鼠标移入后展开 Island")
        }
        if settings.tokenIslandPlacement == .menuBar {
            return L("仅使用右上角菜单栏入口")
        }
        return TokenIslandDisplayDetector.fallbackReason
    }

    var appearanceID: String {
        "\(settings.theme.id)-\(settings.language.resolved.id)"
    }

    var shouldShowAgentWorkRank: Bool {
        settings.agentWorkRankVisibility.shouldShow(hasLocalIdentity: agentWorkRankIdentity != nil)
    }

    func load() {
        defer { MemoryPressure.relieveAllocatorPressure() }
        let loadedSettings = DataService.loadSettings()
        TokenStepLocalization.apply(loadedSettings.language)
        TokenStepThemeRuntime.apply(loadedSettings.theme)
        settings = loadedSettings
        snapshot = (try? DataService.loadSnapshot()) ?? .empty
        ledgerSnapshot = snapshot
        applyOverlays()
        showsUsageRecalibrationNotice = DataService.hasPendingUsageRecalibrationNotice
        if loadedSettings.enabledQuotaProviders.isEmpty {
            quotas = [:]
        } else if loadedSettings.enabledQuotaProviders.contains(.kimi),
                  quotas[.kimi]?.isAvailable != true,
                  let cached = KimiQuotaService.readLastCache() {
            quotas[.kimi] = cached
        }
        if !loadedSettings.cursorCodeSignalEnabled {
            cursorCodeSignal = nil
            cursorCodeSignalError = nil
        }
        if !loadedSettings.agentWorkRankVisibility.readsLocalIdentity {
            clearTokenRankState()
        } else {
            agentWorkRankIdentity = AgentWorkRankService.loadLocalIdentity()
            if loadedSettings.agentWorkRankVisibility == .automatic,
               agentWorkRankIdentity == nil {
                clearTokenRankState()
            }
        }
        autostartEnabled = AutostartService.isEnabled
    }

    func refresh(forceCollection: Bool = true, ignoreAutomaticRetryTTL: Bool = false) {
        guard !isRefreshing else {
            pendingRefreshAfterCurrent = true
            pendingForcedRefresh = pendingForcedRefresh || forceCollection
            return
        }
        let refreshStartedAt = Date()
        if !forceCollection,
           !ignoreAutomaticRetryTTL,
           EnergyRefreshPolicy.isFresh(
               lastAttemptAt: lastAutomaticUsageRefreshAttemptAt,
               ttl: EnergyRefreshPolicy.automaticRetryTTL(
                   requestedSeconds: settings.refreshIntervalSeconds
               ),
               now: refreshStartedAt
           ) {
            return
        }
        if !forceCollection {
            lastAutomaticUsageRefreshAttemptAt = refreshStartedAt
        }
        isRefreshing = true
        lastError = nil
        let historyDays = settings.historyDays
        Task {
            var outcome: CollectionRunOutcome = .unchanged
            var collectionSucceeded = false
            do {
                outcome = try await Task.detached(priority: .utility) {
                    try DataService.runCollectorInHelper(
                        historyDays: historyDays,
                        force: forceCollection
                    )
                }.value
                collectionSucceeded = true
            } catch {
                lastError = error.localizedDescription
            }
            if outcome != .unchanged {
                load()
            }
            if collectionSucceeded, outcome != .updatedWhileSourcesChanged {
                lastUsageObservedAt = Date()
            }
            if collectionSucceeded {
                startUsageSourceWatcher()
            }
            applyOverlays()
            refreshCursorOfficialUsage()
            refreshUsageSync()
            isRefreshing = false
            if pendingRefreshAfterCurrent {
                let force = pendingForcedRefresh
                pendingRefreshAfterCurrent = false
                pendingForcedRefresh = false
                refresh(forceCollection: force, ignoreAutomaticRetryTTL: !force)
            }
        }
    }

    func refreshForForeground(now: Date = Date()) {
        let snapshotDate = UsageSnapshotRefreshPolicy.generatedDate(snapshot.generatedAt)
        let freshestObservation = [snapshotDate, lastUsageObservedAt]
            .compactMap { $0 }
            .max()
        if EnergyRefreshPolicy.shouldRefreshForForeground(
            generatedAt: freshestObservation,
            requestedSeconds: settings.refreshIntervalSeconds,
            now: now
        ) {
            refresh(forceCollection: false)
        }
        refreshCodexQuota(now: now)
        refreshCursorCodeSignal(now: now)
        refreshTokenRank()
    }

    func refreshForSourceChange() {
        refresh(forceCollection: false, ignoreAutomaticRetryTTL: true)
    }

    func setForegroundRefreshSurface(_ identifier: String, visible: Bool) {
        if visible {
            foregroundRefreshSurfaces.insert(identifier)
            refreshForForeground()
        } else {
            foregroundRefreshSurfaces.remove(identifier)
        }
        configureForegroundTimer()
    }

    func refreshCodexQuota(force: Bool = false, now: Date = Date()) {
        refreshCursorOfficialUsage(force: force, now: now)
        let providers = settings.enabledQuotaProviders
        guard !providers.isEmpty else {
            quotas = [:]
            isRefreshingCodexQuota = false
            return
        }
        guard !isRefreshingCodexQuota else { return }
        if !force,
           EnergyRefreshPolicy.isFresh(
               lastAttemptAt: lastQuotaRefreshAttemptAt,
               ttl: EnergyRefreshPolicy.quotaTTL,
               now: now
           ) {
            return
        }
        lastQuotaRefreshAttemptAt = now
        isRefreshingCodexQuota = true
        Task {
            let fetched = await Task.detached(priority: .utility) {
                QuotaRefreshCoordinator.fetch(providers: providers)
            }.value
            for provider in providers {
                if let quota = fetched[provider] {
                    if quota.isAvailable {
                        quotas[provider] = quota
                    } else if quotas[provider]?.isAvailable == true {
                        continue
                    } else {
                        quotas[provider] = quota
                    }
                } else if quotas[provider]?.isAvailable != true {
                    quotas[provider] = .unavailable(provider)
                }
            }
            quotas = quotas.filter { providers.contains($0.key) }
            isRefreshingCodexQuota = false
        }
    }

    func refreshCursorCodeSignal(force: Bool = false, now: Date = Date()) {
        guard settings.cursorCodeSignalEnabled else {
            cursorCodeSignal = nil
            cursorCodeSignalError = nil
            return
        }
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try CursorCodeSignalService.read() }
            }.value
            switch result {
            case let .success(signal):
                cursorCodeSignal = signal
                cursorCodeSignalError = nil
            case .failure:
                if cursorCodeSignal == nil {
                    cursorCodeSignalError = L("Cursor 代码产出暂不可用")
                }
            }
        }
    }

    var hasAnyQuota: Bool {
        visibleQuotas.contains(where: \.isAvailable)
    }

    var showsQuotaColumn: Bool {
        !visibleQuotas.isEmpty
    }

    var visibleQuotas: [ProviderQuota] {
        let items = QuotaProviderID.allCases.compactMap { id -> ProviderQuota? in
            guard settings.enabledQuotaProviders.contains(id) else { return nil }
            guard let quota = quotas[id], quota.shouldDisplay else { return nil }
            return quota
        }
        return items.sorted { lhs, rhs in
            let left = quotaSortRank(lhs)
            let right = quotaSortRank(rhs)
            if left != right { return left < right }
            return false
        }
    }

    var selectedQuota: ProviderQuota {
        let id = settings.resolvedQuotaProvider
        return quotas[id] ?? .unavailable(id, status: .unavailable, message: L("等待刷新"))
    }

    var selectedQuotaRemainingPercent: Double {
        QuotaPresentation.remainingPercent(
            selectedQuota,
            cursorMode: settings.cursorDisplayMode.resolved,
            kimiMode: settings.kimiDisplayMode
        )
    }

    var selectedQuotaDetail: String {
        QuotaPresentation.detail(
            selectedQuota,
            cursorMode: settings.cursorDisplayMode.resolved,
            kimiMode: settings.kimiDisplayMode
        )
    }

    var menuBarShowsQuotaRemaining: Bool {
        switch settings.menuBarRingMode {
        case .quotaRemaining, .tightestQuota:
            return settings.showCodexQuota
        case .tokenGoal:
            return false
        }
    }

    var menuBarQuota: ProviderQuota {
        if settings.menuBarRingMode == .tightestQuota {
            return tightestAvailableQuota ?? selectedQuota
        }
        return selectedQuota
    }

    var tightestAvailableQuota: ProviderQuota? {
        visibleQuotas
            .filter(\.isAvailable)
            .min { lhs, rhs in
                quotaRemainingPercent(lhs) < quotaRemainingPercent(rhs)
            }
    }

    var menuBarQuotaRemainingPercent: Double {
        quotaRemainingPercent(menuBarQuota)
    }

    var subscriptionMonthSummary: SubscriptionMonthSummary {
        SubscriptionLedger.summary(plans: settings.subscriptionPlans, snapshot: snapshot)
    }

    func subscriptionSummary(for provider: QuotaProviderID) -> SubscriptionMonthSummary? {
        SubscriptionLedger.providerSummary(
            provider: provider,
            plans: settings.subscriptionPlans,
            snapshot: snapshot
        )
    }

    var statusBarQuotaTitle: String {
        let quota = menuBarQuota
        let name = quota.provider.displayName
        switch quota.provider {
        case .cursor:
            return "\(name) · \(settings.cursorDisplayMode.resolved.title)"
        case .kimi:
            return "\(name) · \(settings.kimiDisplayMode.title)"
        default:
            return name
        }
    }

    private func quotaRemainingPercent(_ quota: ProviderQuota) -> Double {
        QuotaPresentation.remainingPercent(
            quota,
            cursorMode: settings.cursorDisplayMode.resolved,
            kimiMode: settings.kimiDisplayMode
        )
    }

    private func quotaSortRank(_ quota: ProviderQuota) -> Int {
        if quota.isAvailable && quota.isLow { return 0 }
        if !quota.isAvailable { return 1 }
        return 2
    }

    var hasLowQuotaWarning: Bool {
        visibleQuotas.contains { $0.isAvailable && $0.isLow }
    }

    var codexQuota: CodexQuotaSnapshot {
        quotas[.codex]?.asCodexSnapshot ?? .unavailable
    }

    var claudeQuota: CodexQuotaSnapshot {
        quotas[.claude]?.asCodexSnapshot ?? .unavailable
    }

    func quota(for tool: String) -> CodexQuotaSnapshot {
        if AgentSourceRegistry.matches(tool, family: "claude") {
            return claudeQuota
        }
        return codexQuota
    }

    func agentWork(for date: String) -> DailyAgentWork {
        snapshot.agentWork(for: date)
            ?? DailyAgentWork(
                date: date,
                totalTokens: 0,
                activeHours: 0,
                modelRequestCount: 0,
                toolCallCount: 0,
                sources: []
            )
    }

    func sevenDayAgentAverage(endingAt dateKey: String) -> Int {
        guard let endDate = DateFormatter.tokenStepDay.date(from: dateKey) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let total = (0..<7).reduce(0) { partial, offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: endDate) else {
                return partial
            }
            let key = DateFormatter.tokenStepDay.string(from: date)
            return partial + agentWork(for: key).totalTokens
        }
        return total / 7
    }

    func clearError() {
        lastError = nil
    }

    func dismissUsageRecalibrationNotice() {
        DataService.acknowledgeUsageRecalibrationNotice()
        showsUsageRecalibrationNotice = false
    }

    func refreshTokenIslandAvailability() {
        tokenIslandAvailable = TokenIslandDisplayDetector.isAvailable(for: settings.tokenIslandPlacement, size: TokenIslandWindowPresenter.collapsedSize)
    }

    func setGoal(_ tokens: Int) {
        settings.dailyGoalTokens = max(1_000_000, tokens)
        saveSettingsAndReload()
    }

    func setRefreshInterval(_ seconds: Int) {
        settings.refreshIntervalSeconds = seconds
        saveSettingsAndReload()
        configureTimer()
        configureForegroundTimer()
    }

    func setTheme(_ theme: TokenStepTheme) {
        TokenStepThemeRuntime.apply(theme)
        settings.theme = theme
        saveSettingsAndReload()
    }

    func setLanguage(_ language: TokenStepLanguage) {
        TokenStepLocalization.apply(language)
        settings.language = language
        saveSettingsAndReload()
        updateInstallStatus = L("准备更新")
    }

    func setTokenIslandEnabled(_ enabled: Bool) {
        setTokenIslandPlacement(enabled ? .automatic : .menuBar)
    }

    func setTokenIslandPlacement(_ placement: TokenIslandDisplayPlacement) {
        settings.tokenIslandPlacement = placement
        settings.tokenIslandEnabled = placement != .menuBar
        saveSettingsAndReload()
        refreshTokenIslandAvailability()
    }

    func setCodexQuotaVisible(_ visible: Bool) {
        if visible {
            settings.enabledQuotaProviders.formUnion([.codex, .claude])
        } else {
            settings.enabledQuotaProviders.subtract([.codex, .claude])
        }
        saveSettingsAndReload()
        if settings.showCodexQuota {
            refreshCodexQuota(force: true)
        } else {
            quotas = [:]
            isRefreshingCodexQuota = false
        }
    }

    func setQuotaProvider(_ id: QuotaProviderID, enabled: Bool, confirmNetworkAccess: Bool = true) {
        if enabled, id == .cursor, confirmNetworkAccess, !settings.cursorQuotaEnabled {
            let confirmed = confirmCursorNetworkAccess()
            if !confirmed { return }
        }
        settings.setQuotaProvider(id, enabled: enabled)
        saveSettingsAndReload()
        if settings.enabledQuotaProviders.isEmpty {
            quotas = [:]
            isRefreshingCodexQuota = false
            applyOverlays()
        } else {
            refreshCodexQuota(force: true)
        }
    }

    func hasQuotaSecret(_ id: QuotaProviderID) -> Bool {
        guard let account = id.secretAccount else { return false }
        return TokenStepSecrets.has(account)
    }

    func setSelectedQuotaProvider(_ id: QuotaProviderID) {
        if settings.resolvedQuotaProvider == id, settings.enabledQuotaProviders.contains(id) {
            return
        }
        settings.selectedQuotaProvider = id
        if !settings.enabledQuotaProviders.contains(id) {
            settings.setQuotaProvider(id, enabled: true)
        }
        saveSettingsAndReload()
        if quotas[id]?.isAvailable != true {
            refreshCodexQuota(force: true)
        }
    }

    func setCursorDisplayMode(_ mode: CursorDisplayMode) {
        settings.cursorDisplayMode = mode.resolved
        saveSettingsAndReload()
    }

    func setKimiDisplayMode(_ mode: KimiDisplayMode) {
        settings.kimiDisplayMode = mode
        saveSettingsAndReload()
    }

    func setMenuBarRingMode(_ mode: MenuBarRingMode) {
        settings.menuBarRingMode = mode
        saveSettingsAndReload()
    }

    func setSubscriptionPrice(_ provider: QuotaProviderID, price: Double) {
        settings.upsertSubscription(provider: provider, monthlyPrice: price)
        saveSettingsQuietly()
    }

    func setSubscriptionRenewalDay(_ provider: QuotaProviderID, day: Int) {
        let price = settings.subscriptionPlan(for: provider)?.monthlyPrice ?? 0
        settings.upsertSubscription(provider: provider, monthlyPrice: price, renewalDay: day)
        saveSettingsQuietly()
    }

    func setSubscriptionCurrency(_ provider: QuotaProviderID, currency: SubscriptionCurrency) {
        let price = settings.subscriptionPlan(for: provider)?.monthlyPrice ?? 0
        settings.upsertSubscription(provider: provider, monthlyPrice: price, currency: currency)
        saveSettingsQuietly()
    }

    func openQuotaDashboard(_ id: QuotaProviderID? = nil) {
        NSWorkspace.shared.open((id ?? settings.resolvedQuotaProvider).dashboardURL)
    }

    func importKimiWebAuth() {
        KimiWebAuth.clearStoredToken()
        if let token = KimiWebAuth.importFreshFromBrowsers() {
            do {
                try KimiWebAuth.saveStoredToken(token)
                kimiAuthHint = L("已导入可用的 Kimi 登录态")
                setQuotaProvider(.kimi, enabled: true, confirmNetworkAccess: false)
                refreshCodexQuota(force: true)
            } catch {
                kimiAuthHint = LFormat("保存失败：%@", error.localizedDescription)
            }
        } else {
            kimiAuthHint = L("自动导入失败。请先打开 Kimi 桌面版或在浏览器登录 kimi.com，再点导入；也可粘贴 kimi-auth")
            isQuotaPinned = true
            PinnedQuotaPanelController.shared.show(appState: self)
            NSWorkspace.shared.open(QuotaProviderID.kimi.dashboardURL)
        }
    }

    func savePastedKimiAuth(_ token: String) {
        do {
            try KimiWebAuth.saveStoredToken(token)
            kimiAuthHint = L("已保存网页登录态")
            setQuotaProvider(.kimi, enabled: true, confirmNetworkAccess: false)
            refreshCodexQuota(force: true)
        } catch {
            kimiAuthHint = LFormat("保存失败：%@", error.localizedDescription)
        }
    }

    func toggleQuotaPin() {
        isQuotaPinned.toggle()
        if isQuotaPinned {
            PinnedQuotaPanelController.shared.show(appState: self)
        } else {
            PinnedQuotaPanelController.shared.hide()
        }
    }

    func saveQuotaSecret(_ id: QuotaProviderID, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = id.secretAccount else { return }
        if id == .kimi, trimmed.lowercased().hasPrefix("sk-") {
            lastError = L("Kimi 需要 OAuth，不要用开放平台 key")
            return
        }
        if id == .grok, trimmed.lowercased().hasPrefix("xai-") {
            lastError = L("Grok 需要 grok login，普通 xAI key 无效")
            return
        }
        TokenStepSecrets.set(account, value: trimmed)
        objectWillChange.send()
        if !settings.enabledQuotaProviders.contains(id) {
            setQuotaProvider(id, enabled: true, confirmNetworkAccess: false)
        } else {
            refreshCodexQuota(force: true)
        }
    }

    func clearQuotaSecret(_ id: QuotaProviderID) {
        guard let account = id.secretAccount else { return }
        TokenStepSecrets.delete(account)
        objectWillChange.send()
        refreshCodexQuota(force: true)
    }

    func revealQuotaCredentialFolder(_ id: QuotaProviderID) {
        let relative: String
        switch id {
        case .kimi: relative = ".kimi"
        case .grok: relative = ".grok"
        default: return
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    func openGrokLoginInTerminal() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"grok login\""
        ]
        try? process.run()
    }

    func setCursorCodeSignalEnabled(_ enabled: Bool) {
        if enabled, !settings.cursorCodeSignalEnabled {
            let confirmed = confirmCursorLocalAccess()
            if !confirmed { return }
        }
        settings.cursorCodeSignalEnabled = enabled
        saveSettingsAndReload()
        refreshCursorCodeSignal(force: true)
    }

    func setHistoryDays(_ days: Int) {
        settings.historyDays = days
        saveSettingsAndReload()
        refresh()
    }

    func revealLocalDataInFinder() {
        let urls = [AppPaths.usageJSON, AppPaths.settingsJSON].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.appSupportRoot])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func clearLocalUsageData() {
        let alert = NSAlert()
        alert.messageText = L("确认清除本地用量数据？")
        alert.informativeText = L("将删除 usage.json 与本地缓存，设置会保留。下次同步会重新采集。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("清除"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let removable = [
            AppPaths.usageJSON,
            AppPaths.collectorCacheJSON,
            AppPaths.collectionCheckpointJSON,
            AppPaths.codexIncrementalCacheSQLite,
            AppPaths.claudeQuotaCacheJSON,
            AppPaths.cursorQuotaCacheJSON,
            AppPaths.cursorUsageCacheJSON,
            AppPaths.glmQuotaCacheJSON,
            AppPaths.kimiQuotaCacheJSON,
            AppPaths.grokQuotaCacheJSON
        ]
        for url in removable {
            try? FileManager.default.removeItem(at: url)
        }
        snapshot = .empty
        ledgerSnapshot = .empty
        quotas = [:]
        cursorCodeSignal = nil
        lastError = L("已清除本地用量数据")
        refresh(forceCollection: true)
    }

    @discardableResult
    private func confirmCursorNetworkAccess() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("开启 Cursor 额度？")
        alert.informativeText = L("会只读本机 Cursor 登录态，向 cursor.com 查询两档额度和官方用量事件。用量事件会计入圆环。登录态不落盘、不上传第三方。该接口非官方，可能随时失效。")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("开启"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @discardableResult
    private func confirmCursorLocalAccess() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("开启 Cursor 代码产出？")
        alert.informativeText = L("只读取本机 ai_code_hashes 的计数与模型名，不读取代码、摘要或文件路径。该表每天会被 Cursor 清空，AIQuota 不做历史留存。")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("开启"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func setAgentWorkRankVisibility(_ visibility: AgentWorkRankVisibility) {
        settings.agentWorkRankVisibility = visibility
        saveSettingsAndReload()
        if shouldShowAgentWorkRank {
            refreshTokenRank(force: true)
        } else {
            clearTokenRankState()
        }
    }

    func setExperimentalAgentSourcesVisible(_ visible: Bool) {
        settings.showExperimentalAgentSources = visible
        saveSettingsAndReload()
        refresh()
    }

    func refreshTokenRank(force: Bool = false, now: Date = Date()) {
        guard settings.agentWorkRankVisibility.readsLocalIdentity else {
            clearTokenRankState()
            return
        }
        agentWorkRankIdentity = AgentWorkRankService.loadLocalIdentity()
        guard shouldShowAgentWorkRank else {
            clearTokenRankState()
            return
        }
        guard !isRefreshingTokenRank else { return }
        if !force {
            if EnergyRefreshPolicy.isFresh(
                lastAttemptAt: lastRankRefreshAttemptAt,
                ttl: EnergyRefreshPolicy.rankTTL,
                now: now
            ) {
                return
            }
            if let fetchedAt = tokenRank?.fetchedAt,
               now.timeIntervalSince(fetchedAt) < AgentWorkRankService.cacheTTL {
                return
            }
        }
        lastRankRefreshAttemptAt = now

        agentWorkRankIdentity = AgentWorkRankService.loadLocalIdentity()
        isRefreshingTokenRank = true
        Task {
            defer {
                isRefreshingTokenRank = false
            }
            do {
                let leaderboard = try await AgentWorkRankService.fetchLeaderboard()
                guard shouldShowAgentWorkRank else {
                    clearTokenRankState()
                    return
                }
                tokenRank = leaderboard
                tokenRankError = nil
            } catch {
                guard shouldShowAgentWorkRank else {
                    clearTokenRankState()
                    return
                }
                if tokenRank == nil {
                    tokenRankError = L("暂时无法读取榜单")
                } else {
                    tokenRankError = L("榜单同步失败，显示上次结果")
                }
            }
        }
    }

    func openTokenRankLeaderboardPage() {
        NSWorkspace.shared.open(AgentWorkRankService.leaderboardPageURL)
    }

    func openTokenRankUserPage() {
        NSWorkspace.shared.open(AgentWorkRankService.myPageURL)
    }

    func setAutoUpdateEnabled(_ enabled: Bool) {
        settings.autoUpdateEnabled = enabled
        saveSettingsAndReload()
        if enabled {
            checkForUpdates(silent: true)
        }
    }

    func setAskBeforeDownloadingUpdates(_ enabled: Bool) {
        settings.askBeforeDownloadingUpdates = enabled
        saveSettingsAndReload()
    }

    func setRequireVerifiedUpdates(_ enabled: Bool) {
        settings.requireVerifiedUpdates = enabled
        saveSettingsAndReload()
    }

    func setAutostart(_ enabled: Bool) {
        do {
            try AutostartService.setEnabled(enabled)
            try markAutostartDefaultApplied()
            autostartEnabled = AutostartService.isEnabled
        } catch {
            lastError = error.localizedDescription
        }
    }

    func checkForUpdates(silent: Bool = false) {
        guard !isCheckingForUpdates else { return }
        guard settings.autoUpdateEnabled || !silent else { return }
        isCheckingForUpdates = true
        if !silent {
            lastError = nil
        }
        Task {
            do {
                let result = try await UpdateService.checkForUpdates()
                lastUpdateCheckAt = Date()
                switch result {
                case .upToDate:
                    availableUpdate = nil
                case let .available(update):
                    availableUpdate = settings.skippedUpdateVersion == update.version ? nil : update
                }
            } catch {
                if !silent {
                    lastError = error.localizedDescription
                }
            }
            isCheckingForUpdates = false
        }
    }

    func showUpdateDetails() {
        guard let availableUpdate else {
            checkForUpdates(silent: false)
            return
        }
        UpdateWindowPresenter.shared.show(appState: self, update: availableUpdate)
    }

    func installAvailableUpdate() {
        guard let update = availableUpdate, !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        updateDownloadProgress = 0
        updateInstallStatus = L("正在下载")
        updateDownloadedURL = nil
        lastError = nil
        Task {
            do {
                let url = try await UpdateService.downloadAndInstall(
                    update,
                    requireVerified: settings.requireVerifiedUpdates
                ) { [weak self] progress in
                    self?.updateDownloadProgress = progress
                }
                updateDownloadedURL = url
                updateDownloadProgress = 1
                updateInstallStatus = L("正在安装并重启")
            } catch {
                lastError = error.localizedDescription
                updateInstallStatus = L("更新失败")
                isDownloadingUpdate = false
            }
        }
    }

    func postponeUpdateNotice() {
        availableUpdate = nil
    }

    func skipAvailableUpdate() {
        guard let version = availableUpdate?.version else { return }
        settings.skippedUpdateVersion = version
        availableUpdate = nil
        saveSettingsAndReload()
    }

    func refreshCursorOfficialUsage(force: Bool = false, now: Date = Date()) {
        applyOverlays()
        guard settings.cursorQuotaEnabled else { return }
        guard !isRefreshingCursorUsage else { return }
        if !force,
           EnergyRefreshPolicy.isFresh(
               lastAttemptAt: lastCursorUsageRefreshAttemptAt,
               ttl: EnergyRefreshPolicy.quotaTTL,
               now: now
           ) {
            return
        }
        lastCursorUsageRefreshAttemptAt = now
        isRefreshingCursorUsage = true
        let historyDays = settings.historyDays
        Task {
            _ = await Task.detached(priority: .utility) {
                Result { try CursorUsageService.refresh(historyDays: historyDays) }
            }.value
            applyOverlays()
            isRefreshingCursorUsage = false
        }
    }

    func refreshUsageSync(force: Bool = false, now: Date = Date()) {
        guard settings.usageSyncEnabled else {
            remoteMachines = []
            usageSyncError = nil
            applyOverlays()
            return
        }
        guard !isSyncingUsage else { return }
        if !force,
           EnergyRefreshPolicy.isFresh(
               lastAttemptAt: lastUsageSyncAttemptAt,
               ttl: EnergyRefreshPolicy.usageSyncTTL,
               now: now
           ) {
            return
        }
        lastUsageSyncAttemptAt = now
        isSyncingUsage = true
        let remoteURLString = settings.usageSyncRemoteURL
        let localSnapshot = ledgerSnapshot
        let historyDays = settings.historyDays
        Task {
            do {
                let others = try await Task.detached(priority: .utility) {
                    try UsageSyncService.sync(
                        remoteURLString: remoteURLString,
                        localSnapshot: localSnapshot,
                        historyDays: historyDays
                    )
                }.value
                remoteMachines = others
                lastUsageSyncAt = Date()
                usageSyncError = nil
            } catch {
                usageSyncError = error.localizedDescription
            }
            isSyncingUsage = false
            applyOverlays()
        }
    }

    func setUsageSyncEnabled(_ enabled: Bool) {
        settings.usageSyncEnabled = enabled
        saveSettingsAndReload()
        if enabled {
            refreshUsageSync(force: true)
        } else {
            remoteMachines = []
            usageSyncError = nil
            lastUsageSyncAt = nil
            historyDeviceFilter = .all
            applyOverlays()
        }
    }

    func exportUsageNow(directory: URL? = nil) {
        let folder: URL
        if let directory {
            folder = directory
        } else if let chosen = chooseExportFolder() {
            folder = chosen
            settings.usageExportFolder = chosen.path
            saveSettingsAndReload()
        } else {
            return
        }
        do {
            _ = try UsageExportService.export(snapshot: ledgerSnapshot, to: folder)
            lastUsageExportAt = Date()
            usageExportError = nil
        } catch {
            usageExportError = error.localizedDescription
        }
    }

    func setUsageExportFolder(_ folder: String) {
        settings.usageExportFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.usageExportFolder.isEmpty {
            settings.usageExportAutoEnabled = false
        }
        saveSettingsAndReload()
    }

    func setUsageExportAutoEnabled(_ enabled: Bool) {
        if enabled, settings.usageExportFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let folder = chooseExportFolder() else { return }
            settings.usageExportFolder = folder.path
        }
        settings.usageExportAutoEnabled = enabled && !settings.usageExportFolder.isEmpty
        saveSettingsAndReload()
        if settings.usageExportAutoEnabled {
            exportUsageNow(directory: URL(fileURLWithPath: settings.usageExportFolder, isDirectory: true))
        }
    }

    func chooseAndSetUsageExportFolder() {
        guard let folder = chooseExportFolder() else { return }
        settings.usageExportFolder = folder.path
        saveSettingsAndReload()
        if settings.usageExportAutoEnabled {
            exportUsageNow(directory: folder)
        }
    }

    @discardableResult
    private func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("选择文件夹")
        panel.message = L("只导出 token 计数和估算金额，不含设备名、账号或额度凭证。")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    private func startUsageSourceWatcher() {
        usageSourceWatcher.start()
    }

    func setUsageSyncRemoteURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.usageSyncRemoteURL = trimmed.isEmpty ? TokenStepSettings.defaultUsageSyncRemoteURL : trimmed
        saveSettingsAndReload()
        if settings.usageSyncEnabled {
            refreshUsageSync(force: true)
        }
    }

    private func applyOverlays() {
        applyCursorOfficialUsageOverlay()
        localHistoryDaily = CursorUsageService.localDeviceDaily(
            from: ledgerSnapshot,
            officialDays: settings.cursorQuotaEnabled ? (CursorUsageService.readCache()?.days ?? []) : []
        )
        sanitizeHistoryDeviceFilter()
        guard settings.usageSyncEnabled else { return }
        let remoteDaily = HistoryDevicePresentation.mergedDaily(
            from: remoteMachines.map { SyncedMachineLedger(remote: $0) }
        )
        guard !remoteDaily.isEmpty else { return }
        snapshot = Self.mergingOthersDaily(remoteDaily, into: snapshot)
    }

    private func sanitizeHistoryDeviceFilter() {
        guard case let .machine(id) = historyDeviceFilter else { return }
        if !historyDevices.contains(where: { $0.machineId == id }) {
            historyDeviceFilter = .all
        }
    }

    private func applyCursorOfficialUsageOverlay() {
        guard settings.cursorQuotaEnabled,
              let cache = CursorUsageService.readCache(),
              cache.days.contains(where: { $0.totalTokens > 0 })
        else {
            snapshot = ledgerSnapshot
            return
        }
        snapshot = CursorUsageService.merge(ledgerSnapshot, days: cache.days)
    }

    private static func mergingOthersDaily(_ othersDaily: [DailyUsage], into snapshot: UsageSnapshot) -> UsageSnapshot {
        var dailyByDate = Dictionary(uniqueKeysWithValues: snapshot.daily.map { ($0.date, $0) })
        for other in othersDaily {
            var day = dailyByDate[other.date] ?? DailyUsage(date: other.date, tools: [:], totalTokens: 0, cost: 0)
            day.totalTokens += other.totalTokens
            day.cost += other.cost
            day.equivalentCost += other.equivalentCost
            for (tool, tokens) in other.tools {
                day.tools[tool, default: 0] += tokens
            }
            for (model, tokens) in other.models {
                day.models[model, default: 0] += tokens
            }
            for (tool, models) in other.modelsByTool {
                for (model, tokens) in models {
                    day.modelsByTool[tool, default: [:]][model, default: 0] += tokens
                }
            }
            for (model, cost) in other.modelCosts {
                day.modelCosts[model, default: 0] += cost
            }
            for (tool, cost) in other.toolCosts {
                day.toolCosts[tool, default: 0] += cost
            }
            dailyByDate[other.date] = day
        }
        let daily = dailyByDate.values.sorted { $0.date < $1.date }
        var merged = snapshot
        merged.daily = daily
        merged.totals = UsageTotals(
            tokens: daily.map(\.totalTokens).reduce(0, +),
            cost: daily.map(\.displayCost).reduce(0, +),
            activeDays: daily.filter { $0.totalTokens > 0 }.count
        )
        return merged
    }

    private func saveSettingsAndReload() {
        do {
            try DataService.saveSettings(settings)
            let loadedSettings = DataService.loadSettings()
            TokenStepLocalization.apply(loadedSettings.language)
            TokenStepThemeRuntime.apply(loadedSettings.theme)
            settings = loadedSettings
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func saveSettingsQuietly() {
        do {
            try DataService.saveSettings(settings)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func clearTokenRankState() {
        tokenRank = nil
        agentWorkRankIdentity = nil
        tokenRankError = nil
        isRefreshingTokenRank = false
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        guard let interval = EnergyRefreshPolicy.backgroundInterval(
            requestedSeconds: settings.refreshIntervalSeconds,
            powerSource: TokenStepPowerState.source,
            lowPowerMode: TokenStepPowerState.lowPowerModeEnabled
        ) else {
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(forceCollection: false)
                self.refreshCodexQuota()
                self.refreshCursorCodeSignal()
                self.refreshTokenRank()
                self.configureTimer()
            }
        }
        timer?.tolerance = min(TimeInterval(interval) * 0.1, 60)
    }

    private func configureForegroundTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
        guard !foregroundRefreshSurfaces.isEmpty,
              let interval = EnergyRefreshPolicy.foregroundTickInterval(
                  requestedSeconds: settings.refreshIntervalSeconds
              )
        else {
            return
        }
        foregroundTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(interval),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshForForeground()
                self.configureForegroundTimer()
            }
        }
        foregroundTimer?.tolerance = min(TimeInterval(interval) * 0.1, 10)
    }

    private func refreshIfSnapshotIsStale() {
        guard let reason = UsageSnapshotRefreshPolicy.reason(
            snapshot: snapshot,
            refreshIntervalSeconds: settings.refreshIntervalSeconds,
            now: Date()
        ) else {
            return
        }

        if reason == .accountingRevision {
            let storedRevision = snapshot.sources["Codex"]?.accountingRevision
                .map(String.init) ?? "legacy"
            LifecycleLogger.log(
                "Codex accounting revision \(storedRevision) is older than "
                    + "\(UsageCollector.codexAccountingRevision); starting immediate recalibration."
            )
        }
        refresh(forceCollection: reason != .stale)
    }

    private func scheduleDeferredUpdateCheck() {
        guard settings.autoUpdateEnabled else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            checkForUpdatesIfNeeded()
        }
    }

    private func checkForUpdatesIfNeeded() {
        guard settings.autoUpdateEnabled else { return }
        checkForUpdates(silent: true)
    }

    private func applyDefaultAutostartIfNeeded() {
        repairAutostartIfNeeded()
        guard !FileManager.default.fileExists(atPath: AppPaths.autostartDefaultMarker.path) else { return }
        guard AutostartService.canEnableForCurrentBundle else {
            autostartEnabled = AutostartService.isEnabled
            return
        }
        do {
            if !AutostartService.isEnabled {
                try AutostartService.setEnabled(true)
            }
            try markAutostartDefaultApplied()
            autostartEnabled = AutostartService.isEnabled
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func repairAutostartIfNeeded() {
        guard AutostartService.needsRepairForCurrentBundle else {
            autostartEnabled = AutostartService.isEnabled
            return
        }
        do {
            if try AutostartService.repairForCurrentBundleIfNeeded() {
                try markAutostartDefaultApplied()
            }
            autostartEnabled = AutostartService.isEnabled
        } catch {
            LifecycleLogger.log("Failed to repair login item target: \(error.localizedDescription)")
            lastError = error.localizedDescription
            autostartEnabled = AutostartService.isEnabled
        }
    }

    private func markAutostartDefaultApplied() throws {
        try FileManager.default.createDirectory(
            at: AppPaths.autostartDefaultMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("applied\n".utf8).write(to: AppPaths.autostartDefaultMarker, options: .atomic)
    }
}

enum UsageSnapshotRefreshReason: Equatable {
    case accountingRevision
    case missingModelBreakdown
    case missingSnapshotTimestamp
    case stale
}

enum UsageSnapshotRefreshPolicy {
    static func reason(
        snapshot: UsageSnapshot,
        refreshIntervalSeconds: Int,
        now: Date
    ) -> UsageSnapshotRefreshReason? {
        if DataService.requiresImmediateCodexRecalibration(snapshot) {
            return .accountingRevision
        }
        if snapshot.daily.contains(where: { $0.totalTokens > 0 && $0.models.isEmpty }) {
            return .missingModelBreakdown
        }
        guard refreshIntervalSeconds > 0 else {
            return snapshot.generatedAt == nil ? .missingSnapshotTimestamp : nil
        }
        guard let generatedDate = generatedDate(snapshot.generatedAt)
        else {
            return .missingSnapshotTimestamp
        }
        if now.timeIntervalSince(generatedDate) >= TimeInterval(refreshIntervalSeconds) {
            return .stale
        }
        return nil
    }

    static func generatedDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = generatedAtISOWithFractional.date(from: value) {
            return date
        }
        return generatedAtISO.date(from: value)
    }

    private static let generatedAtISOWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let generatedAtISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
