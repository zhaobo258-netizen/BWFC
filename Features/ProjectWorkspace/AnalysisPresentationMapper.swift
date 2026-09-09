import Foundation

/// 「人物」页展示用的纯投影（A 版 M2）：把真实分析快照条目投影到说话人。
///
/// 纪律：
/// 1. 只有 `subjectSpeakerId` 与说话人 `Speaker.id` 匹配的条目才出现在该人物下；
///    绝不用「证据第一人」猜测未知主体。
/// 2. 人物不会把各类条目硬映射为动机：动机栏只放 `possibleMotive`，
///    缺证据时如实显示「证据不足」，不补造。
/// 3. 条目必须至少有一个证据片段仍存在于当前片段集（按 `evidenceSegmentIds` 校验）；
///    全部失效的条目不进人物卡。
/// 4. `subjectSpeakerId == nil` 的内容统一进「归属待确认」，接原 requestSpeakerAssign。
/// 5. 身份与声纹状态来自模型真实字段（isUserConfirmed / personId / voice 档案），
///    不因本地编号当作「已确认」。
enum AnalysisPresentationMapper {
    // MARK: 值类型投影

    struct Identity: Equatable, Identifiable {
        let speakerID: UUID
        let displayName: String
        let role: String?
        /// 用户明确手工确认（Speaker.isUserConfirmed）
        let isUserConfirmed: Bool
        /// 已跨录音关联人物档案（Speaker.personId != nil）
        let isPersonLinked: Bool
        /// 有声纹档案（voiceProfileId 或 voiceSamplePath 至少其一）
        let hasVoiceProfile: Bool

        var id: UUID { speakerID }

        var statusText: String {
            if isUserConfirmed {
                return "已确认身份"
            }
            if isPersonLinked {
                return "已关联人物档案"
            }
            if hasVoiceProfile {
                return "有声纹档案 · 待确认身份"
            }
            return "仅本场编号 · 未确认"
        }
    }

    struct Entry: Equatable, Identifiable {
        let id: UUID
        let itemID: UUID
        let category: AnalysisItemCategory
        let text: String
        let epistemicStatus: EpistemicStatus
        let confidence: Confidence
        let evidenceSegmentIDs: [UUID]

        var displayCategory: String { category.displayName }
    }

    struct Person: Equatable, Identifiable {
        let identity: Identity
        /// 发言总结：摘要/主题/事实/待确认问题（整理层，属于该人物明确说出的内容）
        let spokenSummaryEntries: [Entry]
        /// 明确诉求或承诺：explicitNeed / decision / actionItem
        let explicitNeedsAndCommitments: [Entry]
        /// 可能动机（推测）：只放 possibleMotive
        let possibleMotives: [Entry]
        /// 其他解释/待确认：顾虑、立场变化、矛盾与回避、待核实、追问线索等
        let otherExplanations: [Entry]

        var id: UUID { identity.id }

        var hasAnyContent: Bool {
            !spokenSummaryEntries.isEmpty
                || !explicitNeedsAndCommitments.isEmpty
                || !possibleMotives.isEmpty
                || !otherExplanations.isEmpty
        }

        /// 行动/承诺存在但动机为空 → 「证据不足」应由视图如实呈现，不在这里臆测。
        var motiveEvidenceInsufficient: Bool {
            !explicitNeedsAndCommitments.isEmpty && possibleMotives.isEmpty
        }
    }

    struct Projection: Equatable {
        let people: [Person]
        /// subjectSpeakerId 为空或指向已删除说话人的条目
        let unassignedEntries: [Entry]
        let totalValidItems: Int
    }

    // MARK: 证据校验（纯逻辑）

    /// 条目证据中仍存在于当前片段集的部分。
    static func currentEvidenceSegments(
        for item: AnalysisItem,
        in segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let wanted = Set(item.evidenceSegmentIds)
        guard !wanted.isEmpty else { return [] }
        let knownIDs = Set(segments.map(\.id))
        guard !wanted.intersection(knownIDs).isEmpty else { return [] }
        return segments
            .filter { wanted.contains($0.id) }
            .sorted { $0.startMs < $1.startMs }
    }

    static func hasCurrentEvidence(
        for item: AnalysisItem,
        in segments: [TranscriptSegment]
    ) -> Bool {
        !currentEvidenceSegments(for: item, in: segments).isEmpty
    }

    // MARK: 投影

    static func project(
        snapshot: ConversationAnalysisSnapshot?,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) -> Projection {
        guard let items = snapshot?.items else {
            return Projection(people: [], unassignedEntries: [], totalValidItems: 0)
        }
        let knownSpeakerIDs = Set(speakers.map(\.id))
        var effectiveItems: [AnalysisItem] = []
        var unassigned: [AnalysisItem] = []
        for item in items {
            guard hasCurrentEvidence(for: item, in: segments) else { continue }
            if let subject = item.subjectSpeakerId,
               knownSpeakerIDs.contains(subject) {
                effectiveItems.append(item)
            } else {
                unassigned.append(item)
            }
        }
        var people: [Person] = []
        for speaker in speakers {
            let owned = effectiveItems.filter { $0.subjectSpeakerId == speaker.id }
            guard !owned.isEmpty else { continue }
            people.append(Person(
                identity: identity(for: speaker),
                spokenSummaryEntries: map(
                    owned.filter { Self.isSpokenSummary($0) },
                    segments: segments
                ),
                explicitNeedsAndCommitments: map(
                    owned.filter { Self.isExplicitNeedOrCommitment($0) },
                    segments: segments
                ),
                possibleMotives: map(
                    owned.filter { $0.category == .possibleMotive },
                    segments: segments
                ),
                otherExplanations: map(
                    owned.filter { Self.isOtherExplanation($0) },
                    segments: segments
                )
            ))
        }
        return Projection(
            people: people.sorted { $0.identity.displayName < $1.identity.displayName },
            unassignedEntries: map(unassigned, segments: segments),
            totalValidItems: effectiveItems.count + unassigned.count
        )
    }

    // MARK: 类别归属（显式映射，防止各类条目硬映射为动机）

    private static func isSpokenSummary(_ item: AnalysisItem) -> Bool {
        switch item.category {
        case .summary, .topic, .fact,
             .concept, .example, .confusingPoint, .reviewQuestion:
            return true
        default:
            return false
        }
    }

    private static func isExplicitNeedOrCommitment(_ item: AnalysisItem) -> Bool {
        switch item.category {
        case .explicitNeed, .decision, .actionItem:
            return true
        default:
            return false
        }
    }

    private static func isOtherExplanation(_ item: AnalysisItem) -> Bool {
        switch item.category {
        case .openQuestion, .possibleConcern, .expressionPurpose,
             .stanceChange, .contradictionEvasion, .factCheck,
             .followUpQuestion, .keyQuote:
            return true
        default:
            return false
        }
    }

    // MARK: 内部

    private static func identity(for speaker: Speaker) -> Identity {
        Identity(
            speakerID: speaker.id,
            displayName: speaker.displayName,
            role: speaker.role?.trimmingCharacters(in: .whitespacesAndNewlines),
            isUserConfirmed: speaker.isUserConfirmed,
            isPersonLinked: speaker.personId != nil,
            hasVoiceProfile: speaker.voiceProfileId != nil
                || (speaker.voiceSamplePath?.isEmpty == false)
        )
    }

    private static func map(
        _ items: [AnalysisItem],
        segments: [TranscriptSegment]
    ) -> [Entry] {
        items.map { item in
            Entry(
                id: item.id,
                itemID: item.id,
                category: item.category,
                text: item.text,
                epistemicStatus: item.epistemicStatus,
                confidence: item.confidence,
                // 只保留当前仍有效的证据 ID，避免失效 ID 生成空来源按钮
                evidenceSegmentIDs: currentEvidenceSegments(
                    for: item,
                    in: segments
                ).map(\.id)
            )
        }
    }
}
