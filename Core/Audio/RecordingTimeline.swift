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
    /// 当前暂停的开始时间；nil 表示不在暂停中
    private(set) var pauseBeganAt: Date?
    /// 已闭合的暂停区间（会议时间轴毫秒）
    private(set) var intervals: [PauseInterval] = []

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// 是否处于暂停中
    var isPaused: Bool { pauseBeganAt != nil }

    /// 会议时间轴毫秒（墙钟，含暂停）
    func wallMs(at date: Date) -> Int64 {
        Int64((date.timeIntervalSince(startedAt)) * 1000)
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
        wallMs(at: date) - totalPausedMs(at: date)
    }
}

/// 时间线错误
enum RecordingTimelineError: Error, Equatable {
    case alreadyPaused
    case notPaused
}
