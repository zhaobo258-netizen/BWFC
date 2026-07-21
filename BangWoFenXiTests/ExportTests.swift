import Foundation
import Testing
@testable import BangWoFenXi

/// 阶段 5 测试共享的会议构造器
enum Stage5Fixtures {
    /// 造一个内容完整的已完成会议（含参会人、片段、快照）
    static func makeCompletedMeeting() -> Meeting {
        let meeting = Meeting(
            title: "年度采购谈判",
            background: "双方就新一年度框架议价",
            ourGoal: "锁定年度量能价格",
            ourBottomLine: "返点不低于 3%",
            counterpartContext: "对方为长期供应商",
            glossary: ["返点", "量能"],
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600)
        )
        let zhang = Participant(cloudAlias: "p_01", displayName: "张总",
                                side: .counterpart, role: "采购负责人", colorToken: "blue")
        let zhao = Participant(cloudAlias: "p_02", displayName: "赵总",
                               side: .ours, role: "销售总监", colorToken: "green")
        meeting.participants = [zhang, zhao]

        let seg1 = TranscriptSegment(
            startMs: 12_000, endMs: 18_000,
            text: "如果年度量能能保证，我们可以再讨论两个点。",
            participantId: zhang.id, remoteSpeakerLabel: "p_01",
            source: .cloud, state: .final
        )
        let seg2 = TranscriptSegment(
            startMs: 19_000, endMs: 25_000,
            text: "量能可以谈，但返点需要和回款周期放在一起确认。",
            participantId: zhao.id, remoteSpeakerLabel: "p_02",
            source: .cloud, state: .final
        )
        let seg3 = TranscriptSegment(
            startMs: 26_000, endMs: 30_000,
            text: "人工修订后的句子。",
            participantId: zhang.id,
            source: .manual, state: .edited
        )
        // 临时片段不应出现在导出中
        let provisional = TranscriptSegment(
            startMs: 31_000, endMs: 33_000, text: "未确认的半句",
            source: .local, state: .provisional
        )
        meeting.segments = [seg2, seg1, seg3, provisional] // 故意乱序

        let snapshot = AnalysisSnapshot(
            version: 2, analyzedThroughMs: 30_000, currentTopicTitle: "年度量能与返点条件",
            counterpartPositions: [
                StructureEntry(text: "对方要求保证年度量能", evidenceSegmentIds: [seg1.id])
            ],
            confirmedItems: [
                StructureEntry(text: "量能可谈", evidenceSegmentIds: [seg2.id])
            ]
        )
        snapshot.topics = [
            TopicState(title: "年度量能", status: .discussing, evidenceSegmentIds: [seg1.id], order: 0)
        ]
        snapshot.insights = [
            Insight(
                category: .possibleMotive, subjectParticipantId: zhang.id,
                statement: "对方可能在用量能承诺交换更好的返点条件。",
                epistemicStatus: .inference, confidence: .medium,
                evidenceSegmentIds: [seg1.id]
            ),
            Insight(
                category: .explicitDemand, subjectParticipantId: zhang.id,
                statement: "对方明确提出年度量能保证要求。",
                epistemicStatus: .explicit, confidence: .high,
                evidenceSegmentIds: [seg1.id]
            )
        ]
        meeting.snapshots = [snapshot]
        return meeting
    }
}

/// Markdown 纪要导出：内容完整、可独立阅读、证据带时间戳和说话人
@Suite("Markdown 导出")
struct MeetingMarkdownExporterTests {
    let meeting = Stage5Fixtures.makeCompletedMeeting()

    @Test("元信息与会议信息完整")
    func headerAndInfo() {
        let md = MeetingMarkdownExporter.makeMarkdown(meeting: meeting)
        #expect(md.contains("# 会议纪要：年度采购谈判"))
        #expect(md.contains("状态：已结束"))
        #expect(md.contains("双方就新一年度框架议价"))
        #expect(md.contains("锁定年度量能价格"))
        #expect(md.contains("返点不低于 3%"))
        #expect(md.contains("对方为长期供应商"))
        #expect(md.contains("返点、量能"))
        #expect(md.contains("张总（对方 · 采购负责人）"))
        #expect(md.contains("赵总（我方 · 销售总监）"))
    }

    @Test("结构总结按固定顺序呈现")
    func structureOrder() {
        let md = MeetingMarkdownExporter.makeMarkdown(meeting: meeting)
        let sections = ["## 结构总结", "### 当前议题", "### 议题列表",
                        "### 我方明确立场", "### 对方明确立场",
                        "### 已确认事项", "### 未决事项", "### 关键数字、日期和承诺"]
        var lastIndex = -1
        for section in sections {
            let range = md.range(of: section)
            #expect(range != nil, "缺少段落：\(section)")
            let index = md.distance(from: md.startIndex, to: range!.lowerBound)
            #expect(index > lastIndex, "段落顺序错误：\(section)")
            lastIndex = index
        }
        #expect(md.contains("年度量能与返点条件"))
        #expect(md.contains("[讨论中] 年度量能"))
        #expect(md.contains("对方要求保证年度量能（证据 [00:12 张总]）"))
    }

    @Test("分析：标签、置信度、证据时间戳与说话人原文")
    func insightsWithEvidence() {
        let md = MeetingMarkdownExporter.makeMarkdown(meeting: meeting)
        #expect(md.contains("AI 推测不等于事实"), "必须包含免责声明")
        #expect(md.contains("### 明确诉求"))
        #expect(md.contains("### 可能动机"))
        #expect(md.contains("对方可能在用量能承诺交换更好的返点条件。 —— 张总 · AI 推测 · 置信度中"))
        #expect(md.contains("对方明确提出年度量能保证要求。 —— 张总 · 明确表达 · 置信度高"))
        #expect(md.contains("证据：[00:12 张总]「如果年度量能能保证，我们可以再讨论两个点。」"))
    }

    @Test("完整转写：按时间排序、含状态与阵营，不含临时片段")
    func transcriptSection() {
        let md = MeetingMarkdownExporter.makeMarkdown(meeting: meeting)
        let transcriptRange = md.range(of: "## 完整转写")
        #expect(transcriptRange != nil)
        let transcript = String(md[transcriptRange!.lowerBound...])
        #expect(transcript.contains("[00:12] **张总（对方）**"))
        #expect(transcript.contains("（云端已确认）"))
        #expect(transcript.contains("（人工已修订）"))
        #expect(!transcript.contains("未确认的半句"), "临时片段不得出现在导出中")
        // 时间排序：00:12 在 00:19 前
        let first = transcript.range(of: "[00:12]")!
        let second = transcript.range(of: "[00:19]")!
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test("空快照会议：空段落显示「尚无足够信息」")
    func emptySnapshotHints() {
        let empty = Meeting(title: "空会议", status: .completed)
        let md = MeetingMarkdownExporter.makeMarkdown(meeting: empty)
        #expect(md.contains("尚无足够信息"))
        #expect(md.contains("（无转写内容）"))
    }

    @Test("导出内容不含 API Key 形态")
    func noSecrets() {
        let md = MeetingMarkdownExporter.makeMarkdown(meeting: meeting)
        #expect(!md.contains("sk-"))
        #expect(!md.contains("apiKey"))
        #expect(!md.contains("API Key"))
    }
}

/// JSON 原始结构导出：可重新解析，片段 ID 与证据引用完整
@Suite("JSON 导出")
struct MeetingJSONExporterTests {
    let meeting = Stage5Fixtures.makeCompletedMeeting()

    @Test("导出 → 重解析：字段与引用完整")
    func roundTrip() throws {
        let data = try MeetingJSONExporter.makeJSONData(meeting: meeting)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""formatVersion" : 1"#) || text.contains(#""formatVersion":1"#))

        let envelope = try MeetingJSONExporter.parse(data: data)
        #expect(envelope.formatVersion == MeetingJSONExporter.currentFormatVersion)
        let restored = envelope.meeting

        #expect(restored.id == meeting.id)
        #expect(restored.title == "年度采购谈判")
        #expect(restored.status == .completed)
        #expect(restored.glossary == ["返点", "量能"])
        #expect(restored.participants.count == 2)
        #expect(restored.participants[0].cloudAlias == "p_01")

        // 片段 ID 完整保留
        #expect(Set(restored.segments.map(\.id)) == Set(meeting.segments.map(\.id)))
        // 证据引用完整：快照中每个证据 ID 都指向真实存在的片段
        let segmentIds = Set(restored.segments.map(\.id))
        let snapshot = try #require(restored.latestSnapshot)
        for insight in snapshot.insights {
            #expect(!insight.evidenceSegmentIds.isEmpty)
            #expect(insight.evidenceSegmentIds.allSatisfy { segmentIds.contains($0) })
        }
        for entry in snapshot.counterpartPositions + snapshot.confirmedItems {
            #expect(entry.evidenceSegmentIds.allSatisfy { segmentIds.contains($0) })
        }
        for topic in snapshot.topics {
            #expect(topic.evidenceSegmentIds.allSatisfy { segmentIds.contains($0) })
        }
        // 分析项类别与判断类型还原
        let motive = try #require(snapshot.insights.first { $0.category == .possibleMotive })
        #expect(motive.epistemicStatus == .inference)
        #expect(motive.confidence == .medium)
    }

    @Test("导出数据不含绝对路径与密钥形态")
    func noAbsolutePathsOrSecrets() throws {
        let data = try MeetingJSONExporter.makeJSONData(meeting: meeting)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Users/"), "导出不得包含机器绝对路径")
        #expect(!text.contains("sk-"))
        #expect(!text.contains("apiKey"))
    }

    @Test("损坏数据重解析抛错")
    func corruptedParseFails() {
        #expect(throws: (any Error).self) {
            _ = try MeetingJSONExporter.parse(data: Data("not json".utf8))
        }
    }
}
