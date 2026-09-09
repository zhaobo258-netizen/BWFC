import AppKit
import Foundation
import PDFKit

@MainActor
@Observable
final class ProjectAIChatController {
    static let maximumDraftCharacters = 4_000

    private let service: any ProjectAIChatServing
    private let persist: (Project) throws -> Void
    private weak var project: Project?
    private var draftAutosaveTask: Task<Void, Never>?
    private var responseTask: Task<ProjectAIChatResponse, Error>?
    private var activeRequestID: UUID?
    private var isRestoringDraft = false

    private(set) var messages: [ProjectAIChatMessage] = []
    /// 当前项目的共创提问范围（A 版 M1，供未来 UI 绑定）。
    private(set) var queryScope: ProjectAIChatQueryScope = .wholeConversation
    /// 模型已回应但本地保存失败时，内存中保留的待重存回复标记。
    private(set) var hasUnsavedReply = false
    var draft = "" {
        didSet {
            guard !isRestoringDraft else { return }
            scheduleDraftAutosave()
        }
    }
    private(set) var conversationSummaries: [NoteDocument.ConversationSummary] = []
    private(set) var noteSummaryStatus: String?
    private(set) var isSending = false
    private(set) var isLoadingAttachments = false
    private(set) var pendingAttachments: [ProjectAIChatAttachment] = []
    private(set) var errorMessage: String?
    private(set) var lastDraftSavedAt: Date?
    private(set) var draftSaveError: String?
    private(set) var contextCoverageMessage: String?
    var isWebSearchEnabled = true
    var noteContextProvider: () -> String? = { nil }
    var relatedProjectsProvider: () -> [Project] = { [] }
    /// 本场适用的已确认业务记忆（12 号 §6.1：回答时使用并说明来源）
    var confirmedMemoriesProvider: () -> [MemoryEntry] = { [] }
    var prepareRequestContext: (() -> Bool)?
    var onConversationUpdated: () -> Void = {}
    var onTranscriptCorrection:
        ((ProjectAIChatTranscriptCorrection) -> Int)?

    var canSend: Bool {
        !isSending
            && !isLoadingAttachments
            && (
                !draft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                || !pendingAttachments.isEmpty
            )
    }

    var canRetryLastMessage: Bool {
        !isSending && errorMessage != nil && messages.last?.role == .user
    }

    init(
        service: any ProjectAIChatServing,
        persist: @escaping (Project) throws -> Void
    ) {
        self.service = service
        self.persist = persist
    }

    func attach(to project: Project) {
        invalidateResponse()
        draftAutosaveTask?.cancel()
        noteSummaryStatus = nil
        conversationSummaries = project.note.conversationSummaries
        self.project = project
        messages = project.aiChatMessages
        queryScope = project.aiChatQueryScope ?? .wholeConversation
        if queryScope.isStrictSegments { isWebSearchEnabled = false }
        hasUnsavedReply = false
        setDraftWithoutAutosave(project.aiChatDraft)
        pendingAttachments = []
        errorMessage = messages.last?.role == .user
            ? "上次消息尚未获得回答，可直接重试。" : nil
        draftSaveError = nil
        contextCoverageMessage = nil
    }

    /// 设置当前范围并按项目保存（保存失败时回滚并如实报告，不静默丢失）。
    /// 不会清掉「上一轮失败、可重试」的错误提示：切换草稿范围不能让重试入口消失。
    @discardableResult
    func setQueryScope(_ scope: ProjectAIChatQueryScope) -> Bool {
        guard let project else { return false }
        let previous = project.aiChatQueryScope
        let hadUnansweredLastMessage = messages.last?.role == .user
        project.aiChatQueryScope = scope == .wholeConversation ? nil : scope
        queryScope = project.aiChatQueryScope ?? .wholeConversation
        do {
            try persist(project)
            if queryScope.isStrictSegments { isWebSearchEnabled = false }
            if !hadUnansweredLastMessage {
                errorMessage = nil
            }
            return true
        } catch {
            project.aiChatQueryScope = previous
            queryScope = previous ?? .wholeConversation
            errorMessage = "提问范围保存失败，范围未改变。"
            return false
        }
    }

    func addReferenceDocuments(from urls: [URL]) async {
        guard !isSending, !isLoadingAttachments, !urls.isEmpty else { return }
        let availableCount = ProjectAIChatAttachmentPolicy.maximumCount
            - pendingAttachments.count
        guard urls.count <= availableCount else {
            errorMessage = "一次最多引用 \(ProjectAIChatAttachmentPolicy.maximumCount) 份文档。"
            return
        }
        let existingCharacters = pendingAttachments.reduce(0) {
            $0 + $1.content.count
        }
        guard existingCharacters
                < ProjectAIChatAttachmentPolicy.maximumTotalCharacters else {
            errorMessage = "引用文档内容已达到本次对话上限。"
            return
        }

        isLoadingAttachments = true
        errorMessage = nil
        defer { isLoadingAttachments = false }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try ProjectAIChatAttachmentLoader.load(
                    urls: urls,
                    existingCharacterCount: existingCharacters
                )
            }.value
            pendingAttachments.append(contentsOf: loaded)
        } catch let error as ProjectAIChatAttachmentLoadingError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "引用文档读取失败，请确认文件未损坏。"
        }
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        errorMessage = nil
    }

    func reportReferenceDocumentSelectionFailure() {
        errorMessage = "引用文档选择失败，请重新选择。"
    }

    func reportUnsupportedReferenceDocumentDrop() {
        errorMessage = ProjectAIChatAttachmentPolicy.unsupportedDropMessage
    }

    func send() async {
        guard !isSending, let project else { return }
        let typedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard typedText.count <= Self.maximumDraftCharacters else {
            errorMessage = "每次最多输入 \(Self.maximumDraftCharacters) 字，请拆分为多条想法。"
            return
        }
        let text = typedText.isEmpty
            ? "请阅读并结合引用文档，说明与当前项目最相关的信息。"
            : typedText
        let attachments = pendingAttachments
        if prepareRequestContext?() == false {
            errorMessage = "最新录音文稿保存失败，尚未发送给 AI。"
            return
        }
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil

        let scope = project.aiChatQueryScope ?? .wholeConversation
        let request: ProjectAIChatRequest
        do {
            request = try ProjectAIChatRequestBuilder.makeForScope(
                project: project,
                scope: scope,
                currentRequest: text,
                noteMarkdown: noteContextProvider(),
                currentAttachments: attachments,
                relatedProjects: relatedProjectsProvider(),
                confirmedMemories: confirmedMemoriesProvider(),
                webSearchEnabled: isWebSearchEnabled
            )
        } catch let error as ProjectAIChatBuildError {
            errorMessage = Self.scopeErrorMessage(for: error)
            return
        } catch {
            errorMessage = "本次问题资料整理失败，尚未发送给 AI。"
            return
        }
        let previousMessages = project.aiChatMessages
        let previousDraft = project.aiChatDraft
        let requestID = UUID()
        // 实际纳入请求对话历史的上一轮消息（与 make 的 maxHistoryCount 口径一致）。
        let historyMessages = Array(
            project.aiChatMessages.suffix(
                ProjectAIChatRequestBuilder.maximumHistoryCount
            )
        )
        let (evidence, context) = ProjectAIChatRequestBuilder.snapshots(
            projectID: project.id,
            requestID: requestID,
            scope: scope,
            request: request,
            project: project,
            historyMessages: historyMessages
        )
        project.aiChatMessages.append(ProjectAIChatMessage(
            role: .user,
            text: String(text.prefix(4_000)),
            attachments: attachments,
            turnID: requestID,
            requestID: requestID,
            queryScope: scope,
            evidenceSnapshot: evidence,
            contextSnapshot: context
        ))
        project.aiChatDraft = ""
        project.aiChatMessages = ProjectAIChatRetention.keepingMostRecent(
            project.aiChatMessages
        )
        do {
            try persist(project)
            hasUnsavedReply = false
        } catch {
            project.aiChatMessages = previousMessages
            project.aiChatDraft = previousDraft
            messages = previousMessages
            errorMessage = "背景信息保存失败，尚未发送给 AI。"
            return
        }

        messages = project.aiChatMessages
        setDraftWithoutAutosave("")
        pendingAttachments = []
        await perform(
            request,
            project: project,
            requestID: requestID,
            evidenceSnapshot: evidence,
            contextSnapshot: context
        )
    }

    func retryLastMessage() async {
        guard canRetryLastMessage,
              let project,
              let message = project.aiChatMessages.last,
              message.role == .user else { return }
        if prepareRequestContext?() == false {
            errorMessage = "最新录音文稿保存失败，尚未重试。"
            return
        }
        if let restored = ProjectAIChatRequestBuilder.restoredRequest(
            currentRequest: message.text,
            evidence: message.evidenceSnapshot,
            context: message.contextSnapshot,
            scope: message.queryScope
        ) {
            let requestID = message.requestID ?? message.turnID ?? UUID()
            await perform(
                restored,
                project: project,
                requestID: requestID,
                evidenceSnapshot: message.evidenceSnapshot,
                contextSnapshot: message.contextSnapshot
            )
            return
        }
        // 旧消息（无快照、无轮次）不臆测来源：按整场对话兼容重建。
        let scope = message.queryScope ?? project.aiChatQueryScope ?? .wholeConversation
        guard !scope.isStrictSegments else {
            errorMessage = "旧消息缺少可复用的来源快照，不能按片段重试；请重新提问。"
            return
        }
        let request: ProjectAIChatRequest
        do {
            request = try ProjectAIChatRequestBuilder.makeForScope(
                project: project,
                scope: scope,
                currentRequest: message.text,
                noteMarkdown: noteContextProvider(),
                currentAttachments: message.attachments,
                relatedProjects: relatedProjectsProvider(),
                confirmedMemories: confirmedMemoriesProvider(),
                webSearchEnabled: isWebSearchEnabled,
                excludingMessageID: message.id
            )
        } catch let error as ProjectAIChatBuildError {
            errorMessage = Self.scopeErrorMessage(for: error)
            return
        } catch {
            errorMessage = "重试资料整理失败，尚未重试。"
            return
        }
        await perform(
            request,
            project: project,
            requestID: UUID(),
            evidenceSnapshot: nil,
            contextSnapshot: nil
        )
    }

    /// 模型已回应但保存失败时保留在内存，供 UI 后续「重新保存」；不自动重发模型。
    @discardableResult
    func saveUnsavedReply() -> Bool {
        guard hasUnsavedReply, let project else { return false }
        if project.aiChatMessages.last?.role != .assistant {
            hasUnsavedReply = false
            return true
        }
        do {
            try persist(project)
            hasUnsavedReply = false
            noteSummaryStatus = "本轮回应已保存。"
            errorMessage = nil
            onConversationUpdated()
            return true
        } catch {
            errorMessage = "AI 已回应，但保存仍然失败，内容仍保留在本机内存，请先复制。"
            return false
        }
    }

    private func perform(
        _ request: ProjectAIChatRequest,
        project: Project,
        requestID: UUID,
        evidenceSnapshot: ProjectAIChatEvidenceSnapshot?,
        contextSnapshot: ProjectAIChatContextSnapshot?
    ) async {
        activeRequestID = requestID
        noteSummaryStatus = nil
        let scope = evidenceSnapshot?.scope ?? contextSnapshot?.scope
        if scope?.isStrictSegments == true {
            contextCoverageMessage = "本回答只使用所选片段原话与当前问题；未混入整场历史、分析、笔记或联网内容。"
        } else {
            contextCoverageMessage = request.transcriptCoverage.flatMap {
                $0.isPartial ? $0.notice : nil
            }
        }
        errorMessage = nil
        draftSaveError = nil
        isSending = true
        defer {
            if activeRequestID == requestID {
                activeRequestID = nil
                responseTask = nil
                isSending = false
            }
        }

        do {
            let service = self.service
            let task = Task { try await service.reply(to: request) }
            responseTask = task
            let response = try await task.value
            guard activeRequestID == requestID,
                  self.project?.id == project.id else { return }
            let reply = replyWithCorrectionStatus(response, request: request)
                + (contextCoverageMessage.map { "\n\n" + $0 } ?? "")
            let assistantMessage = ProjectAIChatMessage(
                role: .assistant,
                text: reply,
                providerName: response.provider.displayName,
                modelID: response.provider.modelID,
                sources: response.sources,
                turnID: requestID,
                requestID: requestID,
                queryScope: scope,
                evidenceSnapshot: evidenceSnapshot,
                contextSnapshot: contextSnapshot
            )
            project.aiChatMessages.append(assistantMessage)
            if let summary = response.noteSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty, summary.count <= 1_200 {
                project.note.conversationSummaries.append(.init(
                    id: assistantMessage.id,
                    markdown: summary,
                    createdAt: assistantMessage.createdAt,
                    sourceTurnID: requestID,
                    citedWebSources: response.sources,
                    evidenceSegmentIDs: evidenceSnapshot?.sentSegments.map(\.id) ?? [],
                    evidenceCopies: evidenceSnapshot?.sentSegments ?? []
                ))
                project.note.updatedAt = assistantMessage.createdAt
            }
            project.aiChatMessages = ProjectAIChatRetention.keepingMostRecent(
                project.aiChatMessages
            )
            messages = project.aiChatMessages
            conversationSummaries = project.note.conversationSummaries
            do {
                try persist(project)
                hasUnsavedReply = false
                if project.note.conversationSummaries.contains(where: { $0.id == assistantMessage.id }) {
                    noteSummaryStatus = "本轮已自动归结笔记"
                } else if response.noteSummary == "" {
                    noteSummaryStatus = "本轮没有需要归结的新内容"
                } else {
                    noteSummaryStatus = "本轮未生成笔记，回应已保留"
                }
                onConversationUpdated()
            } catch {
                noteSummaryStatus = nil
                hasUnsavedReply = true
                errorMessage = "AI 已回应，但对话与笔记本地保存失败，请先复制内容；内容保留在本机内存，可稍后重新保存。"
            }
        } catch let error as AnalysisAPIError {
            guard activeRequestID == requestID else { return }
            errorMessage = Self.message(for: error)
        } catch {
            guard activeRequestID == requestID else { return }
            errorMessage = "AI 共创暂不可用，消息已保存，可直接重试。"
        }
    }

    private func replyWithCorrectionStatus(
        _ response: ProjectAIChatResponse,
        request: ProjectAIChatRequest
    ) -> String {
        let corrections = response.transcriptCorrections.filter {
            ProjectAIChatCorrectionIntent.explicitlyAuthorizes($0, in: request.currentRequest)
        }
        guard !corrections.isEmpty,
              let onTranscriptCorrection else {
            return response.reply + (response.transcriptCorrections.isEmpty ? ""
                : "\n\n未执行自动纠错；如需修改，请明确说“把原词改为新词”。")
        }
        let changed = corrections.reduce(into: 0) {
            $0 += onTranscriptCorrection($1)
        }
        if changed > 0 {
            return response.reply
                + "\n\n已同步修正左侧录音文稿 \(changed) 处。"
        }
        return response.reply
            + "\n\n未在左侧录音文稿找到可安全匹配的原词，"
            + "因此没有自动修改。"
    }

    func clearConversation() {
        guard let project, !project.aiChatMessages.isEmpty else { return }
        let previous = project.aiChatMessages
        project.aiChatMessages = []
        do {
            try persist(project)
            invalidateResponse()
            messages = []
            hasUnsavedReply = false
            errorMessage = nil
            contextCoverageMessage = nil
            onConversationUpdated()
        } catch {
            project.aiChatMessages = previous
            messages = previous
            errorMessage = "清空失败，原对话仍保留。"
        }
    }

    private func invalidateResponse() {
        activeRequestID = nil
        responseTask?.cancel()
        responseTask = nil
        isSending = false
    }

    @discardableResult
    func saveDraftNow() -> Bool {
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil
        persistDraft()
        return draftSaveError == nil
    }

    private func setDraftWithoutAutosave(_ value: String) {
        isRestoringDraft = true
        draft = value
        isRestoringDraft = false
    }

    private func scheduleDraftAutosave() {
        draftAutosaveTask?.cancel()
        draftAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.persistDraft()
        }
    }

    private func persistDraft() {
        guard let project else { return }
        guard project.aiChatDraft != draft else {
            draftSaveError = nil
            return
        }
        let previous = project.aiChatDraft
        project.aiChatDraft = draft
        do {
            try persist(project)
            lastDraftSavedAt = Date()
            draftSaveError = nil
        } catch {
            project.aiChatDraft = previous
            draftSaveError = "草稿自动保存失败，请重试"
        }
    }

    private static func scopeErrorMessage(for error: ProjectAIChatBuildError) -> String {
        switch error {
        case .emptyStrictSelection:
            return "还没有可用的所选片段；片段不存在或尚未定稿时不会自动改发整场录音，请重新选择后提问。"
        case .strictSelectionContainsInvalid:
            return "所选片段中包含已失效或尚无最终文稿的条目，本次未发送任何内容；请重新选择后再提问。"
        case .strictAttachmentsUnsupported:
            return "“仅所选片段”范围暂不支持引用文档；请先移除引用文档，或切换到整场对话再发送。"
        case .strictWebSearchUnsupported:
            return "“仅所选片段”范围不会使用联网搜索；请关闭“联网搜索”，或切换到整场对话。"
        case .strictSelectionExceedsLimit(let characterCount):
            return "所选片段共 \(characterCount) 字，超过单次 \(ProjectAIChatRequestBuilder.maximumTranscriptCharacters) 字上限；请缩小所选片段范围后再提问。"
        }
    }

    private static func message(for error: AnalysisAPIError) -> String {
        switch error {
        case .missingAPIKey:
            return "AI 未连接，请先前往设置连接 Kimi 或 OpenAI 兼容模型。"
        case .credentialAccessRequired:
            return "App 更新后需要重新连接 AI；请前往设置登录 Kimi 或重新保存 API Key。"
        case .unauthorized:
            return "AI 凭证无效，或所选 Kimi K3 尚未开通；请前往设置检查连接与模型。"
        case .clientError(let statusCode) where statusCode == 403
            || statusCode == 404:
            return "所选模型不可用；Kimi K3 需要相应会员权限，可在设置中切换模型。"
        case .timeout:
            return "AI 回应超时，可稍后重试。"
        case .network:
            return "网络连接失败，可点击“重试”继续。"
        case .rateLimited:
            return "AI 请求已达到额度或频率限制，请稍后重试。"
        case .invalidResponse:
            return "AI 返回格式异常，消息已保存，可直接重试。"
        default:
            return error.localizedDescription
        }
    }
}

enum ProjectAIChatAttachmentLoadingError: LocalizedError, Sendable {
    case unsupportedType(String)
    case notAFile(String)
    case fileTooLarge(String)
    case unreadable(String)
    case empty(String)
    case totalLimitReached

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return "暂不支持“\(name)”的文件格式。可引用 PDF、Markdown、TXT、RTF、DOC 或 DOCX。"
        case .notAFile(let name):
            return "“\(name)”不是可读取的文档。"
        case .fileTooLarge(let name):
            return "“\(name)”超过 25 MB，请先压缩或拆分后再引用。"
        case .unreadable(let name):
            return "无法读取“\(name)”的正文，请确认文件未加密或损坏。"
        case .empty(let name):
            return "“\(name)”没有可提取的文字。"
        case .totalLimitReached:
            return "引用文档正文超过本次对话上限，请减少文档或拆分提问。"
        }
    }
}

enum ProjectAIChatAttachmentLoader {
    nonisolated static func load(
        urls: [URL],
        existingCharacterCount: Int
    ) throws -> [ProjectAIChatAttachment] {
        var remaining = ProjectAIChatAttachmentPolicy.maximumTotalCharacters
            - existingCharacterCount
        var attachments: [ProjectAIChatAttachment] = []

        for url in urls {
            guard remaining > 0 else {
                throw ProjectAIChatAttachmentLoadingError.totalLimitReached
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let name = url.lastPathComponent
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard values?.isRegularFile == true else {
                throw ProjectAIChatAttachmentLoadingError.notAFile(name)
            }
            if let fileSize = values?.fileSize,
               fileSize > ProjectAIChatAttachmentPolicy.maximumFileSizeBytes {
                throw ProjectAIChatAttachmentLoadingError.fileTooLarge(name)
            }

            let rawText = try extractedText(from: url)
            let normalized = rawText
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw ProjectAIChatAttachmentLoadingError.empty(name)
            }
            let limit = min(
                remaining,
                ProjectAIChatAttachmentPolicy.maximumPerDocumentCharacters
            )
            let content = String(normalized.prefix(limit))
            attachments.append(ProjectAIChatAttachment(
                fileName: name,
                fileType: url.pathExtension.lowercased(),
                content: content,
                wasTruncated: normalized.count > content.count
            ))
            remaining -= content.count
        }
        return attachments
    }

    nonisolated private static func extractedText(from url: URL) throws
        -> String {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown", "csv", "json":
            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                throw ProjectAIChatAttachmentLoadingError.unreadable(name)
            }
            if let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16) {
                return text
            }
            throw ProjectAIChatAttachmentLoadingError.unreadable(name)

        case "pdf":
            guard let document = PDFDocument(url: url) else {
                throw ProjectAIChatAttachmentLoadingError.unreadable(name)
            }
            return (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")

        case "rtf", "doc", "docx":
            do {
                return try NSAttributedString(
                    url: url,
                    options: [:],
                    documentAttributes: nil
                ).string
            } catch {
                throw ProjectAIChatAttachmentLoadingError.unreadable(name)
            }

        default:
            throw ProjectAIChatAttachmentLoadingError.unsupportedType(name)
        }
    }
}
