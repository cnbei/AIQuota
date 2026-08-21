import SwiftUI

struct PopoverQuotaCard: View {
    @EnvironmentObject private var appState: AppState
    @State private var showKimiPaste = false
    @State private var kimiTokenDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            schedule
            providerPicker
            displayModePickers
            kimiAuthControls
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: appState.settings.resolvedQuotaProvider) { _, provider in
            if provider != .kimi {
                showKimiPaste = false
            }
        }
    }

    private var quota: ProviderQuota { appState.selectedQuota }
    private var remaining: Double { appState.selectedQuotaRemainingPercent }
    private var hasError: Bool { !quota.isAvailable }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            QuotaRingView(remainingPercent: remaining, hasError: hasError, compact: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(quota.provider.displayName)
                        .font(.system(size: 16, weight: .semibold))
                    if let plan = quota.planName, !plan.isEmpty {
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
                Text(appState.selectedQuotaDetail.isEmpty ? (quota.message ?? L("暂未读取到额度")) : appState.selectedQuotaDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fetchedAt = quota.fetchedAt {
                    Text(LFormat("更新于 %@", updatedLabel(fetchedAt)))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if appState.isQuotaPinned {
                    Text(L("已固定置顶，切换应用也不会关闭"))
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if quota.provider == .kimi, let hint = appState.kimiAuthHint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var schedule: some View {
        if !quota.windows.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(quota.provider == .grok ? L("本周额度（共用）") : L("重置日程"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(quota.provider == .cursor ? quota.cursorOfficialWindows : quota.provider == .grok ? quota.grokDisplayWindows : quota.windows) { window in
                    QuotaResetScheduleRow(window: window)
                }
            }
        }
        if quota.provider == .grok {
            Text(L("生图和 Grok 共用本周额度"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerPicker: some View {
        Picker(L("服务"), selection: selectedProviderBinding) {
            ForEach(QuotaProviderID.allCases.filter { appState.settings.enabledQuotaProviders.contains($0) || $0 == appState.settings.resolvedQuotaProvider }) { id in
                Text(id.displayName).tag(id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var displayModePickers: some View {
        if quota.provider == .cursor {
            labeledPicker(L("状态栏显示"), selection: cursorModeBinding) {
                ForEach(CursorDisplayMode.statusBarCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
        if quota.provider == .kimi {
            labeledPicker(L("状态栏显示"), selection: kimiModeBinding) {
                ForEach(KimiDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }

    @ViewBuilder
    private var kimiAuthControls: some View {
        if quota.provider == .kimi {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(L("导入网页登录")) {
                        appState.importKimiWebAuth()
                    }
                    Button(L("粘贴 kimi-auth")) {
                        showKimiPaste = true
                        kimiTokenDraft = ""
                    }
                    Spacer()
                }
                .buttonStyle(.borderless)
                if !appState.isQuotaPinned {
                    Text(L("提示：先点右上角「固定」，再去浏览器按教程复制 cookie"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if showKimiPaste {
                    Text(L("教程：打开 kimi.com → DevTools (⌥⌘I) → Application → Cookies → 复制 kimi-auth"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $kimiTokenDraft)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 54)
                        .border(Color.secondary.opacity(0.3))
                    HStack {
                        Button(L("保存并刷新")) {
                            let token = kimiTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !token.isEmpty else { return }
                            appState.savePastedKimiAuth(token)
                            showKimiPaste = false
                        }
                        Button(L("取消")) { showKimiPaste = false }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Button(appState.isRefreshingCodexQuota ? L("刷新中…") : L("刷新")) {
                    appState.refreshCodexQuota(force: true)
                }
                .disabled(appState.isRefreshingCodexQuota)
                Button(L("打开控制台")) {
                    appState.openQuotaDashboard()
                }
                Spacer()
            }
            .buttonStyle(.borderless)
        }
    }

    private var pinButton: some View {
        Button {
            appState.toggleQuotaPin()
        } label: {
            Image(systemName: appState.isQuotaPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appState.isQuotaPinned ? Color.accentColor : Color.secondary)
                .help(appState.isQuotaPinned ? L("取消固定") : L("固定窗口（方便对照教程）"))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(appState.isQuotaPinned ? L("取消固定窗口") : L("固定窗口（方便对照教程）"))
    }

    private var selectedProviderBinding: Binding<QuotaProviderID> {
        Binding(
            get: { appState.settings.resolvedQuotaProvider },
            set: { appState.setSelectedQuotaProvider($0) }
        )
    }

    private var cursorModeBinding: Binding<CursorDisplayMode> {
        Binding(
            get: { appState.settings.cursorDisplayMode.resolved },
            set: { appState.setCursorDisplayMode($0) }
        )
    }

    private var kimiModeBinding: Binding<KimiDisplayMode> {
        Binding(
            get: { appState.settings.kimiDisplayMode },
            set: { appState.setKimiDisplayMode($0) }
        )
    }

    private func labeledPicker<Value: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: selection, content: content)
                .pickerStyle(.segmented)
                .labelsHidden()
        }
    }

    private func updatedLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct QuotaResetScheduleRow: View {
    let window: QuotaWindow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(window.kind.badgeLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(badgeForeground)
                .frame(width: 28, alignment: .center)
                .padding(.vertical, 2)
                .background(badgeBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(window.displayTitle)
                        .font(.system(size: 11, weight: .medium))
                    Text(String(format: "%.0f%% used", window.usedPercent))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if let resets = window.resetsAt {
                    Text(LFormat("重置 %@  ·  还有 %@", QuotaResetFormat.absolute(resets), QuotaResetFormat.relative(resets)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("重置时间未知"))
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
        case .thirtyDay, .monthlyCredits: return Color.purple.opacity(0.14)
        default: return Color.secondary.opacity(0.12)
        }
    }

    private var badgeForeground: Color {
        switch window.kind {
        case .fiveHour: return Color.orange
        case .sevenDay: return Color.blue
        case .thirtyDay, .monthlyCredits: return Color.purple
        default: return Color.secondary
        }
    }
}
