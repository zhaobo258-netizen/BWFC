import SwiftUI

/// 底部同声转写面板（实施计划 6.5）：
/// - 默认自动滚动到最新；用户向上浏览后暂停滚动并显示「回到最新」；
/// - 临时文字使用较浅颜色；最终替换就地更新（片段 ID 稳定，不整页跳动）；
/// - 说话人未识别时显示「识别中 / 待识别 A…」；
/// - 右键可修改说话人（含待识别映射）、修改文字、加星标（阶段 3）。
struct TranscriptPanelView: View {
    let segments: [TranscriptSegment]
    let participants: [Participant]
    /// 未知说话人标签展示名（「待识别 A/B」，由 DiarizationController 提供）
    var unknownSpeakerDisplay: ((TranscriptSegment) -> String?)?
    /// 证据定位高亮的片段 ID（点击左右两栏证据时设置）
    var highlightedSegmentID: UUID?
    /// 编辑回调（由父视图持久化）
    var onAssignSpeaker: ((TranscriptSegment, Participant?) -> Void)?
    var onEditText: ((TranscriptSegment, String) -> Void)?
    var onToggleStar: ((TranscriptSegment) -> Void)?

    /// 是否贴底自动滚动
    @State private var pinnedToBottom = true
    /// 正在编辑文字的片段
    @State private var editingTextSegment: TranscriptSegment?
    @State private var editingText: String = ""

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
                                participant: participants.first(where: { $0.id == segment.participantId }),
                                unknownDisplay: unknownSpeakerDisplay?(segment)
                            )
                            .id(segment.id)
                            .background(
                                segment.id == highlightedSegmentID
                                    ? Color.yellow.opacity(0.25)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                            .contextMenu {
                                speakerMenu(for: segment)
                                Button("修改文字…") {
                                    editingText = segment.text
                                    editingTextSegment = segment
                                }
                                Divider()
                                Button(segment.isStarred ? "取消星标" : "加星标") {
                                    onToggleStar?(segment)
                                }
                            }
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
                .onChange(of: highlightedSegmentID) { _, newValue in
                    // 点击证据：定位到对应片段（滚动 + 高亮）
                    if let id = newValue, segments.contains(where: { $0.id == id }) {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
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
        .sheet(item: $editingTextSegment) { segment in
            VStack(alignment: .leading, spacing: 12) {
                Text("修改转写文字")
                    .font(.headline)
                Text("修改后该片段标记为「人工已修订」，不再被云端结果覆盖。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $editingText)
                    .frame(minHeight: 100)
                    .border(.quaternary)
                HStack {
                    Spacer()
                    Button("取消") { editingTextSegment = nil }
                    Button("保存") {
                        onEditText?(segment, editingText)
                        editingTextSegment = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 480, height: 260)
        }
    }

    /// 说话人修改菜单（含待识别映射与清除）
    @ViewBuilder
    private func speakerMenu(for segment: TranscriptSegment) -> some View {
        Menu("修改说话人") {
            ForEach(participants) { participant in
                Button {
                    onAssignSpeaker?(segment, participant)
                } label: {
                    if segment.participantId == participant.id {
                        Label("\(participant.displayName)（\(participant.side.displayName)）", systemImage: "checkmark")
                    } else {
                        Text("\(participant.displayName)（\(participant.side.displayName)）")
                    }
                }
            }
            if segment.participantId != nil {
                Divider()
                Button("清除说话人映射") {
                    onAssignSpeaker?(segment, nil)
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
    /// 未知说话人的展示名（「待识别 A」）
    var unknownDisplay: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 开始时间
            Text(Self.formatMs(segment.startMs))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)

            // 星标
            if segment.isStarred {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }

            // 说话人（未识别 → 识别中 / 待识别 A）
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
            Text(stateLabel)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(stateBackground, in: Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var speakerName: String {
        if let participant { return participant.displayName }
        return unknownDisplay ?? "识别中"
    }

    private var speakerColor: Color {
        if let participant {
            return colorForToken(participant.colorToken)
        }
        return .secondary
    }

    /// 状态标签：按来源与状态区分（实施计划 6.5）
    private var stateLabel: String {
        switch segment.state {
        case .provisional:
            return "识别中"
        case .final:
            return segment.source == .cloud ? "云端已确认" : "已确认"
        case .edited:
            return "人工已修订"
        case .failed:
            return "待重试"
        }
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
