import Foundation
import AVFoundation
import CryptoKit
import Testing
@testable import BangWoFenXi

/// 音视频导入服务（阶段 C）：检查、复制、提取；来源文件绝不被修改。
/// 夹具全部为合成音频（正弦波），不使用真实录音。
@Suite("音视频导入服务", .serialized)
final class AudioImportServiceTests {
    private let tempDirectory: URL
    private let fileStore: MeetingFileStore
    private let service: AVFoundationAudioImportService

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-import-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileStore = MeetingFileStore(baseDirectory: tempDirectory)
        service = AVFoundationAudioImportService(fileStore: fileStore)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// 合成一段正弦波音频文件（默认 caf；wav 用 Int16 设置）
    private func makeSyntheticAudio(name: String, seconds: Double = 0.3,
                                    sampleRate: Double = 44_100) throws -> URL {
        let url = tempDirectory.appending(path: name)
        let isWav = name.hasSuffix(".wav")
        let settings: [String: Any] = isWav
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
               AVLinearPCMIsNonInterleaved: false]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
               AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
               AVLinearPCMIsNonInterleaved: true]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        // 写入必须用 processingFormat（Float32 非交错）缓冲；磁盘格式由 settings 决定
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let floatData = buffer.floatChannelData {
            for i in 0..<Int(frameCount) {
                floatData[0][i] = sinf(Float(i) * 2 * .pi * 440 / Float(sampleRate)) * 0.4
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 检查

    @Test("合法 caf：时长正确、无视频轨、文件名保留")
    func inspectValidCaf() async throws {
        let url = try makeSyntheticAudio(name: "sample.caf", seconds: 0.3)
        let info = try await service.inspect(url: url)
        #expect(info.hasVideoTrack == false)
        #expect(info.fileName == "sample.caf")
        #expect(info.durationMs > 200 && info.durationMs < 400)
        #expect(info.fileSizeBytes > 0)
    }

    @Test("合法 wav：可检查")
    func inspectValidWav() async throws {
        let url = try makeSyntheticAudio(name: "sample.wav", seconds: 0.3)
        let info = try await service.inspect(url: url)
        #expect(info.durationMs > 200 && info.durationMs < 400)
    }

    @Test("不存在的文件：明确 fileNotReadable")
    func inspectMissingFile() async {
        let url = tempDirectory.appending(path: "missing.m4a")
        await #expect(throws: AudioImportError.fileNotReadable) {
            _ = try await self.service.inspect(url: url)
        }
    }

    @Test("垃圾字节冒充 m4a：明确导入错误（损坏或无音轨），不静默通过")
    func inspectCorruptFile() async throws {
        let url = tempDirectory.appending(path: "corrupt.m4a")
        try Data(repeating: 0xAB, count: 4096).write(to: url)
        do {
            _ = try await service.inspect(url: url)
            Issue.record("损坏文件不应通过检查")
        } catch let error as AudioImportError {
            #expect(error == .undecodable || error == .noAudioTrack || error == .zeroDuration)
        } catch {
            Issue.record("应抛出 AudioImportError，实际 \(type(of: error))")
        }
    }

    // MARK: - 复制与提取

    @Test("提取：原件副本落项目目录，recording.caf 可读且时长一致，来源文件字节不变")
    func prepareAudioExtractsAndPreservesSource() async throws {
        let source = try makeSyntheticAudio(name: "客户拜访.caf", seconds: 0.5)
        let sourceHashBefore = try sha256(of: source)
        let projectID = UUID()

        let output = try await service.prepareAudio(from: source, for: projectID)

        // 来源文件未被修改
        #expect(try sha256(of: source) == sourceHashBefore)
        // 原件副本存在
        let copy = fileStore.meetingDirectory(for: projectID)
            .appending(path: "source-original.caf")
        #expect(FileManager.default.fileExists(atPath: copy.path))
        // 提取产物在标准路径且可读
        let expected = try fileStore.absoluteURL(forRelativePath: fileStore.relativeAudioPath(for: projectID))
        #expect(output == expected)
        let extracted = try AVAudioFile(forReading: output)
        let extractedSeconds = Double(extracted.length) / extracted.processingFormat.sampleRate
        #expect(abs(extractedSeconds - 0.5) < 0.05)
        // 输出为 48kHz 单声道（标准化）
        #expect(extracted.processingFormat.sampleRate == 48_000)
        #expect(extracted.processingFormat.channelCount == 1)
    }

    @Test("重试：已存在的原件副本不重新复制（03 §6.2：失败重试不重新复制原文件）")
    func retryDoesNotRecopySource() async throws {
        let source = try makeSyntheticAudio(name: "retry.caf", seconds: 0.3)
        let projectID = UUID()
        _ = try await service.prepareAudio(from: source, for: projectID)

        // 给副本打标（替换为不同内容），再次 prepare 不得覆盖
        let copy = fileStore.meetingDirectory(for: projectID)
            .appending(path: "source-original.caf")
        let marker = try makeSyntheticAudio(name: "marker.caf", seconds: 0.1)
        _ = try FileManager.default.replaceItemAt(copy, withItemAt: marker)
        let markerHash = try sha256(of: copy)

        _ = try await service.prepareAudio(from: source, for: projectID)
        #expect(try sha256(of: copy) == markerHash, "重试不得重新复制原件")
    }

    @Test("提取进度：单调递增且收敛到 1")
    func extractionProgressReachesOne() async throws {
        let source = try makeSyntheticAudio(name: "progress.caf", seconds: 0.5)
        let recorder = ProgressRecorder()
        _ = try await service.prepareAudio(from: source, for: UUID()) { value in
            recorder.append(value)
        }
        let values = recorder.values
        #expect(values.last == 1.0)
        #expect(values == values.sorted(), "进度必须单调递增")
    }

    /// 线程安全的进度收集（提取回调可能来自后台线程）
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        var values: [Double] { lock.withLock { storage } }
        func append(_ value: Double) { lock.withLock { storage.append(value) } }
    }

    // MARK: - 真实媒体集成探针（默认跳过；BWFX_IT_MEDIA=1 时执行）

    /// 用系统 afconvert 把合成 caf 转成真实 AAC m4a，走真实 AVFoundation 检查 + 提取。
    /// 常规测试保持快速稳定；阶段验收时用环境变量开启。
    @Test("真实 m4a（afconvert 合成 AAC）：检查与提取全链路",
          .enabled(if: ProcessInfo.processInfo.environment["BWFX_IT_MEDIA"] == "1"))
    func realM4AInspectAndExtract() async throws {
        let caf = try makeSyntheticAudio(name: "it-source.caf", seconds: 1.0)
        let m4a = tempDirectory.appending(path: "it-source.m4a")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", caf.path, m4a.path]
        try convert.run()
        convert.waitUntilExit()
        try #require(convert.terminationStatus == 0, "afconvert 转码失败")

        let info = try await service.inspect(url: m4a)
        #expect(info.hasVideoTrack == false)
        #expect(info.durationMs > 900 && info.durationMs < 1200)

        let projectID = UUID()
        let output = try await service.prepareAudio(from: m4a, for: projectID)
        let extracted = try AVAudioFile(forReading: output)
        #expect(extracted.processingFormat.sampleRate == 48_000)
        let seconds = Double(extracted.length) / 48_000
        #expect(abs(seconds - 1.0) < 0.1, "AAC 解码时长应接近 1 秒，实际 \(seconds)")
    }
}
