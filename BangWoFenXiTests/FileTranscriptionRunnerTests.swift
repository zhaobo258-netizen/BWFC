import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

private final class BlockingFinishTranscriptionService:
    LocalTranscriptionServicing,
    @unchecked Sendable
{
    let results: AsyncStream<LocalTranscriptResult>

    private let lock = NSLock()
    private let resultsContinuation: AsyncStream<LocalTranscriptResult>.Continuation
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var finishStartedStorage = false
    private var cancelRequested = false
    private var cancelCountStorage = 0

    init() {
        var continuation: AsyncStream<LocalTranscriptResult>.Continuation!
        results = AsyncStream { continuation = $0 }
        resultsContinuation = continuation
    }

    func checkMandarinAvailability() async -> TranscriptionAvailability {
        TranscriptionAvailability(
            transcriberAvailable: true,
            mandarinSupported: true,
            assetState: .installed,
            issues: []
        )
    }

    func installMandarinAssets(
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {}

    func startSession(contextualStrings: [String]) async throws {}

    func feed(_ buffer: AVAudioPCMBuffer) async {}

    func finishSession() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                finishStartedStorage = true
                if cancelRequested {
                    return true
                }
                finishContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
        resultsContinuation.finish()
    }

    func cancelSession() async {
        let continuation = lock.withLock {
            cancelCountStorage += 1
            cancelRequested = true
            let continuation = finishContinuation
            finishContinuation = nil
            return continuation
        }
        continuation?.resume()
        resultsContinuation.finish()
    }

    func releaseFinish() {
        let continuation = lock.withLock {
            let continuation = finishContinuation
            finishContinuation = nil
            return continuation
        }
        continuation?.resume()
        resultsContinuation.finish()
    }

    var finishStarted: Bool {
        lock.withLock { finishStartedStorage }
    }

    var cancelCount: Int {
        lock.withLock { cancelCountStorage }
    }
}

/// 文件转写执行器（阶段 C）：读文件喂服务、结果去重、时间轴、取消响应
@Suite("文件转写执行器", .serialized)
final class FileTranscriptionRunnerTests {
    private let tempDirectory: URL

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-runner-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// 合成 48kHz 单声道 PCM caf（与提取产物同规格）
    private func makeAudioFile(seconds: Double) throws -> URL {
        let url = tempDirectory.appending(path: "audio-\(UUID().uuidString).caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }

    @Test("整篇转写：只收最终结果，重复结果去重，按时间升序")
    func runCollectsFinalsAndDeduplicates() async throws {
        let mock = MockLocalTranscriptionService()
        mock.finishEndsStream = true
        // 预注入脚本（AsyncStream 缓冲）：临时结果应被忽略；重复最终结果应去重
        mock.emit(LocalTranscriptResult(startAudioMs: 3000, endAudioMs: 4500,
                                        text: "第二句在后面。", isFinal: true))
        mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1200,
                                        text: "第一句临时", isFinal: false))
        mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1500,
                                        text: "第一句完整内容。", isFinal: true))
        mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 1500,
                                        text: "第一句完整内容。", isFinal: true)) // 引擎重发

        let url = try makeAudioFile(seconds: 0.5)
        let runner = FileTranscriptionRunner(service: mock)
        let segments = try await runner.run(audioURL: url)

        #expect(segments.count == 2, "临时忽略 + 重发去重后应为 2 段")
        #expect(segments.map(\.text) == ["第一句完整内容。", "第二句在后面。"], "按时间升序")
        #expect(segments.allSatisfy { $0.state == .final })
        #expect(mock.startSessionCalls.count == 1)
        #expect(mock.finishCount == 1)
        #expect(mock.fedBufferCount >= 1, "音频必须真实喂入服务")
    }

    @Test("时间轴：导入无暂停区间，片段时间即音频时间")
    func timelineIsAudioTime() async throws {
        let mock = MockLocalTranscriptionService()
        mock.finishEndsStream = true
        mock.emit(LocalTranscriptResult(startAudioMs: 125_000, endAudioMs: 130_000,
                                        text: "两分零五秒处的话。", isFinal: true))
        let url = try makeAudioFile(seconds: 0.2)
        let segments = try await FileTranscriptionRunner(service: mock).run(audioURL: url)
        #expect(segments.first?.startMs == 125_000)
        #expect(segments.first?.endMs == 130_000)
    }

    @Test("进度回调：收敛到 1")
    func progressReachesOne() async throws {
        let mock = MockLocalTranscriptionService()
        mock.finishEndsStream = true
        let url = try makeAudioFile(seconds: 1.5)
        let recorder = ProgressRecorder()
        _ = try await FileTranscriptionRunner(service: mock).run(audioURL: url) { value in
            recorder.append(value)
        }
        #expect(recorder.values.last == 1.0)
    }

    @Test("不可读文件：明确 undecodable")
    func unreadableFileThrows() async {
        let mock = MockLocalTranscriptionService()
        let url = tempDirectory.appending(path: "not-audio.caf")
        try? Data([0x00, 0x01]).write(to: url)
        await #expect(throws: AudioImportError.undecodable) {
            _ = try await FileTranscriptionRunner(service: mock).run(audioURL: url)
        }
    }

    @Test("外层取消：结果流未结束也不悬挂，如实抛出取消")
    func cancellationDoesNotHang() async throws {
        let mock = MockLocalTranscriptionService()
        mock.finishEndsStream = false // 模拟服务收尾迟迟不结束流
        let url = try makeAudioFile(seconds: 0.2)
        let outcome = CancellationOutcome()
        let task = Task {
            do {
                _ = try await FileTranscriptionRunner(service: mock).run(audioURL: url)
                outcome.set(.completed)
            } catch is CancellationError {
                outcome.set(.cancelled)
            } catch {
                outcome.set(.other(String(describing: type(of: error))))
            }
        }
        // 等喂入完成进入等待流阶段后取消
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await task.value
        #expect(outcome.value == .cancelled, "取消后应如实抛出 CancellationError")
    }

    @Test("取消会唤醒卡在有限输入收尾的转写会话")
    func cancellationInterruptsBlockedFinish() async throws {
        let service = BlockingFinishTranscriptionService()
        let url = try makeAudioFile(seconds: 0.2)
        let outcome = CancellationOutcome()
        let task = Task {
            do {
                _ = try await FileTranscriptionRunner(service: service)
                    .run(audioURL: url)
                outcome.set(.completed)
            } catch is CancellationError {
                outcome.set(.cancelled)
            } catch {
                outcome.set(.other(String(describing: type(of: error))))
            }
        }

        let finishDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < finishDeadline, !service.finishStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.finishStarted)

        task.cancel()
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < cancellationDeadline,
              outcome.value == .pending {
            try await Task.sleep(for: .milliseconds(10))
        }
        let completedBeforeDeadline = outcome.value != .pending
        if !completedBeforeDeadline {
            service.releaseFinish()
        }
        await task.value

        #expect(completedBeforeDeadline, "取消必须主动结束卡住的 finishSession")
        #expect(outcome.value == .cancelled)
        #expect(service.cancelCount >= 1)
    }

    @Test("连续短读逐块送入，不覆盖已读音频或丢失帧")
    func shortReadsPreserveEveryFrame() async throws {
        let mock = MockLocalTranscriptionService()
        mock.finishEndsStream = true
        let url = try makeAudioFile(seconds: 0.1)
        let runner = FileTranscriptionRunner(service: mock, readAudio: { file, buffer, requested in
            try file.read(into: buffer, frameCount: min(requested, 600))
        })
        _ = try await runner.run(audioURL: url)
        #expect(mock.fedFrameCount == 4_800)
        #expect(mock.fedBufferCount == 8)
    }

    @Test("收尾错误返回失败并携带已得文稿，不能成为成功结果")
    func finalizationFailurePreservesPartialResults() async throws {
        let mock = MockLocalTranscriptionService()
        mock.finishEndsStream = true
        mock.finishError = .finalizationFailed
        mock.finalResultsOnFinish = [
            .init(startAudioMs: 0, endAudioMs: 100, text: "已保存的一句话", isFinal: true)
        ]
        let url = try makeAudioFile(seconds: 0.1)
        do {
            _ = try await FileTranscriptionRunner(service: mock).run(audioURL: url)
            Issue.record("收尾失败不得返回成功")
        } catch let failure as FileTranscriptionRunner.Failure {
            #expect(failure.cause == .finalizationFailed)
            #expect(failure.partialResults.map(\.text) == ["已保存的一句话"])
        }
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        var values: [Double] { lock.withLock { storage } }
        func append(_ value: Double) { lock.withLock { storage.append(value) } }
    }

    private final class CancellationOutcome: @unchecked Sendable {
        enum Value: Equatable {
            case pending
            case completed
            case cancelled
            case other(String)
        }

        private let lock = NSLock()
        private var storage: Value = .pending
        var value: Value { lock.withLock { storage } }
        func set(_ value: Value) { lock.withLock { storage = value } }
    }
}
