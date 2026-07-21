import SwiftUI

/// 底部同声转写面板（实施计划 6.5）：
/// - 默认自动滚动到最新；用户向上浏览后暂停滚动并显示「回到最新」；
/// - 临时文字使用较浅颜色；最终替换就地更新（片段 ID 稳定，不整页跳动）；
/// - 说话人未识别时显示「识别中」。
struct TranscriptPanelView: View {
    let segments: [TranscriptSegment]
    let participants: [Participant]

    /// 是否贴底自动滚动
    @State private var pinnedToBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if segments.isEmpty {
                            Text("发言后将在此显示实时转写…")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 12)
                        }
                        ForEach(segments) { segment in
                            TranscriptRowView(
                                segment: segment,
                                participant: participants.first(where: { $0.id == segment.participantId })
                            )
                            .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                // 跟踪是否贴底（用户上翻时取消自动滚动）
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 24
                } action: { _, isAtBottom in
                    pinnedToBottom = isAtBottom
                }
                .onChange(of: segments.count) { _, _ in
                    scrollToLatest(proxy: proxy)
                }
                .onChange(of: segments.last?.text) { _, _ in
                    // 临时片段文字就地更新时保持贴底
                    scrollToLatest(proxy: proxy)
                }

                if !pinnedToBottom {
                    Button {
                        pinnedToBottom = true
                        withAnimation {
                            proxy.scrollTo(segments.last?.id, anchor: .bottom)
                        }
                    } label: {
                        Label("回到最新", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(10)
                }
            }
        }
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard pinnedToBottom, let lastID = segments.last?.id else { return }
        proxy.scrollTo(lastID, anchor: .bottom)
    }
}

/// 单个转写片段行
struct TranscriptRowView: View {
    let segment: TranscriptSegment
    let participant: Participant?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 开始时间
            Text(Self.formatMs(segment.startMs))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)

            // 说话人（未识别 → 识别中）
            Text(speakerName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(speakerColor)
                .frame(width: 88, alignment: .leading)
                .lineLimit(1)

            // 正文：临时文字浅色
            Text(segment.text)
                .font(.callout)
                .foregroundStyle(segment.state == .provisional ? .secondary : .primary)

            Spacer(minLength: 8)

            // 状态
            Text(segment.state.displayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(stateBackground, in: Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var speakerName: String {
        participant?.displayName ?? "识别中"
    }

    private var speakerColor: Color {
        if let participant {
            return colorForToken(participant.colorToken)
        }
        return .secondary
    }

    private var stateBackground: Color {
        switch segment.state {
        case .provisional: return .gray.opacity(0.15)
        case .final: return .green.opacity(0.15)
        case .edited: return .blue.opacity(0.15)
        case .failed: return .red.opacity(0.15)
        }
    }

    /// 毫秒 → mm:ss
    static func formatMs(_ ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
