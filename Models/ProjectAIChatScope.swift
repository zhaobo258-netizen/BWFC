import Foundation

/// 显式提问范围（A 版方案 M1）。
///
/// - `.wholeConversation`: 沿用既有行为（按问题/时间选取整场原文，可带授权笔记、
///   分析、联网、人物背景、关联项目、记忆、历史与引用文档）。
/// - `.selectedSegments`: 严格片段模式。只用「当前问题 + 有效选中原话」；
///   不混入旧历史、分析、笔记、联网、人物背景、关联项目、记忆或历史附件。
///
/// 主键一律使用稳定 UUID，不用时间字符串或名称。
enum ProjectAIChatQueryScope: Codable, Sendable, Equatable, Hashable {
    case wholeConversation
    case selectedSegments(selectedSegmentIDs: [UUID])

    var isStrictSegments: Bool {
        if case .selectedSegments = self { return true }
        return false
    }

    var selectedSegmentIDs: [UUID] {
        switch self {
        case .wholeConversation: return []
        case .selectedSegments(let ids): return ids
        }
    }

    // MARK: Codable

    private enum Kind: String, Codable, Sendable {
        case wholeConversation
        case selectedSegments
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case selectedSegmentIDs = "selected_segment_ids"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? .wholeConversation
        switch kind {
        case .wholeConversation:
            self = .wholeConversation
        case .selectedSegments:
            let ids = try container.decodeIfPresent(
                [UUID].self, forKey: .selectedSegmentIDs
            ) ?? []
            self = .selectedSegments(selectedSegmentIDs: ids)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .wholeConversation:
            try container.encode(Kind.wholeConversation, forKey: .kind)
        case .selectedSegments(let ids):
            try container.encode(Kind.selectedSegments, forKey: .kind)
            try container.encode(ids, forKey: .selectedSegmentIDs)
        }
    }
}

/// 逐轮证据快照：在请求真正发送那一刻复制实际包含的原文片段。
/// `TranscriptSegment` 是引用类型（会话过程中会被修订），快照只允许保存值副本，
/// 因此这里逐字段复制 id/text/speaker/毫秒/资产/revision；修改源文不影响旧依据。
struct ProjectAIChatEvidenceSnapshot: Codable, Sendable, Equatable {
    /// 实际发送时的片段值副本（含修订时刻与当时说话人身份）。
    /// text 恒为请求实际外发文本（可能已裁剪），不是当时 project 中的完整原稿。
    struct SegmentCopy: Codable, Sendable, Equatable, Hashable, Identifiable {
        let id: UUID
        let startMs: Int64
        let endMs: Int64
        let text: String
        let participantId: UUID?
        let speakerAlias: String?
        /// 当时说话人本地显示名（下一阶段“当时依据”展示用）。
        let speakerDisplayName: String?
        /// 当时该说话人是否已由用户确认（展示“当时依据”的归属确定性）。
        let speakerWasUserConfirmed: Bool?
        let sourceAssetId: UUID?
        let updatedAt: Date

        init(
            id: UUID,
            startMs: Int64,
            endMs: Int64,
            text: String,
            participantId: UUID?,
            speakerAlias: String?,
            speakerDisplayName: String?,
            speakerWasUserConfirmed: Bool?,
            sourceAssetId: UUID?,
            updatedAt: Date
        ) {
            self.id = id
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
            self.participantId = participantId
            self.speakerAlias = speakerAlias
            self.speakerDisplayName = speakerDisplayName
            self.speakerWasUserConfirmed = speakerWasUserConfirmed
            self.sourceAssetId = sourceAssetId
            self.updatedAt = updatedAt
        }
    }

    /// 覆盖率的确定性数字副本。
    struct CoverageCopy: Codable, Sendable, Equatable {
        var totalSegments: Int
        var includedSegments: Int
        var totalCharacters: Int
        var includedCharacters: Int
        var matchedSegments: Int

        init(
            totalSegments: Int,
            includedSegments: Int,
            totalCharacters: Int,
            includedCharacters: Int,
            matchedSegments: Int
        ) {
            self.totalSegments = totalSegments
            self.includedSegments = includedSegments
            self.totalCharacters = totalCharacters
            self.includedCharacters = includedCharacters
            self.matchedSegments = matchedSegments
        }

        init(coverage: ProjectAIChatRequest.TranscriptCoverage) {
            totalSegments = coverage.totalSegments
            includedSegments = coverage.includedSegments
            totalCharacters = coverage.totalCharacters
            includedCharacters = coverage.includedCharacters
            matchedSegments = coverage.matchedSegments
        }
    }

    let projectID: UUID
    let requestID: UUID
    let capturedAt: Date
    let scope: ProjectAIChatQueryScope
    /// 用户选中/请求纳入的来源；与 sentSegments 区分，便于展示「已选 vs 实际发送」。
    let selectedSegmentIDs: [UUID]
    /// 实际发送给模型的片段值副本。
    let sentSegments: [SegmentCopy]
    let coverage: CoverageCopy?
}

/// 逐轮上下文快照：复制实际发送时模型会看到的非逐字稿上下文。
/// whole 模式保留既有授权（笔记/联网/人物背景/关联项目/记忆/分析）；严格片段模式保持为空。
struct ProjectAIChatContextSnapshot: Codable, Sendable, Equatable {
    let requestID: UUID
    let capturedAt: Date
    let scope: ProjectAIChatQueryScope
    let scenario: String
    let speakers: [ProjectAIChatRequest.Speaker]
    let analysisHeadline: String?
    let analysisItems: [ProjectAIChatRequest.AnalysisItem]
    let projectBackgroundContext: String?
    let relatedProjectContext: [RelatedProjectAIContext]
    let confirmedBusinessMemories: [ProjectAIChatRequest.ConfirmedMemory]
    let noteMarkdown: String?
    let webSearchEnabled: Bool
    let finalReportOverview: String?
    /// 实际作为对话历史外发给模型的上一轮文本值副本（冻结，不依赖当前消息库）。
    let conversationHistory: [ProjectAIChatRequest.HistoryMessage]
    /// 实际外发给模型的引用文档值副本（冻结，不依赖当前消息附件库）。
    let referenceDocuments: [ProjectAIChatRequest.ReferenceDocument]
    /// 纳入历史的消息 ID（仅记录覆盖范围；恢复请求以 conversationHistory 为准）。
    let historyMessageIDs: [UUID]
}

/// 范围校验的纯逻辑结果（供控制器在发送前判定，不在越界后静默回退全场）。
enum ProjectAIChatScopeValidator {
    /// 在项目内仍有效且可作为引用的选中片段（final/edited 且有非空文字）。
    static func eligibleSelectedSegments(
        in project: Project,
        selectedSegmentIDs: [UUID]
    ) -> [TranscriptSegment] {
        let wanted = Set(selectedSegmentIDs)
        guard !wanted.isEmpty else { return [] }
        return project.segments
            .filter { segment in
                guard wanted.contains(segment.id) else { return false }
                let state = segment.state
                let hasUsableText = !segment.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                return (state == .final || state == .edited) && hasUsableText
            }
            .sorted { $0.startMs < $1.startMs }
    }

    /// 选中但已不存在/未定稿/无文字的片段（这些必须明确失败，不能自动回退全场）。
    static func unavailableSegmentIDs(
        in project: Project,
        selectedSegmentIDs: [UUID]
    ) -> [UUID] {
        let wanted = Set(selectedSegmentIDs)
        guard !wanted.isEmpty else { return Array(selectedSegmentIDs) }
        let available = Set(
            eligibleSelectedSegments(
                in: project,
                selectedSegmentIDs: selectedSegmentIDs
            ).map(\.id)
        )
        return selectedSegmentIDs.filter { !available.contains($0) }
    }
}
