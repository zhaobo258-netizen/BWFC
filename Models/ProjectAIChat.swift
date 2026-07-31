import Foundation
import UniformTypeIdentifiers

enum ProjectAIChatRole: String, Codable, Sendable {
    case user
    case assistant
}

struct ProjectAIChatAttachment: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var fileName: String
    var fileType: String
    var content: String
    var wasTruncated: Bool

    init(
        id: UUID = UUID(),
        fileName: String,
        fileType: String,
        content: String,
        wasTruncated: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.fileType = fileType
        self.content = content
        self.wasTruncated = wasTruncated
    }
}

enum ProjectAIChatAttachmentPolicy {
    static let maximumCount = 4
    static let maximumPerDocumentCharacters = 16_000
    static let maximumTotalCharacters = 48_000
    static let maximumFileSizeBytes = 25 * 1_024 * 1_024

    // MARK: - 拖放引用校验

    /// 与 ＋ 按钮的 fileImporter allowedContentTypes 保持一致：只接受文档，不接受音视频。
    /// 对话框引用的是「读得出文字的资料」，与首页导入音视频是两回事，不能共用一份类型表。
    static let referenceContentTypes: [UTType] = [
        "pdf", "md", "markdown", "txt", "rtf", "doc", "docx"
    ].compactMap { UTType(filenameExtension: $0) }

    /// 拖入的文件是否可作为引用文档。目录与不支持类型一律拒绝，
    /// 让 `.onDrop` 同步返回 false，系统直接给「不接受」光标而不是先接受再弹错。
    static func acceptsDroppedFile(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { return false }
        guard let type = values?.contentType else { return false }
        return acceptsContentType(type)
    }

    static func acceptsContentType(_ type: UTType) -> Bool {
        referenceContentTypes.contains { type.conforms(to: $0) }
    }

    /// 落点上的同步预判：NSItemProvider 通常同时登记具体类型与 public.file-url。
    /// 只登记了 file-url、拿不到具体类型时放行，由 `acceptsDroppedFile` 兜底。
    static func acceptsDrop(registeredContentTypes: [UTType]) -> Bool {
        let concrete = registeredContentTypes.filter { $0 != .fileURL && $0 != .url }
        guard !concrete.isEmpty else { return true }
        return concrete.contains { acceptsContentType($0) }
    }

    static let unsupportedDropMessage =
        "只支持 PDF、Word、Markdown 或文本文件，文件夹、音视频和其他类型无法作为引用文档。"
}

struct ProjectAIChatMessage: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var role: ProjectAIChatRole
    var text: String
    var createdAt: Date
    var providerName: String?
    var modelID: String?
    var attachments: [ProjectAIChatAttachment]

    init(
        id: UUID = UUID(),
        role: ProjectAIChatRole,
        text: String,
        createdAt: Date = Date(),
        providerName: String? = nil,
        modelID: String? = nil,
        attachments: [ProjectAIChatAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.providerName = providerName
        self.modelID = modelID
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, providerName, modelID, attachments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ProjectAIChatRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        providerName = try container.decodeIfPresent(
            String.self,
            forKey: .providerName
        )
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        attachments = try container.decodeIfPresent(
            [ProjectAIChatAttachment].self,
            forKey: .attachments
        ) ?? []
    }
}

struct ProjectAIChatTranscriptCorrection: Codable, Sendable, Equatable {
    var wrong: String
    var right: String
    var evidenceSegmentIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case wrong, right
        case evidenceSegmentIDs = "evidence_segment_ids"
    }
}

enum ProjectAIChatRetention {
    static let maximumCount = 60

    static func keepingMostRecent(
        _ messages: [ProjectAIChatMessage]
    ) -> [ProjectAIChatMessage] {
        Array(messages.suffix(maximumCount))
    }
}

enum ProjectAIUserContext {
    static let maximumMessageCount = 20
    static let maximumMessageLength = 2_000

    static func statements(
        from messages: [ProjectAIChatMessage]
    ) -> [String] {
        messages
            .filter { $0.role == .user }
            .suffix(maximumMessageCount)
            .compactMap { message in
                let trimmed = message.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty else { return nil }
                return String(trimmed.prefix(maximumMessageLength))
            }
    }
}
