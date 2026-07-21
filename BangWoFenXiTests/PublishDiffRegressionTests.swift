import Foundation
import Testing
@testable import BangWoFenXi

/// 发布差分回归（渲染风暴二次修复的硬保证）：
/// - 内容无变化时绝不重发（segments 数组不替换，界面零更新）；
/// - 高频混合场景下单位时间发布次数有上限；
/// - 行数据映射差分稳定（Equatable 行零重建的依据）。
@Suite("发布差分回归")
@MainActor
final class PublishDiffRegressionTests {

    private func makeMeeting() throws -> Meeting {
        let meeting = Meeting(title: "差分回归")
        try meeting.transition(to: .ready)
        return meeting
    }

    private func settle(_ ms: UInt64) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    @Test("同一临时文字反复到达：只有第一次发布，其余被差分跳过")
    func identicalContentNotRepublished() async throws {
        PerfCounters.reset()
        let mock = MockLocalTranscriptionService()
        let controller = LocalTranscriptionController(service: mock)
        try await controller.start(for: makeMeeting()) { nil }

        mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1000, text: "同一句临时文字", isFinal: false))
        try await settle(150)
        let afterFirst = controller.segmentsPublishCount
        #expect(afterFirst == 1, "首次临时结果应发布一次")

        // 相同内容再连续到达 10 次（节流 + 差分双重保护）
        for _ in 0..<10 {
            mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1000, text: "同一句临时文字", isFinal: false))
        }
        try await settle(500) // 等尾随刷新执行
        #expect(controller.segmentsPublishCount == afterFirst,
                "内容无变化时不得再发布（数组不替换、界面零更新）")

        // 内容变化：必须发布
        mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1000, text: "同一句临时文字，变长了", isFinal: false))
        try await settle(500)
        #expect(controller.segmentsPublishCount == afterFirst + 1)
        await controller.cancel()
    }

    @Test("高频混合场景：400ms 内 200 个临时结果，发布次数 ≤6 且最终文字一致")
    func highFrequencyBurstBounded() async throws {
        let mock = MockLocalTranscriptionService()
        let controller = LocalTranscriptionController(service: mock)
        try await controller.start(for: makeMeeting()) { nil }

        let baseline = controller.segmentsPublishCount
        for index in 0..<200 {
            mock.emit(LocalTranscriptResult(
                startAudioMs: 0, endAudioMs: 2000,
                text: "高频临时结果第\(index)版", isFinal: false
            ))
        }
        try await settle(400)
        let published = controller.segmentsPublishCount - baseline
        #expect(published <= 6,
                "突发期间发布必须有硬上限（≤6），实际 \(published)")

        try await settle(400) // 尾随刷新
        #expect(controller.segments.last?.text == "高频临时结果第199版",
                "节流后必须收敛到最后一版文字")
        await controller.cancel()
    }

    @Test("最终片段到达后，临时尾巴的差分不干扰最终发布")
    func finalAfterProvisionalPublished() async throws {
        let mock = MockLocalTranscriptionService()
        let controller = LocalTranscriptionController(service: mock)
        let meeting = try makeMeeting()
        try await controller.start(for: meeting) { nil }

        mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1000, text: "如果年度量能", isFinal: false))
        try await settle(150)
        mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1000,
                                        text: "如果年度量能能保证。", isFinal: true))
        try await settle(150)
        #expect(controller.segments.count == 1)
        #expect(controller.segments.first?.state == .final)
        #expect(meeting.segments.count == 1)
        await controller.cancel()
    }

    // MARK: - 行数据映射（Equatable 行零重建的依据）

    @Test("行数据映射：相同输入产出相等行（差分稳定），高亮/说话人正确")
    func rowDataMappingStable() {
        let participant = Participant(cloudAlias: "p_01", displayName: "张总",
                                      side: .counterpart, colorToken: "blue")
        let segment = TranscriptSegment(startMs: 12_000, endMs: 15_000, text: "测试句。",
                                        participantId: participant.id,
                                        source: .cloud, state: .final)
        let row1 = TranscriptRowData.make(from: segment, participants: [participant],
                                          unknownDisplay: nil, highlightedID: nil)
        let row2 = TranscriptRowData.make(from: segment, participants: [participant],
                                          unknownDisplay: nil, highlightedID: nil)
        #expect(row1 == row2, "相同输入必须产出相等行数据（Equatable 差分生效前提）")
        #expect(row1.speakerName == "张总")
        #expect(row1.speakerColorToken == "blue")
        #expect(!row1.isHighlighted)

        let rowHighlighted = TranscriptRowData.make(from: segment, participants: [participant],
                                                    unknownDisplay: nil, highlightedID: segment.id)
        #expect(rowHighlighted != row1, "高亮变化必须体现为行差异（仅该行重建）")
        #expect(rowHighlighted.isHighlighted)

        // 未识别说话人回退展示
        let unknown = TranscriptSegment(startMs: 0, endMs: 1000, text: "测试。",
                                        source: .cloud, state: .final)
        let rowUnknown = TranscriptRowData.make(from: unknown, participants: [participant],
                                                unknownDisplay: "待识别 A", highlightedID: nil)
        #expect(rowUnknown.speakerName == "待识别 A")
        #expect(rowUnknown.speakerColorToken == nil)
    }

    @Test("说话人菜单项：预计算为值类型数组，内容稳定")
    func speakerMenuItemsPrecomputed() {
        let participants = [
            Participant(cloudAlias: "p_01", displayName: "张总", side: .counterpart),
            Participant(cloudAlias: "p_02", displayName: "赵总", side: .ours)
        ]
        let items1 = SpeakerMenuItem.makeItems(from: participants)
        let items2 = SpeakerMenuItem.makeItems(from: participants)
        #expect(items1 == items2, "菜单项为值类型且内容稳定")
        #expect(items1.map(\.title) == ["张总（对方）", "赵总（我方）"])
        #expect(items1.map(\.id) == participants.map(\.id))
    }

    // MARK: - 性能计数器

    @Test("PerfCounters：计数、快照、清零")
    func perfCountersWork() {
        PerfCounters.reset()
        PerfCounters.increment(.provisionalResult)
        PerfCounters.increment(.provisionalResult)
        PerfCounters.increment(.segmentsNoChangeSkip)
        let snapshot = PerfCounters.snapshot()
        let provisional = snapshot.first { $0.counter == .provisionalResult }?.count
        let skip = snapshot.first { $0.counter == .segmentsNoChangeSkip }?.count
        #expect(provisional == 2)
        #expect(skip == 1)
        #expect(snapshot.count == PerfCounters.Counter.allCases.count)
        PerfCounters.reset()
        #expect(PerfCounters.snapshot().allSatisfy { $0.count == 0 })
    }
}
