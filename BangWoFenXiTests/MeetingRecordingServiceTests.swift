import Foundation
import Testing
@testable import BangWoFenXi

/// 录音编排测试：状态机驱动的录音生命周期 + 设备中断处理（Mock 采集，不碰硬件）
@Suite("录音编排")
@MainActor
final class MeetingRecordingServiceTests {
    let tempDirectory: URL
    let fileStore: MeetingFileStore
    let mock: MockAudioCaptureService
    let service: MeetingRecordingService

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileStore = MeetingFileStore(baseDirectory: tempDirectory)
        mock = MockAudioCaptureService()
        service = MeetingRecordingService(capture: mock, fileStore: fileStore)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// 造一个 ready 状态的会议
    private func makeReadyMeeting() -> Meeting {
        let meeting = Meeting(title: "录音编排测试")
        try? meeting.transition(to: .ready)
        return meeting
    }

    private func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("完整生命周期：ready → 录音 → 暂停 → 继续 → 结束")
    func fullLifecycle() throws {
        let meeting = makeReadyMeeting()

        // 开始
        try service.startRecording(for: meeting, deviceID: "mock-usb")
        #expect(meeting.status == .recording)
        #expect(meeting.startedAt != nil)
        #expect(meeting.audioRelativePath == fileStore.relativeAudioPath(for: meeting.id))
        #expect(mock.selectDeviceCalls == ["mock-usb"])
        #expect(mock.startCaptureURLs.count == 1)
        #expect(service.activeMeeting === meeting)

        // 文件写入约定目录
        let captureURL = try #require(mock.startCaptureURLs.first)
        #expect(captureURL.path.hasPrefix(tempDirectory.path))
        #expect(captureURL.lastPathComponent == MeetingFileStore.recordingFileName)

        // 暂停
        try service.pauseRecording()
        #expect(meeting.status == .paused)
        #expect(mock.pauseCount == 1)

        // 继续：闭合一个暂停区间
        try service.resumeRecording()
        #expect(meeting.status == .recording)
        #expect(mock.resumeCount == 1)
        #expect(meeting.pauseIntervals.count == 1)

        // 结束：finalizing → completed
        try service.finishRecording()
        #expect(meeting.status == .completed)
        #expect(meeting.endedAt != nil)
        #expect(mock.stopCount == 1)
        #expect(service.activeMeeting == nil)
    }

    @Test("非 ready 状态不允许开始录音")
    func startRejectsNonReady() {
        let draftMeeting = Meeting(title: "草稿")
        #expect(throws: MeetingRecordingError.self) {
            try service.startRecording(for: draftMeeting, deviceID: nil)
        }
        #expect(draftMeeting.status == .draft)
        #expect(mock.startCaptureURLs.isEmpty, "状态校验失败时不得启动采集")
    }

    @Test("采集启动失败：状态回滚且不留会话")
    func startCaptureFailureRollsBack() {
        let meeting = makeReadyMeeting()
        mock.startCaptureError = AudioCaptureError.engineStartFailed("模拟失败")
        #expect(throws: (any Error).self) {
            try service.startRecording(for: meeting, deviceID: nil)
        }
        #expect(meeting.status == .ready, "采集失败时会议状态必须保持 ready")
        #expect(meeting.audioRelativePath == nil)
        #expect(service.activeMeeting == nil)
        #expect(mock.stopCount == 1, "失败时应清理采集资源")
        #expect(service.lastErrorDescription != nil)
    }

    @Test("未开始时暂停/继续/结束均抛错")
    func operationsWithoutSessionThrow() {
        #expect(throws: MeetingRecordingError.self) { try service.pauseRecording() }
        #expect(throws: MeetingRecordingError.self) { try service.resumeRecording() }
        #expect(throws: MeetingRecordingError.self) { try service.finishRecording() }
    }

    @Test("录音中重复暂停被状态机拒绝")
    func doublePauseRejected() throws {
        let meeting = makeReadyMeeting()
        try service.startRecording(for: meeting, deviceID: nil)
        try service.pauseRecording()
        #expect(throws: (any Error).self) { try service.pauseRecording() }
        #expect(meeting.status == .paused)
    }

    @Test("设备拔出：自动暂停并标记中断（实施计划 11.2）")
    func deviceDisconnectAutoPauses() async throws {
        let meeting = makeReadyMeeting()
        try service.startRecording(for: meeting, deviceID: nil)
        #expect(meeting.status == .recording)

        mock.simulateDeviceDisconnect()
        // onDeviceDisconnected 回调经 Task 切到 MainActor，等待生效
        try await Task.sleep(for: .milliseconds(100))

        #expect(meeting.status == .paused, "设备拔出必须自动暂停")
        #expect(service.deviceInterrupted)
        #expect(mock.pauseCount == 1)
    }

    @Test("设备中断后选择新设备，再继续录音")
    func switchDeviceAndResume() async throws {
        let meeting = makeReadyMeeting()
        try service.startRecording(for: meeting, deviceID: "mock-builtin")
        mock.simulateDeviceDisconnect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.deviceInterrupted)

        try service.switchInputDevice(to: "mock-usb")
        #expect(!service.deviceInterrupted)
        #expect(mock.selectDeviceCalls.last == "mock-usb")

        try service.resumeRecording()
        #expect(meeting.status == .recording)
    }

    @Test("录音写入失败：自动暂停并记录暂停区间，修复后可继续")
    func writeFailureAutoPausesAndCanResume() async throws {
        let meeting = makeReadyMeeting()
        try service.startRecording(for: meeting, deviceID: nil)

        mock.simulateWriteFailure()
        await waitFor { service.writeFailureInterrupted }

        #expect(meeting.status == .paused)
        #expect(service.interruptionReason == .fileWriteFailure)
        #expect(!service.deviceInterrupted)
        #expect(mock.pauseCount == 1)
        #expect(service.timeline?.isPaused == true)
        #expect(service.lastErrorDescription == RecordingInterruptionReason.fileWriteFailure.userMessage)

        try service.resumeRecording()

        #expect(meeting.status == .recording)
        #expect(service.interruptionReason == nil)
        #expect(meeting.pauseIntervals.count == 1)
    }

    @Test("暂停中结束：闭合暂停区间并完成会议")
    func finishWhilePaused() throws {
        let meeting = makeReadyMeeting()
        try service.startRecording(for: meeting, deviceID: nil)
        try service.pauseRecording()
        try service.finishRecording()
        #expect(meeting.status == .completed)
        #expect(meeting.pauseIntervals.count == 1, "暂停中结束必须闭合暂停区间")
        #expect(mock.stopCount == 1)
    }

    @Test("已结束项目续录：追加原音频并沿用原时间轴")
    func continueCompletedRecording() throws {
        let originalStart = Date(timeIntervalSince1970: 1_000)
        let meeting = Meeting(
            title: "已结束项目",
            status: .completed,
            startedAt: originalStart,
            endedAt: originalStart.addingTimeInterval(50),
            audioRelativePath: fileStore.relativeAudioPath(for: UUID()),
            pauseIntervals: [PauseInterval(startMs: 20_000, endMs: 25_000)],
            timelineDurationMs: 50_000
        )
        meeting.audioRelativePath = fileStore.relativeAudioPath(for: meeting.id)
        mock.existingAudioDurationMs = 45_000

        try service.continueRecording(for: meeting, deviceID: "mock-usb", timelineOffsetMs: 50_000)

        #expect(meeting.status == .recording)
        #expect(meeting.startedAt == originalStart)
        #expect(meeting.endedAt == nil)
        #expect(meeting.timelineDurationMs == 50_000)
        #expect(mock.appendCaptureURLs.count == 1)
        #expect(mock.startCaptureURLs.isEmpty)
        #expect(service.elapsedWallMs() >= 50_000)
        #expect(service.timeline?.initialEffectiveAudioOffsetMs == 45_000)
    }

    @Test("续录启动失败时恢复原结束状态")
    func continuationFailureRollsBack() {
        let endedAt = Date(timeIntervalSince1970: 2_000)
        let meeting = Meeting(
            title: "续录失败",
            status: .completed,
            endedAt: endedAt,
            timelineDurationMs: 30_000
        )
        mock.startCaptureError = AudioCaptureError.engineStartFailed("模拟失败")

        #expect(throws: (any Error).self) {
            try service.continueRecording(for: meeting, deviceID: nil, timelineOffsetMs: 30_000)
        }
        #expect(meeting.status == .completed)
        #expect(meeting.endedAt == endedAt)
        #expect(meeting.timelineDurationMs == 30_000)
        #expect(service.activeMeeting == nil)
    }
}
