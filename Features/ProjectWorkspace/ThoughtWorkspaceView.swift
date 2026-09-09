import AppKit
import SwiftUI

/// A 版右区手写笔记高度规则（纯值类型，body 与单测共用同一口径）。
/// - 笔记整区（含头部 + 编辑区 + 状态行）= 右区总高 25%，上限 180。
/// - 展开后仍须为下方 AI（对话/归结）留足空间；不足时收起笔记并把空间让给 AI。
enum ThoughtWorkspaceNoteHeightPolicy {
    /// 笔记整区占右区总高的比例
    static let shareOfTotal: CGFloat = 0.25
    /// 笔记整区高度上限
    static let maximumNoteHeight: CGFloat = 180
    /// 顶部标题行高度（header）
    static let headerHeight: CGFloat = 38
    /// 保存状态行高度（status）
    static let statusHeight: CGFloat = 24
    /// 笔记展开时下方 AI 区（含对话 header/composer）须保留的最低空间；
    /// 低于该值时先收起笔记，保证 AI 正文与输入按钮可见。
    static let minimumLowerSpaceWhenNotesExpanded: CGFloat = 440

    /// 笔记整区高度 = 总高 × 25%（含 header/status，不是编辑器单独 25%），上限 180。
    static func reservedNoteHeight(totalHeight: CGFloat) -> CGFloat {
        let share = max(0, totalHeight) * shareOfTotal
        return min(share, maximumNoteHeight)
    }

    /// 编辑器高度 = 整区高度 − 头部 − 状态行（不为负）。
    static func editorHeight(totalHeight: CGFloat) -> CGFloat {
        max(0, reservedNoteHeight(totalHeight: totalHeight)
            - headerHeight - statusHeight)
    }

    /// 是否适合展开笔记：25% 高度后下方仍有足够的 AI 空间。
    /// 低窗口先收起笔记，用户可经「专注手写笔记」sheet 编辑。
    static func shouldExpandNotes(totalHeight: CGFloat) -> Bool {
        max(0, totalHeight - reservedNoteHeight(totalHeight: totalHeight))
            >= minimumLowerSpaceWhenNotesExpanded
    }
}

/// 「笔记与 AI」右区（A 版 M2）：
/// - 上部持续可访问的手写笔记（真实 NoteController + StableNoteEditor，保留选区/IME/undo），
///   默认约占上部 25%、可收起、可展开；手写笔记永不触发发送（submitPolicy = .never）。
/// - 低高窗口优先收起笔记，把空间让给 AI 正文与输入。
/// - 下部 AI 对话/提问（复用 ProjectAIChatView），并提供独立「AI 归结」页：
///   每轮 AI 自动归结不改手写内容，用户可主动「摘入笔记」（按稳定 ID 去重）。
struct ThoughtWorkspaceView: View {
    @Bindable var noteController: NoteController
    let project: Project
    @Bindable var chatController: ProjectAIChatController
    let noteContextEnabled: Bool
    let onNoteContextChanged: (Bool) -> Void
    let onOpenSettings: () -> Void
    var speechController: AnswerSpeechController?
    let canReanalyze: Bool
    var onOpenEvidence: (EvidenceRouteTarget) -> Void = { _ in }
    var onReanalyze: () -> Void = {}
    /// 供范围条显示所选片段的当前文本
    var segmentsProvider: () -> [TranscriptSegment] = { [] }
    /// 外部（原话页）发起的输入框聚焦令牌：切到 AI 并聚焦输入
    var externalComposerFocusToken: UUID?
    /// 历史来源「回到完整对话」的轮次定位请求（透传给 ProjectAIChatView 消费）
    var conversationTurnNavigationRequest: AIChatNavigationRequest?
    var onConversationNavigationConsumed: (UUID) -> Void = { _ in }

    private enum LowerMode: String, CaseIterable {
        case chat = "AI 对话"
        case summaries = "AI 归结"
    }

    /// 顶部标题行高度（与高度规则一致，供 header 布局复用）
    private static var headerHeight: CGFloat { ThoughtWorkspaceNoteHeightPolicy.headerHeight }
    /// 保存状态行高度
    private static var statusHeight: CGFloat { ThoughtWorkspaceNoteHeightPolicy.statusHeight }

    @State private var notesCollapsed = false
    @State private var lowerMode: LowerMode = .chat
    @State private var insertNotice: String?
    /// 低高度自动收起笔记时打开的「笔记专注」sheet（同一 NoteController，保留选区/IME/undo）
    @State private var showNoteFocusSheet = false

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            // AI 空间不足（回复正文/输入按钮放不下）时先收起笔记
            let canExpandNotes =
                ThoughtWorkspaceNoteHeightPolicy.shouldExpandNotes(
                    totalHeight: totalHeight
                )
            let collapsed = notesCollapsed || !canExpandNotes
            let lowHeight = !canExpandNotes
            VStack(spacing: 0) {
                if collapsed {
                    collapsedNotesBar(lowHeight: lowHeight)
                } else {
                    notesPane(
                        editorHeight: ThoughtWorkspaceNoteHeightPolicy
                            .editorHeight(totalHeight: totalHeight)
                    )
                    .frame(
                        height: ThoughtWorkspaceNoteHeightPolicy
                            .reservedNoteHeight(totalHeight: totalHeight)
                    )
                }
                Divider()
                lowerPane
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(BWTheme.columnBackground.opacity(0.72))
        .onChange(of: externalComposerFocusToken) { _, token in
            // 从原话点「就这句问 AI」后必须切回对话页，让输入可见
            if token != nil, lowerMode != .chat {
                withAnimation(.easeInOut(duration: 0.15)) {
                    lowerMode = .chat
                }
            }
        }
        .onAppear {
            if conversationTurnNavigationRequest != nil { lowerMode = .chat }
        }
        .onChange(of: conversationTurnNavigationRequest) { _, request in
            if request != nil { lowerMode = .chat }
        }
        .sheet(isPresented: $showNoteFocusSheet) {
            noteFocusSheet
        }
    }

    /// 展开时整体笔记高度（含 header + 编辑器 + 状态行，总高 25%、上限 180）。
    private static func reservedNoteHeight(totalHeight: CGFloat) -> CGFloat {
        ThoughtWorkspaceNoteHeightPolicy.reservedNoteHeight(
            totalHeight: totalHeight
        )
    }

    /// 编辑器高度（同一纯值规则；body 与 notesPane 消费同一口径）
    private static func editorHeight(totalHeight: CGFloat) -> CGFloat {
        ThoughtWorkspaceNoteHeightPolicy.editorHeight(
            totalHeight: totalHeight
        )
    }

    // MARK: - 手写笔记（上部）

    private func notesPane(editorHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            notesHeader(expanded: true)
            Divider()
            StableNoteEditor(
                text: Binding(
                    get: { noteController.markdown },
                    set: { noteController.update(markdown: $0) }
                ),
                isEditable: true,
                accessibilityLabel: "项目手写笔记",
                accessibilityHelp: "手写笔记保存在本机；回车换行，永不自动发送",
                submitPolicy: .never,
                onSubmit: {}
            )
            .frame(height: editorHeight)
            noteStatusRow
        }
    }

    private func collapsedNotesBar(lowHeight: Bool) -> some View {
        VStack(spacing: 0) {
            notesHeader(expanded: false, canExpand: !lowHeight)
            if noteController.saveError != nil {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("笔记保存失败：\(noteController.saveError ?? "")")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("重试") { _ = noteController.saveNow() }
                        .controlSize(.small)
                        .frame(minHeight: BWTheme.minimumHitHeight)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: Self.statusHeight)
            }
        }
    }

    private func notesHeader(expanded: Bool, canExpand: Bool = true) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text")
                .foregroundStyle(BWTheme.accent)
            Text(expanded ? "手写笔记" : "手写笔记（已收起）")
                .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
            Spacer(minLength: 0)
            Toggle("供 AI 使用", isOn: Binding(
                get: { noteContextEnabled },
                set: { onNoteContextChanged($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("开启后，手写笔记用于 AI 回应、开花和完整总结的共创章节（最多 20,000 字）")
            .accessibilityLabel("手写笔记供 AI 使用")
            Button {
                if !expanded && !canExpand {
                    // 低高度窗口：用笔记专注 sheet 提供编辑入口，不挤占 AI 正文
                    showNoteFocusSheet = true
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        notesCollapsed.toggle()
                    }
                }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
            .frame(minWidth: BWTheme.minimumHitWidth, minHeight: BWTheme.minimumHitHeight)
            .help(expanded
                  ? "收起手写笔记"
                  : (canExpand
                     ? "展开手写笔记"
                     : "在专注窗口编辑手写笔记（不挤占 AI 空间）"))
            .accessibilityLabel(expanded
                                ? "收起手写笔记"
                                : (canExpand ? "展开手写笔记" : "在专注窗口编辑手写笔记"))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Self.headerHeight)
    }

    /// 笔记专注 sheet：低高度时也可随时编辑，处理保存失败，返回后仍回到 AI 页。
    private var noteFocusSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Label("专注手写笔记", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                if let saveError = noteController.saveError {
                    Text("保存失败：\(saveError)")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(.orange)
                }
                Button("完成") {
                    showNoteFocusSheet = false
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: BWTheme.minimumHitHeight)
            }
            .padding(12)
            Divider()
            StableNoteEditor(
                text: Binding(
                    get: { noteController.markdown },
                    set: { noteController.update(markdown: $0) }
                ),
                isEditable: true,
                accessibilityLabel: "专注手写笔记",
                accessibilityHelp: "回车换行；内容自动保存到项目笔记",
                submitPolicy: .never,
                onSubmit: {}
            )
            HStack {
                if noteController.saveError != nil {
                    Button("重试保存") { _ = noteController.saveNow() }
                        .frame(minHeight: BWTheme.minimumHitHeight)
                } else if let savedAt = noteController.lastSavedAt {
                    Text("已保存 \(savedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成并返回 AI") {
                    _ = noteController.saveNow()
                    showNoteFocusSheet = false
                }
                .frame(minHeight: BWTheme.minimumHitHeight)
            }
            .padding(12)
        }
        .frame(minWidth: 680, minHeight: 420)
    }

    private var noteStatusRow: some View {
        HStack(spacing: 6) {
            if let saveError = noteController.saveError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("笔记保存失败：\(saveError)")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
                Button("重试") { _ = noteController.saveNow() }
                    .controlSize(.small)
            } else if let savedAt = noteController.lastSavedAt {
                Text("已自动保存 \(savedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.secondary)
            } else {
                Text("笔记仅保存在本机")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let insertNotice {
                Text(insertNotice)
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.accent)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Self.statusHeight)
    }

    // MARK: - 下部（AI 对话 / AI 归结）

    private var lowerPane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $lowerMode) {
                ForEach(LowerMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 340)
            .tint(BWTheme.accent)

            if lowerMode == .chat {
                ProjectAIChatView(
                    controller: chatController,
                    legacyNoteMarkdown: "",
                    legacyNoteContextEnabled: noteContextEnabled,
                    canReanalyze: canReanalyze,
                    onLegacyNoteContextChanged: onNoteContextChanged,
                    onReanalyze: onReanalyze,
                    onOpenSettings: onOpenSettings,
                    speechController: speechController,
                    hidesLegacyNoteCard: true,
                    segmentsProvider: segmentsProvider,
                    externalComposerFocusToken: externalComposerFocusToken,
                    onOpenEvidence: onOpenEvidence,
                    composerSubmitPolicy: .newlineOnReturnSendOnCommand,
                    conversationTurnNavigationRequest: conversationTurnNavigationRequest,
                    onConversationNavigationConsumed: onConversationNavigationConsumed
                )
            } else {
                summariesPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summariesPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if noteController.saveError != nil {
                    HStack {
                        Text("笔记尚未保存，当前内容仍保留在窗口中。")
                            .foregroundStyle(.orange)
                        Button("重试保存") { noteController.saveNow() }
                    }
                    .font(.system(size: BWTheme.fontSizeDetail))
                }
                if chatController.conversationSummaries.isEmpty {
                    ContentUnavailableView(
                        "还没有 AI 归结",
                        systemImage: "text.badge.checkmark",
                        description: Text("每轮 AI 回应后，会在不修改手写内容的前提下生成独立归结，可主动摘入笔记。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                ForEach(chatController.conversationSummaries.reversed()) { summary in
                    summaryCard(summary)
                }
            }
            .padding(10)
        }
    }

    private func summaryCard(_ summary: NoteDocument.ConversationSummary) -> some View {
        let alreadyInserted = noteController.insertedSummaryIDs.contains(summary.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("AI 归结")
                    .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                Text(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    insertSummary(summary)
                } label: {
                    Text(alreadyInserted ? "已摘入" : "摘入笔记")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: BWTheme.fontSizeDetail))
                .frame(minHeight: BWTheme.minimumHitHeight)
                .disabled(alreadyInserted)
                .help(alreadyInserted
                      ? "已按稳定 ID 去重，不会重复插入"
                      : "把本轮归结追加到手写笔记（按轮次去重）")
                .accessibilityLabel(alreadyInserted ? "该归结已摘入手写笔记" : "摘入本轮归结到手写笔记")
            }
            Text(summary.markdown)
                .font(.system(size: BWTheme.fontSizeBody))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if summary.sourceTurnID != nil {
                    Label("第 \(summaryIndex(of: summary)) 轮", systemImage: "number")
                }
                if !summary.evidenceCopies.isEmpty {
                    Label("\(summary.evidenceCopies.count) 条原话依据",
                          systemImage: "text.quote")
                }
                if !summary.citedWebSources.isEmpty {
                    Label("\(summary.citedWebSources.count) 个联网来源",
                          systemImage: "globe")
                }
                Spacer()
            }
            .font(.system(size: BWTheme.fontSizeDetail))
            .foregroundStyle(.secondary)

            if !summary.evidenceCopies.isEmpty {
                ForEach(Array(summary.evidenceCopies.enumerated()), id: \.element.id) { index, copy in
                    Button {
                        let turnID = summary.sourceTurnID ?? summary.id
                        onOpenEvidence(.aiHistory(turnID: turnID,
                                                  requestScopeLabel: "AI 归结第 \(summaryIndex(of: summary)) 轮",
                                                  copy: copy))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "text.quote")
                            Text("当时依据 \(index + 1) · \(TranscriptRowView.formatMs(copy.startMs))")
                            Text(copy.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .padding(.horizontal, 8)
                        .frame(minHeight: BWTheme.minimumHitHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BWTheme.accent)
                    .help("打开「当时依据」对照")
                    .accessibilityLabel("打开第 \(index + 1) 条当时依据")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bwCard(padding: 10)
    }

    private func summaryIndex(of summary: NoteDocument.ConversationSummary) -> Int {
        guard let index = chatController.conversationSummaries.firstIndex(
            where: { $0.id == summary.id }
        ) else { return 0 }
        return index + 1
    }

    private func insertSummary(_ summary: NoteDocument.ConversationSummary) {
        let result = noteController.insertSummary(summary)
        switch result {
        case .inserted:
            if noteController.saveError == nil {
                insertNotice = "已摘入手写笔记"
            } else {
                insertNotice = nil
            }
        case .duplicate:
            insertNotice = "该归结已在手写笔记中"
        case .emptySummary:
            insertNotice = nil
        }
    }
}
