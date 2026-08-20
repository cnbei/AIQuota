import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    var historyLimit: Int? = nil
    @State private var loadedCount = HistoryDetailPaging.pageSize

    var body: some View {
        VStack(spacing: 22) {
            TokenCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("近 8 个月活动墙"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Color.tokenInk)
                            Text(L("颜色越深，用量越高；描边是今天"))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.tokenMuted)
                        }
                        Spacer()
                        Text(LFormat("%d 个活跃日", appState.historyTotals.activeDays))
                            .font(.callout.weight(.bold))
                            .foregroundStyle(Color.tokenGreenDark)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.tokenMint.opacity(0.28), in: Capsule())
                    }

                    if appState.showsHistoryDeviceChart {
                        HistoryDeviceFilterBar()
                    }

                    ContributionWallView(
                        rows: Array(appState.historyDaily.suffix(238)),
                        goal: appState.settings.dailyGoalTokens
                    )
                }
            }

            StatsView()

            TokenCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("全部明细"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Color.tokenInk)
                            Text(historySummaryText)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.tokenMuted)
                        }
                        Spacer()
                        TokenToolLegend(tools: historyTools)
                    }

                    LazyVStack(spacing: 0) {
                        header
                        ForEach(Array(historyRows.enumerated()), id: \.element.id) { index, row in
                            HistoryRow(row: row, goal: appState.settings.dailyGoalTokens)
                                .onAppear {
                                    loadMoreIfNeeded(index: index)
                                }
                        }
                        if hasMore {
                            Text(LFormat("已显示 %d / %d 条，向下滚动加载更多", historyRows.count, allDetailRows.count))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.tokenMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .onAppear {
                                    loadMore()
                                }
                        }
                    }
                }
            }
        }
        .onChange(of: appState.historyDeviceFilter) { _, _ in
            loadedCount = HistoryDetailPaging.pageSize
        }
        .onChange(of: allDetailRows.count) { _, _ in
            loadedCount = min(max(loadedCount, HistoryDetailPaging.pageSize), max(HistoryDetailPaging.pageSize, allDetailRows.count))
        }
    }

    private var allDetailRows: [DailyUsage] {
        let rows = appState.visibleHistoryRows
        guard let historyLimit else { return rows }
        return Array(rows.prefix(historyLimit))
    }

    private var historyRows: [DailyUsage] {
        if historyLimit != nil { return allDetailRows }
        return HistoryDetailPaging.displayed(allDetailRows, loadedCount: loadedCount)
    }

    private var hasMore: Bool {
        historyLimit == nil && historyRows.count < allDetailRows.count
    }

    private var historySummaryText: String {
        if let historyLimit {
            return LFormat("最近 %d 天，适合保存为截图", min(historyLimit, historyRows.count))
        }
        if hasMore {
            return LFormat("已显示 %d / %d 条，向下滚动加载更多", historyRows.count, allDetailRows.count)
        }
        return LFormat("%d 条记录，向下滚动查看完整历史", allDetailRows.count)
    }

    private var historyTools: [String] {
        uniqueToolNames(in: allDetailRows)
    }

    private func loadMoreIfNeeded(index: Int) {
        guard hasMore, index >= historyRows.count - 4 else { return }
        loadMore()
    }

    private func loadMore() {
        guard historyLimit == nil else { return }
        loadedCount = HistoryDetailPaging.advance(loadedCount: loadedCount, total: allDetailRows.count)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(L("日期")).frame(width: 118, alignment: .leading)
            Text(L("Token 消耗")).frame(width: 150, alignment: .leading)
            Text(L("消耗金额")).frame(width: 126, alignment: .leading)
            Text(L("主力工具")).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.heavy))
        .foregroundStyle(Color.tokenMuted)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.tokenTrack.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HistoryDeviceFilterBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("按设备筛选"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.tokenMuted)
            ChipFlow(spacing: 8, lineSpacing: 8) {
                filterChip(title: L("全部设备"), selected: appState.historyDeviceFilter == .all, color: Color.tokenInk) {
                    appState.setHistoryDeviceFilter(.all)
                }
                ForEach(appState.historyDevices) { device in
                    filterChip(
                        title: HistoryDevicePresentation.displayTitle(for: device, among: appState.historyDevices),
                        selected: appState.historyDeviceFilter == .machine(device.machineId),
                        color: tokenDeviceColor(machineId: device.machineId, isLocal: device.isLocal)
                    ) {
                        appState.setHistoryDeviceFilter(.machine(device.machineId))
                    }
                }
            }
        }
    }

    private func filterChip(title: String, selected: Bool, color: Color = Color.tokenGreen, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : Color.tokenInk)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(selected ? color : Color.tokenSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.black.opacity(selected ? 0 : 0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? 0, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + result.origins[index].x, y: bounds.minY + result.origins[index].y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let limit = width > 0 ? width : .greatestFiniteMagnitude

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: width > 0 ? width : x, height: y + rowHeight), origins, sizes)
    }
}

private struct HistoryRow: View {
    var row: DailyUsage
    var goal: Int

    var body: some View {
        HStack(spacing: 16) {
            Text(row.date)
                .frame(width: 118, alignment: .leading)
                .foregroundStyle(Color.tokenInk.opacity(0.72))
            Text(TokenStepFormat.tokens(row.totalTokens))
                .fontWeight(.heavy)
                .foregroundStyle(Color.tokenInk)
                .frame(width: 150, alignment: .leading)
            Text(TokenStepFormat.money(row.displayCost))
                .frame(width: 126, alignment: .leading)
                .foregroundStyle(Color.tokenInk.opacity(0.72))
            HStack(spacing: 8) {
                Circle()
                    .fill(tokenToolColor(dominantTool))
                    .frame(width: 8, height: 8)
                Text(dominantTool)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.tokenInk.opacity(0.72))
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.055))
                .frame(height: 1)
        }
    }

    private var dominantTool: String {
        row.tools.max(by: { $0.value < $1.value })?.key ?? L("无")
    }
}
