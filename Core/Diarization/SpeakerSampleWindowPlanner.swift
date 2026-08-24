import Foundation

/// 声纹样本窗口规划（纯逻辑，09 号计划需求 2）：
/// 用户在对话中把「待识别」指认为某说话人后，从这个人已有的发言里
/// 自动挑一段作为声纹样本，免去对麦克风单独录样本（录音中麦克风被占用时也可用）。
///
/// 时间口径（与 DiarizationController.enqueue 相反方向）：
/// 片段的 startMs/endMs 是会议墙钟时间轴（含暂停），录音文件里没有暂停区间，
/// 因此裁剪前必须经 RecordingTimeline 换算回音频流时间。
enum SpeakerSampleWindowPlanner {
    /// 规划出的裁剪窗口（音频流时间，毫秒）
    struct Window: Equatable, Sendable {
        var audioStartMs: Int64
        var audioEndMs: Int64
    }

    /// 从候选片段中挑声纹样本窗口。
    /// - 只允许 cloud/final、已有云端说话人标签且已确认归属的单人片段；
    /// - 换算到真实音频时间后必须整段落在 2–10 秒内，不从超长片段猜测子区间；
    /// - 合格候选按真实音频时长降序。
    /// - Parameters:
    ///   - segments: 该说话人（或该云端标签）名下的片段
    ///   - wallToAudioMs: 会议时间轴毫秒 → 音频流毫秒（无暂停时可传恒等映射）
    /// - Returns: 音频流时间窗口；无合格候选返回 nil
    static func plan(
        segments: [TranscriptSegment],
        wallToAudioMs: (Int64) -> Int64
    ) -> Window? {
        let candidates = segments.compactMap { segment -> Window? in
            guard segment.source == .cloud,
                  segment.state == .final,
                  segment.participantId != nil,
                  let remoteLabel = segment.remoteSpeakerLabel,
                  !remoteLabel.isEmpty,
                  segment.endMs > segment.startMs else {
                return nil
            }
            let audioStart = wallToAudioMs(segment.startMs)
            let audioEnd = wallToAudioMs(segment.endMs)
            let durationMs = audioEnd - audioStart
            guard durationMs >= VoiceSampleValidator.minDurationMs,
                  durationMs <= VoiceSampleValidator.maxDurationMs else {
                return nil
            }
            return Window(audioStartMs: audioStart, audioEndMs: audioEnd)
        }
        return candidates.max {
            ($0.audioEndMs - $0.audioStartMs) < ($1.audioEndMs - $1.audioStartMs)
        }
    }

    /// 会议墙钟毫秒 → 音频流毫秒（按已闭合暂停区间扣减；
    /// RecordingTimeline 的逆映射的反方向，供录音结束后无运行时时间线时使用）。
    /// 落在暂停区间内的时刻映射到该暂停开始处的音频位置。
    static func audioMs(forWallMs wallMs: Int64, pauseIntervals: [PauseInterval]) -> Int64 {
        var paused: Int64 = 0
        for interval in pauseIntervals.sorted(by: { $0.startMs < $1.startMs }) {
            if wallMs >= interval.endMs {
                paused += interval.durationMs
            } else if wallMs > interval.startMs {
                paused += wallMs - interval.startMs
            } else {
                break
            }
        }
        return wallMs - paused
    }
}
