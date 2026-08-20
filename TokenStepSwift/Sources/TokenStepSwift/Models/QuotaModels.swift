import Foundation

enum QuotaProviderID: String, Codable, CaseIterable, Identifiable, Hashable {
    case codex
    case claude
    case cursor
    case glm
    case kimi
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .glm: return "GLM"
        case .kimi: return "Kimi"
        case .grok: return "Grok"
        }
    }

    var credentialHint: String {
        switch self {
        case .codex: return L("读取本机 Codex 登录态")
        case .claude: return L("读取 Keychain 中的 Claude OAuth")
        case .cursor: return L("两档额度 + 官方用量事件计入圆环")
        case .glm: return L("填写 Coding Plan API Key，只进钥匙串")
        case .kimi: return L("网页 kimi-auth 或 ~/.kimi access_token，不要用开放平台 key")
        case .grok: return L("读取 ~/.grok/auth.json，短码不要贴到 AIQuota")
        }
    }

    var dashboardURL: URL {
        switch self {
        case .codex:
            return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .claude:
            return URL(string: "https://claude.ai/settings/usage")!
        case .cursor:
            return URL(string: "https://cursor.com/dashboard/spending")!
        case .glm:
            return URL(string: "https://open.bigmodel.cn/usercenter/plan")!
        case .kimi:
            return URL(string: "https://www.kimi.com/membership/subscription?tab=quota")!
        case .grok:
            return URL(string: "https://grok.com/?_s=usage")!
        }
    }
}

enum CursorDisplayMode: String, Codable, CaseIterable, Identifiable {
    case included
    case cursorModels
    case otherModels

    var id: String { rawValue }

    static var statusBarCases: [CursorDisplayMode] { [.included, .cursorModels, .otherModels] }

    var resolved: CursorDisplayMode { self }

    var title: String {
        switch self {
        case .included: return L("总体")
        case .cursorModels: return "Cursor Models"
        case .otherModels: return "Other Models"
        }
    }
}

enum KimiDisplayMode: String, Codable, CaseIterable, Identifiable {
    case membership
    case code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .membership: return L("总体")
        case .code: return L("Kimi Code")
        }
    }
}

enum MenuBarRingMode: String, Codable, CaseIterable, Identifiable {
    case tokenGoal
    case quotaRemaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokenGoal: return L("Token 目标")
        case .quotaRemaining: return L("额度剩余")
        }
    }
}

struct QuotaMetrics: Equatable, Codable, Sendable {
    var cursorIncludedUsed: Double? = nil
    var cursorModelsUsed: Double? = nil
    var otherModelsUsed: Double? = nil
    var cursorSpendDollars: Double? = nil
    var cursorLimitDollars: Double? = nil
    var kimiMembershipUsed: Double? = nil
    var kimiCodeUsed: Double? = nil
    var grokWeeklyUsed: Double? = nil
    var grokBuildUsed: Double? = nil
    var grokImagineUsed: Double? = nil
    var grokChatUsed: Double? = nil
    var grokVoiceUsed: Double? = nil
    var grokApiUsed: Double? = nil
    var grokBotUsed: Double? = nil
}

enum QuotaWindowKind: String, Codable, Equatable {
    case fiveHour
    case sevenDay
    case thirtyDay
    case session
    case weekly
    case monthlyCredits
    case tokenWindow
    case spend
    case cursorModels
    case otherModels

    var title: String {
        switch self {
        case .fiveHour: return L("5 小时")
        case .sevenDay: return L("7 天")
        case .thirtyDay: return L("30 天")
        case .session: return L("会话")
        case .weekly: return L("本周")
        case .monthlyCredits: return L("本月额度")
        case .tokenWindow: return L("Token 窗")
        case .spend: return L("花费")
        case .cursorModels: return L("Cursor 模型")
        case .otherModels: return L("其他模型")
        }
    }

    var shortTitle: String {
        switch self {
        case .fiveHour: return L("5小时")
        case .sevenDay: return L("7天")
        case .thirtyDay: return L("30天")
        case .session: return L("会话")
        case .weekly: return L("本周")
        case .monthlyCredits: return L("本月")
        case .tokenWindow: return L("Token")
        case .spend: return L("花费")
        case .cursorModels: return L("自有")
        case .otherModels: return L("其他")
        }
    }

    var badgeLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        case .thirtyDay: return "30d"
        case .session: return L("会话")
        case .weekly: return L("本周")
        case .monthlyCredits: return L("本月")
        case .tokenWindow: return "Tok"
        case .spend: return L("花费")
        case .cursorModels: return L("自有")
        case .otherModels: return L("其他")
        }
    }

    var sortOrder: Int {
        switch self {
        case .fiveHour: return 0
        case .sevenDay: return 1
        case .thirtyDay: return 2
        case .session: return 3
        case .weekly: return 4
        case .monthlyCredits: return 5
        case .tokenWindow: return 6
        case .spend: return 7
        case .cursorModels: return 8
        case .otherModels: return 9
        }
    }
}

enum QuotaStatus: String, Codable, Equatable {
    case available
    case unavailable
    case notLoggedIn
    case wrongKeyType
    case needsLogin
}

struct QuotaWindow: Equatable, Identifiable, Codable {
    var kind: QuotaWindowKind
    var usedPercent: Double
    var remaining: Double?
    var total: Double?
    var resetsAt: Date?
    var title: String? = nil

    var id: String {
        "\(kind.rawValue)-\(title ?? "")-\(resetsAt?.timeIntervalSince1970 ?? 0)"
    }

    var remainingPercent: Double {
        if let remaining, let total, total > 0 {
            return min(max(remaining / total * 100, 0), 100)
        }
        return min(max(100 - usedPercent, 0), 100)
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return kind.title
    }

    var isLow: Bool {
        remainingPercent < 20
    }
}

struct ProviderQuota: Equatable, Identifiable, Codable {
    var provider: QuotaProviderID
    var windows: [QuotaWindow]
    var status: QuotaStatus
    var fetchedAt: Date?
    var message: String?
    var planName: String? = nil
    var detail: String? = nil
    var metrics: QuotaMetrics? = nil

    var id: String { provider.rawValue }

    var isAvailable: Bool {
        status == .available && !windows.isEmpty
    }

    var shouldDisplay: Bool {
        isAvailable
    }

    var cursorOfficialWindows: [QuotaWindow] {
        windows.filter { $0.kind == .cursorModels || $0.kind == .otherModels }
    }

    var grokDisplayWindows: [QuotaWindow] {
        let sharedTitles: Set<String> = ["本周共用", L("本周共用"), "Shared this week"]
        let shared = windows.filter { window in
            guard let title = window.title, !title.isEmpty else { return true }
            return sharedTitles.contains(title)
        }
        if let window = shared.first {
            return [window]
        }
        if let weekly = windows.first(where: { $0.kind == .weekly || $0.kind == .monthlyCredits }) {
            return [weekly]
        }
        return Array(windows.prefix(1))
    }

    var lowestRemainingPercent: Double? {
        windows.map(\.remainingPercent).min()
    }

    var isLow: Bool {
        windows.contains(where: \.isLow)
    }

    static func unavailable(
        _ provider: QuotaProviderID,
        status: QuotaStatus = .unavailable,
        fetchedAt: Date? = nil,
        message: String? = nil
    ) -> ProviderQuota {
        ProviderQuota(
            provider: provider,
            windows: [],
            status: status,
            fetchedAt: fetchedAt,
            message: message
        )
    }

    var asCodexSnapshot: CodexQuotaSnapshot {
        CodexQuotaSnapshot(
            fetchedAt: fetchedAt,
            fiveHour: windows.first(where: { $0.kind == .fiveHour }).map {
                CodexQuotaWindow(kind: .fiveHour, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
            },
            sevenDay: windows.first(where: { $0.kind == .sevenDay }).map {
                CodexQuotaWindow(kind: .sevenDay, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
            }
        )
    }
}

extension CodexQuotaSnapshot {
    func asProviderQuota(_ provider: QuotaProviderID) -> ProviderQuota {
        var windows: [QuotaWindow] = []
        if let fiveHour {
            windows.append(
                QuotaWindow(
                    kind: .fiveHour,
                    usedPercent: fiveHour.usedPercent,
                    remaining: fiveHour.remainingPercent,
                    total: 100,
                    resetsAt: fiveHour.resetsAt
                )
            )
        }
        if let sevenDay {
            windows.append(
                QuotaWindow(
                    kind: .sevenDay,
                    usedPercent: sevenDay.usedPercent,
                    remaining: sevenDay.remainingPercent,
                    total: 100,
                    resetsAt: sevenDay.resetsAt
                )
            )
        }
        let detail = windows
            .map { String(format: "%@ %.0f%% used", $0.kind.badgeLabel, $0.usedPercent) }
            .joined(separator: " · ")
        return ProviderQuota(
            provider: provider,
            windows: windows,
            status: isAvailable ? .available : .unavailable,
            fetchedAt: fetchedAt,
            message: isAvailable ? nil : L("暂不可用"),
            planName: planName,
            detail: detail.isEmpty ? nil : detail
        )
    }
}

enum QuotaPresentation {
    static func remainingPercent(
        _ quota: ProviderQuota,
        cursorMode: CursorDisplayMode,
        kimiMode: KimiDisplayMode
    ) -> Double {
        guard quota.isAvailable else { return 0 }
        if let used = usedPercent(quota, cursorMode: cursorMode, kimiMode: kimiMode) {
            return max(0, min(100, 100 - used))
        }
        return quota.lowestRemainingPercent ?? 0
    }

    static func detail(
        _ quota: ProviderQuota,
        cursorMode: CursorDisplayMode,
        kimiMode: KimiDisplayMode
    ) -> String {
        if let message = quota.message, !quota.isAvailable {
            return message
        }
        switch quota.provider {
        case .cursor:
            return cursorDetail(quota, mode: cursorMode)
        case .kimi:
            return kimiDetail(quota, mode: kimiMode)
        case .grok:
            return quota.detail ?? quota.grokDisplayWindows
                .map { String(format: "%@ %.0f%% used", $0.displayTitle, $0.usedPercent) }
                .joined(separator: " · ")
        default:
            return quota.detail ?? quota.windows
                .map { String(format: "%@ %.0f%% used", $0.kind.badgeLabel, $0.usedPercent) }
                .joined(separator: " · ")
        }
    }

    static func usedPercent(
        _ quota: ProviderQuota,
        cursorMode: CursorDisplayMode,
        kimiMode: KimiDisplayMode
    ) -> Double? {
        switch quota.provider {
        case .cursor:
            switch cursorMode {
            case .included:
                return quota.metrics?.cursorIncludedUsed
                    ?? quota.windowUsed(titled: "总体")
                    ?? quota.metrics?.cursorModelsUsed
                    ?? quota.windowUsed(kind: .cursorModels)
                    ?? quota.metrics?.otherModelsUsed
            case .otherModels:
                return quota.metrics?.otherModelsUsed
                    ?? quota.windowUsed(kind: .otherModels)
                    ?? quota.metrics?.cursorIncludedUsed
                    ?? quota.metrics?.cursorModelsUsed
            case .cursorModels:
                return quota.metrics?.cursorModelsUsed
                    ?? quota.windowUsed(kind: .cursorModels)
                    ?? quota.metrics?.cursorIncludedUsed
                    ?? quota.metrics?.otherModelsUsed
            }
        case .kimi:
            switch kimiMode {
            case .membership:
                return quota.metrics?.kimiMembershipUsed
                    ?? quota.windowUsed(kind: .monthlyCredits)
                    ?? quota.metrics?.kimiCodeUsed
            case .code:
                return quota.metrics?.kimiCodeUsed
                    ?? quota.codeWindows.map(\.usedPercent).max()
                    ?? quota.metrics?.kimiMembershipUsed
            }
        case .grok:
            return quota.metrics?.grokWeeklyUsed
                ?? quota.grokDisplayWindows.map(\.usedPercent).max()
                ?? quota.windows.map(\.usedPercent).max()
        default:
            return quota.windows.map(\.usedPercent).max()
        }
    }

    private static func cursorDetail(_ quota: ProviderQuota, mode: CursorDisplayMode) -> String {
        var parts: [String] = []
        if let spend = quota.metrics?.cursorSpendDollars, let limit = quota.metrics?.cursorLimitDollars, limit > 0 {
            parts.append(String(format: "$%.2f / $%.0f", spend, limit))
        } else if let spend = quota.metrics?.cursorSpendDollars {
            parts.append(String(format: "$%.2f", spend))
        }
        switch mode {
        case .included:
            if let used = quota.metrics?.cursorIncludedUsed {
                parts.append(String(format: "总体 %.0f%% used", used))
            }
        case .cursorModels:
            if let used = quota.metrics?.cursorModelsUsed ?? quota.windowUsed(kind: .cursorModels) {
                parts.append(String(format: "Cursor Models %.0f%% used", used))
            }
        case .otherModels:
            if let used = quota.metrics?.otherModelsUsed ?? quota.windowUsed(kind: .otherModels) {
                parts.append(String(format: "Other Models %.0f%% used", used))
            }
        }
        if mode != .cursorModels, let used = quota.metrics?.cursorModelsUsed ?? quota.windowUsed(kind: .cursorModels) {
            parts.append(String(format: "Cursor Models %.0f%%", used))
        }
        if mode != .otherModels, let used = quota.metrics?.otherModelsUsed ?? quota.windowUsed(kind: .otherModels) {
            parts.append(String(format: "Other Models %.0f%%", used))
        }
        if mode != .included, let used = quota.metrics?.cursorIncludedUsed {
            parts.append(String(format: "总体 %.0f%%", used))
        }
        if parts.isEmpty, let fallback = quota.detail {
            return fallback
        }
        return parts.joined(separator: " · ")
    }

    private static func kimiDetail(_ quota: ProviderQuota, mode: KimiDisplayMode) -> String {
        switch mode {
        case .membership:
            if let used = quota.metrics?.kimiMembershipUsed ?? quota.windowUsed(kind: .monthlyCredits) {
                var parts = [String(format: "总使用量 %.2f%%", used)]
                if let code = quota.metrics?.kimiCodeUsed ?? quota.codeWindows.map(\.usedPercent).max() {
                    parts.append(String(format: "Code %.0f%% used", code))
                }
                return parts.joined(separator: " · ")
            }
        case .code:
            var parts: [String] = []
            for window in quota.codeWindows.sorted(by: { $0.kind.sortOrder < $1.kind.sortOrder }) {
                parts.append(String(format: "%@ %.0f%% used", window.kind.badgeLabel, window.usedPercent))
            }
            if parts.isEmpty, let code = quota.metrics?.kimiCodeUsed {
                parts.append(String(format: "Code %.0f%% used", code))
            }
            if let membership = quota.metrics?.kimiMembershipUsed ?? quota.windowUsed(kind: .monthlyCredits) {
                parts.append(String(format: "总体 %.2f%%", membership))
            }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        return quota.detail ?? ""
    }
}

private extension ProviderQuota {
    var codeWindows: [QuotaWindow] {
        windows.filter { ($0.title ?? "").localizedCaseInsensitiveContains("code") }
    }

    func windowUsed(kind: QuotaWindowKind) -> Double? {
        windows.first(where: { $0.kind == kind })?.usedPercent
    }

    func windowUsed(titled title: String) -> Double? {
        windows.first(where: { $0.title == title })?.usedPercent
    }
}

enum QuotaResetFormat {
    static func absolute(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = TokenStepLocalization.locale
        if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "MM-dd HH:mm"
        } else if calendar.dateComponents([.day], from: Date(), to: date).day ?? 99 <= 14 {
            formatter.dateFormat = "MM-dd HH:mm"
        } else {
            formatter.dateFormat = "yyyy-MM-dd"
        }
        return formatter.string(from: date)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "已重置" }
        let hours = Int(seconds / 3600)
        if hours < 48 {
            let h = max(1, hours)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            if hours < 1 { return "\(max(1, minutes))m" }
            if h < 24 { return minutes > 0 ? "\(h)h \(minutes)m" : "\(h)h" }
            return "\(h / 24)d \(h % 24)h"
        }
        let days = Int((seconds / 86400).rounded(.up))
        return "\(days)d"
    }
}

struct QuotaPace: Equatable {
    enum Kind: String, Equatable {
        case onPace
        case deficit
        case reserve
    }

    var kind: Kind
    var deltaPercent: Double
    var expectedUsedPercent: Double
    var elapsedFraction: Double
    var eta: Date?
    var lastsUntilReset: Bool

    var compactDelta: String {
        let value = Int(abs(deltaPercent).rounded())
        switch kind {
        case .onPace: return "0%"
        case .deficit: return "+\(value)%"
        case .reserve: return "-\(value)%"
        }
    }

    func summary(resetsAt: Date?, now: Date = Date()) -> String {
        switch kind {
        case .onPace:
            return L("节奏正常")
        case .deficit:
            if let eta {
                return LFormat("%d%% 超速 · 预计 %@ 后用完", Int(abs(deltaPercent).rounded()), QuotaResetFormat.relative(eta, now: now))
            }
            return LFormat("%d%% 超速", Int(abs(deltaPercent).rounded()))
        case .reserve:
            return lastsUntilReset
                ? LFormat("%d%% 有余量 · 能撑到重置", Int(abs(deltaPercent).rounded()))
                : LFormat("%d%% 有余量", Int(abs(deltaPercent).rounded()))
        }
    }
}

enum QuotaPaceCalculator {
    static func windowDuration(for kind: QuotaWindowKind) -> TimeInterval? {
        switch kind {
        case .fiveHour: return 5 * 3600
        case .sevenDay, .weekly: return 7 * 24 * 3600
        case .thirtyDay, .monthlyCredits: return 30 * 24 * 3600
        default: return nil
        }
    }

    static func pace(
        usedPercent: Double,
        resetsAt: Date?,
        kind: QuotaWindowKind,
        now: Date = Date()
    ) -> QuotaPace? {
        guard let duration = windowDuration(for: kind), let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = duration - remaining
        guard duration > 0, elapsed > 0 else { return nil }
        let fraction = min(max(elapsed / duration, 0), 1)
        guard fraction >= 0.03 else { return nil }

        let used = min(max(usedPercent, 0), 100)
        let expected = fraction * 100
        let delta = used - expected
        let paceKind: QuotaPace.Kind
        if abs(delta) < 3 {
            paceKind = .onPace
        } else {
            paceKind = delta > 0 ? .deficit : .reserve
        }

        var eta: Date?
        var lastsUntilReset = remaining > 0
        if used > 0, elapsed > 0 {
            let burnPerSecond = used / elapsed
            let secondsToEmpty = (100 - used) / max(burnPerSecond, 0.0001)
            if secondsToEmpty < remaining {
                eta = now.addingTimeInterval(secondsToEmpty)
                lastsUntilReset = false
            }
        }

        return QuotaPace(
            kind: paceKind,
            deltaPercent: delta,
            expectedUsedPercent: expected,
            elapsedFraction: fraction,
            eta: eta,
            lastsUntilReset: lastsUntilReset
        )
    }
}

enum QuotaRemainingColor {
    static func rgb(_ remaining: Double) -> (red: Double, green: Double, blue: Double) {
        let ratio = max(0, min(100, remaining)) / 100
        if ratio >= 0.45 {
            let t = (ratio - 0.45) / 0.55
            return (0.18 + (1 - t) * 0.16, 0.58 + t * 0.08, 0.24)
        }
        if ratio >= 0.20 {
            let t = (ratio - 0.20) / 0.25
            return (0.78, 0.46 + t * 0.10, 0.08)
        }
        return (0.76, 0.20, 0.18)
    }

    static func textRGB(_ remaining: Double) -> (red: Double, green: Double, blue: Double) {
        let ratio = max(0, min(100, remaining)) / 100
        if ratio >= 0.45 {
            return (0.09, 0.42, 0.20)
        }
        if ratio >= 0.20 {
            return (0.55, 0.32, 0.04)
        }
        return (0.63, 0.13, 0.13)
    }
}

struct CursorCodeModelCount: Equatable {
    var name: String
    var blocks: Int
}

struct CursorCodeSignal: Equatable {
    var fetchedAt: Date
    var blockCount: Int
    var modelCount: Int
    var conversationCount: Int
    var requestCount: Int
    var fileCount: Int
    var models: [CursorCodeModelCount]
    var status: String

    var isEmpty: Bool {
        blockCount <= 0
    }

    static func empty(status: String = "empty") -> CursorCodeSignal {
        CursorCodeSignal(
            fetchedAt: Date(),
            blockCount: 0,
            modelCount: 0,
            conversationCount: 0,
            requestCount: 0,
            fileCount: 0,
            models: [],
            status: status
        )
    }
}
