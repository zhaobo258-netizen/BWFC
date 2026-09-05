import Foundation
import AVFoundation

/// 本地回放服务协议（阶段 1：AVAudioPlayer 即可；时间跳转基础能力）。
/// 协议隔离便于测试替换。
protocol AudioPlaybackServicing: AnyObject, Sendable {
    /// 加载音频文件
    func load(url: URL) throws
    /// 播放
    func play() throws
    /// 暂停（保留播放位置）
    func pause()
    /// 停止并回到开头
    func stop()
    /// 跳转到指定秒
    func seek(to seconds: TimeInterval)
    /// 总时长（秒）
    var duration: TimeInterval { get }
    /// 当前播放位置（秒）
    var currentTime: TimeInterval { get }
    /// 是否正在播放
    var isPlaying: Bool { get }
}

/// 回放错误
enum AudioPlaybackError: Error, Equatable {
    case notLoaded
    case fileMissing
    case playbackFailed
}

/// 基于 AVAudioPlayer 的回放实现
final class AVAudioPlaybackService: AudioPlaybackServicing, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private let lock = NSLock()

    func load(url: URL) throws {
        lock.withLock {
            player?.stop()
            player = nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioPlaybackError.fileMissing
        }
        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.prepareToPlay()
        lock.withLock { player = newPlayer }
    }

    func play() throws {
        let current = lock.withLock { player }
        guard let current else { throw AudioPlaybackError.notLoaded }
        guard current.play() else { throw AudioPlaybackError.playbackFailed }
    }

    func pause() {
        lock.withLock { player?.pause() }
    }

    func stop() {
        lock.withLock {
            player?.stop()
            player?.currentTime = 0
        }
    }

    func seek(to seconds: TimeInterval) {
        lock.withLock {
            guard let player else { return }
            player.currentTime = min(max(0, seconds), player.duration)
        }
    }

    var duration: TimeInterval {
        lock.withLock { player?.duration ?? 0 }
    }

    var currentTime: TimeInterval {
        lock.withLock { player?.currentTime ?? 0 }
    }

    var isPlaying: Bool {
        lock.withLock { player?.isPlaying ?? false }
    }
}

/// 回放控制器（界面层）：周期性刷新播放位置，驱动进度条与时间显示。
@MainActor
@Observable
final class AudioPlaybackController {
    private let player: any AudioPlaybackServicing
    private var ticker: Timer?

    private(set) var isLoaded = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    init(player: any AudioPlaybackServicing = AVAudioPlaybackService()) {
        self.player = player
    }

    /// 加载音频文件
    func load(url: URL) throws {
        stop()
        isLoaded = false
        duration = 0
        do {
            try player.load(url: url)
        } catch {
            errorMessage = "原音频无法读取，请检查文件是否存在。"
            throw error
        }
        duration = player.duration
        currentTime = 0
        isLoaded = true
        isPlaying = false
        errorMessage = nil
    }

    /// 播放 / 暂停切换
    func togglePlay() {
        guard isLoaded else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            play()
        }
    }

    func play() {
        guard isLoaded else { return }
        do {
            try player.play()
            isPlaying = player.isPlaying
            errorMessage = isPlaying ? nil : "音频未能播放，请检查输出设备后重试。"
        } catch {
            isPlaying = false
            errorMessage = "音频未能播放，请检查输出设备后重试。"
        }
    }

    func stop() {
        player.stop()
        isPlaying = false
        currentTime = 0
    }

    /// 跳转到指定秒
    func seek(to seconds: TimeInterval) {
        player.seek(to: seconds)
        currentTime = player.currentTime
    }

    /// 开始周期刷新（视图 onAppear 调用）
    func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.player.currentTime
                self.isPlaying = self.player.isPlaying
            }
        }
    }

    /// 停止周期刷新（视图 onDisappear 调用）
    func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

struct ProjectAudioPlaybackTarget: Equatable {
    var projectID: UUID
    var title: String
    var relativePath: String
    var seconds: TimeInterval

    static func resolve(
        project: Project,
        segment: TranscriptSegment? = nil,
        sourceProjects: [Project] = []
    ) -> Self? {
        let source: Project
        let wallMs: Int64
        if project.sourceType.isCombinedAnalysis {
            let reference: SourceRecordingReference?
            if let segment {
                reference = ProjectHomeSupport.sourceRecording(for: segment, in: project)
            } else {
                reference = project.sourceRecordings.first
            }
            guard let reference,
                  let original = sourceProjects.first(where: { $0.id == reference.projectID }) else { return nil }
            source = original
            wallMs = max(0, (segment?.startMs ?? reference.timelineOffsetMs) - reference.timelineOffsetMs)
        } else {
            source = project
            wallMs = max(0, segment?.startMs ?? 0)
        }
        guard let path = source.runtimeAssetRelativePath, !path.isEmpty else { return nil }
        var coveredUntil: Int64 = 0
        var pausedMs: Int64 = 0
        for pause in source.pauseIntervals.sorted(by: { $0.startMs < $1.startMs }) {
            let start = max(coveredUntil, max(0, pause.startMs))
            let end = min(wallMs, pause.endMs)
            if end > start { pausedMs += end - start }
            coveredUntil = max(coveredUntil, end)
        }
        return Self(projectID: source.id, title: source.title, relativePath: path,
                    seconds: TimeInterval(max(0, wallMs - pausedMs)) / 1_000)
    }
}
