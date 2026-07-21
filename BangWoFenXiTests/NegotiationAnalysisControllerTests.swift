import Foundation
import Testing
@testable import BangWoFenXi

/// 谈判分析调度控制器：触发 / 防抖 / 串行 / 游标 / 失败保留上一版 / 快照原子替换
@Suite("谈判分析调度")
@MainActor
final class NegotiationAnalysisControllerTests {
    let mock: MockNegotiationAnalysisService
    var fakeNow: Int64
    let controller: NegotiationAnalysisController
    let meeting: Meeting

    init() {
        mock = MockNegotiationAnalysisService()
        fakeNow = 1_000_000
        let nowBox = LockedBox<Int64>(fakeNow)
        self.nowBox = nowBox
        controller = NegotiationAnalysisController(
            service: mock,
            nowMs: { nowBox.withLock { $0 } }
        )
        meeting = Meeting(
            title: "分析测试",
            background: "背景",
            ourGoal: "目标",
            ourBottomLine: "底线",
            counterpartContext: "对方"
        )
        meeting.participants.append(
            Participant(cloudAlias: "p_01", displayName: "张总", side: .counterpart, role: "采购")
        )
        controller.attach(to: meeting)
    }

    private let nowBox: LockedBox<Int64>

    deinit {
        // LockedBox 无需清理
    }

    /// 推进假时钟（毫秒）
    private func advance(_ ms: Int64) {
        nowBox.withLock { $0 += ms }
        fakeNow += ms
    }

    /// 向会议添加一个云端确认片段并通知调度器
    private func addFinalSegment(startMs: Int64, text: String) -> TranscriptSegment {
        let segment = TranscriptSegment(
            startMs: startMs, endMs: startMs + 2_000, text: text,
            participantId: meeting.participants[0].id,
            source: .cloud, state: .final
        )
        meeting.segments.append(segment)
        controller.noteNewFinalSegment()
        return segment
    }

    @Test("不足 3 个新片段不发起分析")
    func belowThresholdNoCall() async {
        _ = addFinalSegment(startMs: 0, text: "第一句。")
        _ = addFinalSegment(startMs: 2_000, text: "第二句。")
        advance(20_000)
        await controller.tick()
        #expect(mock.calls.isEmpty)
    }

    @Test("满 3 个片段且过防抖：发起分析并推进游标")
    func firesAfterDebounce() async {
        let s1 = addFinalSegment(startMs: 0, text: "第一句。")
        _ = addFinalSegment(startMs: 2_000, text: "第二句。")
        _ = addFinalSegment(startMs: 4_000, text: "第三句。")

        // 防抖 10 秒未过：不触发
        await controller.tick()
        #expect(mock.calls.isEmpty)

        advance(10_100)
        await controller.tick()
        #expect(mock.calls.count == 1)
        #expect(meeting.lastAnalyzedSegmentEndMs == 6_000, "游标推进到已分析片段末尾")
        #expect(controller.currentSnapshot != nil, "快照原子替换生效")
        #expect(controller.currentSnapshot?.version == 1)
        #expect(controller.lastSuccessAt != nil)
        #expect(mock.calls[0].instructions == AnalysisSystemPrompt.text)
        #expect(mock.calls[0].inputJSON.contains(s1.id.uuidString))
    }

    @Test("证据校验端到端：云端返回引用不存在片段的项不进快照")
    func evidenceFilteringEndToEnd() async throws {
        let real = addFinalSegment(startMs: 0, text: "真实片段。")
        _ = addFinalSegment(startMs: 2_000, text: "第二句。")
        _ = addFinalSegment(startMs: 4_000, text: "第三句。")
        mock.resultQueue = [
            AnalysisOutputDTO(
                currentTopic: "议题",
                topics: [],
                ourPositions: [],
                counterpartPositions: [
                    .init(text: "引用不存在片段", evidenceSegmentIds: [UUID().uuidString]),
                    .init(text: "引用真实片段", evidenceSegmentIds: [real.id.uuidString])
                ],
                confirmedItems: [], openItems: [], keyFacts: [],
                insights: []
            )
        ]
        advance(10_100)
        await controller.tick()
        let snapshot = try #require(controller.currentSnapshot)
        #expect(snapshot.counterpartPositions.count == 1)
        #expect(snapshot.counterpartPositions.first?.text == "引用真实片段")
    }

    @Test("串行：分析期间的 tick 不并发第二个请求")
    func serialSingleRequest() async {
        mock.delayMs = 300
        _ = addFinalSegment(startMs: 0, text: "第一句。")
        _ = addFinalSegment(startMs: 2_000, text: "第二句。")
        _ = addFinalSegment(startMs: 4_000, text: "第三句。")
        advance(10_100)

        // 第一次 tick 启动请求（挂起 300ms）
        async let first: Void = controller.tick()
        try? await Task.sleep(for: .milliseconds(50))
        // 请求进行中再来新内容并 tick：不得并发
        _ = addFinalSegment(startMs: 6_000, text: "第四句。")
        await controller.tick()
        await first
        // 等补一轮合并请求完成
        try? await Task.sleep(for: .milliseconds(500))

        let callCount = mock.calls.count
        #expect(callCount <= 2, "同一时间最多一个请求；新内容合并到下一次，实际 \(callCount) 次")
    }

    @Test("失败保留上一版快照，且不推进游标")
    func failureKeepsPreviousSnapshot() async throws {
        _ = addFinalSegment(startMs: 0, text: "第一句。")
        _ = addFinalSegment(startMs: 2_000, text: "第二句。")
        _ = addFinalSegment(startMs: 4_000, text: "第三句。")
        advance(10_100)
        await controller.tick()
        let firstSnapshot = try #require(controller.currentSnapshot)
        #expect(meeting.lastAnalyzedSegmentEndMs == 6_000)

        // 新内容到达，下一次分析失败
        _ = addFinalSegment(startMs: 6_000, text: "第四句。")
        _ = addFinalSegment(startMs: 8_000, text: "第五句。")
        _ = addFinalSegment(startMs: 10_000, text: "第六句。")
        mock.errorQueue = [AnalysisAPIError.serverError(statusCode: 500)]
        advance(10_100)
        await controller.tick()

        #expect(controller.currentSnapshot?.version == firstSnapshot.version, "失败必须保留上一版")
        #expect(meeting.lastAnalyzedSegmentEndMs == 6_000, "失败不推进游标")
        #expect(controller.lastErrorDescription != nil)
        // 状态诚实化：不得继续显示「正常」，应如实显示失败类别与重试承诺
        #expect(controller.hasRecentFailure)
        #expect(controller.statusDescription.contains("重试失败（服务繁忙）"))
        #expect(controller.statusDescription.contains("自动重试"))
    }

    @Test("401：云端分析暂停；修复后恢复")
    func unauthorizedSuspends() async {
        _ = addFinalSegment(startMs: 0, text: "第一句。")
        _ = addFinalSegment(startMs: 2_000, text: "第二句。")
        _ = addFinalSegment(startMs: 4_000, text: "第三句。")
        mock.errorQueue = [AnalysisAPIError.unauthorized]
        advance(10_100)
        await controller.tick()

        guard case .suspended = controller.state else {
            Issue.record("401 必须使云端分析暂停")
            return
        }
        // 暂停期间 tick 不发请求
        await controller.tick()
        #expect(mock.calls.count == 1)

        controller.resumeAfterKeyFix()
        advance(30_100) // 过失败退避
        await controller.tick()
        #expect(mock.calls.count == 2)
    }

    @Test("结束后最终分析：消费完整最终转写（含已分析过的片段）")
    func finalAnalysisUsesFullTranscript() async {
        _ = addFinalSegment(startMs: 0, text: "第一句。")
        _ = addFinalSegment(startMs: 2_000, text: "第二句。")
        _ = addFinalSegment(startMs: 4_000, text: "第三句。")
        advance(10_100)
        await controller.tick()
        #expect(meeting.lastAnalyzedSegmentEndMs == 6_000)

        await controller.generateFinalAnalysis()
        #expect(mock.calls.count == 2)
        // 最终分析的输入包含全部片段（不止增量）
        let input = mock.calls[1].inputJSON
        #expect(input.contains("第一句。"))
        #expect(input.contains("第二句。"))
        #expect(input.contains("第三句。"))
        #expect(controller.currentSnapshot?.version == 2)
    }

    @Test("人工已修订片段参与分析（实施计划：分析消费人工确认片段）")
    func editedSegmentsEligible() async {
        let edited = TranscriptSegment(startMs: 0, endMs: 2_000, text: "人工修订的句子。",
                                       source: .manual, state: .edited)
        meeting.segments.append(edited)
        let provisional = TranscriptSegment(startMs: 2_000, endMs: 4_000, text: "临时半句",
                                            source: .local, state: .provisional)
        meeting.segments.append(provisional)
        controller.noteNewFinalSegment()
        controller.noteNewFinalSegment()
        controller.noteNewFinalSegment()
        advance(10_100)
        await controller.tick()

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].inputJSON.contains("人工修订的句子。"))
        #expect(!mock.calls[0].inputJSON.contains("临时半句"), "临时片段不参与分析")
    }
}
