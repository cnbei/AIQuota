import CoreServices
import Foundation

enum UsageSourceWatchRoots {
    static func existingPaths(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let candidates = [
            homeURL.appendingPathComponent(".codex/sessions", isDirectory: true),
            homeURL.appendingPathComponent(".claude/projects", isDirectory: true),
            homeURL.appendingPathComponent(".claude/transcripts", isDirectory: true),
            homeURL.appendingPathComponent(".kimi-code/sessions", isDirectory: true),
            homeURL.appendingPathComponent(".kimi/sessions", isDirectory: true),
            homeURL.appendingPathComponent(".grok/logs", isDirectory: true),
            homeURL.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true),
            homeURL.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true),
            homeURL.appendingPathComponent(".local/share/opencode", isDirectory: true),
            homeURL.appendingPathComponent(".opencode", isDirectory: true),
            homeURL.appendingPathComponent(".cline/data/sessions", isDirectory: true),
            homeURL.appendingPathComponent(
                "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks",
                isDirectory: true
            ),
            homeURL.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev/tasks",
                isDirectory: true
            ),
            homeURL.appendingPathComponent("Library/Application Support/CherryStudio", isDirectory: true),
            homeURL.appendingPathComponent("Library/Application Support/Cherry Studio", isDirectory: true)
        ]
        let fallbacks = [
            homeURL.appendingPathComponent(".codex", isDirectory: true),
            homeURL.appendingPathComponent(".claude", isDirectory: true)
        ]
        var seen = Set<String>()
        var paths: [String] = []
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if seen.insert(url.path).inserted {
                paths.append(url.path)
            }
        }
        if paths.isEmpty {
            for url in fallbacks where FileManager.default.fileExists(atPath: url.path) {
                if seen.insert(url.path).inserted {
                    paths.append(url.path)
                }
            }
        }
        return paths
    }
}

final class UsageSourceWatcher: @unchecked Sendable {
    static let debounceInterval: TimeInterval = 2.5

    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var debounceWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "app.aiquota.usage-watch")

    deinit {
        stop()
    }

    func start(paths: [String] = UsageSourceWatchRoots.existingPaths()) {
        let normalized = paths.sorted()
        queue.sync {
            if stream != nil, watchedPaths == normalized {
                return
            }
            tearDownLocked()
            watchedPaths = normalized
            guard !normalized.isEmpty else { return }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<UsageSourceWatcher>.fromOpaque(info).takeUnretainedValue().scheduleNotify()
            }
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                normalized as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                )
            ) else {
                return
            }
            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
        }
    }

    func stop() {
        queue.sync {
            tearDownLocked()
        }
    }

    private func scheduleNotify() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func tearDownLocked() {
        debounceWork?.cancel()
        debounceWork = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        watchedPaths = []
    }
}
