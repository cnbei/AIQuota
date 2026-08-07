import Foundation
import Combine

@MainActor
final class QuotaStore: ObservableObject {
    @Published var selected: QuotaProviderID {
        didSet {
            UserDefaults.standard.set(selected.rawValue, forKey: Self.selectionKey)
            Task { await refresh(selected) }
        }
    }

    /// Cursor ring: Cursor Models vs Other Models.
    @Published var cursorDisplayMode: CursorDisplayMode {
        didSet {
            UserDefaults.standard.set(cursorDisplayMode.rawValue, forKey: Self.cursorModeKey)
        }
    }

    /// Kimi ring: membership total vs Kimi Code rate limits.
    @Published var kimiDisplayMode: KimiDisplayMode {
        didSet {
            UserDefaults.standard.set(kimiDisplayMode.rawValue, forKey: Self.kimiModeKey)
        }
    }

    @Published private(set) var snapshots: [QuotaProviderID: QuotaSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    /// Detached floating panel stays open while following tutorials (e.g. Kimi auth).
    @Published var isPinned = false

    private var timer: Timer?
    private static let selectionKey = "aiQuota.selectedProvider"
    private static let cursorModeKey = "aiQuota.cursorDisplayMode"
    private static let kimiModeKey = "aiQuota.kimiDisplayMode"
    private static let refreshSeconds: TimeInterval = 180

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.selectionKey),
           let id = QuotaProviderID(rawValue: raw) {
            selected = id
        } else {
            selected = .codex
        }

        if let raw = UserDefaults.standard.string(forKey: Self.cursorModeKey),
           let mode = CursorDisplayMode(rawValue: raw) {
            cursorDisplayMode = mode
        } else {
            cursorDisplayMode = .cursorModels
        }

        if let raw = UserDefaults.standard.string(forKey: Self.kimiModeKey),
           let mode = KimiDisplayMode(rawValue: raw) {
            kimiDisplayMode = mode
        } else {
            kimiDisplayMode = .membership
        }

        for id in QuotaProviderID.allCases {
            snapshots[id] = .loading(id)
        }
    }

    var current: QuotaSnapshot {
        let raw = snapshots[selected] ?? .loading(selected)
        return raw.applying(cursorMode: cursorDisplayMode, kimiMode: kimiDisplayMode)
    }

    func start() {
        Task { await refreshAll() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: (QuotaProviderID, QuotaSnapshot).self) { group in
            for id in QuotaProviderID.allCases {
                group.addTask {
                    let snap = await Self.fetch(id)
                    return (id, snap)
                }
            }
            for await (id, snap) in group {
                snapshots[id] = snap
            }
        }
    }

    func refresh(_ id: QuotaProviderID) async {
        isRefreshing = true
        defer { isRefreshing = false }
        snapshots[id] = await Self.fetch(id)
    }

    private static func fetch(_ id: QuotaProviderID) async -> QuotaSnapshot {
        switch id {
        case .codex: return await CodexProvider.fetch()
        case .cursor: return await CursorProvider.fetch()
        case .kimi: return await KimiProvider.fetch()
        }
    }
}
