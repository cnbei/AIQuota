import SwiftUI
import AppKit

@main
struct AIQuotaApp: App {
    @StateObject private var store = QuotaStore()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIconRenderer.image(
                remaining: store.current.remainingPercent,
                hasError: store.current.error != nil
            ))
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuPanel: View {
    @EnvironmentObject private var store: QuotaStore

    @State private var showKimiPaste = false
    @State private var kimiTokenDraft = ""
    @State private var kimiAuthHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                QuotaRingView(
                    remainingPercent: store.current.remainingPercent,
                    hasError: store.current.error != nil,
                    compact: false
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(store.selected.title)
                            .font(.system(size: 16, weight: .semibold))
                        if let plan = store.current.planName, !plan.isEmpty {
                            Text(plan)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        pinButton
                    }
                    Text(store.current.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(updatedLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if store.isPinned {
                        Text("已固定置顶，切换应用也不会关闭")
                            .font(.system(size: 10))
                            .foregroundStyle(.blue)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if store.selected == .kimi, let kimiAuthHint {
                        Text(kimiAuthHint)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
            }

            if !store.current.windows.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("重置日程")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(store.current.windows) { window in
                        ResetScheduleRow(window: window)
                    }
                }
            }

            Picker("服务", selection: $store.selected) {
                ForEach(QuotaProviderID.allCases) { id in
                    Text(id.title).tag(id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if store.selected == .kimi {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("导入网页登录") {
                            importKimiWebAuth()
                        }
                        Button("粘贴 kimi-auth") {
                            showKimiPaste = true
                            kimiTokenDraft = ""
                        }
                        Spacer()
                    }
                    .buttonStyle(.borderless)

                    if !store.isPinned {
                        Text("提示：先点右上角「固定」，再去浏览器按教程复制 cookie")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    if showKimiPaste {
                        Text("教程：打开 kimi.com → DevTools (⌥⌘I) → Application → Cookies → 复制 kimi-auth")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: $kimiTokenDraft)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 54)
                            .border(Color.secondary.opacity(0.3))
                        HStack {
                            Button("保存并刷新") {
                                let token = kimiTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !token.isEmpty else { return }
                                do {
                                    try KimiWebAuth.saveStoredToken(token)
                                    showKimiPaste = false
                                    kimiAuthHint = "已保存网页登录态"
                                    Task { await store.refresh(.kimi) }
                                } catch {
                                    kimiAuthHint = "保存失败：\(error.localizedDescription)"
                                }
                            }
                            Button("取消") { showKimiPaste = false }
                            Spacer()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            HStack {
                Button(store.isRefreshing ? "刷新中…" : "刷新") {
                    Task { await store.refresh(store.selected) }
                }
                .disabled(store.isRefreshing)

                Button("打开控制台") {
                    NSWorkspace.shared.open(store.selected.dashboardURL)
                }

                Spacer()

                Button("退出") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { store.start() }
        .onChange(of: store.selected) { newValue in
            if newValue != .kimi {
                showKimiPaste = false
                kimiAuthHint = nil
            }
        }
    }

    private var pinButton: some View {
        Button {
            togglePin()
        } label: {
            Image(systemName: store.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.isPinned ? Color.accentColor : Color.secondary)
                .help(store.isPinned ? "取消固定" : "固定窗口（方便对照教程）")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(store.isPinned ? "取消固定窗口" : "固定窗口")
    }

    private var updatedLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "更新于 \(formatter.string(from: store.current.updatedAt))"
    }

    private func togglePin() {
        if store.isPinned {
            store.isPinned = false
            PinnedPanelController.shared.hide()
        } else {
            store.isPinned = true
            // Only auto-open the paste tutorial when already on Kimi.
            if store.selected == .kimi {
                showKimiPaste = true
            }
            PinnedPanelController.shared.show(store: store)
        }
    }

    private func importKimiWebAuth() {
        KimiWebAuth.clearStoredToken()
        if KimiWebAuth.importFreshFromBrowsers() != nil {
            kimiAuthHint = "已从浏览器导入网页登录态"
            Task { await store.refresh(.kimi) }
        } else {
            kimiAuthHint = "自动导入失败。请先: pip3 install --user browser-cookie3；浏览器登录 kimi.com；或改用粘贴 kimi-auth"
            if !store.isPinned {
                showKimiPaste = true
                store.isPinned = true
                PinnedPanelController.shared.show(store: store)
            }
            NSWorkspace.shared.open(QuotaProviderID.kimi.dashboardURL)
        }
    }
}

/// Dedicated floating NSPanel — safer than SwiftUI Window + collectionBehavior for menu-bar apps.
@MainActor
final class PinnedPanelController: NSObject, NSWindowDelegate {
    static let shared = PinnedPanelController()

    private var panel: NSPanel?
    private weak var store: QuotaStore?

    func show(store: QuotaStore) {
        self.store = store
        let panel = ensurePanel(store: store)
        // Refresh hosting root so state stays in sync.
        panel.contentView = NSHostingView(
            rootView: MenuPanel()
                .environmentObject(store)
        )
        if panel.frame.origin == .zero {
            panel.center()
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
        store?.isPinned = false
    }

    private func ensurePanel(store: QuotaStore) -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "AIQuota"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: MenuPanel()
                .environmentObject(store)
        )
        self.panel = panel
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        store?.isPinned = false
    }
}

private struct ResetScheduleRow: View {
    let window: QuotaWindow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(window.kind.label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(badgeForeground)
                .frame(width: 28, alignment: .center)
                .padding(.vertical, 2)
                .background(badgeBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let title = window.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    if let used = window.usedPercent {
                        Text(String(format: "%.0f%% used", used))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("用量未知")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                if let resets = window.resetsAt {
                    Text("重置 \(ResetFormat.absolute(resets))  ·  还有 \(ResetFormat.relative(resets))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("重置时间未知")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var badgeBackground: Color {
        switch window.kind {
        case .fiveHour: return Color.orange.opacity(0.18)
        case .sevenDay: return Color.blue.opacity(0.16)
        case .thirtyDay: return Color.purple.opacity(0.14)
        }
    }

    private var badgeForeground: Color {
        switch window.kind {
        case .fiveHour: return Color.orange
        case .sevenDay: return Color.blue
        case .thirtyDay: return Color.purple
        }
    }
}
