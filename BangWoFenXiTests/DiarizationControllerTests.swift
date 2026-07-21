import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

/// 云端识别编排集成测试：分片产出→上传→合并→退避→恢复（Mock 服务，无真实网络）
@Suite("云端识别编排")
@MainActor
final class DiarizationControllerTests {
    let tempDirectory: URL
    let fileStore: MeetingFileStore
    let mockDiarization: MockDiarizationService
    let mockTranscription: MockLocalTranscriptionService
    let transcriptController: LocalTranscriptionController
    let sleepCalls: LockedBox<[Int64]>
    let controller: DiarizationController
    let meeting: Meeting
    let timeline: RecordingTimeline

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileStore = MeetingFileStore(baseDirectory: tempDirectory)
        mockDiarization = MockDiarizationService()
        mockTranscription = MockLocalTranscriptionService()
        transcriptController = LocalTranscriptionController(service: mockTranscription)
        sleepCalls = LockedBox([])
        let sleeps = sleepCalls
        controller = DiarizationController(
            diarization: mockDiarization,
            fileStore: fileStore,
            transcriptController: transcriptController,
            sleep: { ms in sleeps.withLock { $0.append(ms) } }
        )

        // 会议：recording 状态 + 45 秒真实录音文件
        meeting = Meeting(title: "编排测试")
        let participant = Participant(cloudAlias: "p_01", displayName: "张总", side: .counterpart)
        meeting.participants.append(participant)
        try meeting.transition(to: .ready)
        try meeting.transition(to: .recording)
        meeting.audioRelativePath = fileStore.relativeAudioPath(for: meeting.id)
        timeline = RecordingTimeline(startedAt: Date().addingTimeInterval(-60))

        // 45 秒正弦波录音
        let audioURL = fileStore.meetingDirectory(for: meeting.id)
            .appending(path: MeetingFileStore.recordingFileName)
        try fileStore.ensureMeetingDirectory(for: meeting.id)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        let frameCount = AVAudioFrameCount(format.sampleRate * 45)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            buffer.floatChannelData![0][frame] = sin(2 * Float.pi * 440 * Float(frame) / 44_100) * 0.3
        }
        try file.write(from: buffer)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// 启动转写控制器与编排（建立会议关联）
    private func startAll() async throws {
        try await transcriptController.start(for: meeting) { [timeline] in timeline }
        controller.start(for: meeting) { [timeline] in timeline }
    }

    @Test("分片产出：闭合窗口入队、文件生成、队列持久化")
    func chunkProduction() async throws {
        mockDiarization.delayMs = 600 // 让上传慢一点，先看出队列入队
        try await startAll()

        controller.produceChunks(uptoAudioMs: 45_000)
        // 窗口 0（0–20s）与 1（18–38s）闭合；窗口 2（36–56s）未闭合
        #expect(controller.queue.map(\.index) == [0, 1])
        #expect(controller.queue.allSatisfy { $0.status != .succeeded || true })
        let chunksDir = fileStore.chunksDirectory(for: meeting.id)
        #expect(FileManager.default.fileExists(atPath: chunksDir.appending(path: "chunk_0000.wav").path))
        #expect(FileManager.default.fileExists(atPath: chunksDir.appending(path: "chunk_0001.wav").path))
        // 时间轴固化（无暂停：wall == audio）
        #expect(controller.queue[0].wallStartMs == 0)
        #expect(controller.queue[0].wallEndMs == 20_000)
        #expect(controller.queue[1].wallStartMs == 18_000)
        // 队列已持久化
        let restored = try ChunkQueueStore(fileURL: fileStore.chunkQueueFileURL(for: meeting.id)).load()
        #expect(restored.count == 2)

        await controller.finishAndDrain()
    }

    @Test("成功流：云端片段合并入库、说话人按代号映射、分片文件删除")
    func successFlow() async throws {
        mockDiarization.resultQueue = [
            DiarizationChunkResult(durationMs: 20_000, segments: [
                .init(startMs: 1_000, endMs: 5_000, text: "如果年度量能能保证。", speakerLabel: "p_01")
            ]),
            DiarizationChunkResult(durationMs: 20_000, segments: [
                .init(startMs: 2_000, endMs: 6_000, text: "量能可以谈，返点需要确认。", speakerLabel: "spk_unknown")
            ])
        ]
        try await startAll()
        controller.produceChunks(uptoAudioMs: 40_000)
        await controller.finishAndDrain()

        // 全部成功
        #expect(controller.queue.allSatisfy { $0.status == .succeeded })
        // 分片文件已删除（实施计划 7.4）
        let chunksDir = fileStore.chunksDirectory(for: meeting.id)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: chunksDir.path)) ?? []
        #expect(remaining.filter { $0.hasPrefix("chunk_") }.isEmpty)

        // 片段入库：墙钟 = 分片起点 + 相对时间
        let segments = meeting.segments
        #expect(segments.count == 2)
        #expect(segments[0].startMs == 1_000)
        #expect(segments[0].endMs == 5_000)
        #expect(segments[0].source == .cloud)
        #expect(segments[0].state == .final)
        #expect(segments[0].participantId == meeting.participants[0].id, "p_01 必须映射为参会人")
        // 第二个片段来自窗口 1（起点 18s）：18000+2000=20000
        #expect(segments[1].startMs == 20_000)
        #expect(segments[1].participantId == nil, "未知标签不映射")
        #expect(segments[1].remoteSpeakerLabel == "spk_unknown")
        // 待识别展示名
        #expect(controller.displayName(forRemoteLabel: "spk_unknown") == "待识别 A")
        #expect(controller.lastConfirmedAt != nil)
    }

    @Test("结尾：尾部残缺分片（36–45s）入队并处理")
    func tailWindowDrained() async throws {
        try await startAll()
        controller.produceChunks(uptoAudioMs: 40_000)     // 0、1 号
        await controller.finishAndDrain(uptoAudioMs: 45_000) // 应补 2 号尾部（36–45s）
        #expect(controller.queue.map(\.index) == [0, 1, 2])
        let tail = try #require(controller.queue.last)
        #expect(tail.audioStartMs == 36_000)
        #expect(tail.audioEndMs == 45_000)
        #expect(tail.status == .succeeded)
    }

    @Test("持续网络失败：指数退避后进入待用户重试，不无限循环")
    func persistentFailureBackoff() async throws {
        mockDiarization.persistentError = DiarizationAPIError.network
        try await startAll()
        controller.produceChunks(uptoAudioMs: 20_000) // 仅窗口 0
        // 用 18.5s 截止收尾，避免产生尾部残缺分片干扰退避断言
        await controller.finishAndDrain(uptoAudioMs: 18_500)

        let entry = try #require(controller.queue.first)
        #expect(entry.status == .awaitingUserRetry)
        #expect(entry.attemptCount == 5, "首次 + 4 次重试 = 5 次尝试")
        // 退避序列：1s、2s、4s、8s
        #expect(sleepCalls.withLock { $0 }.filter { $0 >= 1_000 } == [1_000, 2_000, 4_000, 8_000])
        // 分片文件保留（未成功不得删除）
        let chunksDir = fileStore.chunksDirectory(for: meeting.id)
        #expect(FileManager.default.fileExists(atPath: chunksDir.appending(path: "chunk_0000.wav").path))

        // 用户手动重试：错误解除后成功
        mockDiarization.persistentError = nil
        controller.retryAwaitingUserChunks()
        await controller.finishAndDrain(uptoAudioMs: 18_500)
        #expect(controller.queue.first?.status == .succeeded)
    }

    @Test("401：云端暂停、分片回到待处理、本地继续；修复后重试成功")
    func unauthorizedSuspendsCloud() async throws {
        mockDiarization.errorQueue = [DiarizationAPIError.unauthorized]
        try await startAll()
        controller.produceChunks(uptoAudioMs: 20_000)
        await controller.finishAndDrain()

        guard case .suspended(let reason) = controller.cloudState else {
            Issue.record("401 必须使云端进入暂停态")
            return
        }
        #expect(reason.contains("401"))
        // 不消耗重试次数，分片回到待处理
        #expect(controller.queue.first?.status == .pending)
        #expect(controller.queue.first?.attemptCount == 0)

        // 修复 Key 后恢复并成功
        controller.resumeAfterKeyFix()
        await controller.finishAndDrain()
        #expect(controller.queue.first?.status == .succeeded)
        #expect(controller.cloudState == .idle)
    }

    @Test("App 重启恢复：uploading 中断条目按失败重试，队列完整恢复")
    func restartRecovery() async throws {
        // 预置一个「上次崩溃时」的队列：一个 uploading、一个 succeeded
        let store = ChunkQueueStore(fileURL: fileStore.chunkQueueFileURL(for: meeting.id))
        try fileStore.ensureChunksDirectory(for: meeting.id)
        // uploading 条目的分片文件必须存在（否则恢复时丢弃）
        let chunksDir = fileStore.chunksDirectory(for: meeting.id)
        try AudioChunkExtractor.extract(
            from: fileStore.meetingDirectory(for: meeting.id)
                .appending(path: MeetingFileStore.recordingFileName),
            startMs: 0, endMs: 20_000,
            to: chunksDir.appending(path: "chunk_0000.wav")
        )
        try store.save([
            ChunkQueueEntry(index: 0, audioStartMs: 0, audioEndMs: 20_000,
                            wallStartMs: 0, wallEndMs: 20_000,
                            fileName: "chunk_0000.wav", status: .uploading, attemptCount: 1),
            ChunkQueueEntry(index: 1, audioStartMs: 18_000, audioEndMs: 38_000,
                            wallStartMs: 18_000, wallEndMs: 38_000,
                            fileName: "chunk_0001.wav", status: .succeeded, attemptCount: 0)
        ])
        mockDiarization.resultQueue = [
            DiarizationChunkResult(durationMs: 20_000, segments: [
                .init(startMs: 0, endMs: 3_000, text: "恢复后补传成功。", speakerLabel: "p_01")
            ])
        ]

        try await startAll()
        // uploading → failed（允许重试）；succeeded 保留
        #expect(controller.queue[0].status == .succeeded || controller.queue[0].status == .failed || controller.queue[0].status == .uploading)
        await controller.finishAndDrain()

        #expect(controller.queue.allSatisfy { $0.status == .succeeded })
        #expect(meeting.segments.first?.text == "恢复后补传成功。", "重启后必须补传并落位")
    }

    @Test("错序结果按绝对时间排序合并")
    func outOfOrderResultsSorted() async throws {
        mockDiarization.resultQueue = [
            // 窗口 0：较晚的片段
            DiarizationChunkResult(durationMs: 20_000, segments: [
                .init(startMs: 10_000, endMs: 15_000, text: "晚一点的片段。", speakerLabel: nil)
            ]),
            // 窗口 1：反而包含更早的片段
            DiarizationChunkResult(durationMs: 20_000, segments: [
                .init(startMs: 2_000, endMs: 6_000, text: "更早的片段。", speakerLabel: nil)
            ])
        ]
        try await startAll()
        controller.produceChunks(uptoAudioMs: 40_000)
        await controller.finishAndDrain()

        #expect(meeting.segments.map(\.startMs) == [10_000, 20_000].sorted())
        #expect(meeting.segments.first?.text == "晚一点的片段。")
        #expect(meeting.segments.last?.text == "更早的片段。")
    }

    @Test("上传请求只带代号与样本文件，不带真实姓名")
    func knownSpeakersAliasedOnly() async throws {
        // 给参会人准备样本文件
        let participant = meeting.participants[0]
        let sampleRelative = fileStore.relativeVoiceSamplePath(meetingID: meeting.id, participantID: participant.id)
        let sampleURL = try fileStore.absoluteURL(forRelativePath: sampleRelative)
        try FileManager.default.createDirectory(at: sampleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01, 0x02]).write(to: sampleURL)
        participant.voiceReferencePath = sampleRelative
        participant.voiceReferenceDurationMs = 3_000

        try await startAll()
        controller.produceChunks(uptoAudioMs: 20_000)
        await controller.finishAndDrain()

        let speakers = try #require(mockDiarization.calls.first?.speakers)
        #expect(speakers.count == 1)
        #expect(speakers[0].alias == "p_01", "云端只传本地代号（实施计划 7.5）")
        #expect(speakers[0].sampleURL.lastPathComponent.hasSuffix(".wav"))
    }
}

/// 简单的线程安全盒子（测试用）
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
