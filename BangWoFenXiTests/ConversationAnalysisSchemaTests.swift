import Foundation
import Testing
@testable import BangWoFenXi

/// V2 通用分析 Schema（阶段 D，03 §8.4 / §10.2）：
/// 证据存在性校验、枚举白名单、说话人代号回映射、四场景同一 Schema、旧 JSON 兼容。
@Suite("通用分析 Schema 与快照构建")
struct ConversationAnalysisSchemaTests {

    private func makeItemDTO(
        category: String = "fact",
        text: String = "对方确认了交付时间。",
        subjectSpeakerId: String? = nil,
        epistemicStatus: String = "explicit",
        confidence: String = "high",
        evidenceSegmentIds: [String]
    ) -> ConversationAnalysisOutputDTO.ItemDTO {
        ConversationAnalysisOutputDTO.ItemDTO(
            category: category, text: text,
            subjectSpeakerId: subjectSpeakerId,
            epistemicStatus: epistemicStatus, confidence: confidence,
            evidenceSegmentIds: evidenceSegmentIds
        )
    }

    // MARK: - 证据存在性（红线：无证据不进 UI）

    @Test("证据为空数组的条目被丢弃")
    func emptyEvidenceDropped() {
        let dto = ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: nil, scenarioConfidence: nil,
            items: [makeItemDTO(evidenceSegmentIds: [])]
        )
        let snapshot = ConversationAnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: [UUID()], speakerIdByAlias: [:],
            version: 1, analyzedThroughMs: 1_000
        )
        #expect(snapshot.items.isEmpty)
    }

    @Test("证据引用不存在片段的条目被丢弃；引用真实片段的保留")
    func nonexistentEvidenceDropped() {
        let real = UUID()
        let dto = ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: nil, scenarioConfidence: nil,
            items: [
                makeItemDTO(text: "引用不存在片段", evidenceSegmentIds: [UUID().uuidString]),
                makeItemDTO(text: "引用真实片段", evidenceSegmentIds: [real.uuidString])
            ]
        )
        let snapshot = ConversationAnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: [real], speakerIdByAlias: [:],
            version: 1, analyzedThroughMs: 1_000
        )
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items.first?.text == "引用真实片段")
        #expect(snapshot.items.first?.evidenceSegmentIds == [real])
    }

    @Test("证据 ID 无法解析为 UUID 或部分无效：整条丢弃（不做部分保留）")
    func unparsableOrPartialEvidenceDropped() {
        let real = UUID()
        let dto = ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: nil, scenarioConfidence: nil,
            items: [
                makeItemDTO(text: "证据不是 UUID", evidenceSegmentIds: ["p_01"]),
                makeItemDTO(text: "证据一半真一半假",
                            evidenceSegmentIds: [real.uuidString, UUID().uuidString])
            ]
        )
        let snapshot = ConversationAnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: [real], speakerIdByAlias: [:],
            version: 1, analyzedThroughMs: 1_000
        )
        #expect(snapshot.items.isEmpty, "证据必须全部真实存在，混入假证据即整条丢弃")
    }

    // MARK: - 枚举白名单与状态映射

    @Test("推断状态与置信度正确映射；白名单外的值整条丢弃")
    func epistemicAndConfidenceMapping() {
        let real = UUID()
        let dto = ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: nil, scenarioConfidence: nil,
            items: [
                makeItemDTO(text: "明确高置信", epistemicStatus: "explicit", confidence: "high",
                            evidenceSegmentIds: [real.uuidString]),
                makeItemDTO(category: "possible_motive", text: "推断低置信",
                            epistemicStatus: "inference", confidence: "low",
                            evidenceSegmentIds: [real.uuidString]),
                makeItemDTO(text: "非法状态", epistemicStatus: "certain", confidence: "high",
                            evidenceSegmentIds: [real.uuidString]),
                makeItemDTO(text: "非法置信度", epistemicStatus: "explicit", confidence: "95%",
                            evidenceSegmentIds: [real.uuidString]),
                makeItemDTO(category: "made_up_category", text: "非法类别",
                            evidenceSegmentIds: [real.uuidString])
            ]
        )
        let snapshot = ConversationAnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: [real], speakerIdByAlias: [:],
            version: 1, analyzedThroughMs: 1_000
        )
        #expect(snapshot.items.count == 2, "白名单外的值不得猜测归类")
        #expect(snapshot.items[0].epistemicStatus == .explicit)
        #expect(snapshot.items[0].confidence == .high)
        #expect(snapshot.items[1].category == .possibleMotive)
        #expect(snapshot.items[1].epistemicStatus == .inference)
        #expect(snapshot.items[1].confidence == .low)
    }

    @Test("空白正文的条目被丢弃")
    func blankTextDropped() {
        let real = UUID()
        let dto = ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: nil, scenarioConfidence: nil,
            items: [makeItemDTO(text: "  \n ", evidenceSegmentIds: [real.uuidString])]
        )
        let snapshot = ConversationAnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: [real], speakerIdByAlias: [:],
            version: 1, analyzedThroughMs: 1_000
        )
        #expect(snapshot.items.isEmpty)
    }

    @Test("说话人代号回映射本地 ID；未知代号如实为 nil（不猜测）")
    func speakerAliasMapping() {
        let real = UUID()
        let speakerId = UUID()
        let dto = ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: nil, scenarioConfidence: nil,
            items: [
                makeItemDTO(text: "已知代号", subjectSpeakerId: "p_01",
                            evidenceSegmentIds: [real.uuidString]),
                makeItemDTO(text: "未知代号", subjectSpeakerId: "p_99",
                            evidenceSegmentIds: [real.uuidString])
            ]
        )
        let snapshot = ConversationAnalysisSnapshotBuilder.build(
            from: dto, validSegmentIds: [real], speakerIdByAlias: ["p_01": speakerId],
            version: 1, analyzedThroughMs: 1_000
        )
        #expect(snapshot.items[0].subjectSpeakerId == speakerId)
        #expect(snapshot.items[1].subjectSpeakerId == nil)
    }

    // MARK: - 五场景同一 Schema

    @Test("五个场景 wire 名往返一致（同一 Schema，无场景私有字段）")
    func scenarioWireRoundTrip() {
        for scenario in ProjectScenario.allCases {
            let wire = ConversationAnalysisTaxonomy.wireName(for: scenario)
            #expect(ConversationAnalysisTaxonomy.scenario(fromWire: wire) == scenario)
        }
        #expect(ConversationAnalysisTaxonomy.wireName(for: .internalMeeting) == "internal_meeting")
        #expect(ConversationAnalysisTaxonomy.scenario(fromWire: "board_meeting") == nil)
    }

    @Test("五个场景 Codable 往返及中文显示名稳定")
    func scenarioCodableAndDisplayNames() throws {
        let expectedNames = ["客户拜访", "内部会议", "课堂培训", "访谈采访", "自由记录"]
        #expect(ProjectScenario.allCases.map(\.displayName) == expectedNames)
        for scenario in ProjectScenario.allCases {
            let data = try JSONEncoder().encode(scenario)
            #expect(try JSONDecoder().decode(ProjectScenario.self, from: data) == scenario)
        }
    }

    @Test("全部类别 wire 名往返一致且互不重复")
    func categoryWireRoundTrip() {
        var seen = Set<String>()
        for category in AnalysisItemCategory.allCases {
            let wire = ConversationAnalysisTaxonomy.wireName(for: category)
            #expect(ConversationAnalysisTaxonomy.category(fromWire: wire) == category)
            #expect(seen.insert(wire).inserted, "wire 名不得重复：\(wire)")
        }
        #expect(ConversationAnalysisTaxonomy.category(fromWire: "made_up") == nil)
    }

    @Test("每个类别都有唯一页签归属（总结/动机与目的两分完备）")
    func categoryTabPartition() {
        let summaryTab = AnalysisItemCategory.allCases.filter(\.belongsToSummaryTab)
        let insightTab = AnalysisItemCategory.allCases.filter { !$0.belongsToSummaryTab }
        #expect(summaryTab.count + insightTab.count == AnalysisItemCategory.allCases.count)
        #expect(!summaryTab.isEmpty)
        #expect(!insightTab.isEmpty)
    }

    @Test("场景建议映射：合法值进入快照，非法值如实为 nil")
    func detectedScenarioMapping() {
        let real = UUID()
        let valid = ConversationAnalysisSnapshotBuilder.build(
            from: ConversationAnalysisOutputDTO(
                headline: "拜访总结", detectedScenario: "client_visit",
                scenarioConfidence: "medium", items: [makeItemDTO(evidenceSegmentIds: [real.uuidString])]
            ),
            validSegmentIds: [real], speakerIdByAlias: [:], version: 1, analyzedThroughMs: 1_000
        )
        #expect(valid.detectedScenario == .clientVisit)
        #expect(valid.scenarioConfidence == .medium)
        #expect(valid.headline == "拜访总结")

        let invalid = ConversationAnalysisSnapshotBuilder.build(
            from: ConversationAnalysisOutputDTO(
                headline: "  ", detectedScenario: "poker_game",
                scenarioConfidence: "certain", items: []
            ),
            validSegmentIds: [], speakerIdByAlias: [:], version: 1, analyzedThroughMs: 0
        )
        #expect(invalid.detectedScenario == nil)
        #expect(invalid.scenarioConfidence == nil)
        #expect(invalid.headline == nil, "空白 headline 如实为 nil")
    }

    @Test("模型单条缺少可选字段时不应拖垮整版 JSON")
    func tolerantItemDecoding() throws {
        let data = Data("""
        {
          "headline": "讨论总结",
          "items": [
            {
              "category": "fact",
              "text": "有完整证据的事实",
              "epistemic_status": "explicit",
              "confidence": "high",
              "evidence_segment_ids": ["\(UUID().uuidString)"]
            },
            {
              "category": "topic",
              "text": "模型漏掉了置信度"
            }
          ]
        }
        """.utf8)

        let dto = try JSONDecoder().decode(
            ConversationAnalysisOutputDTO.self,
            from: data
        )

        #expect(dto.items.count == 2)
        #expect(dto.items[0].subjectSpeakerId == nil)
        #expect(dto.items[1].confidence.isEmpty)
        #expect(dto.items[1].evidenceSegmentIds.isEmpty)
    }

    // MARK: - 持久化兼容

    @Test("Project JSON 往返：analysisSnapshots 完整保留")
    func projectRoundTripWithSnapshots() throws {
        let segmentId = UUID()
        let item = AnalysisItem(
            category: .actionItem, text: "下周提供样品",
            epistemicStatus: .explicit, confidence: .high,
            evidenceSegmentIds: [segmentId]
        )
        let snapshot = ConversationAnalysisSnapshot(
            version: 3, analyzedThroughMs: 120_000,
            headline: "样品与价格达成初步一致",
            detectedScenario: .clientVisit, scenarioConfidence: .high,
            items: [item]
        )
        let project = Project(title: "往返测试", sourceType: .liveRecording,
                              analysisSnapshots: [snapshot])
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded.analysisSnapshots.count == 1)
        let restored = try #require(decoded.analysisSnapshots.first)
        #expect(restored.version == 3)
        #expect(restored.analyzedThroughMs == 120_000)
        #expect(restored.headline == "样品与价格达成初步一致")
        #expect(restored.detectedScenario == .clientVisit)
        #expect(restored.items.first?.category == .actionItem)
        #expect(restored.items.first?.evidenceSegmentIds == [segmentId])
    }

    @Test("阶段 D 之前的 Project JSON（无 analysisSnapshots 键）可解码为空数组")
    func legacyProjectJSONDecodes() throws {
        let project = Project(title: "旧项目", sourceType: .liveRecording)
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        )
        object.removeValue(forKey: "analysisSnapshots")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded.analysisSnapshots.isEmpty)
        #expect(decoded.id == project.id)
    }
}
