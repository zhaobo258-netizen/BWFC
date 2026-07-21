import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

/// 分片队列持久化与分片提取（重启恢复 / 边界重叠提取）
@Suite("分片队列与提取")
final class ChunkQueueAndExtractorTests {
    let tempDirectory: URL

    init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// 生成指定时长正弦波 .caf 文件
    private func makeSineFile(seconds: Double, named name: String) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let url = tempDirectory.appending(path: name)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            buffer.floatChannelData![0][frame] =
                sin(2 * Float.pi * 440 * Float(frame) / 44_100) * 0.5
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: - 队列持久化

    @Test("队列状态持久化并可恢复（App 重启依据）")
    func queueStoreRoundTrip() throws {
        let store = ChunkQueueStore(fileURL: tempDirectory.appending(path: "queue.json"))
        let entries = [
            ChunkQueueEntry(index: 0, audioStartMs: 0, audioEndMs: 20_000,
                            wallStartMs: 0, wallEndMs: 20_000,
                            fileName: "chunk_0000.wav", status: .succeeded, attemptCount: 0),
            ChunkQueueEntry(index: 1, audioStartMs: 18_000, audioEndMs: 38_000,
                            wallStartMs: 18_000, wallEndMs: 38_000,
                            fileName: "chunk_0001.wav", status: .failed, attemptCount: 2)
        ]
        try store.save(entries)
        let restored = try store.load()
        #expect(restored == entries)
        #expect(restored[1].needsProcessing)
        #expect(!restored[0].needsProcessing)
    }

    @Test("队列文件不存在时返回空")
    func queueStoreEmpty() throws {
        let store = ChunkQueueStore(fileURL: tempDirectory.appending(path: "not-exists.json"))
        #expect(try store.load().isEmpty)
    }

    // MARK: - 分片提取

    @Test("按窗口提取：帧数精确（含 2 秒重叠语义）")
    func extractWindow() throws {
        let source = try makeSineFile(seconds: 45, named: "recording.caf")
        let chunkURL = tempDirectory.appending(path: "chunk.wav")

        // 窗口 1：[18000, 38000] —— 20 秒
        let frames = try AudioChunkExtractor.extract(
            from: source, startMs: 18_000, endMs: 38_000, to: chunkURL
        )
        #expect(frames == 20 * 44_100)

        let chunk = try AVAudioFile(forReading: chunkURL)
        #expect(chunk.length == 20 * 44_100)
        #expect(chunk.processingFormat.sampleRate == 44_100)
    }

    @Test("超出源时长的窗口自动截断")
    func extractClampedToSource() throws {
        let source = try makeSineFile(seconds: 25, named: "short.caf")
        let chunkURL = tempDirectory.appending(path: "chunk2.wav")
        // 窗口 [18000, 38000] 但源只有 25 秒 → 实际 7 秒
        let frames = try AudioChunkExtractor.extract(
            from: source, startMs: 18_000, endMs: 38_000, to: chunkURL
        )
        #expect(frames == 7 * 44_100)
    }

    @Test("空窗口与缺失源报错")
    func extractErrors() throws {
        let source = try makeSineFile(seconds: 5, named: "tiny.caf")
        let dest = tempDirectory.appending(path: "x.wav")
        #expect(throws: AudioChunkExtractor.ExtractError.self) {
            try AudioChunkExtractor.extract(from: source, startMs: 1000, endMs: 1000, to: dest)
        }
        #expect(throws: AudioChunkExtractor.ExtractError.self) {
            try AudioChunkExtractor.extract(
                from: tempDirectory.appending(path: "missing.caf"),
                startMs: 0, endMs: 1000, to: dest
            )
        }
    }

    @Test("音频文件时长换算")
    func durationMs() throws {
        let source = try makeSineFile(seconds: 3.5, named: "dur.caf")
        let ms = try AudioChunkExtractor.durationMs(of: source)
        #expect(abs(ms - 3_500) <= 10)
    }
}
