import Foundation

/// 分析输出的严格 JSON Schema（Structured Outputs，实施计划 10.2）。
/// 以严格模式发送；模型不得返回 schema 之外的内容。
enum AnalysisSchema {
    /// Structured Outputs 的 schema 对象（[String: Any]，请求时序列化）
    static var jsonSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "current_topic": ["type": ["string", "null"]],
            "topics": [
                "type": "array",
                "items": topicSchema
            ],
            "our_positions": entryArraySchema,
            "counterpart_positions": entryArraySchema,
            "confirmed_items": entryArraySchema,
            "open_items": entryArraySchema,
            "key_facts": entryArraySchema,
            "insights": [
                "type": "array",
                "items": insightSchema
            ]
        ],
        "required": [
            "current_topic", "topics", "our_positions", "counterpart_positions",
            "confirmed_items", "open_items", "key_facts", "insights"
        ]
    ] }

    /// 结构化输出名称
    static let schemaName = "negotiation_analysis"

    private static var evidenceIdsSchema: [String: Any] { [
        "type": "array",
        "items": ["type": "string"],
        "minItems": 1 // 每个结论必须引用至少一个片段 ID（实施计划 10.3）
    ] }

    private static var entrySchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "text": ["type": "string"],
            "evidence_segment_ids": evidenceIdsSchema
        ],
        "required": ["text", "evidence_segment_ids"]
    ] }

    private static var entryArraySchema: [String: Any] { [
        "type": "array",
        "items": entrySchema
    ] }

    private static var topicSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "title": ["type": "string"],
            "status": ["type": "string", "enum": ["discussing", "confirmed", "open"]],
            "evidence_segment_ids": evidenceIdsSchema
        ],
        "required": ["title", "status", "evidence_segment_ids"]
    ] }

    private static var insightSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "category": [
                "type": "string",
                "enum": [
                    "explicit_demand", "possible_concern", "possible_motive",
                    "attitude_change", "concession_signal", "contradiction_evasion"
                ]
            ],
            "subject_participant_id": ["type": ["string", "null"]],
            "statement": ["type": "string"],
            "epistemic_status": ["type": "string", "enum": ["explicit", "inference"]],
            "confidence": ["type": "string", "enum": ["low", "medium", "high"]],
            "evidence_segment_ids": evidenceIdsSchema
        ],
        "required": [
            "category", "subject_participant_id", "statement",
            "epistemic_status", "confidence", "evidence_segment_ids"
        ]
    ] }
}

/// 云端分析输出 DTO（对应严格 schema；解码失败即丢弃整版结果）
struct AnalysisOutputDTO: Decodable, Equatable, Sendable {
    var currentTopic: String?
    var topics: [TopicDTO]
    var ourPositions: [EntryDTO]
    var counterpartPositions: [EntryDTO]
    var confirmedItems: [EntryDTO]
    var openItems: [EntryDTO]
    var keyFacts: [EntryDTO]
    var insights: [InsightDTO]

    enum CodingKeys: String, CodingKey {
        case currentTopic = "current_topic"
        case topics
        case ourPositions = "our_positions"
        case counterpartPositions = "counterpart_positions"
        case confirmedItems = "confirmed_items"
        case openItems = "open_items"
        case keyFacts = "key_facts"
        case insights
    }

    struct TopicDTO: Decodable, Equatable, Sendable {
        var title: String
        var status: String
        var evidenceSegmentIds: [String]

        enum CodingKeys: String, CodingKey {
            case title, status
            case evidenceSegmentIds = "evidence_segment_ids"
        }
    }

    struct EntryDTO: Decodable, Equatable, Sendable {
        var text: String
        var evidenceSegmentIds: [String]

        enum CodingKeys: String, CodingKey {
            case text
            case evidenceSegmentIds = "evidence_segment_ids"
        }
    }

    struct InsightDTO: Decodable, Equatable, Sendable {
        var category: String
        var subjectParticipantId: String?
        var statement: String
        var epistemicStatus: String
        var confidence: String
        var evidenceSegmentIds: [String]

        enum CodingKeys: String, CodingKey {
            case category
            case subjectParticipantId = "subject_participant_id"
            case statement
            case epistemicStatus = "epistemic_status"
            case confidence
            case evidenceSegmentIds = "evidence_segment_ids"
        }
    }
}

/// 快照构建与证据校验（实施计划 9.4 / 阶段 4）：
/// 任何 evidence_segment_ids 为空或引用不存在片段的项都视为无效，不进入 UI。
enum AnalysisSnapshotBuilder {
    /// 由 DTO 构建快照；version 与 analyzedThroughMs 由调度器决定。
    /// 非法项（空证据、引用不存在片段、无法识别的枚举值）在构建时被过滤。
    static func build(
        from dto: AnalysisOutputDTO,
        validSegmentIds: Set<UUID>,
        participantIdByAlias: [String: UUID],
        version: Int,
        analyzedThroughMs: Int64
    ) -> AnalysisSnapshot {
        let snapshot = AnalysisSnapshot(
            version: version,
            analyzedThroughMs: analyzedThroughMs,
            currentTopicTitle: dto.currentTopic,
            ourPositions: dto.ourPositions.compactMap { entry(from: $0, validIds: validSegmentIds) },
            counterpartPositions: dto.counterpartPositions.compactMap { entry(from: $0, validIds: validSegmentIds) },
            confirmedItems: dto.confirmedItems.compactMap { entry(from: $0, validIds: validSegmentIds) },
            openItems: dto.openItems.compactMap { entry(from: $0, validIds: validSegmentIds) },
            keyFacts: dto.keyFacts.compactMap { entry(from: $0, validIds: validSegmentIds) }
        )

        snapshot.topics = dto.topics.compactMap { topicDTO in
            guard let status = AnalysisTaxonomy.topicStatus(fromWire: topicDTO.status),
                  let evidence = validEvidenceIds(topicDTO.evidenceSegmentIds, validIds: validSegmentIds) else {
                return nil
            }
            return TopicState(title: topicDTO.title, status: status, evidenceSegmentIds: evidence)
        }

        snapshot.insights = dto.insights.compactMap { insightDTO in
            guard let category = AnalysisTaxonomy.category(fromWire: insightDTO.category),
                  let epistemic = EpistemicStatus(rawValue: insightDTO.epistemicStatus),
                  let confidence = Confidence(rawValue: insightDTO.confidence),
                  let evidence = validEvidenceIds(insightDTO.evidenceSegmentIds, validIds: validSegmentIds) else {
                return nil
            }
            let subjectId = insightDTO.subjectParticipantId.flatMap { participantIdByAlias[$0] }
            return Insight(
                category: category,
                subjectParticipantId: subjectId,
                statement: insightDTO.statement,
                epistemicStatus: epistemic,
                confidence: confidence,
                evidenceSegmentIds: evidence
            )
        }

        return snapshot
    }

    /// 结构项校验与映射：证据为空或含不存在片段 ID 的项返回 nil（不进 UI）
    private static func entry(
        from dto: AnalysisOutputDTO.EntryDTO,
        validIds: Set<UUID>
    ) -> StructureEntry? {
        guard let evidence = validEvidenceIds(dto.evidenceSegmentIds, validIds: validIds) else {
            return nil
        }
        return StructureEntry(text: dto.text, evidenceSegmentIds: evidence)
    }

    /// 证据 ID 列表校验：非空、可解析、全部真实存在
    private static func validEvidenceIds(_ rawIds: [String], validIds: Set<UUID>) -> [UUID]? {
        guard !rawIds.isEmpty else { return nil }
        let parsed = rawIds.compactMap { UUID(uuidString: $0) }
        guard parsed.count == rawIds.count else { return nil }
        guard parsed.allSatisfy({ validIds.contains($0) }) else { return nil }
        return parsed
    }
}
