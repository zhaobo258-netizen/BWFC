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
    private var isRestoringDraft = false

    private(set) var messages: [ProjectAIChatMessage] = []
    var draft = "" {
        didSet {
            guard !isRestoringDraft else { return }
            scheduleDraftAutosave()
        }
    }
    private(set) var isSending = false
    private(set) var isLoadingAttachments = false
    private(set) var pendingAttachments: [ProjectAIChatAttachment] = []
    private(set) var errorMessage: String?
    private(set) var lastDraftSavedAt: Date?
    private(set) var draftSaveError: String?
    var noteContextProvider: () -> String? = { nil }
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

    init(
        service: any ProjectAIChatServing,
        persist: @escaping (Project) throws -> Void
    ) {
        self.service = service
        self.persist = persist
    }

    func attach(to project: Project) {
        draftAutosaveTask?.cancel()
        self.project = project
        messages = project.aiChatMessages
        setDraftWithoutAutosave(project.aiChatDraft)
        pendingAttachments = []
        errorMessage = nil
        draftSaveError = nil
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

        let request = ProjectAIChatRequestBuilder.make(
            project: project,
            currentRequest: text,
            noteMarkdown: noteContextProvider(),
            currentAttachments: attachments
        )
        let previousMessages = project.aiChatMessages
        let previousDraft = project.aiChatDraft
        project.aiChatMessages.append(ProjectAIChatMessage(
            role: .user,
            text: String(text.prefix(4_000)),
            attachments: attachments
        ))
        project.aiChatDraft = ""
        project.aiChatMessages = ProjectAIChatRetention.keepingMostRecent(
            project.aiChatMessages
        )
        do {
            try persist(project)
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
        errorMessage = nil
        draftSaveError = nil
        isSending = true
        defer { isSending = false }

        do {
            let response = try await service.reply(to: request)
            let reply = replyWithCorrectionStatus(response)
            project.aiChatMessages.append(ProjectAIChatMessage(
                role: .assistant,
                text: reply,
                providerName: response.provider.displayName,
                modelID: response.provider.modelID
            ))
            project.aiChatMessages = ProjectAIChatRetention.keepingMostRecent(
                project.aiChatMessages
            )
            messages = project.aiChatMessages
            do {
                try persist(project)
                onConversationUpdated()
            } catch {
                errorMessage = "AI 已回应，但本地保存失败，请先复制回应内容。"
            }
        } catch let error as AnalysisAPIError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = "AI 共创暂不可用，请稍后重试。"
        }
    }

    private func replyWithCorrectionStatus(
        _ response: ProjectAIChatResponse
    ) -> String {
        guard !response.transcriptCorrections.isEmpty,
              let onTranscriptCorrection else {
            return response.reply
        }
        let changed = response.transcriptCorrections.reduce(into: 0) {
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
            messages = []
            errorMessage = nil
            onConversationUpdated()
        } catch {
            project.aiChatMessages = previous
            messages = previous
            errorMessage = "清空失败，原对话仍保留。"
        }
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
        case .rateLimited:
            return "AI 请求已达到额度或频率限制，请稍后重试。"
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
