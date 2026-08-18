import AppKit
import SwiftUI

struct PopoverFooterView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L("本地统计"), systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tokenMuted)
                Spacer()
                Text(refreshLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tokenMuted)
            }

            HStack(spacing: 8) {
                Button {
                    MainWindowPresenter.shared.show(appState: appState)
                } label: {
                    Text(L("打开仪表盘"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(Color.tokenGreen, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L("打开仪表盘"))

                footerIconButton(
                    title: appState.isRefreshing || appState.isRefreshingCodexQuota ? L("刷新中…") : L("刷新"),
                    symbol: "arrow.clockwise"
                ) {
                    appState.refresh()
                    appState.refreshCodexQuota(force: true)
                }
                .disabled(appState.isRefreshing || appState.isRefreshingCodexQuota)

                footerIconButton(title: L("打开控制台"), symbol: "safari") {
                    appState.openQuotaDashboard()
                }

                footerIconButton(title: L("设置"), symbol: "gearshape") {
                    SettingsWindowPresenter.shared.show(appState: appState)
                }

                footerIconButton(title: L("退出"), symbol: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var refreshLabel: String {
        appState.settings.refreshIntervalSeconds == 0
            ? L("手动刷新")
            : LFormat("刷新 %@", TokenStepFormat.intervalLabel(appState.settings.refreshIntervalSeconds))
    }

    private func footerIconButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.tokenInk.opacity(0.78))
                .frame(width: 34, height: 34)
                .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.055))
                )
                .help(title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
