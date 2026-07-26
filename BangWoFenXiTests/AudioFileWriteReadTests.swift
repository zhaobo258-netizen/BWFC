import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

/// 音频文件写入与回放测试：
/// 用合成 PCM 缓冲验证「写文件 → 读回 → 回放可加载」链路（无需麦克风硬件）。
@Suite("音频文件写入与回放")
final class AudioFileWriteReadTests {
    let tempDirectory: URL

    init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// 生成指定时长的正弦波 PCM 缓冲（440Hz）
    private func makeSineBuffer(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData else { return nil }
        for frame in 0..<Int(frameCount) {
            let value = sin(2 * Float.pi * 440 * Float(frame) / Float(format.sampleRate)) * 0.5
            channelData[0][frame] = value
        }
        return buffer
    }

    @Test("合成缓冲写入 AVAudioFile，读回帧数一致")
    func writeAndReadBack() throws {
        // 与采集服务相同的格式约定：硬件格式（44.1kHz 单声道 float32）写 .caf
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let fileURL = tempDirectory.appending(path: "roundtrip.caf")

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: AudioRecordingSettings.fileSettings(for: format)
        )
        // 写入 3 段共 3 秒（模拟连续 tap 缓冲）
        for _ in 0..<3 {
            let buffer = try #require(makeSineBuffer(format: format, seconds: 1))
            try file.write(from: buffer)
        }

        let readFile = try AVAudioFile(forReading: fileURL)
        #expect(readFile.length == Int64(format.sampleRate * 3),
                "读回帧数必须等于写入帧数")
        #expect(readFile.processingFormat.sampleRate == format.sampleRate)
    }

    @Test("写入的文件可被 AVAudioPlayer 加载，时长正确")
    func playbackLoadsWrittenFile() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let fileURL = tempDirectory.appending(path: "playback.caf")
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: AudioRecordingSettings.fileSettings(for: format)
        )
        let buffer = try #require(makeSineBuffer(format: format, seconds: 2))
        try file.write(from: buffer)

        let playback = AVAudioPlaybackService()
        try playback.load(url: fileURL)
        #expect(abs(playback.duration - 2.0) < 0.01)
        #expect(!playback.isPlaying)

        // 时间跳转：钳位在有效范围内
        playback.seek(to: 1.5)
        #expect(abs(playback.currentTime - 1.5) < 0.01)
        playback.seek(to: 99)
        #expect(playback.currentTime <= playback.duration)
        playback.seek(to: -5)
        #expect(playback.currentTime == 0)
    }

    @Test("加载不存在的文件报 fileMissing")
    func loadMissingFileFails() {
        let playback = AVAudioPlaybackService()
        #expect(throws: AudioPlaybackError.self) {
            try playback.load(url: tempDirectory.appending(path: "not-exists.caf"))
        }
    }

    @Test("RMS 电平计算：静音为 0，正弦波大于 0")
    func rmsLevelComputation() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

        let loud = try #require(makeSineBuffer(format: format, seconds: 0.1))
        #expect(AVAudioCaptureService.rmsLevel(of: loud) > 0.1)

        guard let silent = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410) else {
            Issue.record("无法创建缓冲")
            return
        }
        silent.frameLength = 4410
        memset(silent.floatChannelData![0], 0, 4410 * MemoryLayout<Float>.stride)
        #expect(AVAudioCaptureService.rmsLevel(of: silent) == 0)
    }

    @Test("连续 5 次写失败只触发一次通知")
    func consecutiveWriteFailuresNotifyOnce() {
        var tracker = AudioWriteFailureTracker(threshold: 5)
        var notifications = 0

        for _ in 0..<8 {
            let event = tracker.attempt {
                throw SyntheticAudioWriteError.failed
            }
            if event?.shouldNotify == true {
                notifications += 1
            }
        }

        #expect(notifications == 1)
    }

    @Test("偶发写失败被成功写入打断，不触发自动暂停")
    func intermittentWriteFailureDoesNotNotify() {
        var tracker = AudioWriteFailureTracker(threshold: 5)

        for _ in 0..<3 {
            #expect(tracker.attempt { throw SyntheticAudioWriteError.failed }?.shouldNotify == false)
        }
        #expect(tracker.attempt {} == nil)
        for _ in 0..<4 {
            #expect(tracker.attempt { throw SyntheticAudioWriteError.failed }?.shouldNotify == false)
        }
    }
}

private enum SyntheticAudioWriteError: Error {
    case failed
}
