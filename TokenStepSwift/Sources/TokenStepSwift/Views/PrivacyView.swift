import SwiftUI

struct PrivacyView: View {
    @EnvironmentObject private var appState: AppState
    @State private var remoteURLDraft = ""

    var body: some View {
        VStack(spacing: 12) {
            TokenCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("本地优先"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("默认不联网、不上传。Token 统计全部来自本机日志。"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                    PrivacyFactRow(title: L("读取"), value: L("日期 · 模型名 · 客户端名 · token 计数"))
                    PrivacyFactRow(title: L("不读取"), value: L("prompt · 代码正文 · 对话内容"))
                    PrivacyFactRow(title: L("不做"), value: L("不开代理 · 不按字数估算 token"))
                    PrivacyFactRow(title: L("本地保留"), value: L("已经记下的每日用量只升不降，并会同步到 Origin"))
                    PrivacyFactRow(title: L("可选导出"), value: L("CSV / JSON 只含计数和估算金额，不含设备名或账号"))
                    PrivacyFactRow(title: L("手填月费"), value: L("只存在本机，不随用量同步，也不上传"))
                }
            }

            HStack(alignment: .top, spacing: 13) {
                TokenCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("联网项（全部默认关闭）"))
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(L("开启后才会发起请求，逐项独立"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tokenMuted)
                        PrivacyNetworkRow(badge: "L2", style: .l2, title: L("Codex 额度"), detail: L("本机 codex 登录态"))
                        PrivacyNetworkRow(badge: "L2", style: .l2, title: L("Claude 额度"), detail: L("钥匙串 OAuth → Anthropic"))
                        PrivacyNetworkRow(badge: "L2", style: .l2, title: L("Cursor 额度与官方用量"), detail: L("state.vscdb → cursor.com 事件计入圆环"))
                        PrivacyNetworkRow(badge: "L2", style: .l2, title: L("GLM / Kimi / Grok"), detail: L("各自本机凭证"))
                        PrivacyNetworkRow(badge: L("榜"), style: .ok, title: L("消耗榜"), detail: L("仅在开启后上报"))
                    }
                }

                TokenCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(L("Cursor 明细"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Color.tokenInk)
                            SettingsBadge(text: L("L3 本地"), style: .l3)
                        }
                        Text(L("额度走网络；官方用量事件计入圆环；代码产出纯本地。"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tokenMuted)
                        PrivacyFactRow(title: L("读 accessToken"), value: L("仅内存 · 不落盘不上传"))
                        PrivacyFactRow(title: L("读代码块计数"), value: L("ai_code_hashes 的 count 与 model"))
                        PrivacyFactRow(title: L("明确不读"), value: L("tracked_file_content（代码正文）"), emphasis: true)
                        PrivacyFactRow(title: L("明确不读"), value: L("conversation_summaries（对话摘要）"), emphasis: true)
                        Text(L("Cursor 的用量接口非官方公开契约，可能随时变更。失效时只影响这一项。"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tokenMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(red: 0.42, green: 0.36, blue: 0.82).opacity(0.16))
                )
            }

            TokenCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("本地文件"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("可直接查看或删除"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                    Text("\(AppPaths.usageJSON.path)\n\(AppPaths.settingsJSON.path)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.tokenMuted)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.tokenTrack.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(L("今日花费含本地估算，以及已开启的 Cursor 官方 charged 金额。额度栏里的美元/百分比不要和圆环花费加在一起。"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 9) {
                        Button {
                            appState.revealLocalDataInFinder()
                        } label: {
                            Text(L("在 Finder 中显示"))
                                .font(.callout.weight(.bold))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())

                        Button {
                            appState.clearLocalUsageData()
                        } label: {
                            Text(L("清除本地数据"))
                                .font(.callout.weight(.bold))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                    }
                }
            }

            TokenCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("跨机器同步"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("把本机每日 token 计数同步到你自己的私有 git 仓库，多台电脑会自动叠加显示总用量。只同步日期/模型名/来源名/token 计数，不包含 prompt 或代码正文。"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("历史页柱状图按设备分色，可筛选单台电脑看用量。各台电脑和 Cursor 账号的完整历史会写入 Origin，累计只升不降。"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    SettingsToggleRow(
                        title: L("开启跨机器同步"),
                        isOn: Binding(
                            get: { appState.settings.usageSyncEnabled },
                            set: { appState.setUsageSyncEnabled($0) }
                        )
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("同步仓库地址"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.tokenMuted)
                        TextField("", text: $remoteURLDraft)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            appState.setUsageSyncRemoteURL(remoteURLDraft)
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.tokenInk)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.tokenTrack.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onAppear { remoteURLDraft = appState.settings.usageSyncRemoteURL }
                        .onChange(of: appState.settings.usageSyncRemoteURL) { _, newValue in
                            remoteURLDraft = newValue
                        }
                    }

                    Text(usageSyncStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appState.usageSyncError != nil ? Color(red: 0.56, green: 0.21, blue: 0.09) : Color.tokenMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 9) {
                        Button {
                            appState.refreshUsageSync(force: true)
                        } label: {
                            Text(appState.isSyncingUsage ? L("同步中…") : L("立即同步"))
                                .font(.callout.weight(.bold))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .disabled(!appState.settings.usageSyncEnabled || appState.isSyncingUsage)
                    }

                    Text(L("需要先在这台电脑上安装并登录 origin CLI（origin auth login），否则同步会失败但不影响其它功能。"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var usageSyncStatusText: String {
        if appState.isSyncingUsage {
            return L("同步中…")
        }
        if let error = appState.usageSyncError {
            return error
        }
        if let lastSyncAt = appState.lastUsageSyncAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return LFormat("上次同步 %@", formatter.string(from: lastSyncAt))
        }
        if appState.settings.usageSyncEnabled {
            return L("尚未同步")
        }
        return L("未开启")
    }
}

private struct PrivacyFactRow: View {
    var title: String
    var value: String
    var emphasis = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.tokenInk)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(emphasis ? Color(red: 0.56, green: 0.21, blue: 0.09) : Color.tokenMuted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1)
        }
    }
}

private struct PrivacyNetworkRow: View {
    var badge: String
    var style: SettingsBadgeStyle
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: 8) {
            SettingsBadge(text: badge, style: style)
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.tokenInk)
            Spacer()
            Text(detail)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.tokenMuted)
                .lineLimit(1)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1)
        }
    }
}
