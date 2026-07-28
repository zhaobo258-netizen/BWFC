import SwiftUI

/// 转写行数据（值类型，Equatable）。
/// SwiftUI 以行级 Equatable 做差分：未变化的行不重建 body（渲染风暴根治点）。
struct TranscriptRowData: Equatable, Identifiable {
    let id: UUID
    var startMs: Int64
    var text: String
    var state: SegmentState
    var source: SegmentSource
    var isStarred: Bool
    var speakerName: String
    var speakerColorToken: String?
    var isHighlighted: Bool

    /// 由片段映射（纯函数，可单测）
    static func make(
        from segment: TranscriptSegment,
        participants: [Participant],
        unknownDisplay: String?,
        highlightedID: UUID?
    ) -> TranscriptRowData {
        let participant = segment.participantId.flatMap { id in
            participants.first(where: { $0.id == id })
        }
        return TranscriptRowData(
            id: segment.id,
            startMs: segment.startMs,
            text: segment.text,
            state: segment.state,
            source: segment.source,
            isStarred: segment.isStarred,
            speakerName: participant?.displayName ?? (unknownDisplay ?? "识别中"),
            speakerColorToken: participant?.colorToken,
            isHighlighted: segment.id == highlightedID
        )
    }
}

/// 说话人菜单项（值类型）。
/// 由参会人列表**预先构建一次**（替代每行每次重建时对参会人 class 数组做
/// ForEach 泛型 keypath 解析——采样中该路径占单行成本大头）。
struct SpeakerMenuItem: Equatable, Identifiable {
    let id: UUID
    let title: String

    static func makeItems(from participants: [Participant]) -> [SpeakerMenuItem] {
        participants.map {
            SpeakerMenuItem(id: $0.id, title: "\($0.displayName)（\($0.side.displayName)）")
        }
    }
}

/// 底部同声转写面板（实施计划 6.5）：
/// - 默认自动滚动到最新；用户向上浏览后暂停滚动并显示「回到最新」；
/// - 临时文字使用较浅颜色；最终替换就地更新（片段 ID 稳定，不整页跳动）；
/// - 说话人未识别时显示「识别中 / 待识别 A…」；
/// - 右键可修改说话人（含待识别映射）、修改文字、加星标（阶段 3）。
/// 性能：行视图为 Equatable，未变化行零重建；菜单内容预计算为值类型数组。
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
    /// 全局纠错（错词, 正词）→ 由父视图执行替换、持久化并记住规则
    var onGlobalCorrect: ((String, String) -> Int)?

    /// 是否贴底自动滚动
    @State private var pinnedToBottom = true
    /// 正在编辑文字的片段
    @State private var editingTextSegment: TranscriptSegment?
    @State private var editingText: String = ""
    /// 纠错弹层：源片段（提供原文参照）
    @State private var correctingSegment: TranscriptSegment?

    var body: some View {
        let _ = PerfCounters.incrementPanelBodyEval() // 求值计数（自激排查；写非观测全局，安全）
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if segments.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .font(.title2)
                                    .foregroundStyle(BWTheme.accent.opacity(0.75))
                                Text("等待第一段发言")
                                    .font(.callout)
                                    .fontWeight(.medium)
                                Text("开始说话后，实时转写会显示在这里")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 28)
                        }
                        ForEach(rows) { row in
                            TranscriptRowView(row: row)
                                .contextMenu {
                                    rowContextMenu(for: row)
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
        .sheet(item: $correctingSegment) { segment in
            GlobalCorrectionSheet(
                sourceText: segment.text,
                matchCount: { wrong in
                    TranscriptCorrector.matchCount(of: wrong, in: segments)
                },
                onApply: { wrong, right in
                    onGlobalCorrect?(wrong, right) ?? 0
                }
            )
        }
    }

    /// 片段 → 行数据（纯映射；行 Equatable 保证未变化行零重建）
    private var rows: [TranscriptRowData] {
        segments.map { segment in
            TranscriptRowData.make(
                from: segment,
                participants: participants,
                unknownDisplay: unknownSpeakerDisplay?(segment),
                highlightedID: highlightedSegmentID
            )
        }
    }

    /// 说话人菜单项（预计算为值类型数组；参会人不变时内容稳定）
    private var speakerItems: [SpeakerMenuItem] {
        SpeakerMenuItem.makeItems(from: participants)
    }

    /// 行右键菜单（扁平、值类型驱动）
    @ViewBuilder
    private func rowContextMenu(for row: TranscriptRowData) -> some View {
        Section("修改说话人") {
            ForEach(speakerItems) { item in
                Button {
                    guard let segment = segment(for: row),
                          let participant = participants.first(where: { $0.id == item.id }) else {
                        return
                    }
                    onAssignSpeaker?(segment, participant)
                } label: {
                    if row.speakerName == item.title.components(separatedBy: "（").first {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
            if hasSpeaker(row) {
                Button("清除说话人映射") {
                    guard let segment = segment(for: row) else { return }
                    onAssignSpeaker?(segment, nil)
                }
            }
        }
        Button("修改文字…") {
            guard let segment = segment(for: row) else { return }
            editingText = segment.text
            editingTextSegment = segment
        }
        Button("纠错（全局替换）…") {
            guard let segment = segment(for: row) else { return }
            correctingSegment = segment
        }
        Divider()
        Button(row.isStarred ? "取消星标" : "加星标") {
            guard let segment = segment(for: row) else { return }
            onToggleStar?(segment)
        }
    }

    /// 行 → 原始片段（编辑操作需要模型引用）
    private func segment(for row: TranscriptRowData) -> TranscriptSegment? {
        segments.first(where: { $0.id == row.id })
    }

    private func hasSpeaker(_ row: TranscriptRowData) -> Bool {
        segment(for: row)?.participantId != nil
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard pinnedToBottom, let lastID = segments.last?.id else { return }
        proxy.scrollTo(lastID, anchor: .bottom)
    }
}

/// 单个转写片段行（Equatable：row 未变则 body 零重建）
struct TranscriptRowView: View, Equatable {
    let row: TranscriptRowData

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BWSpeakerDot(name: row.speakerName, color: speakerColor, size: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.speakerName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(speakerColor)
                        .lineLimit(1)
                    Text(Self.formatMs(row.startMs))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    if row.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Spacer(minLength: 4)
                    // 状态标签：仅非常态（识别中/人工修订/待重试）显示，减少视觉噪音
                    if row.state != .final {
                        Text(stateLabel)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(stateBackground, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(row.text)
                    .font(.callout)
                    .foregroundStyle(row.state == .provisional ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            row.isHighlighted ? BWTheme.accent.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var speakerColor: Color {
        if let token = row.speakerColorToken {
            return colorForToken(token)
        }
        return .gray
    }

    /// 状态标签：按来源与状态区分（实施计划 6.5）
    private var stateLabel: String {
        switch row.state {
        case .provisional:
            return "识别中"
        case .final:
            return row.source == .cloud ? "云端已确认" : "已确认"
        case .edited:
            return "人工已修订"
        case .failed:
            return "待重试"
        }
    }

    private var stateBackground: Color {
        switch row.state {
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

/// 全局纠错弹层（老板 2026-07-27 需求 2）：
/// 从原文中选中/输入错词 → 输入正词 → 预览命中片段数 → 一键全局替换。
/// 替换同时记为纠错规则：之后到达的转写（本地与云端）自动套用；正词进入词库。
struct GlobalCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sourceText: String
    let matchCount: (String) -> Int
    /// 执行纠错，返回实际修改的片段数
    let onApply: (String, String) -> Int

    @State private var wrong: String = ""
    @State private var right: String = ""
    @State private var resultMessage: String?

    private var trimmedWrong: String { wrong.trimmingCharacters(in: .whitespaces) }
    private var trimmedRight: String { right.trimmingCharacters(in: .whitespaces) }
    private var canApply: Bool {
        TranscriptCorrector.isValidRule(wrong: trimmedWrong, right: trimmedRight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("转写纠错")
                .font(.headline)
            Text("原文（选中错词后可直接拷贝）：")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(sourceText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
            .padding(8)
            .background(BWTheme.columnBackground, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                TextField("听错的词", text: $wrong)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("正确的词", text: $right)
                    .textFieldStyle(.roundedBorder)
            }

            if !trimmedWrong.isEmpty {
                let hits = matchCount(trimmedWrong)
                Text(hits > 0 ? "将替换 \(hits) 个片段中的「\(trimmedWrong)」" : "当前文稿未找到「\(trimmedWrong)」")
                    .font(.caption)
                    .foregroundStyle(hits > 0 ? Color.secondary : Color.orange)
            }
            Text("替换整场文稿并记住这条纠错：之后的转写自动纠正，正词加入词库优先识别。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("全局纠错") {
                    let changed = onApply(trimmedWrong, trimmedRight)
                    resultMessage = "已纠正 \(changed) 个片段，并记住该规则。"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
