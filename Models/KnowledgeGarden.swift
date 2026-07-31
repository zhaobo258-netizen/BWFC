import Foundation

enum KnowledgeBranchType: String, Codable, Sendable, CaseIterable {
    case conceptExplanation
    case crossDomainConnection
    case continueQuestion

    var displayName: String {
        switch self {
        case .conceptExplanation: return "概念解释"
        case .crossDomainConnection: return "联想连接"
        case .continueQuestion: return "继续追问"
        }
    }
}

struct KnowledgeBranch: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var type: KnowledgeBranchType
    var title: String
    var body: String

    init(
        id: UUID = UUID(),
        type: KnowledgeBranchType,
        title: String,
        body: String
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.body = body
    }
}

enum KnowledgeProviderKind: String, Codable, Sendable, CaseIterable {
    case obsidian
    case internet
    case externalMCP

    var displayName: String {
        switch self {
        case .obsidian: return "Obsidian"
        case .internet: return "互联网"
        case .externalMCP: return "外部 MCP"
        }
    }
}

struct KnowledgeConnection: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var provider: KnowledgeProviderKind
    var providerId: String?
    var providerName: String
    var sourceId: String
    var title: String
    var excerpt: String
    var sourceLocation: String
    var relevance: Double?
    var retrievedAt: Date

    init(
        id: UUID = UUID(),
        provider: KnowledgeProviderKind,
        providerId: String? = nil,
        providerName: String? = nil,
        sourceId: String,
        title: String,
        excerpt: String,
        sourceLocation: String,
        relevance: Double? = nil,
        retrievedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.providerId = providerId
        self.providerName = providerName ?? provider.displayName
        self.sourceId = sourceId
        self.title = title
        self.excerpt = excerpt
        self.sourceLocation = sourceLocation
        self.relevance = relevance
        self.retrievedAt = retrievedAt
    }

    var stableProviderID: String {
        providerId ?? provider.rawValue
    }
}

struct KnowledgeSourceSynthesis: Codable, Sendable, Hashable {
    var summary: String
    var keyPoints: [String]
    var discussionRelevance: String
    var sourceIds: [String]
    var generatedAt: Date

    init(
        summary: String,
        keyPoints: [String],
        discussionRelevance: String,
        sourceIds: [String],
        generatedAt: Date = Date()
    ) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.discussionRelevance = discussionRelevance
        self.sourceIds = sourceIds
        self.generatedAt = generatedAt
    }
}

struct KnowledgeSeed: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var seedText: String
    var whyItMatters: String
    var evidenceSegmentIds: [UUID]
    var branches: [KnowledgeBranch]
    var connections: [KnowledgeConnection]
    var sourceSynthesis: KnowledgeSourceSynthesis?
    var searchQueries: [String]
    var isAddedToProject: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        seedText: String,
        whyItMatters: String,
        evidenceSegmentIds: [UUID],
        branches: [KnowledgeBranch] = [],
        connections: [KnowledgeConnection] = [],
        sourceSynthesis: KnowledgeSourceSynthesis? = nil,
        searchQueries: [String] = [],
        isAddedToProject: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.seedText = seedText
        self.whyItMatters = whyItMatters
        self.evidenceSegmentIds = evidenceSegmentIds
        self.branches = branches
        self.connections = connections
        self.sourceSynthesis = sourceSynthesis
        self.searchQueries = searchQueries
        self.isAddedToProject = isAddedToProject
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
