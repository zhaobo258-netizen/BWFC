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
    var sourceRecordingTitle: String?
    var isHighlighted: Bool
    /// 批量模式（说话人左键指认计划 20261007）：显示复选框
    var isBatchMode: Bool = false
    /// 批量模式中的选中态（以片段 UUID 为准，由工作台持有）
    var isSelected: Bool = false

    /// 由片段映射（纯函数，可单测）
    static func make(
        from segment: TranscriptSegment,
        participants: [Participant],
        unknownDisplay: String?,
        highlightedID: UUID?,
        sourceRecordingTitle: String? = nil,
        displayStartMs: Int64? = nil,
        isBatchMode: Bool = false,
        isSelected: Bool = false
    ) -> TranscriptRowData {
        let participant = segment.participantId.flatMap { id in
            participants.first(where: { $0.id == id })
        }
        // 整场回填冲突（15 号计划 F02）：旧归属待人工复核，在行内如实标注
        let conflictSuffix = segment.speakerAttributionConflict == true ? "（归属待确认）" : ""
        return TranscriptRowData(
            id: segment.id,
            startMs: displayStartMs ?? segment.startMs,
            text: segment.text,
            state: segment.state,
            source: segment.source,
            isStarred: segment.isStarred,
            speakerName: (participant?.displayName ?? (unknownDisplay ?? "识别中")) + conflictSuffix,
            speakerColorToken: participant?.colorToken,
            sourceRecordingTitle: sourceRecordingTitle,
            isHighlighted: segment.id == highlightedID,
            isBatchMode: isBatchMode,
            isSelected: isSelected
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

enum TranscriptScrollPolicy {
    static func isAtBottom(
        contentOffsetY: CGFloat,
        containerHeight: CGFloat,
        contentHeight: CGFloat,
        tolerance: CGFloat = 24
    ) -> Bool {
        contentOffsetY + containerHeight >= contentHeight - tolerance
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
    /// 录音中的实时电平（0…1）。空态时把「已在录、收到声音了」放到用户正在看的位置，
    /// 而不是只留在窗口边缘的电平条上。非录音场景传 nil。
    var liveAudioLevel: Float?
    var emptyTitle: String = "等待第一段发言"
    var emptyDetail: String = "开始说话后，实时转写会显示在这里"
    var onPlaySegment: ((TranscriptSegment) -> Void)?
    /// 编辑回调（由父视图持久化）
    var onAssignSpeaker: ((TranscriptSegment, Participant?) -> Void)?
    var onEditText: ((TranscriptSegment, String) -> Void)?
    var onToggleStar: ((TranscriptSegment) -> Void)?
    /// 全局纠错（错词, 正词）→ 由父视图执行替换、持久化并记住规则
    var onGlobalCorrect: ((String, String) -> Int)?
    /// 打开完整指认弹层：可选已有/新建人物，并显式批量标注未确认发言。
    var onRequestSpeakerAssignment: ((TranscriptSegment) -> Void)?
    /// 「就这句问 AI」：把该片段设为当前提问范围（M2 原话页）
    var onAskAI: ((TranscriptSegment) -> Void)?
    /// 合并分析项目用：展示该片段来自哪段原始录音及其原始时间戳。
    var sourceRecordingTitle: ((TranscriptSegment) -> String?)? = nil
    var sourceRecordingStartMs: ((TranscriptSegment) -> Int64)? = nil

    // MARK: 左键快捷指认（说话人左键指认计划 20261007；工作台单一弹层路由）

    /// 当前打开人物弹层的片段（nil = 无弹层；同一时间只有一个）
    var quickAssignSegmentID: UUID? = nil
    /// 本场可选人物（快捷弹层列表）
    var quickAssignSpeakers: [Speaker] = []
    /// 弹层内当前已归属人物（用于勾选态展示）
    var quickAssignCurrentSpeaker: ((TranscriptSegment) -> UUID?)? = nil
    /// 打开弹层（工作台路由：同一时间只保留一个人物选择面板）
    var onQuickAssignOpen: ((TranscriptSegment) -> Void)? = nil
    /// 返回 true 表示已成功保存（弹层关闭）；false 表示失败（弹层保留可重试）
    var onQuickAssignPick: ((TranscriptSegment, Speaker) -> Bool)? = nil
    var onQuickAssignCreate: ((TranscriptSegment, String, String?) -> Bool)? = nil
    /// 清除归属（弹层“更多操作”，与指认具备同等撤销能力）；返回 true 表示已保存
    var onQuickAssignClear: ((TranscriptSegment) -> Bool)? = nil
    /// 从单条弹层进入批量模式（自动勾选当前句）
    var onQuickAssignStartBatch: ((TranscriptSegment) -> Void)? = nil
    var onQuickAssignDismiss: (() -> Void)? = nil

    // MARK: 多选批量（计划 20261007 §三）

    var isBatchMode: Bool = false
    var selectedSegmentIds: Set<UUID> = []
    var onToggleSelect: ((UUID, Bool) -> Void)? = nil
    /// Shift 连续范围选择（锚点由工作台持有）
    var onShiftSelect: ((UUID) -> Void)? = nil

    /// 是否贴底自动滚动
    @State private var pinnedToBottom = true
    @State private var pendingScrollTask: Task<Void, Never>?
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
                                Text(emptyTitle)
                                    .font(.callout)
                                    .fontWeight(.medium)
                                Text(emptyDetail)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                if let liveAudioLevel {
                                    emptyStateLevelMeter(level: liveAudioLevel)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 28)
                        }
                        ForEach(rows) { row in
                            assignRow(row)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onScrollPhaseChange { _, newPhase, context in
                    switch newPhase {
                    case .interacting:
                        if pinnedToBottom {
                            pinnedToBottom = false
                        }
                    case .idle:
                        let geometry = context.geometry
                        let isAtBottom = TranscriptScrollPolicy.isAtBottom(
                            contentOffsetY: geometry.contentOffset.y,
                            containerHeight: geometry.containerSize.height,
                            contentHeight: geometry.contentSize.height
                        )
                        if pinnedToBottom != isAtBottom {
                            pinnedToBottom = isAtBottom
                        }
                    default:
                        break
                    }
                }
                .onChange(of: segments.count) { _, _ in
                    // 多选时暂停自动追随（计划 20261007 §三）：新到达的原话不自动入选，
                    // 退出批量后由用户通过“回到最新”恢复跟随
                    guard !isBatchMode else { return }
                    scrollToLatest(proxy: proxy)
                }
                .onChange(of: segments.last?.text) { _, _ in
                    // 追加中更新末句文字同样不得把批量视图拉到底部（审查修复 7）
                    guard !isBatchMode else { return }
                    scrollToLatest(proxy: proxy)
                }
                .onChange(of: isBatchMode) { _, batch in
                    if batch {
                        // 进入批量：取消挂起的滚动并解除贴底，位置留在用户当前查看处
                        pendingScrollTask?.cancel()
                        pendingScrollTask = nil
                        if pinnedToBottom { pinnedToBottom = false }
                    }
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
                        pendingScrollTask?.cancel()
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
        .onDisappear {
            pendingScrollTask?.cancel()
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

    /// 空态里的电平反馈：录音刚开始时用户最需要的是「设备真的在收音」的确认
    private func emptyStateLevelMeter(level: Float) -> some View {
        VStack(spacing: 5) {
            ProgressView(value: Double(min(max(level, 0), 1)))
                .frame(width: 140)
                .tint(BWTheme.accent)
            if level > 0.02 {
                Text("已收到声音")
                    .font(.caption2)
                    .foregroundStyle(BWTheme.accent)
            } else {
                Text("正在收音，暂未检测到声音")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(level > 0.02 ? "已收到声音" : "正在收音，暂未检测到声音")
    }

    /// 片段 → 行数据（纯映射；行 Equatable 保证未变化行零重建）
    private var rows: [TranscriptRowData] {
        segments.map { segment in
            TranscriptRowData.make(
                from: segment,
                participants: participants,
                unknownDisplay: unknownSpeakerDisplay?(segment),
                highlightedID: highlightedSegmentID,
                sourceRecordingTitle: sourceRecordingTitle?(segment),
                displayStartMs: sourceRecordingStartMs?(segment),
                isBatchMode: isBatchMode,
                isSelected: selectedSegmentIds.contains(segment.id)
            )
        }
    }

    /// 行构造（拆出以控制类型检查复杂度）：批量状态、弹层锚点与手势隔离
    @ViewBuilder
    private func assignRow(_ row: TranscriptRowData) -> some View {
        let segment = segments.first(where: { $0.id == row.id })
        let showsButton = onQuickAssignPick != nil && segment != nil
        TranscriptRowView(
            row: row,
            showsSpeakerButton: showsButton,
            onSpeakerTap: segment.map { seg in { handleSpeakerAreaTap(seg) } },
            onToggleSelect: segment.map { seg in { handleSpeakerAreaTap(seg) } }
        )
        .popover(
            isPresented: quickAssignPopoverShown(for: row),
            arrowEdge: .bottom
        ) {
            if let seg = segment {
                QuickSpeakerAssignPopover(
                    segment: seg,
                    speakers: quickAssignSpeakers,
                    currentSpeakerID: quickAssignCurrentSpeaker?(seg),
                    onPick: { if onQuickAssignPick?(seg, $0) == true { onQuickAssignDismiss?() } },
                    onCreate: { if onQuickAssignCreate?(seg, $0, $1) == true { onQuickAssignDismiss?() } },
                    onClear: { if onQuickAssignClear?(seg) == true { onQuickAssignDismiss?() } },
                    onStartBatch: {
                        onQuickAssignStartBatch?(seg)
                        onQuickAssignDismiss?()
                    }
                )
            }
        }
        .onTapGesture(count: 2) {
            if let segment {
                onPlaySegment?(segment)
            }
        }
        .contextMenu {
            if let onPlaySegment, let segment {
                Button("从此处回听") { onPlaySegment(segment) }
            }
            rowContextMenu(for: row)
        }
    }

    private func quickAssignPopoverShown(for row: TranscriptRowData) -> Binding<Bool> {
        Binding(
            get: { quickAssignSegmentID == row.id },
            set: { shown in
                if !shown, quickAssignSegmentID == row.id {
                    onQuickAssignDismiss?()
                }
            }
        )
    }

    /// 头像/姓名区域点击：批量模式下切换勾选（Shift 为连续范围），
    /// 非批量模式下打开人物弹层（由工作台单一弹层路由持有）。
    private func handleSpeakerAreaTap(_ segment: TranscriptSegment) {
        if isBatchMode {
            // 批量模式：复选框/头像/姓名统一走这里（审查修复 2）；
            // Shift 为连续范围，普通点击切换勾选
            if NSEvent.modifierFlags.contains(.shift) {
                onShiftSelect?(segment.id)
            } else {
                onToggleSelect?(segment.id, !selectedSegmentIds.contains(segment.id))
            }
            return
        }
        if quickAssignSegmentID == segment.id {
            onQuickAssignDismiss?()
        } else {
            onQuickAssignOpen?(segment)
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
                    // 冲突后缀不参与勾选匹配：按人物名比对
                    if row.speakerName
                        .replacingOccurrences(of: "（归属待确认）", with: "")
                        == item.title.components(separatedBy: "（").first {
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
            if onRequestSpeakerAssignment != nil {
                Button("指认或批量标注…") {
                    guard let segment = segment(for: row) else { return }
                    onRequestSpeakerAssignment?(segment)
                }
            }
        }
        Button("就这句问 AI…") {
            guard let segment = segment(for: row) else { return }
            onAskAI?(segment)
        }
        .disabled(onAskAI == nil)
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
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, pinnedToBottom else { return }
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

/// 单个转写片段行（Equatable：row 未变则 body 零重建）
struct TranscriptRowView: View, Equatable {
    let row: TranscriptRowData
    /// 头像/姓名是否作为左键指认按钮（原话与标记页启用）
    var showsSpeakerButton: Bool = false
    var onSpeakerTap: (() -> Void)? = nil
    /// 批量模式复选框点击
    var onToggleSelect: (() -> Void)? = nil

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if row.isBatchMode {
                Button {
                    onToggleSelect?()
                } label: {
                    Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(row.isSelected ? BWTheme.accent : .secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(row.isSelected ? "取消勾选" : "勾选这一条")
                .accessibilityLabel(row.isSelected ? "取消勾选这一条" : "勾选这一条")
                .padding(.top, 1)
            }
            speakerArea
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    speakerLabel
                    Text(Self.formatMs(row.startMs))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    if let sourceRecordingTitle = row.sourceRecordingTitle {
                        Text(sourceRecordingTitle)
                            .font(.caption2)
                            .foregroundStyle(BWTheme.accent.opacity(0.8))
                            .lineLimit(1)
                    }
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
            rowBackground,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    /// 选中底纹 > 证据高亮 > 无
    private var rowBackground: Color {
        if row.isSelected { return BWTheme.accent.opacity(0.10) }
        if row.isHighlighted { return BWTheme.accent.opacity(0.14) }
        return .clear
    }

    /// 头像：批量模式下是勾选区域；否则在启用指认的页面是弹层按钮
    private var speakerArea: some View {
        Group {
            if showsSpeakerButton, !row.isBatchMode {
                Button {
                    onSpeakerTap?()
                } label: {
                    BWSpeakerDot(name: row.speakerName, color: speakerColor, size: 22)
                        .frame(minWidth: 22, minHeight: 22)
                }
                .buttonStyle(.plain)
                .help("指认说话人")
                .accessibilityLabel("指认这句话的说话人")
            } else if row.isBatchMode {
                Button {
                    onToggleSelect?()
                } label: {
                    BWSpeakerDot(name: row.speakerName, color: speakerColor, size: 22)
                        .frame(minWidth: 22, minHeight: 22)
                }
                .buttonStyle(.plain)
                .help(row.isSelected ? "取消勾选" : "勾选这一条")
                .accessibilityLabel(row.isSelected ? "取消勾选这一条" : "勾选这一条")
            } else {
                BWSpeakerDot(name: row.speakerName, color: speakerColor, size: 22)
            }
        }
    }

    /// 姓名标签：启用指认时同为按钮；批量模式点击等同勾选
    @ViewBuilder
    private var speakerLabel: some View {
        if showsSpeakerButton, !row.isBatchMode {
            Button {
                onSpeakerTap?()
            } label: {
                Text(row.speakerName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(speakerColor)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("指认说话人")
        } else if row.isBatchMode {
            Button {
                onToggleSelect?()
            } label: {
                Text(row.speakerName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(speakerColor)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            Text(row.speakerName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(speakerColor)
                .lineLimit(1)
        }
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

/// 左键快捷指认弹层（说话人左键指认计划 20261007 §二）：
/// 一次点击打开、一次点击人物完成；注明“仅修改这一条”，
/// 不同组回填、不学声纹、不启动整场回查。
struct QuickSpeakerAssignPopover: View {
    let segment: TranscriptSegment
    let speakers: [Speaker]
    let currentSpeakerID: UUID?
    var onPick: (Speaker) -> Void
    var onCreate: (String, String?) -> Void
    /// 清除归属（更多操作；具备同等撤销能力）
    var onClear: (() -> Void)? = nil
    /// 进入多选批量（自动勾选当前句）
    var onStartBatch: (() -> Void)? = nil

    @State private var searchText = ""
    @State private var newName = ""
    @State private var newRole = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredSpeakers: [Speaker] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return speakers }
        return speakers.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.role ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这句话是谁说的")
                .font(.headline)
            Text("仅修改这一条；原文：" + String(segment.text.prefix(60)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if speakers.count > 6 {
                TextField("按姓名或角色搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(filteredSpeakers) { speaker in
                        Button {
                            onPick(speaker)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: currentSpeakerID == speaker.id
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(currentSpeakerID == speaker.id
                                        ? BWTheme.accent : .secondary)
                                    .font(.caption)
                                BWSpeakerDot(name: speaker.displayName,
                                             color: colorForToken(speaker.colorToken), size: 20)
                                Text(speaker.displayName)
                                    .font(.callout)
                                if let role = speaker.role, !role.isEmpty {
                                    Text(role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if speaker.voiceSamplePath != nil {
                                    Image(systemName: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                        .help("已有声纹样本")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                    if filteredSpeakers.isEmpty {
                        Text("没有匹配的人物")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxHeight: 180)

            Divider()

            VStack(spacing: 6) {
                TextField("新人物姓名（本场添加）", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(createIfValid)
                TextField("角色 / 职位（可选）", text: $newRole)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(createIfValid)
                Button("添加人物并指认") { createIfValid() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedName.isEmpty)
            }

            HStack(spacing: 10) {
                if onStartBatch != nil {
                    Button("选择多条后指认…") {
                        onStartBatch?()
                    }
                    .controlSize(.small)
                }
                if onClear != nil, currentSpeakerID != nil {
                    Button("清除归属", role: .destructive) {
                        onClear?()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func createIfValid() {
        guard !trimmedName.isEmpty else { return }
        let role = newRole.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(trimmedName, role.isEmpty ? nil : role)
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
