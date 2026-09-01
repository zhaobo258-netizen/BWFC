import Foundation
import Testing
@testable import BangWoFenXi

/// 整场会议删除（实施计划 12.1）：数据库记录 + 录音/样本/分片全部清理
@Suite("会议删除")
@MainActor
final class MeetingDeletionTests {
    let tempDirectory: URL
    let fileStore: MeetingFileStore
    let environment: AppEnvironment

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileStore = MeetingFileStore(baseDirectory: tempDirectory)
        environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: fileStore,
            // 独立凭证 service：不触碰生产条目，避免授权弹窗（与 Key 分家测试同一模式）
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.meeting-deletion"
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    @Test("删除会议：数据库记录与全部关联文件不存在（实施计划 12.1 验收）")
    func deleteRemovesEverything() throws {
        let meeting = Stage5Fixtures.makeCompletedMeeting()
        try environment.persist(meeting)

        // 布置关联文件：录音、样本、分片、队列
        let meetingDir = try fileStore.ensureMeetingDirectory(for: meeting.id)
        try Data([0x01]).write(to: meetingDir.appending(path: MeetingFileStore.recordingFileName))
        let sampleURL = meetingDir
            .appending(path: MeetingFileStore.samplesDirectoryName, directoryHint: .isDirectory)
            .appending(path: "\(UUID().uuidString).wav")
        try FileManager.default.createDirectory(
            at: sampleURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0x02]).write(to: sampleURL)
        let chunksDir = try fileStore.ensureChunksDirectory(for: meeting.id)
        try Data([0x03]).write(to: chunksDir.appending(path: "chunk_0000.wav"))
        try ChunkQueueStore(fileURL: fileStore.chunkQueueFileURL(for: meeting.id)).save([
            ChunkQueueEntry(index: 0, audioStartMs: 0, audioEndMs: 20_000,
                            wallStartMs: 0, wallEndMs: 20_000,
                            fileName: "chunk_0000.wav", status: .succeeded, attemptCount: 0)
        ])
        #expect(FileManager.default.fileExists(atPath: meetingDir.path))

        // 删除
        try environment.deleteMeeting(meeting)

        // 验证：数据库无记录
        #expect(try environment.allMeetings().isEmpty)
        // 验证：会议专属目录（录音/样本/分片/队列）不存在
        #expect(!FileManager.default.fileExists(atPath: meetingDir.path))
        #expect(!FileManager.default.fileExists(atPath: sampleURL.path))
        #expect(!FileManager.default.fileExists(atPath: chunksDir.path))
    }

    @Test("删除其中一场不影响其他会议")
    func deleteKeepsOthers() throws {
        let meetingA = Stage5Fixtures.makeCompletedMeeting()
        let meetingB = Meeting(title: "另一场会议")
        try environment.persist(meetingA)
        try environment.persist(meetingB)
        _ = try fileStore.ensureMeetingDirectory(for: meetingA.id)
        _ = try fileStore.ensureMeetingDirectory(for: meetingB.id)

        try environment.deleteMeeting(meetingA)
        let remaining = try environment.allMeetings()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == meetingB.id)
        #expect(FileManager.default.fileExists(
            atPath: fileStore.meetingDirectory(for: meetingB.id).path
        ))
    }
}

/// finalizing 拆分流程：beginFinish / completeFinalizing 的状态约束
@Suite("finalizing 流程")
@MainActor
final class FinalizingFlowTests {
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

    @Test("拆分流程：beginFinish → finalizing（采集停止）→ completeFinalizing → completed")
    func splitFlow() throws {
        let meeting = Meeting(title: "拆分流程")
        try meeting.transition(to: .ready)
        try service.startRecording(for: meeting, deviceID: nil)

        try service.beginFinish()
        #expect(meeting.status == .finalizing)
        #expect(mock.stopCount == 1, "beginFinish 必须停止采集")
        let captureEndedAt = try #require(meeting.endedAt)

        // finalizing 期间不允许再次 beginFinish
        #expect(throws: (any Error).self) { try service.beginFinish() }

        Thread.sleep(forTimeInterval: 0.01)
        try service.completeFinalizing()
        #expect(meeting.status == .completed)
        #expect(meeting.endedAt == captureEndedAt, "AI 与转写收尾耗时不得计入录音时长")
    }

    @Test("未 beginFinish 直接 completeFinalizing 抛错")
    func completeWithoutBeginThrows() throws {
        let meeting = Meeting(title: "非法顺序")
        try meeting.transition(to: .ready)
        try service.startRecording(for: meeting, deviceID: nil)
        #expect(throws: MeetingRecordingError.self) {
            try service.completeFinalizing()
        }
        #expect(meeting.status == .recording, "非法调用不得改变状态")
    }

    @Test("暂停中 beginFinish：闭合暂停区间后进入 finalizing")
    func beginFinishWhilePaused() throws {
        let meeting = Meeting(title: "暂停收尾")
        try meeting.transition(to: .ready)
        try service.startRecording(for: meeting, deviceID: nil)
        try service.pauseRecording()
        try service.beginFinish()
        #expect(meeting.status == .finalizing)
        #expect(meeting.pauseIntervals.count == 1, "暂停中收尾必须闭合暂停区间")
    }
}
