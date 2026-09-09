import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectAIChatView: View {
    @Bindable var controller: ProjectAIChatController
    let legacyNoteMarkdown: String
    let legacyNoteContextEnabled: Bool
    let canReanalyze: Bool
    let onLegacyNoteContextChanged: (Bool) -> Void
    let onReanalyze: () -> Void
    let onOpenSettings: () -> Void
    /// 语音外放（12 号 §10：点击播放/停止，可取消）
    var speechController: AnswerSpeechController?
    /// 由上层 ThoughtWorkspaceView 提供：不再渲染只读 legacy note 卡（手写笔记已在顶部可编辑）
    var hidesLegacyNoteCard = false
    /// 供范围条/范围 chips 取当前片段文本
    var segmentsProvider: () -> [TranscriptSegment] = { [] }
    /// 外部（原话页）聚焦请求：非空时把输入框设为第一响应者（一次性令牌）
    var externalComposerFocusToken: UUID?
    /// 历史/本轮证据回链统一出口（M2 证据抽屉）
    var onOpenEvidence: (EvidenceRouteTarget) -> Void = { _ in }
    /// A 版提交策略：Enter 换行、⌘↩ 发送（旧默认保持 `.sendOnReturn`）
    var composerSubmitPolicy: NoteEditorSubmitPolicy = .sendOnReturn
    /// 历史来源「回到完整对话」的轮次定位请求（每次点击换新 id；AIChatView 消费一次）
    var conversationTurnNavigationRequest: AIChatNavigationRequest?
    var onConversationNavigationConsumed: (UUID) -> Void = { _ in }

    @State private var isConfirmingClear = false
    @State private var isSelectingReferenceDocuments = false
    @State private var isLegacyNoteExpanded = false
    @State private var isDropTargeted = false
    /// 消息列表是否贴底（A 版：用户上翻历史后，新增消息不再强制滚底）
    @State private var messagesPinnedToBottom = true
    @State private var hasNewReplyWhileAway = false
    @State private var lastFocusTokenHandled: UUID?
    /// 用户是否正在亲自滚动（拖拽/惯性）。只有用户滚动结束后才按位置更新贴底，
    /// 程序化 scrollTo 定位（如长回复 .top）不把跟随状态误判成「用户离开」。
    @State private var userScrollInteractionInProgress = false
    /// 可读大视图：窄列里也能完整阅读/展开对话
    @State private var isConversationExpanded = false
    /// 展开大视图时的定位目标（assistant 消息 id）；nil = 不定位
    @State private var expandedConversationScrollTarget: UUID?
    /// 该轮正文已不在保留记录中（被裁剪 / 已清空），如实提示，不冒充定位最新
    @State private var expandedConversationTurnUnavailable = false
    @State private var lastHandledConversationNavigationID: UUID?

    private static let supportedReferenceDocumentTypes =
        ProjectAIChatAttachmentPolicy.referenceContentTypes

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if controller.messages.isEmpty && normalizedLegacyNote == nil {
                    emptyState
                } else {
                    messages
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            if let errorMessage = controller.errorMessage {
                errorRow(errorMessage)
            }
            if let errorMessage = speechController?.errorMessage {
                Text(errorMessage)
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            if !hidesLegacyNoteCard, let coverage = controller.contextCoverageMessage {
                Text(coverage)
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityLabel("本轮原文覆盖范围：" + coverage)
            }
            composer
        }
        .background(BWTheme.columnBackground.opacity(0.72))
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: 220,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .fileImporter(
            isPresented: $isSelectingReferenceDocuments,
            allowedContentTypes: Self.supportedReferenceDocumentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await controller.addReferenceDocuments(from: urls)
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    controller.reportReferenceDocumentSelectionFailure()
                }
            }
        }
        .confirmationDialog(
            "清空 AI 共创记录？",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("清空共创记录", role: .destructive) {
                speechController?.stop()
                controller.clearConversation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("手写笔记、已归结笔记和逐字稿不会删除；已有完整总结会标记为需要更新。")
        }
        .onAppear {
            // 单区新挂载子视图时也要消费初始请求（onChange 只在变化后触发）
            handleConversationTurnNavigation(conversationTurnNavigationRequest)
        }
        .onChange(of: conversationTurnNavigationRequest) { _, request in
            handleConversationTurnNavigation(request)
        }
        .onDisappear { speechController?.handleDisappear() }
        .sheet(isPresented: $isConversationExpanded) {
            expandedConversationSheet
        }
    }

    // MARK: - 历史来源「回到完整对话」定位

    /// 处理轮次定位请求：找到对应 assistant 消息则打开大视图并定位；
    /// 轮次不在保留记录中则打开大视图并显示缺失说明，不冒充定位到最新一轮。
    private func handleConversationTurnNavigation(_ request: AIChatNavigationRequest?) {
        guard let request else { return }
        guard lastHandledConversationNavigationID != request.id else { return }
        lastHandledConversationNavigationID = request.id
        if let target = AIChatTurnLocator.assistantMessageID(
            turnID: request.turnID,
            in: controller.messages
        ) {
            expandedConversationScrollTarget = target
            expandedConversationTurnUnavailable = false
        } else {
            expandedConversationScrollTarget = nil
            expandedConversationTurnUnavailable = true
        }
        isConversationExpanded = true
        onConversationNavigationConsumed(request.id)
    }

    /// 手动从标题栏展开大视图：清掉上次定位/缺失状态，回到「最新一条」贴底阅读。
    private func expandConversationManually() {
        expandedConversationScrollTarget = nil
        expandedConversationTurnUnavailable = false
        isConversationExpanded = true
    }

    /// 可读大视图：完整对话只读展开，长回复不被截断。
    /// 轮次导航定位对应 assistant 消息；正文不在保留记录时如实提示，不冒充定位最新。
    private var expandedConversationSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Label("AI 对话（展开）", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: BWTheme.fontSizeBody, weight: .semibold))
                Spacer()
                Button("返回工作台") {
                    isConversationExpanded = false
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: BWTheme.primaryActionHeight)
            }
            .padding(12)

            if expandedConversationTurnUnavailable {
                Divider()
                Label("该轮对话正文已不在保留记录中",
                      systemImage: "clock.badge.questionmark")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .help("该轮回复已超过保留条数或被清空；只保留归结与当时依据，不冒充定位到最新一轮。")
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if controller.messages.isEmpty {
                            Text(expandedConversationTurnUnavailable
                                 ? "该轮对话正文已不在保留记录中，且当前共创记录已被清空。"
                                 : "还没有对话内容。")
                                .font(.system(size: BWTheme.fontSizeBody))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(controller.messages) { message in
                            readableMessageRow(message)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    if let target = expandedConversationScrollTarget {
                        proxy.scrollTo(target, anchor: .top)
                    } else if !expandedConversationTurnUnavailable,
                              let last = controller.messages.last {
                        proxy.scrollTo(last.id,
                                       anchor: last.role == .assistant ? .top : .bottom)
                    }
                }
                .onChange(of: expandedConversationScrollTarget) { _, newTarget in
                    if let newTarget {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(newTarget, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 600, minHeight: 560)
        .background(BWTheme.paper)
    }

    /// 大视图只读行：完整展示正文，不打开任何 sheet，避免叠层。
    private func readableMessageRow(_ message: ProjectAIChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(message.role == .user ? "我的想法" : "AI 反馈")
                    .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                    .foregroundStyle(message.role == .user ? BWTheme.accent : .secondary)
                Spacer()
                if let provider = message.providerName, let model = message.modelID {
                    Text("\(provider) · \(model)")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(message.text)
                .font(.system(size: 15))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !message.attachments.isEmpty {
                Text(message.attachments.map(\.fileName).joined(separator: "、"))
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (message.role == .user
                ? BWTheme.accent.opacity(0.10)
                : Color.secondary.opacity(0.07)),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var header: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(BWTheme.accent)
                    .frame(width: 3, height: 13)
                Label(
                    hidesLegacyNoteCard ? "与AI一起想" : "AI 共创笔记",
                    systemImage: "bubble.left.and.text.bubble.right"
                )
                .font(.system(size: BWTheme.fontSizeBody, weight: .semibold))
                .help(hidesLegacyNoteCard
                      ? "把想法写在下方，发送后逐轮自动归结可在「AI 归结」页查看"
                      : "用户想法与 AI 反馈会进入共创记录")
                Spacer()
                if !controller.messages.isEmpty {
                    Button {
                        expandConversationManually()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .frame(minWidth: BWTheme.minimumHitWidth,
                           minHeight: BWTheme.minimumHitHeight)
                    .help("展开对话：在可读大视图中查看完整往来")
                    .accessibilityLabel("展开完整对话大视图")
                }
                Button {
                    onReanalyze()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .frame(minWidth: BWTheme.minimumHitWidth,
                       minHeight: BWTheme.minimumHitHeight)
                .disabled(!canReanalyze || controller.isSending)
                .help("使用共创记录中的背景和纠正更新完整分析")
                .accessibilityLabel("使用共创记录更新分析")
                if !controller.messages.isEmpty {
                    Button {
                        isConfirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .frame(minWidth: BWTheme.minimumHitWidth,
                           minHeight: BWTheme.minimumHitHeight)
                    .accessibilityLabel("清空 AI 共创记录")
                }
            }
            if !hidesLegacyNoteCard {
                HStack(spacing: 6) {
                    Text(controller.noteSummaryStatus ?? "每次回应后自动归结笔记")
                    Spacer()
                    Label("纳入完整总结", systemImage: "doc.text")
                        .foregroundStyle(BWTheme.accent)
                        .help("用户想法与 AI 反馈会在完整总结中单独标明来源")
                }
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hidesLegacyNoteCard {
                // A 模式精简空态：其余操作说明已就近分布在范围条、＋ 与联网开关上。
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(BWTheme.accent.opacity(0.75))
                    Text("把你的判断、疑问或灵感直接写在这里，与 AI 一起想。发送后逐轮整理可在「AI 归结」页查看并摘入笔记。")
                        .font(.system(size: BWTheme.fontSizeBody))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(BWTheme.accent.opacity(0.75))
                    Text("把你的判断、疑问或灵感直接写在这里。发送后，AI 会结合录音、已有分析和你明确授权的此前笔记回应。")
                        .font(.system(size: BWTheme.fontSizeBody))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    Text("用左下角“＋”可引用 PDF、Word、Markdown 或文本，与 AI 一起阅读。")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                    Text("开启“联网搜索”后，AI 会按需检索并在回答下方保留可打开的真实来源。")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !hidesLegacyNoteCard, let normalizedLegacyNote {
                            legacyNoteCard(normalizedLegacyNote)
                        }
                        ForEach(controller.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                        if controller.isSending {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(
                                    controller.isWebSearchEnabled
                                        ? "AI 正在判断是否需要联网并结合项目内容回应…"
                                        : "AI 正在结合录音和共创内容回应…"
                                )
                                    .font(.system(size: BWTheme.fontSizeDetail))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                }
                .onScrollPhaseChange { _, newPhase, context in
                    switch newPhase {
                    case .interacting:
                        // 用户开始拖动/滚动：立刻不再自动滚底（背景回复到达不抢滚动）
                        userScrollInteractionInProgress = true
                        if messagesPinnedToBottom {
                            messagesPinnedToBottom = false
                        }
                    case .idle:
                        // 只有「用户亲自滚动完成」才按落点更新贴底；
                        // 程序自动定位（scrollTo .top/.bottom）不改变跟随状态。
                        guard userScrollInteractionInProgress else { return }
                        userScrollInteractionInProgress = false
                        let isBottom = TranscriptScrollPolicy.isAtBottom(
                            contentOffsetY: context.geometry.contentOffset.y,
                            containerHeight: context.geometry.containerSize.height,
                            contentHeight: context.geometry.contentSize.height
                        )
                        if messagesPinnedToBottom != isBottom {
                            messagesPinnedToBottom = isBottom
                        }
                    default:
                        break
                    }
                }
                .onChange(of: controller.messages.count) { _, _ in
                    guard let last = controller.messages.last else { return }
                    if last.role == .user {
                        // 主动发送新问题：重置跟随状态，输入与问题贴底；
                        // 随后 AI 回复到达时在贴底分支里定位到回复顶部（开头可见）。
                        messagesPinnedToBottom = true
                        hasNewReplyWhileAway = false
                        userScrollInteractionInProgress = false
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                        return
                    }
                    if messagesPinnedToBottom {
                        // 长回复定位到其顶部，避免开头被藏掉
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id,
                                           anchor: last.role == .assistant ? .top : .bottom)
                        }
                    } else {
                        // 用户正在上翻历史：不抢滚动，提示「新回复」
                        hasNewReplyWhileAway = true
                    }
                }
                .onAppear {
                    // 视图重新挂载（如双区→单区/页面切换）且无历史导航事件时，
                    // 直接看最新回复开头，不默认停在最旧第一条。
                    if messagesPinnedToBottom,
                       let last = controller.messages.last {
                        proxy.scrollTo(
                            last.id,
                            anchor: last.role == .assistant ? .top : .bottom
                        )
                    }
                }

                if hasNewReplyWhileAway {
                    Button {
                        if let last = controller.messages.last {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(last.id,
                                               anchor: last.role == .assistant ? .top : .bottom)
                            }
                        }
                        messagesPinnedToBottom = true
                        hasNewReplyWhileAway = false
                    } label: {
                        Label("新回复", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: BWTheme.fontSizeLabel, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(8)
                    .help("有新回复，点击回到最新")
                    .accessibilityLabel("回到最新并显示新回复")
                }
            }
        }
    }

    private func messageBubble(_ message: ProjectAIChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 28)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(message.role == .user ? "我的想法" : "AI 反馈")
                        .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                        .foregroundStyle(
                            message.role == .user ? BWTheme.accent : .secondary
                        )
                    if message.role == .assistant, let speechController {
                        Button {
                            speechController.togglePlayback(
                                messageID: message.id.uuidString,
                                reply: message.text
                            )
                        } label: {
                            Image(
                                systemName: speechController.speakingMessageID
                                    == message.id.uuidString
                                    ? "speaker.wave.2.fill"
                                    : "speaker.wave.2"
                            )
                            .font(.system(size: BWTheme.fontSizeDetail))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .frame(minWidth: BWTheme.minimumHitWidth,
                               minHeight: BWTheme.minimumHitHeight)
                        .help(
                            speechController.speakingMessageID
                                == message.id.uuidString
                                ? "停止朗读这条回答"
                                : "朗读这条回答"
                        )
                        .accessibilityLabel(
                            speechController.speakingMessageID
                                == message.id.uuidString
                                ? "停止朗读这条回答"
                                : "朗读这条回答"
                        )
                        if speechController.speakingMessageID
                            == message.id.uuidString {
                            Text("正在朗读")
                                .font(.system(size: BWTheme.fontSizeDetail))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(message.text)
                    .font(.system(size: BWTheme.fontSizeBody))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(message.attachments) { attachment in
                            Label {
                                Text(attachment.fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "doc.text")
                            }
                            .font(.system(size: BWTheme.fontSizeDetail))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                if !message.sources.isEmpty {
                    sourceList(message.sources)
                }
                if message.role == .assistant {
                    turnEvidenceArea(message)
                }
                if message.role == .assistant,
                   let providerName = message.providerName,
                   let modelID = message.modelID {
                    Text("\(providerName) · \(modelID)")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(9)
            .background(
                (message.role == .user
                    ? BWTheme.accent.opacity(0.10)
                    : Color.secondary.opacity(0.07)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            if message.role == .assistant {
                Spacer(minLength: 28)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 本轮证据区：有冻结来源的逐条/分组可开；旧消息如实标记无逐轮来源。
    @ViewBuilder
    private func turnEvidenceArea(_ message: ProjectAIChatMessage) -> some View {
        if let evidence = message.evidenceSnapshot {
        let isStrict = message.queryScope?.isStrictSegments == true
            || evidence.scope.isStrictSegments
        let allCopies = evidence.sentSegments

        VStack(alignment: .leading, spacing: 5) {
            if isStrict {
                Label("本轮原话依据（发送时冻结）", systemImage: "text.quote")
                    .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本轮范围：整场原文")
                            .font(.system(size: BWTheme.fontSizeLabel, weight: .medium))
                        if let coverage = evidence.coverage {
                            Text(wholeScopeCoverageText(coverage))
                                .font(.system(size: BWTheme.fontSizeDetail))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let context = message.contextSnapshot {
                    // 详细读取类型默认折叠，避免覆盖长句挤占；逐轮真实快照仍完整保留可展开
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            wholeScopeContextTypes(context)
                        }
                        .padding(.top, 2)
                    } label: {
                        Text("本轮实际读取内容（可展开）")
                            .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("展开本轮实际读取内容")
                }
            }

            if allCopies.isEmpty {
                Text(isStrict ? "所选片段当时不可用，未发送原话。"
                              : "本轮未外发原话（无可用定稿片段）。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.tertiary)
            } else {
                // 默认收起；展开后逐条可开，不默认铺满挤占正文
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(allCopies.enumerated()), id: \.element.id) { index, copy in
                            evidenceRow(message: message, index: index, copy: copy)
                        }
                    }
                } label: {
                    Label("\(allCopies.count) 条原话来源（可展开）",
                          systemImage: "chevron.right")
                        .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                        .foregroundStyle(BWTheme.accent)
                }
                .foregroundStyle(BWTheme.accent)
                .accessibilityLabel("查看本轮原话来源")
            }
        }
        .padding(7)
        .background(
            Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 7)
        )
        } else {
            HStack(spacing: 5) {
                Image(systemName: "clock.badge.questionmark")
                Text("旧记录：当时未保存逐轮来源快照")
            }
            .font(.system(size: BWTheme.fontSizeDetail))
            .foregroundStyle(.tertiary)
        }
    }

    /// whole 范围展示本轮实际加入的上下文类型（读 M1 冻结快照，不臆测）。
    private func wholeScopeContextTypes(_ context: ProjectAIChatContextSnapshot) -> some View {
        var types: [String] = ["整场原文"]
        if let note = context.noteMarkdown,
           !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            types.append("获授权手写笔记")
        }
        if !context.analysisItems.isEmpty { types.append("已有分析") }
        if context.analysisHeadline != nil { types.append("分析总览") }
        if let background = context.projectBackgroundContext,
           !background.isEmpty { types.append("项目背景") }
        if !context.relatedProjectContext.isEmpty { types.append("关联项目") }
        if !context.confirmedBusinessMemories.isEmpty { types.append("已确认记忆") }
        if !context.referenceDocuments.isEmpty {
            types.append("\(context.referenceDocuments.count) 份引用文档")
        }
        if !context.conversationHistory.isEmpty {
            types.append("\(context.conversationHistory.count) 轮历史")
        }
        return Text("实际加入：" + types.joined(separator: "、"))
            .font(.system(size: BWTheme.fontSizeDetail))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func evidenceRow(message: ProjectAIChatMessage,
                             index: Int,
                             copy: ProjectAIChatEvidenceSnapshot.SegmentCopy) -> some View {
        Button {
            openEvidenceRoute(message: message, copy: copy)
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
        .help("打开这条「当时依据」对照")
        .accessibilityLabel("打开第 \(index + 1) 条当时依据")
    }

    private func wholeScopeCoverageText(_ coverage: ProjectAIChatEvidenceSnapshot.CoverageCopy) -> String {
        let percent = coverage.totalSegments > 0
            ? Int((Double(coverage.includedSegments) / Double(coverage.totalSegments)) * 100)
            : 0
        return "已纳入 \(coverage.includedSegments)/\(coverage.totalSegments) 段原文（约 \(percent)% 覆盖面）"
    }

    private func openEvidenceRoute(
        message: ProjectAIChatMessage,
        copy: ProjectAIChatEvidenceSnapshot.SegmentCopy
    ) {
        let turnID = message.turnID ?? message.requestID ?? message.id
        onOpenEvidence(.aiHistory(
            turnID: turnID,
            requestScopeLabel: message.queryScope?.isStrictSegments == true
                ? "所选原话"
                : "整场原文",
            copy: copy
        ))
    }

    private func sourceList(_ sources: [ProjectAIChatSource]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("联网来源", systemImage: "globe")
                .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                if let url = URL(string: source.sourceLocation),
                   url.scheme == "https" || url.scheme == "http" {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("【\(source.id)】")
                                Text(source.title)
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right.square")
                            }
                            .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                            Text(source.excerpt)
                                .font(.system(size: BWTheme.fontSizeDetail))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(source.providerName)
                                .font(.system(size: BWTheme.fontSizeDetail))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: BWTheme.minimumHitHeight)
                    .help("打开来源：\(source.title)")
                    .accessibilityLabel("联网来源 \(source.title)")
                }
            }
        }
        .padding(7)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    private func legacyNoteCard(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("项目笔记", systemImage: "note.text")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Toggle(
                    "供 AI 使用",
                    isOn: Binding(
                        get: { legacyNoteContextEnabled },
                        set: { value in
                            onLegacyNoteContextChanged(value)
                        }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("开启后，项目笔记会用于 AI 回应、开花和完整总结的共创章节")
            }

            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(isLegacyNoteExpanded ? nil : 7)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(
                    legacyNoteContextEnabled
                        ? "区分用户观点与 AI 建议，不会混成录音事实"
                        : "原文保留在本机，暂不发送给 AI"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                Spacer()
                Button(isLegacyNoteExpanded ? "收起" : "展开") {
                    isLegacyNoteExpanded.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
        .padding(9)
        .background(
            BWTheme.accent.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(BWTheme.accent.opacity(0.18), lineWidth: 1)
        }
    }

    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text(text)
                .lineLimit(2)
            if controller.canRetryLastMessage {
                Spacer()
                Button("重试") {
                    Task { await controller.retryLastMessage() }
                }
                .controlSize(.small)
                .frame(minHeight: BWTheme.minimumHitHeight)
            }
            if text.contains("设置") {
                Spacer()
                Button("前往设置", action: onOpenSettings)
                    .controlSize(.small)
                    .frame(minHeight: BWTheme.minimumHitHeight)
            }
        }
        .font(.system(size: BWTheme.fontSizeDetail))
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private enum ScopeChoice: Hashable {
        case wholeConversation
        case selectedSegments
    }

    /// A 版范围条：展示并修改 M1 真范围；切换只影响下一轮，不丢草稿、不自动发送。
    private var scopeBar: some View {
        let strict = controller.queryScope.isStrictSegments
        let selectedIDs = controller.queryScope.selectedSegmentIDs
        let currentSegments = segmentsProvider()
        let segmentByID = Dictionary(
            uniqueKeysWithValues: currentSegments.map { ($0.id, $0) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("范围", systemImage: "scope")
                    .font(.system(size: BWTheme.fontSizeLabel, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { strict ? ScopeChoice.selectedSegments : .wholeConversation },
                    set: { choice in
                        switch choice {
                        case .wholeConversation:
                            if strict {
                                _ = controller.setQueryScope(.wholeConversation)
                            }
                        case .selectedSegments:
                            if !strict {
                                _ = controller.setQueryScope(.selectedSegments(
                                    selectedSegmentIDs: []
                                ))
                            }
                        }
                    }
                )) {
                    Text("本次交流").tag(ScopeChoice.wholeConversation)
                    Text("所选原话").tag(ScopeChoice.selectedSegments)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .tint(BWTheme.accent)
                .help("选择 AI 的读取范围：整场原文，或只读你在原话页选中的片段")

                Spacer(minLength: 0)
            }

            if strict {
                if selectedIDs.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("还没有选中原话：在原话页对片段选「就这句问 AI」，或在证据面板设置范围。")
                    }
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if selectedIDs.count <= 8 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(selectedIDs, id: \.self) { id in
                                scopeChip(id: id, segment: segmentByID[id])
                            }
                        }
                    }
                } else {
                    Text("已选中 \(selectedIDs.count) 段原话；移除可在原话页重新选择。")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(wholeScopeDescription)
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var wholeScopeDescription: String {
        var enabled: [String] = ["整场原文"]
        if controller.isWebSearchEnabled { enabled.append("可按需联网") }
        if legacyNoteContextEnabled { enabled.append("获授权手写笔记") }
        if !controller.pendingAttachments.isEmpty {
            enabled.append("\(controller.pendingAttachments.count) 份引用文档")
        }
        // 以下类型只要非空即真实加入（M1 规则：分析/人物背景/关联项目/
        // 已确认记忆/历史对话），每轮以冻结快照为准；不在上方臆测“已归纳内容”。
        enabled.append("分析/人物背景/关联项目/已确认记忆/历史")
        return "范围：本次交流 · " + enabled.joined(separator: "、")
    }

    private func scopeChip(id: UUID, segment: TranscriptSegment?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "text.quote")
                .font(.system(size: BWTheme.fontSizeDetail))
            Text(segment.map { TranscriptRowView.formatMs($0.startMs) }
                 ?? String(id.uuidString.prefix(8)))
                .font(.system(size: BWTheme.fontSizeDetail))
                .monospacedDigit()
            Text(segment?.text ?? "")
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                let remaining = controller.queryScope.selectedSegmentIDs.filter { $0 != id }
                _ = controller.setQueryScope(.selectedSegments(selectedSegmentIDs: remaining))
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: BWTheme.fontSizeDetail))
            }
            .buttonStyle(.plain)
            .frame(width: BWTheme.minimumHitWidth, height: BWTheme.minimumHitHeight)
            .contentShape(Rectangle())
            .help("移除这段，只影响下一轮")
            .accessibilityLabel("移除这段原话")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(BWTheme.accent.opacity(0.08), in: Capsule())
        .overlay {
            Capsule().stroke(BWTheme.accent.opacity(0.25), lineWidth: 1)
        }
        .frame(minHeight: BWTheme.minimumHitHeight)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !controller.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(controller.pendingAttachments) { attachment in
                            pendingAttachmentChip(attachment)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            scopeBar

            HStack(spacing: 7) {
                let strict = controller.queryScope.isStrictSegments
                Toggle(
                    isOn: $controller.isWebSearchEnabled
                ) {
                    Label("联网搜索", systemImage: "globe")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(strict)
                .help(strict
                      ? "已选片段范围：不联网、不带笔记/历史/文档，只读所选原话与当前问题"
                      : "开启后，AI 只向互联网发送最多两条、每条不超过 24 字的检索词；逐字稿和笔记不会发送给搜索源")
                .accessibilityHint(strict
                                   ? "片段范围内不联网"
                                   : "控制本次及后续项目对话是否允许联网检索")
                Text(
                    strict
                        ? "片段范围内不联网、不引用笔记/历史/文档"
                        : (controller.isWebSearchEnabled
                           ? "按需检索；逐字稿和笔记不发送给搜索源"
                           : "仅使用项目内容和模型已有知识")
                )
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    isSelectingReferenceDocuments = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(
                            Color.secondary.opacity(0.10),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAcceptMoreReferenceDocuments)
                .help("引用 PDF、Word、Markdown 或文本")
                .accessibilityLabel("引用文档")
                .accessibilityHint("选择最多四份文档，与本次想法一起发送给 AI")

                ZStack(alignment: .topLeading) {
                    StableNoteEditor(
                        text: $controller.draft,
                        isEditable: !controller.isSending,
                        accessibilityLabel: "AI 提问输入框",
                        accessibilityHelp: composerSubmitPolicy == .sendOnReturn
                            ? "回车发送，Shift Return 换行"
                            : "回车换行，Command Return 发送",
                        submitPolicy: composerSubmitPolicy,
                        onSubmit: {
                            guard controller.canSend else { return }
                            Task { await controller.send() }
                        },
                        focusRequestToken: externalComposerFocusToken
                    )
                    if controller.draft.isEmpty {
                        Text(composerSubmitPolicy == .sendOnReturn
                             ? "记录想法，或向 AI 追问（↩ 发送，⇧↩ 换行）"
                             : "记录想法，或向 AI 追问（↩ 换行，⌘↩ 发送）")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 54, idealHeight: 70, maxHeight: 116)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(0.82),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            isDropTargeted
                                ? BWTheme.accent
                                : Color.secondary.opacity(0.18),
                            lineWidth: isDropTargeted ? 2 : 1
                        )
                }
                .onDrop(
                    of: ProjectAIChatAttachmentPolicy.referenceContentTypes + [.fileURL],
                    isTargeted: $isDropTargeted
                ) { providers in
                    handleReferenceDocumentDrop(providers)
                }

                Button {
                    Task { await controller.send() }
                } label: {
                    Label("发送", systemImage: "paperplane.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 54, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(BWTheme.accent)
                .disabled(!controller.canSend)
                .help(composerSubmitPolicy == .sendOnReturn
                      ? "发送想法并获取 AI 反馈（↩）"
                      : "发送想法并获取 AI 反馈（⌘↩）")
                .accessibilityLabel("发送想法并获取 AI 反馈")
            }

            composerStatus
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.bar)
    }

    /// ＋ 按钮与拖放共用同一道闸：发送中、正在读取、已达上限、片段范围都不再收新文档
    private var canAcceptMoreReferenceDocuments: Bool {
        !controller.queryScope.isStrictSegments
            && !controller.isSending
            && !controller.isLoadingAttachments
            && controller.pendingAttachments.count
                < ProjectAIChatAttachmentPolicy.maximumCount
    }

    /// 拖放引用文档：支持一次多份，超额与不支持类型由控制器和策略各自拦。
    /// 类型不符时同步返回 false，光标直接显示「不接受」而不是先接受再弹错。
    private func handleReferenceDocumentDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptMoreReferenceDocuments else { return false }
        let candidates = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                && ProjectAIChatAttachmentPolicy.acceptsDrop(
                    registeredContentTypes:
                        provider.registeredTypeIdentifiers.compactMap(UTType.init)
                )
        }
        guard !candidates.isEmpty else { return false }
        Task { @MainActor in
            // NSItemProvider 不是 Sendable，不能塞进任务组并发加载；
            // 最多 4 份文件 URL，顺序取回足够快，也不必冒数据竞争的风险。
            var collected: [URL] = []
            for provider in candidates {
                let url = await withCheckedContinuation {
                    (continuation: CheckedContinuation<URL?, Never>) in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                if let url { collected.append(url) }
            }
            let accepted = collected.filter(ProjectAIChatAttachmentPolicy.acceptsDroppedFile)
            guard !accepted.isEmpty else {
                controller.reportUnsupportedReferenceDocumentDrop()
                return
            }
            await controller.addReferenceDocuments(from: accepted)
        }
        return true
    }

    @ViewBuilder
    private var composerStatus: some View {
        if controller.isLoadingAttachments {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在提取引用文档正文…")
            }
            .font(.system(size: BWTheme.fontSizeDetail))
            .foregroundStyle(.secondary)
        } else if let draftSaveError = controller.draftSaveError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(draftSaveError)
                Spacer()
                Button("重试") {
                    controller.saveDraftNow()
                }
                .buttonStyle(.borderless)
                .frame(minHeight: BWTheme.minimumHitHeight)
            }
            .font(.system(size: BWTheme.fontSizeDetail))
            .foregroundStyle(.orange)
        } else if !controller.pendingAttachments.isEmpty {
            Text("发送时上传所选正文给当前 AI；仅保存文件名和提取后的文字，不保存原文件路径。")
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 5) {
                if !controller.draft.isEmpty {
                    if let savedAt = controller.lastDraftSavedAt {
                        Text(
                            "草稿已自动保存 "
                                + savedAt.formatted(
                                    date: .omitted,
                                    time: .shortened
                                )
                        )
                    } else {
                        Text("草稿仅保存在本机")
                    }
                } else {
                    Text("发送后 AI 才会看到，并纳入完整总结")
                }
                Spacer()
                if controller.draft.count > 3_600 {
                    Text(
                        "\(controller.draft.count)/"
                            + "\(ProjectAIChatController.maximumDraftCharacters)"
                    )
                    .foregroundStyle(
                        controller.draft.count
                            > ProjectAIChatController.maximumDraftCharacters
                            ? .orange
                            : .secondary
                    )
                }
            }
            .font(.system(size: BWTheme.fontSizeDetail))
            .foregroundStyle(.secondary)
        }
    }

    private func pendingAttachmentChip(
        _ attachment: ProjectAIChatAttachment
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .foregroundStyle(BWTheme.accent)
            Text(attachment.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            if attachment.wasTruncated {
                Text("已截取")
                    .foregroundStyle(.secondary)
            }
            Button {
                controller.removePendingAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: BWTheme.minimumHitWidth, height: BWTheme.minimumHitHeight)
            .contentShape(Rectangle())
            .accessibilityLabel("移除引用文档 \(attachment.fileName)")
        }
        .font(.system(size: BWTheme.fontSizeDetail))
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(
            BWTheme.accent.opacity(0.08),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(BWTheme.accent.opacity(0.25), lineWidth: 1)
        }
    }

    private var normalizedLegacyNote: String? {
        let trimmed = NoteDocument(
            markdown: legacyNoteMarkdown,
            conversationSummaries: controller.conversationSummaries
        ).combinedMarkdown().trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
