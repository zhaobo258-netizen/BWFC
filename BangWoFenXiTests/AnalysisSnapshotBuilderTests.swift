import Foundation
import Testing
@testable import BangWoFenXi

/// 分析快照构建与证据校验（实施计划 9.4：无证据或证据不存在的项不进 UI）
@Suite("分析快照构建")
struct AnalysisSnapshotBuilderTests {
    let validID1 = UUID()
    let validID2 = UUID()
    let participantID = UUID()

    private var validIds: Set<UUID> { [validID1, validID2] }
    private var aliasMap: [String: UUID] { ["p_01": participantID] }

    private func makeDTO(
        entries: [AnalysisOutputDTO.EntryDTO] = [],
        insights: [AnalysisOutputDTO.InsightDTO] = [],
        topics: [AnalysisOutputDTO.TopicDTO] = []
    ) -> AnalysisOutputDTO {
        AnalysisOutputDTO(
            currentTopic: "年度量能",
            topics: topics,
            ourPositions: entries,
            counterpartPositions: [],
            confirmedItems: [],
            openItems: [],
            keyFacts: [],
            insights: insights
        )
    }

    @Test("合法输入完整映射")
    func validBuild() {
        let dto = makeDTO(
            entries: [.init(text: "我方要求锁定量能", evidenceSegmentIds: [validID1.uuidString])],
            insights: [.init(category: "possible_motive",
                             subjectParticipantId: "p_01",
                             statement: "对方可能在用量能换返点。",
                             epistemicStatus: "inference",
                             confidence: "medium",
                             evidenceSegmentIds: [validID1.uuidString, validID2.uuidString])],
            topics: [.init(title: "年度量能", status: "discussing",
                           evidenceSegmentIds: [validID2.uuidString])]
        )
        let snapshot = AnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: validIds,
            participantIdByAlias: aliasMap, version: 3, analyzedThroughMs: 50_000
        )
        #expect(snapshot.version == 3)
        #expect(snapshot.analyzedThroughMs == 50_000)
        #expect(snapshot.currentTopicTitle == "年度量能")
        #expect(snapshot.ourPositions.count == 1)
        #expect(snapshot.topics.count == 1)
        #expect(snapshot.topics.first?.status == .discussing)

        let insight = try? #require(snapshot.insights.first)
        #expect(insight?.category == .possibleMotive)
        #expect(insight?.epistemicStatus == .inference)
        #expect(insight?.confidence == .medium)
        #expect(insight?.subjectParticipantId == aliasMap["p_01"])
        #expect(insight?.evidenceSegmentIds.count == 2)
        #expect(insight?.hasValidEvidence == true)
    }

    @Test("空证据的项被过滤")
    func emptyEvidenceFiltered() {
        let dto = makeDTO(
            entries: [.init(text: "无证据立场", evidenceSegmentIds: [])],
            insights: [.init(category: "explicit_demand", subjectParticipantId: nil,
                             statement: "无证据诉求", epistemicStatus: "explicit",
                             confidence: "low", evidenceSegmentIds: [])],
            topics: [.init(title: "无证据议题", status: "discussing", evidenceSegmentIds: [])]
        )
        let snapshot = AnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: validIds,
            participantIdByAlias: aliasMap, version: 1, analyzedThroughMs: 0
        )
        #expect(snapshot.ourPositions.isEmpty)
        #expect(snapshot.insights.isEmpty)
        #expect(snapshot.topics.isEmpty)
    }

    @Test("引用不存在片段的项被过滤（实施计划 9.4）")
    func phantomEvidenceFiltered() {
        let phantom = UUID()
        let dto = makeDTO(
            entries: [
                .init(text: "引用不存在片段", evidenceSegmentIds: [phantom.uuidString]),
                .init(text: "证据真实存在", evidenceSegmentIds: [validID1.uuidString])
            ],
            insights: [.init(category: "explicit_demand", subjectParticipantId: nil,
                             statement: "部分证据不存在", epistemicStatus: "explicit",
                             confidence: "high",
                             evidenceSegmentIds: [validID1.uuidString, phantom.uuidString])]
        )
        let snapshot = AnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: validIds,
            participantIdByAlias: aliasMap, version: 1, analyzedThroughMs: 0
        )
        #expect(snapshot.ourPositions.count == 1)
        #expect(snapshot.ourPositions.first?.text == "证据真实存在")
        #expect(snapshot.insights.isEmpty, "任一证据不存在则整项丢弃")
    }

    @Test("无法识别的类别 / 议题状态被过滤")
    func unknownEnumsFiltered() {
        let dto = makeDTO(
            insights: [
                .init(category: "mind_reading", subjectParticipantId: nil,
                      statement: "不存在的类别", epistemicStatus: "inference",
                      confidence: "low", evidenceSegmentIds: [validID1.uuidString]),
                .init(category: "possible_concern", subjectParticipantId: nil,
                      statement: "合法类别", epistemicStatus: "inference",
                      confidence: "high", evidenceSegmentIds: [validID1.uuidString])
            ],
            topics: [
                .init(title: "非法状态", status: "settled", evidenceSegmentIds: [validID1.uuidString]),
                .init(title: "合法状态", status: "open", evidenceSegmentIds: [validID1.uuidString])
            ]
        )
        let snapshot = AnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: validIds,
            participantIdByAlias: aliasMap, version: 1, analyzedThroughMs: 0
        )
        #expect(snapshot.insights.count == 1)
        #expect(snapshot.insights.first?.category == .possibleConcern)
        #expect(snapshot.topics.count == 1)
        #expect(snapshot.topics.first?.status == .open)
    }

    @Test("未知代号 subject_participant_id 解析为 nil（不丢弃该分析项）")
    func unknownAliasBecomesNil() {
        let dto = makeDTO(
            insights: [.init(category: "attitude_change", subjectParticipantId: "p_99",
                             statement: "未知代号的态度变化", epistemicStatus: "inference",
                             confidence: "low", evidenceSegmentIds: [validID1.uuidString])]
        )
        let snapshot = AnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: validIds,
            participantIdByAlias: aliasMap, version: 1, analyzedThroughMs: 0
        )
        #expect(snapshot.insights.count == 1)
        #expect(snapshot.insights.first?.subjectParticipantId == nil)
    }

    @Test("证据 ID 无法解析为 UUID 的项被过滤")
    func malformedEvidenceIdFiltered() {
        let dto = makeDTO(
            entries: [.init(text: "坏 ID", evidenceSegmentIds: ["not-a-uuid"])]
        )
        let snapshot = AnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: validIds,
            participantIdByAlias: aliasMap, version: 1, analyzedThroughMs: 0
        )
        #expect(snapshot.ourPositions.isEmpty)
    }
}
