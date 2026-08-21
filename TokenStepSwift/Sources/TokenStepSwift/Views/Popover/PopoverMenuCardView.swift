import SwiftUI

struct PopoverMenuCardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showKimiPaste = false
    @State private var kimiTokenDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if hasDisplayModes {
                menuDivider
                displayModePickers
            }
            menuDivider
            if quota.isAvailable {
                usageSection
            } else {
                Text(quota.message ?? L("暂未读取到额度"))
                    .font(.subheadline)
                    .foregroundStyle(Color.tokenMuted)
            }
            menuDivider
            tokenSection
            if hasKimiExtras {
                menuDivider
                extras
            }
        }
        .onChange(of: appState.settings.resolvedQuotaProvider) { _, provider in
            if provider != .kimi {
                showKimiPaste = false
            }
        }
    }

    private var hasDisplayModes: Bool {
        quota.provider == .cursor || quota.provider == .kimi
    }

    private var hasKimiExtras: Bool {
        quota.provider == .kimi
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(Color.tokenInk.opacity(0.10))
            .frame(height: 1)
            .padding(.vertical, 10)
    }

    private var quota: ProviderQuota { appState.selectedQuota }
    private var remaining: Double { appState.selectedQuotaRemainingPercent }
    private var tint: Color {
        let rgb = QuotaRemainingColor.rgb(remaining)
        return quota.isAvailable
            ? Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            : Color.tokenMuted
    }
    private var remainingTextColor: Color {
        let rgb = QuotaRemainingColor.textRGB(remaining)
        return quota.isAvailable
            ? Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            : Color.tokenMuted
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            QuotaRingView(
                remainingPercent: remaining,
                hasError: !quota.isAvailable,
                compact: false
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(quota.provider.displayName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.tokenInk)
                        .lineLimit(1)
                    if let plan = quota.planName, !plan.isEmpty {
                        Text(plan)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tokenMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        appState.toggleQuotaPin()
                    } label: {
                        Image(systemName: appState.isQuotaPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(appState.isQuotaPinned ? Color.tokenGreen : Color.tokenMuted)
                    }
                    .buttonStyle(.plain)
                    .help(appState.isQuotaPinned ? L("取消固定") : L("固定窗口（方便对照教程）"))
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(quota.isAvailable ? Color.tokenMuted : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if quota.isAvailable {
                    if quota.provider == .cursor, let spend = quota.metrics?.cursorSpendDollars {
                        Text(LFormat("已用 %@", TokenStepFormat.money(spend)))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.tokenInk)
                    } else {
                        Text(LFormat("%@ 剩余", TokenStepFormat.percent(remaining)))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(remainingTextColor)
                    }
                }
                Text(L("状态栏显示所选圆环"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tokenMuted)
            }
        }
    }

    private var subtitle: String {
        if !quota.isAvailable {
            return quota.message ?? L("暂未读取到额度")
        }
        if !appState.selectedQuotaDetail.isEmpty {
            return appState.selectedQuotaDetail
        }
        if let fetchedAt = quota.fetchedAt {
            return LFormat("更新于 %@", updatedLabel(fetchedAt))
        }
        return L("已同步")
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if quota.provider == .cursor {
                cursorSpendSection
            } else {
                ForEach(displayedWindows) { window in
                    let pace = QuotaPaceCalculator.pace(
                        usedPercent: window.usedPercent,
                        resetsAt: window.resetsAt,
                        kind: window.kind
                    )
                    CodexBarMetricRow(
                        title: LFormat("%@ %.0f%% 剩余", window.displayTitle, window.remainingPercent),
                        remainingPercent: window.remainingPercent,
                        resetText: window.resetsAt.map { LFormat("重置 %@", QuotaResetFormat.relative($0)) },
                        metaText: pace?.summary(resetsAt: window.resetsAt),
                        tint: tint,
                        expectedUsedPercent: pace?.expectedUsedPercent
                    )
                }
            }
            if quota.provider == .grok {
                Text(L("生图和 Grok 共用本周额度"))
                    .font(.footnote)
                    .foregroundStyle(Color.tokenMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cursorResetDate: Date? {
        quota.windows.compactMap(\.resetsAt).first
    }

    private var displayedWindows: [QuotaWindow] {
        if quota.provider == .kimi, appState.settings.kimiDisplayMode == .code {
            let code = quota.windows.filter { ($0.title ?? "").localizedCaseInsensitiveContains("code") }
            return code.isEmpty ? quota.windows : code
        }
        if quota.provider == .grok {
            return quota.grokDisplayWindows
        }
        return quota.windows
    }

    private var cursorSpendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("本账期已用"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.tokenMuted)
            if let spend = quota.metrics?.cursorSpendDollars {
                Text(TokenStepFormat.money(spend))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
            } else {
                Text(L("暂未读取到花费"))
                    .font(.body)
                    .foregroundStyle(Color.tokenMuted)
            }
            if let reset = cursorResetDate {
                Text(LFormat("重置 %@  ·  还有 %@", QuotaResetFormat.absolute(reset), QuotaResetFormat.relative(reset)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tokenMuted)
            }
            if let used = quota.metrics?.cursorModelsUsed {
                cursorPoolBar(title: "Cursor Models", usedPercent: used)
            }
            if let used = quota.metrics?.otherModelsUsed {
                cursorPoolBar(title: "Other Models", usedPercent: used)
            }
        }
    }

    private func cursorPoolBar(title: String, usedPercent: Double) -> some View {
        let remaining = min(max(100 - usedPercent, 0), 100)
        let rgb = QuotaRemainingColor.rgb(remaining)
        return VStack(alignment: .leading, spacing: 4) {
            Text(LFormat("%@ 已用 %.0f%%", title, usedPercent))
                .font(.footnote)
                .foregroundStyle(Color.tokenInk)
            CodexBarUsageBar(
                fillPercent: usedPercent,
                tint: Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            )
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("今日 Token"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.tokenInk)
                Spacer()
                Text(appState.todayLap.lapStatusText)
                    .font(.footnote)
                    .foregroundStyle(Color.tokenMuted)
            }
            CodexBarUsageBar(
                fillPercent: appState.todayLap.currentLapPercent,
                tint: Color.tokenGreen
            )
            HStack {
                Text(TokenStepFormat.tokens(appState.today.totalTokens, compact: true))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
                Text(LFormat("/ %@", TokenStepFormat.tokens(appState.settings.dailyGoalTokens, compact: true)))
                    .font(.caption)
                    .foregroundStyle(Color.tokenMuted)
                Spacer()
                Text(TokenStepFormat.money(appState.today.displayCost))
                    .font(.caption)
                    .foregroundStyle(Color.tokenMuted)
            }
            ForEach(tokenRows.prefix(4)) { row in
                HStack {
                    Text(row.source)
                        .font(.footnote)
                    Spacer()
                    Text(TokenStepFormat.tokens(row.tokens, compact: true))
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.tokenMuted)
            }
            if tokenRows.isEmpty {
                Text(L("今日还没有 Agent 记录"))
                    .font(.footnote)
                    .foregroundStyle(Color.tokenMuted)
            }
        }
    }

    private var tokenRows: [AgentWorkSource] {
        appState.todayAgentWork.sources
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
    }

    @ViewBuilder
    private var displayModePickers: some View {
        if quota.provider == .cursor {
            labeledChipRow(L("状态栏显示")) {
                ForEach(CursorDisplayMode.statusBarCases) { mode in
                    popoverChip(title: mode.title, selected: cursorBinding.wrappedValue == mode) {
                        cursorBinding.wrappedValue = mode
                    }
                }
            }
        }
        if quota.provider == .kimi {
            labeledChipRow(L("状态栏显示")) {
                ForEach(KimiDisplayMode.allCases) { mode in
                    popoverChip(title: mode.title, selected: kimiBinding.wrappedValue == mode) {
                        kimiBinding.wrappedValue = mode
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var extras: some View {
        if quota.provider == .kimi {
            kimiAuth
        }
        if let hint = appState.kimiAuthHint, quota.provider == .kimi {
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var kimiAuth: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(L("导入网页登录")) { appState.importKimiWebAuth() }
                Button(L("粘贴 kimi-auth")) {
                    showKimiPaste = true
                    kimiTokenDraft = ""
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            if !appState.isQuotaPinned {
                Text(L("提示：先点右上角「固定」，再去浏览器按教程复制 cookie"))
                    .font(.footnote)
                    .foregroundStyle(Color.tokenMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showKimiPaste {
                Text(L("教程：打开 kimi.com → DevTools (⌥⌘I) → Application → Cookies → 复制 kimi-auth"))
                    .font(.footnote)
                    .foregroundStyle(Color.tokenMuted)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $kimiTokenDraft)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 48)
                    .border(Color.tokenInk.opacity(0.18))
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

    private var cursorBinding: Binding<CursorDisplayMode> {
        Binding(
            get: { appState.settings.cursorDisplayMode.resolved },
            set: { appState.setCursorDisplayMode($0) }
        )
    }

    private var kimiBinding: Binding<KimiDisplayMode> {
        Binding(
            get: { appState.settings.kimiDisplayMode },
            set: { appState.setKimiDisplayMode($0) }
        )
    }

    private func labeledChipRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.tokenMuted)
            HStack(spacing: 6, content: content)
        }
    }

    private func popoverChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.tokenInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(selected ? Color.tokenGreen : Color.tokenSurface, in: Capsule())
                .overlay(Capsule().stroke(Color.black.opacity(selected ? 0 : 0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func updatedLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
