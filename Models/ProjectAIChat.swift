import Foundation

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
