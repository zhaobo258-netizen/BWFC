import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

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
        let task = Task {
            try await FileTranscriptionRunner(service: mock).run(audioURL: url)
        }
        // 等喂入完成进入等待流阶段后取消
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消后不应正常返回")
        } catch is CancellationError {
            // 预期
        } catch {
            Issue.record("应抛出 CancellationError，实际 \(type(of: error))")
        }
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        var values: [Double] { lock.withLock { storage } }
        func append(_ value: Double) { lock.withLock { storage.append(value) } }
    }
}
