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

    @Test("续录准备保留旧音频并从文件末尾追加")
    func prepareAppendingFilePreservesExistingAudio() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let fileURL = tempDirectory.appending(path: "append.caf")
        do {
            let original = try AVAudioFile(
                forWriting: fileURL,
                settings: AudioRecordingSettings.fileSettings(for: format)
            )
            try original.write(from: #require(makeSineBuffer(format: format, seconds: 2)))
        }

        do {
            let candidate = try AVAudioCaptureService.preparePacketAppendWriter(
                fileURL: fileURL,
                format: format
            )
            let prepared = try #require(candidate)
            #expect(abs(prepared.existingDurationMs - 2_000) <= 1)
            try prepared.writer.write(#require(makeSineBuffer(format: format, seconds: 1)))
        }

        let reread = try AVAudioFile(forReading: fileURL)
        #expect(reread.length == Int64(format.sampleRate * 3))
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

    @Test("回放目标跳过暂停，暂停中位置落在恢复边界")
    func playbackTargetConvertsPauseTimeline() throws {
        let project = Project(title: "现场录音", sourceType: .liveRecording, status: .ready)
        project.runtimeAssetRelativePath = "Meetings/source/recording.caf"
        project.pauseIntervals = [
            PauseInterval(startMs: 10_000, endMs: 30_000),
            PauseInterval(startMs: 40_000, endMs: 45_000)
        ]
        for (wall, expected) in [(5_000, 5.0), (10_000, 10.0), (20_000, 10.0),
                                 (30_000, 10.0), (35_000, 15.0), (50_000, 25.0)] {
            let segment = TranscriptSegment(startMs: Int64(wall), endMs: Int64(wall + 500),
                                            text: "原话", source: .local, state: .final)
            let target = try #require(ProjectAudioPlaybackTarget.resolve(project: project, segment: segment))
            #expect(target.projectID == project.id)
            #expect(target.relativePath == project.runtimeAssetRelativePath)
            #expect(target.seconds == expected)
        }
    }

    @Test("汇总回放先还原来源偏移，再扣除原录音暂停")
    func combinedPlaybackUsesSourceOffsetAndPauses() throws {
        let first = Project(title: "第一场", sourceType: .importedAudio, status: .ready)
        first.runtimeAssetRelativePath = "Meetings/first/recording.caf"
        let source = Project(title: "第二场", sourceType: .liveRecording, status: .ready)
        source.runtimeAssetRelativePath = "Meetings/second/recording.caf"
        source.pauseIntervals = [PauseInterval(startMs: 10_000, endMs: 30_000)]
        let combined = Project(title: "汇总", sourceType: .combinedRecordings, status: .ready)
        combined.sourceRecordings = [
            .init(projectID: first.id, title: first.title, recordedAt: Date(),
                  timelineOffsetMs: 0, durationMs: 100_000),
            .init(projectID: source.id, title: source.title, recordedAt: Date(),
                  timelineOffsetMs: 100_000, durationMs: 60_000)
        ]
        let segment = TranscriptSegment(startMs: 135_000, endMs: 138_000, text: "第二场原话",
                                        source: .local, state: .final, sourceAssetId: source.id)
        let target = try #require(ProjectAudioPlaybackTarget.resolve(
            project: combined, segment: segment, sourceProjects: [first, source]
        ))
        #expect(target.projectID == source.id)
        #expect(target.title == source.title)
        #expect(target.relativePath == source.runtimeAssetRelativePath)
        #expect(target.seconds == 15)
        let defaultTarget = try #require(ProjectAudioPlaybackTarget.resolve(
            project: combined, sourceProjects: [first, source]
        ))
        #expect(defaultTarget.projectID == first.id)
        #expect(defaultTarget.seconds == 0)
    }

    @Test("汇总片段来源缺失时不退回播放第一份录音")
    func missingSourceDoesNotPlayAnotherRecording() {
        let source = Project(title: "原录音", sourceType: .liveRecording, status: .ready)
        source.runtimeAssetRelativePath = "Meetings/source/recording.caf"
        let combined = Project(title: "汇总", sourceType: .combinedRecordings, status: .ready)
        combined.sourceRecordings = [
            .init(projectID: source.id, title: source.title, recordedAt: Date(),
                  timelineOffsetMs: 0, durationMs: 60_000)
        ]
        let segment = TranscriptSegment(startMs: 2_000, endMs: 3_000, text: "来源不明",
                                        source: .local, state: .final)
        #expect(ProjectAudioPlaybackTarget.resolve(
            project: combined, segment: segment, sourceProjects: [source]
        ) == nil)
        segment.sourceAssetId = UUID()
        #expect(ProjectAudioPlaybackTarget.resolve(
            project: combined, segment: segment, sourceProjects: [source]
        ) == nil)
        segment.sourceAssetId = source.id
        #expect(ProjectAudioPlaybackTarget.resolve(project: combined, segment: segment) == nil)
        source.runtimeAssetRelativePath = nil
        #expect(ProjectAudioPlaybackTarget.resolve(
            project: combined, segment: segment, sourceProjects: [source]
        ) == nil)
        #expect(ProjectAudioPlaybackTarget.resolve(project: source) == nil)
    }

    @MainActor
    @Test("新文件加载失败后旧文件不能继续播放且状态清零")
    func controllerFailedLoadCannotPlayOldFile() throws {
        let mock = PlaybackBoundaryMock()
        let controller = AudioPlaybackController(player: mock)
        try controller.load(url: tempDirectory.appending(path: "first.caf"))
        controller.seek(to: 12)
        controller.play()
        #expect(controller.isPlaying)
        let previousCalls = mock.playCalls
        mock.loadError = .fileMissing
        #expect(throws: AudioPlaybackError.fileMissing) {
            try controller.load(url: tempDirectory.appending(path: "missing.caf"))
        }
        #expect(!controller.isLoaded)
        #expect(!controller.isPlaying)
        #expect(controller.currentTime == 0)
        #expect(controller.duration == 0)
        #expect(controller.errorMessage != nil)
        controller.play()
        controller.togglePlay()
        #expect(mock.playCalls == previousCalls)
        #expect(!mock.isPlaying)
    }

    @MainActor
    @Test("播放器抛错或实际没有开始播放时不能显示播放中")
    func controllerPlayFailureIsVisible() throws {
        let mock = PlaybackBoundaryMock()
        let controller = AudioPlaybackController(player: mock)
        try controller.load(url: tempDirectory.appending(path: "audio.caf"))
        mock.playError = .playbackFailed
        controller.play()
        #expect(!controller.isPlaying)
        #expect(controller.errorMessage != nil)
        mock.playError = nil
        mock.startsPlaying = false
        controller.togglePlay()
        #expect(!controller.isPlaying)
        #expect(controller.errorMessage != nil)
        mock.startsPlaying = true
        controller.togglePlay()
        #expect(controller.isPlaying)
        #expect(controller.errorMessage == nil)
        controller.stop()
    }

    @Test("底层播放器加载缺失或损坏文件后释放上一份音频")
    func failedReplacementLoadClearsPlayer() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let valid = tempDirectory.appending(path: "valid.caf")
        do {
            let file = try AVAudioFile(forWriting: valid,
                                      settings: AudioRecordingSettings.fileSettings(for: format))
            try file.write(from: #require(makeSineBuffer(format: format, seconds: 0.2)))
        }
        let corrupt = tempDirectory.appending(path: "corrupt.caf")
        try Data("invalid audio".utf8).write(to: corrupt)
        let playback = AVAudioPlaybackService()
        for invalid in [tempDirectory.appending(path: "missing.caf"), corrupt] {
            try playback.load(url: valid)
            #expect(playback.duration > 0)
            #expect(throws: (any Error).self) { try playback.load(url: invalid) }
            #expect(playback.duration == 0)
            #expect(playback.currentTime == 0)
            #expect(!playback.isPlaying)
            #expect(throws: AudioPlaybackError.notLoaded) { try playback.play() }
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

private final class PlaybackBoundaryMock: AudioPlaybackServicing, @unchecked Sendable {
    var loadError: AudioPlaybackError?
    var playError: AudioPlaybackError?
    var startsPlaying = true
    private(set) var playCalls = 0
    private(set) var duration: TimeInterval = 60
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false

    func load(url: URL) throws {
        if let loadError { throw loadError }
        currentTime = 0
        isPlaying = false
    }

    func play() throws {
        playCalls += 1
        if let playError { throw playError }
        isPlaying = startsPlaying
    }

    func pause() { isPlaying = false }
    func stop() { isPlaying = false; currentTime = 0 }
    func seek(to seconds: TimeInterval) { currentTime = min(max(0, seconds), duration) }
}
