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
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(updatedLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
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
        .frame(width: 300)
        .onAppear { store.start() }
    }

    private var updatedLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "更新于 \(formatter.string(from: store.current.updatedAt))"
    }
}
