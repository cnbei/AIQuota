import Foundation

enum QuotaRefreshCoordinator {
    static func fetch(providers: Set<QuotaProviderID>) -> [QuotaProviderID: ProviderQuota] {
        var result: [QuotaProviderID: ProviderQuota] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let quota = read(provider)
                lock.lock()
                result[provider] = quota
                lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 12)
        return result
    }

    static func read(_ provider: QuotaProviderID) -> ProviderQuota {
        do {
            let quota: ProviderQuota
            switch provider {
            case .codex:
                quota = try CodexQuotaService.read().asProviderQuota(.codex)
            case .claude:
                quota = try ClaudeQuotaService.read().asProviderQuota(.claude)
            case .cursor:
                quota = try CursorQuotaService.read()
            case .glm:
                quota = try GLMQuotaService.read()
            case .kimi:
                quota = try KimiQuotaService.read()
            case .grok:
                quota = try GrokQuotaService.read()
            }
            if quota.isAvailable {
                writeCache(quota)
            }
            return quota
        } catch {
            return ProviderQuota.unavailable(
                provider,
                status: status(for: provider, error: error),
                message: error.localizedDescription
            )
        }
    }

    private static func writeCache(_ quota: ProviderQuota) {
        let url = AppPaths.appSupportRoot
            .appendingPathComponent("cache/\(quota.provider.rawValue)-quota-cache.json")
        let cache = ProviderQuotaCache(fetchedAt: quota.fetchedAt ?? Date(), quota: quota)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: url, options: [.atomic])
        } catch {
            // Cache is best-effort.
        }
    }

    private static func status(for provider: QuotaProviderID, error: Error) -> QuotaStatus {
        let text = error.localizedDescription
        if text.contains("未登录") {
            return .notLoggedIn
        }
        if text.contains("非订阅") || text.contains("按量") {
            return .wrongKeyType
        }
        if text.contains("grok login") || text.contains("需要") && provider == .grok {
            return .needsLogin
        }
        return .unavailable
    }
}
