import Foundation
import Testing
@testable import BangWoFenXi

/// 渲染风暴回归测试（实机故障：主线程 100% SwiftUI 重建、转写区无更新）：
/// 1. 临时结果发布节流（单位时间发布次数上限）；
/// 2. 可用性检查 TTL 缓存（探测次数上限）。
@Suite("渲染风暴回归")
@MainActor
final class RenderingStormRegressionTests {

    /// 造一个 ready 会议
    private func makeMeeting() throws -> Meeting {
        let meeting = Meeting(title: "风暴回归")
        try meeting.transition(to: .ready)
        return meeting
    }

    private func settle(_ ms: UInt64 = 120) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: - 临时结果发布节流

    @Test("连续 50 个临时结果：发布次数受限，尾随刷新保证文字最终一致")
    func provisionalPublishThrottled() async throws {
        let mock = MockLocalTranscriptionService()
        let controller = LocalTranscriptionController(service: mock)
        let meeting = try makeMeeting()
        try await controller.start(for: meeting) { nil }

        let baseline = controller.segmentsPublishCount

        // 连续快速到达 50 个 volatile 结果（模拟渐进式识别的高频输出）
        for index in 0..<50 {
            mock.emit(LocalTranscriptResult(
                startAudioMs: 0, endAudioMs: 2000,
                text: "如果年度量能能保证我们可以再讨论两个点，第\(index)版",
                isFinal: false
            ))
        }
        // 让事件循环处理（不给足节流间隔）
        try await settle(50)

        let publishedDuringBurst = controller.segmentsPublishCount - baseline
        #expect(publishedDuringBurst <= 3,
                "高频临时结果期间发布次数必须受限（≤3），实际 \(publishedDuringBurst)")

        // 等待尾随刷新：最后一版文字必须可见（不丢最终状态）
        try await settle(400)
        #expect(controller.segments.last?.text.contains("第49版") == true,
                "尾随刷新后必须呈现最后一版临时文字")
        await controller.cancel()
    }

    @Test("节流窗口内的更新：首次立即发布，窗口内合并为一次尾随")
    func throttleWindowSemantics() async throws {
        let mock = MockLocalTranscriptionService()
        let controller = LocalTranscriptionController(service: mock)
        let meeting = try makeMeeting()
        try await controller.start(for: meeting) { nil }

        mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1000, text: "第一版", isFinal: false))
        try await settle(120)
        let afterFirst = controller.segmentsPublishCount
        #expect(afterFirst >= 1, "第一个临时结果应立即发布")

        // 窗口内连续 10 次：不得每个都发布
        for index in 0..<10 {
            mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1000, text: "更新\(index)", isFinal: false))
        }
        try await settle(30)
        #expect(controller.segmentsPublishCount - afterFirst <= 1,
                "节流窗口内最多一次立即发布")
        await controller.cancel()
    }

    @Test("最终结果不受节流影响：每个都立即发布")
    func finalResultsPublishImmediately() async throws {
        let mock = MockLocalTranscriptionService()
        let controller = LocalTranscriptionController(service: mock)
        let meeting = try makeMeeting()
        try await controller.start(for: meeting) { nil }

        let baseline = controller.segmentsPublishCount
        for index in 0..<5 {
            mock.emit(LocalTranscriptResult(
                startAudioMs: Int64(index * 2000), endAudioMs: Int64(index * 2000 + 1000),
                text: "第\(index)句不同内容的话。", isFinal: true
            ))
        }
        try await settle(120)
        #expect(controller.segmentsPublishCount - baseline == 5,
                "每个最终结果都必须立即发布")
        #expect(meeting.segments.count == 5)
        await controller.cancel()
    }

    // MARK: - 可用性检查 TTL 缓存

    @Test("TTL 内重复检查：服务探测只发生一次")
    func availabilityCachedWithinTTL() async throws {
        let mock = MockLocalTranscriptionService()
        let controller = LocalTranscriptionController(service: mock, availabilityCacheTTL: 60)

        _ = await controller.checkAvailability()
        _ = await controller.checkAvailability()
        _ = await controller.checkAvailability()
        #expect(mock.availabilityProbeCount == 1,
                "TTL 内三次检查只能探测一次（热路径反复 XPC 探测回归）")

        // 强制刷新：绕过缓存
        _ = await controller.checkAvailability(forceRefresh: true)
        #expect(mock.availabilityProbeCount == 2)
    }

    @Test("TTL 过期后重新探测")
    func availabilityRefreshedAfterTTL() async throws {
        let mock = MockLocalTranscriptionService()
        let controller = LocalTranscriptionController(service: mock, availabilityCacheTTL: 0.05)

        _ = await controller.checkAvailability()
        try await Task.sleep(for: .milliseconds(120))
        _ = await controller.checkAvailability()
        #expect(mock.availabilityProbeCount == 2, "过期后必须重新探测")
    }

    // MARK: - 缓存策略纯逻辑

    @Test("AvailabilityCachePolicy：边界行为")
    func cachePolicyLogic() {
        let policy = AvailabilityCachePolicy(ttl: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(!policy.shouldReuse(checkedAt: nil, now: t0), "从未检查不可复用")
        #expect(policy.shouldReuse(checkedAt: t0, now: t0.addingTimeInterval(59)))
        #expect(!policy.shouldReuse(checkedAt: t0, now: t0.addingTimeInterval(60)))
        #expect(!policy.shouldReuse(checkedAt: t0, now: t0.addingTimeInterval(120)))
        // 时钟回拨防御
        #expect(!policy.shouldReuse(checkedAt: t0, now: t0.addingTimeInterval(-1)))
    }
}
