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

    @Published private(set) var snapshots: [QuotaProviderID: QuotaSnapshot] = [:]
    @Published private(set) var isRefreshing = false

    private var timer: Timer?
    private static let selectionKey = "aiQuota.selectedProvider"
    private static let refreshSeconds: TimeInterval = 180

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.selectionKey),
           let id = QuotaProviderID(rawValue: raw) {
            selected = id
        } else {
            selected = .codex
        }
        for id in QuotaProviderID.allCases {
            snapshots[id] = .loading(id)
        }
    }

    var current: QuotaSnapshot {
        snapshots[selected] ?? .loading(selected)
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
