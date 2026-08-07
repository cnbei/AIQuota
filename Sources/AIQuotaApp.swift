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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                QuotaRingView(
                    remainingPercent: store.current.remainingPercent,
                    hasError: store.current.error != nil,
                    compact: false
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.selected.title)
                        .font(.system(size: 16, weight: .semibold))
                    if let plan = store.current.planName, !plan.isEmpty {
                        Text(plan)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(store.current.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
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
        .frame(width: 320)
        .onAppear { store.start() }
    }

    private var updatedLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "更新于 \(formatter.string(from: store.current.updatedAt))"
    }

    private func importKimiWebAuth() {
        KimiWebAuth.clearStoredToken()
        if let _ = KimiWebAuth.importFreshFromBrowsers() {
            kimiAuthHint = "已从浏览器导入网页登录态"
            Task { await store.refresh(.kimi) }
        } else {
            kimiAuthHint = "自动导入失败。请先: pip3 install --user browser-cookie3；浏览器登录 kimi.com；或改用粘贴 kimi-auth"
            NSWorkspace.shared.open(QuotaProviderID.kimi.dashboardURL)
        }
    }
}
