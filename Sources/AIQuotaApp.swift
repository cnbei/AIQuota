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
                    }
                    Text(store.current.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(updatedLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if let kimiAuthHint {
                        Text(kimiAuthHint)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
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
            }

            if showKimiPaste {
                VStack(alignment: .leading, spacing: 6) {
                    Text("从浏览器 DevTools → Application → Cookies → kimi-auth 复制值：")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
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
        .frame(width: 340)
        .onAppear { store.start() }
    }

    private var updatedLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "更新于 \(formatter.string(from: store.current.updatedAt))"
    }

    private func importKimiWebAuth() {
        KimiWebAuth.clearStoredToken()
        if KimiWebAuth.importFreshFromBrowsers() != nil {
            kimiAuthHint = "已从浏览器导入网页登录态"
            Task { await store.refresh(.kimi) }
        } else {
            kimiAuthHint = "自动导入失败。请先: pip3 install --user browser-cookie3；浏览器登录 kimi.com；或改用粘贴 kimi-auth"
            NSWorkspace.shared.open(QuotaProviderID.kimi.dashboardURL)
        }
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
