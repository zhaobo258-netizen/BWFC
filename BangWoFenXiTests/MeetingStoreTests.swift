import Foundation
import Testing
@testable import BangWoFenXi

/// 会议持久化测试（阶段 0：存储容器与模型可用性基线）。
/// 使用临时目录与内存实现，测试结束后清理，不产生任何残留数据。
@Suite("会议持久化")
final class MeetingStoreTests {
    let tempDirectory: URL

    init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// 完整模型树：写入 → 换一个 store 实例重新读取 → 字段逐一校验
    @Test("完整模型读写")
    func fullModelRoundTrip() throws {
        let store = try JSONMeetingStore(directory: tempDirectory)

        // 会议
        let meeting = Meeting(
            title: "年度采购谈判",
            background: "双方就新一年度框架议价",
            ourGoal: "锁定年度量能价格",
            ourBottomLine: "返点不低于 3%",
            counterpartContext: "对方为长期供应商",
            glossary: ["返点", "量能"],
            status: .draft
        )

        // 参会人
        let participant = Participant(
            cloudAlias: "p_01",
            displayName: "测试对方",
            side: .counterpart,
            role: "采购负责人",
            colorToken: "blue"
        )
        meeting.participants.append(participant)

        // 片段
        let segment = TranscriptSegment(
            startMs: 125_000,
            endMs: 131_500,
            text: "测试用转写文本",
            participantId: participant.id,
            remoteSpeakerLabel: "p_01",
            source: .cloud,
            state: .final
        )
        meeting.segments.append(segment)

        // 快照 + 议题 + 分析项
        let snapshot = AnalysisSnapshot(
            version: 1,
            analyzedThroughMs: 131_500,
            currentTopicTitle: "年度量能",
            counterpartPositions: [
                StructureEntry(text: "对方要求保证年度量能", evidenceSegmentIds: [segment.id])
            ]
        )
        snapshot.topics.append(
            TopicState(title: "年度量能", status: .discussing,
                       evidenceSegmentIds: [segment.id], order: 0)
        )
        snapshot.insights.append(
            Insight(
                category: .explicitDemand,
                subjectParticipantId: participant.id,
                statement: "对方明确提出年度量能保证要求。",
                epistemicStatus: .explicit,
                confidence: .high,
                evidenceSegmentIds: [segment.id]
            )
        )
        meeting.snapshots.append(snapshot)

        try store.saveMeetings([meeting])

        // 用一个新的 store 实例重新读取，排除内存缓存干扰
        let rereadStore = try JSONMeetingStore(directory: tempDirectory)
        let meetings = try rereadStore.loadMeetings()
        #expect(meetings.count == 1)

        let fetched = try #require(meetings.first)
        #expect(fetched.id == meeting.id)
        #expect(fetched.title == "年度采购谈判")
        #expect(fetched.status == .draft)
        #expect(fetched.glossary == ["返点", "量能"])
        #expect(fetched.ourBottomLine == "返点不低于 3%")
        #expect(fetched.lastAnalyzedSegmentEndMs == 0)

        #expect(fetched.participants.count == 1)
        let fetchedParticipant = try #require(fetched.participants.first)
        #expect(fetchedParticipant.side == .counterpart)
        #expect(fetchedParticipant.cloudAlias == "p_01")

        #expect(fetched.segments.count == 1)
        let fetchedSegment = try #require(fetched.segments.first)
        #expect(fetchedSegment.source == .cloud)
        #expect(fetchedSegment.state == .final)
        #expect(fetchedSegment.startMs == 125_000)
        #expect(fetchedSegment.endMs == 131_500)

        #expect(fetched.snapshots.count == 1)
        let fetchedSnapshot = try #require(fetched.snapshots.first)
        #expect(fetchedSnapshot.version == 1)
        #expect(fetchedSnapshot.currentTopicTitle == "年度量能")
        #expect(fetchedSnapshot.counterpartPositions.first?.text == "对方要求保证年度量能")
        #expect(fetchedSnapshot.topics.count == 1)
        #expect(fetchedSnapshot.topics.first?.status == .discussing)

        let fetchedInsight = try #require(fetchedSnapshot.insights.first)
        #expect(fetchedInsight.category == .explicitDemand)
        #expect(fetchedInsight.epistemicStatus == .explicit)
        #expect(fetchedInsight.confidence == .high)
        #expect(fetchedInsight.evidenceExists(in: [fetchedSegment.id]))
    }

    /// 空库读取返回空数组而不是报错
    @Test("空库返回空数组")
    func emptyStoreReturnsEmptyArray() throws {
        let store = try JSONMeetingStore(directory: tempDirectory)
        #expect(try store.loadMeetings().isEmpty)
    }

    /// 覆盖保存：删除会议后重新保存，读取结果反映删除
    @Test("覆盖保存反映删除")
    func overwriteSaveReflectsDeletion() throws {
        let store = try JSONMeetingStore(directory: tempDirectory)
        let meetingA = Meeting(title: "会议 A")
        let meetingB = Meeting(title: "会议 B")
        meetingB.segments.append(
            TranscriptSegment(startMs: 0, endMs: 1000, text: "测试",
                              source: .local, state: .provisional)
        )
        try store.saveMeetings([meetingA, meetingB])
        #expect(try store.loadMeetings().count == 2)

        // 删除会议 B（其片段随会议树一并消失，满足实施计划 12.1 的删除语义）
        try store.saveMeetings([meetingA])
        let remaining = try store.loadMeetings()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == meetingA.id)
        #expect(remaining.first?.segments.isEmpty == true)
    }

    /// 内存实现的读写一致性（降级路径）
    @Test("内存存储读写一致")
    func inMemoryStore() throws {
        let store = InMemoryMeetingStore()
        #expect(try store.loadMeetings().isEmpty)
        try store.saveMeetings([Meeting(title: "内存会议")])
        #expect(try store.loadMeetings().first?.title == "内存会议")
    }

    /// 实施计划 9.4：空证据的分析项 / 结构记录视为无效
    @Test("空证据视为无效")
    func emptyEvidenceIsInvalid() {
        let noEvidenceInsight = Insight(
            category: .possibleMotive,
            statement: "无证据的推测不应进入 UI。",
            epistemicStatus: .inference,
            confidence: .low,
            evidenceSegmentIds: []
        )
        #expect(!noEvidenceInsight.hasValidEvidence)
        #expect(!noEvidenceInsight.evidenceExists(in: [UUID()]))

        let phantomInsight = Insight(
            category: .explicitDemand,
            statement: "引用不存在片段的分析无效。",
            epistemicStatus: .explicit,
            confidence: .medium,
            evidenceSegmentIds: [UUID()]
        )
        #expect(phantomInsight.hasValidEvidence)
        #expect(!phantomInsight.evidenceExists(in: [UUID()]), "引用不存在的片段必须判定无效")

        #expect(!StructureEntry(text: "无证据立场", evidenceSegmentIds: []).hasValidEvidence)
        #expect(!TopicState(title: "无证据议题").hasValidEvidence)
    }
}
