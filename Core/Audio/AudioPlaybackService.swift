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
}

/// 基于 AVAudioPlayer 的回放实现
final class AVAudioPlaybackService: AudioPlaybackServicing, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private let lock = NSLock()

    func load(url: URL) throws {
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
        current.play()
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

    init(player: any AudioPlaybackServicing = AVAudioPlaybackService()) {
        self.player = player
    }

    /// 加载音频文件
    func load(url: URL) throws {
        try player.load(url: url)
        duration = player.duration
        currentTime = 0
        isLoaded = true
        isPlaying = false
    }

    /// 播放 / 暂停切换
    func togglePlay() {
        guard isLoaded else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? player.play()
            isPlaying = true
        }
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
