import Foundation
import Testing
@testable import BangWoFenXi

/// 本地转写控制器测试：结果流消费、临时/最终替换、时间逆映射、入库与持久化回调
@Suite("本地转写控制器")
@MainActor
final class LocalTranscriptionControllerTests {
    let mock: MockLocalTranscriptionService
    let controller: LocalTranscriptionController

    init() {
        mock = MockLocalTranscriptionService()
        controller = LocalTranscriptionController(service: mock)
    }

    /// 造一个带词汇与参会人的 ready 会议
    private func makeMeeting() throws -> Meeting {
        let meeting = Meeting(title: "转写测试", glossary: ["返点", "量能"])
        meeting.participants.append(
            Participant(cloudAlias: "p_01", displayName: "张总", side: .counterpart, role: "采购负责人")
        )
        try meeting.transition(to: .ready)
        return meeting
    }

    /// 等待异步消费生效
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    /// 轮询等待条件达成（并行高负载下消费任务调度可能超过固定睡眠窗口；
    /// 超时后退出循环，由后续断言如实判定——同步方式加固，不降低断言强度）
    private func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("不可用则拒绝启动并给出真实原因")
    func startRefusedWhenUnavailable() async throws {
        mock.availability = TranscriptionAvailability(
            transcriberAvailable: false,
            mandarinSupported: true,
            assetState: .installed,
            issues: ["本设备不支持 Apple 语音识别（SpeechTranscriber 不可用）"]
        )
        let meeting = try makeMeeting()
        await #expect(throws: LocalTranscriptionError.self) {
            try await controller.start(for: meeting) { nil }
        }
        guard case .unavailable(let reason) = controller.runState else {
            Issue.record("不可用时应进入 unavailable 状态")
            return
        }
        #expect(reason.contains("SpeechTranscriber 不可用"))
        #expect(mock.startSessionCalls.isEmpty, "不可用时不得启动会话")
    }

    @Test("上下文词汇：专业词汇 + 参会人姓名与角色")
    func contextualStringsPassthrough() async throws {
        let meeting = try makeMeeting()
        try await controller.start(for: meeting) { nil }
        let passed = try #require(mock.startSessionCalls.first)
        #expect(passed.contains("返点"))
        #expect(passed.contains("量能"))
        #expect(passed.contains("张总"))
        #expect(passed.contains("采购负责人"))
        await controller.cancel()
    }

    @Test("临时结果上屏，最终结果被替换且无重复")
    func provisionalThenFinal() async throws {
        let meeting = try makeMeeting()
        var persistedCount = 0
        controller.onFinalSegment = { persistedCount += 1 }
        try await controller.start(for: meeting) { nil }

        mock.emit(LocalTranscriptResult(startAudioMs: 1000, endAudioMs: 2500,
                                        text: "如果年度量能", isFinal: false))
        await waitFor { self.controller.segments.count == 1 }
        #expect(controller.segments.count == 1)
        #expect(controller.segments.first?.state == .provisional)
        #expect(meeting.segments.isEmpty, "临时片段不入库")

        mock.emit(LocalTranscriptResult(startAudioMs: 1000, endAudioMs: 2500,
                                        text: "如果年度量能能保证，我们可以再讨论两个点。", isFinal: true))
        await waitFor { self.controller.segments.first?.state == .final }
        #expect(controller.segments.count == 1, "临时被最终替换后不得残留两条")
        #expect(controller.segments.first?.state == .final)
        #expect(meeting.segments.count == 1, "最终片段必须入库")
        #expect(persistedCount == 1, "最终片段必须触发持久化回调")
        await controller.cancel()
    }

    @Test("重复最终结果只入库一次")
    func duplicateFinalPersistedOnce() async throws {
        let meeting = try makeMeeting()
        try await controller.start(for: meeting) { nil }

        let result = LocalTranscriptResult(startAudioMs: 0, endAudioMs: 2000,
                                         text: "返点需要和回款周期一起确认。", isFinal: true)
        mock.emit(result)
        mock.emit(result) // 引擎重发
        await waitFor { meeting.segments.count == 1 }
        #expect(meeting.segments.count == 1)
        await controller.cancel()
    }

    @Test("结果时间经时间线逆映射还原暂停区间")
    func timeMappingAcrossPause() async throws {
        let meeting = try makeMeeting()
        // 构造时间线：墙钟 5s 暂停、8s 恢复 → 音频时间 5s 对应墙钟 8s
        let start = Date(timeIntervalSince1970: 1_000)
        var timeline = RecordingTimeline(startedAt: start)
        try timeline.beginPause(at: start.addingTimeInterval(5))
        _ = try timeline.endPause(at: start.addingTimeInterval(8))

        try await controller.start(for: meeting) { timeline }

        mock.emit(LocalTranscriptResult(startAudioMs: 5_000, endAudioMs: 7_000,
                                        text: "恢复后的第一句。", isFinal: true))
        await waitFor { meeting.segments.count == 1 }
        let segment = try #require(meeting.segments.first)
        #expect(segment.startMs == 8_000, "音频 5s 应映射到墙钟 8s（暂停 3s）")
        #expect(segment.endMs == 10_000)
        await controller.cancel()
    }

    @Test("结束会话：丢弃尾部临时片段并回到空闲")
    func finishDropsProvisional() async throws {
        let meeting = try makeMeeting()
        try await controller.start(for: meeting) { nil }

        mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1000,
                                        text: "已确认的一句。", isFinal: true))
        mock.emit(LocalTranscriptResult(startAudioMs: 1000, endAudioMs: 2000,
                                        text: "尚未确认的半句", isFinal: false))
        await waitFor { self.controller.segments.count == 2 }
        #expect(controller.segments.count == 2)

        await controller.finish()
        #expect(controller.runState == .idle)
        #expect(controller.segments.count == 1, "结束后临时片段被丢弃")
        #expect(controller.segments.first?.state == .final)
        #expect(mock.finishCount == 1)
    }

    @Test("启动失败：错误透出且不进入运行态")
    func startFailurePropagates() async throws {
        mock.startError = LocalTranscriptionError.noCompatibleAudioFormat
        let meeting = try makeMeeting()
        await #expect(throws: (any Error).self) {
            try await controller.start(for: meeting) { nil }
        }
        #expect(controller.runState != .running)
        #expect(controller.lastErrorDescription != nil)
    }
}
