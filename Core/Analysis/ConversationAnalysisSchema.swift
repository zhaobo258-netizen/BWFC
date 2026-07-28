import Foundation

/// V2 类别/场景的协议映射（snake_case ⇄ Swift 枚举；无法识别的值 → nil，该项丢弃）
enum ConversationAnalysisTaxonomy {
    static func wireName(for category: AnalysisItemCategory) -> String {
        switch category {
        case .summary: return "summary"
        case .topic: return "topic"
        case .fact: return "fact"
        case .decision: return "decision"
        case .actionItem: return "action_item"
        case .openQuestion: return "open_question"
        case .explicitNeed: return "explicit_need"
        case .possibleConcern: return "possible_concern"
        case .possibleMotive: return "possible_motive"
        case .expressionPurpose: return "expression_purpose"
        case .stanceChange: return "stance_change"
        case .contradictionEvasion: return "contradiction_evasion"
        case .keyQuote: return "key_quote"
        case .factCheck: return "fact_check"
        case .followUpQuestion: return "follow_up_question"
        case .concept: return "concept"
        case .example: return "example"
        case .confusingPoint: return "confusing_point"
        case .reviewQuestion: return "review_question"
        case .knowledgeSeed: return "knowledge_seed"
        }
    }

    static func category(fromWire name: String) -> AnalysisItemCategory? {
        AnalysisItemCategory.allCases.first { wireName(for: $0) == name }
    }

    static func wireName(for scenario: ProjectScenario) -> String {
        switch scenario {
        case .clientVisit: return "client_visit"
        case .internalMeeting: return "internal_meeting"
        case .classLearning: return "class_learning"
        case .journalistInterview: return "journalist_interview"
        case .freeform: return "freeform"
        }
    }

    static func scenario(fromWire name: String) -> ProjectScenario? {
        ProjectScenario.allCases.first { wireName(for: $0) == name }
    }
}

/// V2 云端输出 DTO（03 §10.2；解码失败即丢弃整版结果，保留上一版）
struct ConversationAnalysisOutputDTO: Decodable, Equatable, Sendable {
    var headline: String?
    var detectedScenario: String?
    var scenarioConfidence: String?
    var items: [ItemDTO]

    enum CodingKeys: String, CodingKey {
        case headline
        case detectedScenario = "detected_scenario"
        case scenarioConfidence = "scenario_confidence"
        case items
    }

    struct ItemDTO: Decodable, Equatable, Sendable {
        var category: String
        var text: String
        var subjectSpeakerId: String?
        var epistemicStatus: String
        var confidence: String
        var evidenceSegmentIds: [String]

        enum CodingKeys: String, CodingKey {
            case category, text
            case subjectSpeakerId = "subject_speaker_id"
            case epistemicStatus = "epistemic_status"
            case confidence
            case evidenceSegmentIds = "evidence_segment_ids"
        }
    }
}

/// V2 快照构建与证据校验：
/// 任何 evidence_segment_ids 为空、无法解析或引用不存在片段的条目都不进 UI；
/// 枚举白名单外的值整条丢弃（不猜测归类）。
enum ConversationAnalysisSnapshotBuilder {
    static func build(
        from dto: ConversationAnalysisOutputDTO,
        validSegmentIds: Set<UUID>,
        speakerIdByAlias: [String: UUID],
        version: Int,
        analyzedThroughMs: Int64,
        now: Date = Date()
    ) -> ConversationAnalysisSnapshot {
        let items: [AnalysisItem] = dto.items.compactMap { item in
            guard let category = ConversationAnalysisTaxonomy.category(fromWire: item.category),
                  let epistemic = EpistemicStatus(rawValue: item.epistemicStatus),
                  let confidence = Confidence(rawValue: item.confidence),
                  let evidence = validEvidenceIds(item.evidenceSegmentIds, validIds: validSegmentIds),
                  !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AnalysisItem(
                category: category,
                text: item.text,
                subjectSpeakerId: item.subjectSpeakerId.flatMap { speakerIdByAlias[$0] },
                epistemicStatus: epistemic,
                confidence: confidence,
                evidenceSegmentIds: evidence,
                firstObservedAt: now,
                lastUpdatedAt: now
            )
        }

        let headline = dto.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConversationAnalysisSnapshot(
            version: version,
            createdAt: now,
            analyzedThroughMs: analyzedThroughMs,
            headline: (headline?.isEmpty ?? true) ? nil : headline,
            detectedScenario: dto.detectedScenario.flatMap(ConversationAnalysisTaxonomy.scenario(fromWire:)),
            scenarioConfidence: dto.scenarioConfidence.flatMap { Confidence(rawValue: $0) },
            items: items
        )
    }

    /// 证据 ID 列表校验：非空、全部可解析、全部真实存在
    private static func validEvidenceIds(_ rawIds: [String], validIds: Set<UUID>) -> [UUID]? {
        guard !rawIds.isEmpty else { return nil }
        let parsed = rawIds.compactMap { UUID(uuidString: $0) }
        guard parsed.count == rawIds.count,
              parsed.allSatisfy({ validIds.contains($0) }) else { return nil }
        return parsed
    }
}
