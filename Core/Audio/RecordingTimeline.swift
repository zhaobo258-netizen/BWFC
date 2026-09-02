import Foundation

/// 录音时间线（纯逻辑，不含任何音频框架依赖）：
/// 跟踪会话开始时间、暂停区间，负责「会议时间轴」与「录音文件时长」之间的换算。
///
/// - 会议时间轴：从点击「开始录音」起的墙钟时间（含暂停）。
/// - 文件时长：实际写入音频的累计时长（= 会议时间轴 - 累计暂停时长）。
///   暂停期间不写文件，因此暂停区间在文件中不存在（实施计划阶段 1 验收：
///   「暂停区间无异常音频」）。
struct RecordingTimeline: Sendable {
    /// 会话开始时间（进入 recording 的时刻）
    let startedAt: Date
    /// 本次续录开始前，原项目已有的会议时间轴位置
    let initialWallOffsetMs: Int64
    /// 本次续录开始前，原录音文件已有的媒体时长
    let initialEffectiveAudioOffsetMs: Int64
    /// 当前暂停的开始时间；nil 表示不在暂停中
    private(set) var pauseBeganAt: Date?
    /// 续录前已存在的暂停区间，仅用于映射旧录音时间
    private let priorIntervals: [PauseInterval]
    /// 已闭合的暂停区间（会议时间轴毫秒）
    private(set) var intervals: [PauseInterval] = []

    init(
        startedAt: Date,
        initialWallOffsetMs: Int64 = 0,
        initialEffectiveAudioOffsetMs: Int64 = 0,
        priorIntervals: [PauseInterval] = []
    ) {
        self.startedAt = startedAt
        self.initialWallOffsetMs = max(0, initialWallOffsetMs)
        self.initialEffectiveAudioOffsetMs = max(0, initialEffectiveAudioOffsetMs)
        self.priorIntervals = priorIntervals
    }

    /// 是否处于暂停中
    var isPaused: Bool { pauseBeganAt != nil }

    /// 会议时间轴毫秒（墙钟，含暂停）
    func wallMs(at date: Date) -> Int64 {
        initialWallOffsetMs + Int64((date.timeIntervalSince(startedAt)) * 1000)
    }

    /// 开始暂停；重复暂停抛错
    mutating func beginPause(at date: Date) throws {
        guard pauseBeganAt == nil else {
            throw RecordingTimelineError.alreadyPaused
        }
        pauseBeganAt = date
    }

    /// 结束暂停并闭合一个暂停区间；未在暂停中抛错
    @discardableResult
    mutating func endPause(at date: Date) throws -> PauseInterval {
        guard let began = pauseBeganAt else {
            throw RecordingTimelineError.notPaused
        }
        let interval = PauseInterval(startMs: wallMs(at: began), endMs: wallMs(at: date))
        intervals.append(interval)
        pauseBeganAt = nil
        return interval
    }

    /// 截至 date 的累计暂停毫秒（含进行中的暂停）
    func totalPausedMs(at date: Date) -> Int64 {
        let closed = intervals.reduce(Int64(0)) { $0 + $1.durationMs }
        guard let began = pauseBeganAt else { return closed }
        return closed + (wallMs(at: date) - wallMs(at: began))
    }

    /// 截至 date 应写入文件的音频毫秒（会议时间轴 - 累计暂停）
    func effectiveAudioMs(at date: Date) -> Int64 {
        let sessionWallMs = wallMs(at: date) - initialWallOffsetMs
        return initialEffectiveAudioOffsetMs + sessionWallMs - totalPausedMs(at: date)
    }

    /// 逆映射：音频流时间（不含暂停）→ 会议时间轴毫秒。
    /// 阶段 2：SpeechAnalyzer 结果时间基于「送入的音频流」，需经此映射回到会议时间轴。
    /// 边界说明：音频时间恰好等于某暂停起点锚点时，对应的是恢复后的第一帧，
    /// 因此使用严格小于比较（该帧应映射到暂停结束之后）。
    func wallMs(forEffectiveAudioMs audioMs: Int64) -> Int64 {
        if audioMs < initialEffectiveAudioOffsetMs {
            return Self.wallMs(forEffectiveAudioMs: audioMs, intervals: priorIntervals)
        }
        let sessionAudioMs = audioMs - initialEffectiveAudioOffsetMs
        var pausedBefore: Int64 = 0
        for interval in intervals.sorted(by: { $0.startMs < $1.startMs }) {
            // 该暂停起点在音频流时间中的位置 = 墙钟起点 - 此前的累计暂停
            let audioAnchor = interval.startMs - initialWallOffsetMs - pausedBefore
            if sessionAudioMs < audioAnchor {
                return initialWallOffsetMs + sessionAudioMs + pausedBefore
            }
            pausedBefore += interval.durationMs
        }
        return initialWallOffsetMs + sessionAudioMs + pausedBefore
    }

    /// 本地转写每次重启会从 0 计时，需先补上旧录音的媒体偏移。
    func wallMs(forSessionAudioMs audioMs: Int64) -> Int64 {
        wallMs(forEffectiveAudioMs: initialEffectiveAudioOffsetMs + audioMs)
    }

    private static func wallMs(
        forEffectiveAudioMs audioMs: Int64,
        intervals: [PauseInterval]
    ) -> Int64 {
        var pausedBefore: Int64 = 0
        for interval in intervals.sorted(by: { $0.startMs < $1.startMs }) {
            let audioAnchor = interval.startMs - pausedBefore
            if audioMs < audioAnchor {
                return audioMs + pausedBefore
            }
            pausedBefore += interval.durationMs
        }
        return audioMs + pausedBefore
    }
}

/// 时间线错误
enum RecordingTimelineError: Error, Equatable {
    case alreadyPaused
    case notPaused
}
