import Foundation
import CoreMedia
import Speech

/// SpeechTranscriber attributed run 中携带的真实音频时间。
struct TimedTranscriptRun: Equatable, Sendable {
    var startAudioMs: Int64
    var endAudioMs: Int64
    var text: String
}

/// 使用 attributed run 的 audioTimeRange 做断句，不按字符数推算时间。
enum TimedTranscriptSegmenter {
    struct Configuration: Equatable, Sendable {
        var silenceGapMs: Int64 = 700
        var hardMaximumDurationMs: Int64 = 10_000
    }

    /// 从 SpeechTranscriber 返回文本中提取真实 audioTimeRange。
    /// 没有独立时间的标点/空白并入相邻的已定时 run，不创造子字符时间。
    static func audioTimedRuns(from text: AttributedString) -> [TimedTranscriptRun] {
        var result: [TimedTranscriptRun] = []
        var leadingUntimedText = ""

        for run in text.runs {
            let runText = String(text[run.range].characters)
            guard !runText.isEmpty else { continue }

            if let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
               let bounds = millisecondBounds(for: timeRange) {
                result.append(
                    TimedTranscriptRun(
                        startAudioMs: bounds.start,
                        endAudioMs: bounds.end,
                        text: leadingUntimedText + runText
                    )
                )
                leadingUntimedText = ""
            } else if result.isEmpty {
                leadingUntimedText += runText
            } else {
                result[result.count - 1].text += runText
            }
        }

        return result
    }

    /// 在 run 边界按句末标点、静音间隔或硬时长上限切分。
    /// 若单个 run 本身已超过硬上限，保留其真实整段时间，不伪造内部边界。
    static func segment(
        runs: [TimedTranscriptRun],
        configuration: Configuration = Configuration()
    ) -> [LocalTranscriptResult] {
        var output: [LocalTranscriptResult] = []
        var currentStart: Int64?
        var currentEnd: Int64 = 0
        var currentText = ""

        func flush() {
            guard let start = currentStart else { return }
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, currentEnd > start {
                output.append(
                    LocalTranscriptResult(
                        startAudioMs: start,
                        endAudioMs: currentEnd,
                        text: trimmed,
                        isFinal: true
                    )
                )
            }
            currentStart = nil
            currentEnd = 0
            currentText = ""
        }

        for run in runs where run.endAudioMs > run.startAudioMs && !run.text.isEmpty {
            if let start = currentStart {
                let silenceGap = run.startAudioMs - currentEnd
                let candidateEnd = max(currentEnd, run.endAudioMs)
                let exceedsHardMaximum = candidateEnd - start > configuration.hardMaximumDurationMs
                if silenceGap >= configuration.silenceGapMs || exceedsHardMaximum {
                    flush()
                }
            }

            if currentStart == nil {
                currentStart = run.startAudioMs
                currentEnd = run.endAudioMs
            } else {
                currentEnd = max(currentEnd, run.endAudioMs)
            }
            currentText += run.text

            if endsSentence(run.text) {
                flush()
            }
        }
        flush()
        return output
    }

    private static func millisecondBounds(for range: CMTimeRange) -> (start: Int64, end: Int64)? {
        guard range.isValid,
              range.start.isNumeric,
              range.duration.isNumeric,
              range.duration > .zero else {
            return nil
        }
        let startSeconds = range.start.seconds
        let endSeconds = CMTimeRangeGetEnd(range).seconds
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              startSeconds >= 0,
              endSeconds > startSeconds else {
            return nil
        }
        return (
            Int64((startSeconds * 1_000).rounded()),
            Int64((endSeconds * 1_000).rounded())
        )
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return false }
        return "。！？；!?;…".contains(last)
    }
}
