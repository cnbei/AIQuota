import Foundation
import SwiftUI

enum QuotaProviderID: String, CaseIterable, Identifiable, Codable {
    case codex
    case cursor
    case kimi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .kimi: return "Kimi"
        }
    }

    var dashboardURL: URL {
        switch self {
        case .codex:
            return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .cursor:
            return URL(string: "https://cursor.com/dashboard/spending")!
        case .kimi:
            return URL(string: "https://www.kimi.com/membership/subscription?tab=quota")!
        }
    }
}

/// Which Cursor Spending pool drives the menu-bar ring.
enum CursorDisplayMode: String, CaseIterable, Identifiable, Codable {
    case cursorModels
    case otherModels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursorModels: return "Cursor Models"
        case .otherModels: return "Other Models"
        }
    }
}

/// Which Kimi metric drives the menu-bar ring.
enum KimiDisplayMode: String, CaseIterable, Identifiable, Codable {
    case membership
    case code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .membership: return "总体"
        case .code: return "Kimi Code"
        }
    }
}

/// Raw used% values so the ring can switch without refetching.
struct QuotaMetrics: Equatable, Sendable {
    var cursorModelsUsed: Double?
    var otherModelsUsed: Double?
    var kimiMembershipUsed: Double?
    /// Most constrained Code window used% (max of 5h / 7d).
    var kimiCodeUsed: Double?
}

enum QuotaWindowKind: String, Equatable, Sendable, CaseIterable {
    case fiveHour
    case sevenDay
    case thirtyDay

    var label: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        case .thirtyDay: return "30d"
        }
    }

    /// Sort short windows first.
    var sortOrder: Int {
        switch self {
        case .fiveHour: return 0
        case .sevenDay: return 1
        case .thirtyDay: return 2
        }
    }

    static func fromWindowSeconds(_ seconds: Double) -> QuotaWindowKind? {
        if seconds <= 6 * 3600 { return .fiveHour }
        if seconds >= 25 * 24 * 3600 { return .thirtyDay }
        if seconds >= 6 * 24 * 3600 { return .sevenDay }
        return nil
    }
}

struct QuotaWindow: Equatable, Identifiable, Sendable {
    var kind: QuotaWindowKind
    /// Optional subtitle, e.g. "Cursor Models" / "Code".
    var title: String?
    /// Used percent 0...100 when known.
    var usedPercent: Double?
    var resetsAt: Date?

    var id: String { "\(kind.rawValue)-\(title ?? "")-\(resetsAt?.timeIntervalSince1970 ?? 0)" }

    var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }
}

struct QuotaSnapshot: Equatable, Sendable {
    var provider: QuotaProviderID
    /// Remaining quota 0...100 (higher = more left).
    var remainingPercent: Double
    var detail: String
    var planName: String?
    var windows: [QuotaWindow]
    var updatedAt: Date
    var error: String?
    /// Optional dual metrics for Cursor / Kimi display-mode switching.
    var metrics: QuotaMetrics? = nil

    static func loading(_ provider: QuotaProviderID) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            remainingPercent: 0,
            detail: "加载中…",
            planName: nil,
            windows: [],
            updatedAt: Date(),
            error: nil
        )
    }

    static func failed(_ provider: QuotaProviderID, message: String) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            remainingPercent: 0,
            detail: message,
            planName: nil,
            windows: [],
            updatedAt: Date(),
            error: message
        )
    }

    /// Apply user display preference to ring + detail (uses cached metrics).
    func applying(
        cursorMode: CursorDisplayMode,
        kimiMode: KimiDisplayMode
    ) -> QuotaSnapshot {
        guard error == nil else { return self }
        var snap = self
        switch provider {
        case .cursor:
            let used: Double?
            switch cursorMode {
            case .cursorModels:
                used = metrics?.cursorModelsUsed ?? metrics?.otherModelsUsed
            case .otherModels:
                used = metrics?.otherModelsUsed ?? metrics?.cursorModelsUsed
            }
            if let used {
                snap.remainingPercent = max(0, min(100, 100 - used))
            }
            snap.detail = Self.cursorDetail(
                mode: cursorMode,
                metrics: metrics,
                fallback: detail
            )
        case .kimi:
            let used: Double?
            switch kimiMode {
            case .membership:
                used = metrics?.kimiMembershipUsed ?? metrics?.kimiCodeUsed
            case .code:
                used = metrics?.kimiCodeUsed ?? metrics?.kimiMembershipUsed
            }
            if let used {
                snap.remainingPercent = max(0, min(100, 100 - used))
            }
            snap.detail = Self.kimiDetail(
                mode: kimiMode,
                metrics: metrics,
                windows: windows,
                fallback: detail
            )
        case .codex:
            break
        }
        return snap
    }

    private static func cursorDetail(
        mode: CursorDisplayMode,
        metrics: QuotaMetrics?,
        fallback: String
    ) -> String {
        guard let metrics else { return fallback }
        var parts: [String] = []
        switch mode {
        case .cursorModels:
            if let u = metrics.cursorModelsUsed {
                parts.append(String(format: "Cursor Models %.0f%% used", u))
            }
            if let u = metrics.otherModelsUsed {
                parts.append(String(format: "Other %.0f%% used", u))
            }
        case .otherModels:
            if let u = metrics.otherModelsUsed {
                parts.append(String(format: "Other Models %.0f%% used", u))
            }
            if let u = metrics.cursorModelsUsed {
                parts.append(String(format: "Cursor Models %.0f%% used", u))
            }
        }
        return parts.isEmpty ? fallback : parts.joined(separator: " · ")
    }

    private static func kimiDetail(
        mode: KimiDisplayMode,
        metrics: QuotaMetrics?,
        windows: [QuotaWindow],
        fallback: String
    ) -> String {
        guard let metrics else { return fallback }
        switch mode {
        case .membership:
            if let u = metrics.kimiMembershipUsed {
                var parts = [String(format: "总使用量 %.2f%%", u)]
                if let code = metrics.kimiCodeUsed {
                    parts.append(String(format: "Code %.0f%% used", code))
                }
                return parts.joined(separator: " · ")
            }
        case .code:
            let codeWindows = windows.filter { ($0.title ?? "").localizedCaseInsensitiveContains("code") }
            var parts: [String] = []
            for w in codeWindows.sorted(by: { $0.kind.sortOrder < $1.kind.sortOrder }) {
                if let used = w.usedPercent {
                    parts.append(String(format: "%@ %.0f%% used", w.kind.label, used))
                }
            }
            if parts.isEmpty, let code = metrics.kimiCodeUsed {
                parts.append(String(format: "Code %.0f%% used", code))
            }
            if let m = metrics.kimiMembershipUsed {
                parts.append(String(format: "总体 %.2f%%", m))
            }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        return fallback
    }
}

enum QuotaColor {
    /// Green when plentiful, red when nearly exhausted.
    static func forRemaining(_ remaining: Double) -> Color {
        let r = max(0, min(100, remaining)) / 100
        if r >= 0.45 {
            let t = (r - 0.45) / 0.55
            return Color(
                red: 0.20 + (1 - t) * 0.35,
                green: 0.72 + t * 0.10,
                blue: 0.28
            )
        } else if r >= 0.20 {
            let t = (r - 0.20) / 0.25
            return Color(
                red: 0.92,
                green: 0.45 + t * 0.35,
                blue: 0.15
            )
        } else {
            return Color(red: 0.90, green: 0.22, blue: 0.22)
        }
    }
}

enum ResetFormat {
    static func absolute(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) || cal.isDateInTomorrow(date) {
            f.dateFormat = "MM-dd HH:mm"
        } else if cal.dateComponents([.day], from: Date(), to: date).day ?? 99 <= 14 {
            f.dateFormat = "MM-dd HH:mm"
        } else {
            f.dateFormat = "yyyy-MM-dd"
        }
        return f.string(from: date)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "已重置" }
        let hours = Int(seconds / 3600)
        if hours < 48 {
            let h = max(1, hours)
            let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            if h < 1 { return "\(max(1, m))m" }
            if h < 24 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
            return "\(h / 24)d \(h % 24)h"
        }
        let days = Int((seconds / 86400).rounded(.up))
        return "\(days)d"
    }

    static func windowLine(_ window: QuotaWindow) -> String {
        var parts: [String] = [window.kind.label]
        if let title = window.title, !title.isEmpty {
            parts.append(title)
        }
        if let used = window.usedPercent {
            parts.append(String(format: "%.0f%% used", used))
        }
        if let resets = window.resetsAt {
            parts.append("重置 \(absolute(resets)) · \(relative(resets))")
        }
        return parts.joined(separator: " · ")
    }
}
