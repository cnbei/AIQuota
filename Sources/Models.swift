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

struct QuotaSnapshot: Equatable, Sendable {
    var provider: QuotaProviderID
    /// Remaining quota 0...100 (higher = more left).
    var remainingPercent: Double
    var detail: String
    var planName: String?
    var updatedAt: Date
    var error: String?

    static func loading(_ provider: QuotaProviderID) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            remainingPercent: 0,
            detail: "加载中…",
            planName: nil,
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
            updatedAt: Date(),
            error: message
        )
    }
}

enum QuotaColor {
    /// Green when plentiful, red when nearly exhausted.
    static func forRemaining(_ remaining: Double) -> Color {
        let r = max(0, min(100, remaining)) / 100
        // Interpolate green → yellow → red as remaining drops.
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
