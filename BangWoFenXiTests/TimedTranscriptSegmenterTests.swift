import Foundation
import CoreMedia
import Speech
import Testing
@testable import BangWoFenXi

@Suite("真实音频时间断句")
struct TimedTranscriptSegmenterTests {
    @Test("句末标点在 attributed run 边界切分，保留真实时间")
    func punctuationBoundary() {
        let segments = TimedTranscriptSegmenter.segment(runs: [
            .init(startAudioMs: 0, endAudioMs: 1_000, text: "第一句。"),
            .init(startAudioMs: 1_050, endAudioMs: 2_000, text: "第二句"),
        ])

        #expect(segments == [
            .init(startAudioMs: 0, endAudioMs: 1_000, text: "第一句。", isFinal: true),
            .init(startAudioMs: 1_050, endAudioMs: 2_000, text: "第二句", isFinal: true),
        ])
    }

    @Test("静音间隔切分为两个真实时间片段")
    func silenceBoundary() {
        let segments = TimedTranscriptSegmenter.segment(runs: [
            .init(startAudioMs: 0, endAudioMs: 500, text: "前半"),
            .init(startAudioMs: 1_300, endAudioMs: 1_800, text: "后半"),
        ])

        #expect(segments.map(\.startAudioMs) == [0, 1_300])
        #expect(segments.map(\.endAudioMs) == [500, 1_800])
        #expect(segments.map(\.text) == ["前半", "后半"])
    }

    @Test("硬上限只在 run 边界切分，不按字符均分时间")
    func hardMaximumAtRunBoundary() {
        let segments = TimedTranscriptSegmenter.segment(
            runs: [
                .init(startAudioMs: 0, endAudioMs: 4_000, text: "A"),
                .init(startAudioMs: 4_000, endAudioMs: 8_000, text: "B"),
                .init(startAudioMs: 8_000, endAudioMs: 12_000, text: "C"),
            ],
            configuration: .init(silenceGapMs: 700, hardMaximumDurationMs: 10_000)
        )

        #expect(segments.map(\.text) == ["AB", "C"])
        #expect(segments.map(\.startAudioMs) == [0, 8_000])
        #expect(segments.map(\.endAudioMs) == [8_000, 12_000])
    }

    @Test("单个超长 run 保留整段真实时间，不伪造内部时间")
    func oversizedSingleRunIsNotFabricated() {
        let segments = TimedTranscriptSegmenter.segment(runs: [
            .init(startAudioMs: 2_000, endAudioMs: 17_000, text: "单个超长 run")
        ])

        #expect(segments == [
            .init(
                startAudioMs: 2_000,
                endAudioMs: 17_000,
                text: "单个超长 run",
                isFinal: true
            )
        ])
    }

    @Test("直接读取 Speech attributed runs 的 audioTimeRange，未定时标点并入相邻 run")
    func attributedAudioTimeRanges() {
        var transcript = timedText("第一句", startSeconds: 1, endSeconds: 2)
        transcript.append(AttributedString("。"))
        transcript.append(timedText("第二句", startSeconds: 2.2, endSeconds: 3))

        let runs = TimedTranscriptSegmenter.audioTimedRuns(from: transcript)
        #expect(runs == [
            .init(startAudioMs: 1_000, endAudioMs: 2_000, text: "第一句。"),
            .init(startAudioMs: 2_200, endAudioMs: 3_000, text: "第二句"),
        ])
        let segments = TimedTranscriptSegmenter.segment(runs: runs)
        #expect(segments.map(\.startAudioMs) == [1_000, 2_200])
        #expect(segments.map(\.endAudioMs) == [2_000, 3_000])
    }

    private func timedText(
        _ text: String,
        startSeconds: Double,
        endSeconds: Double
    ) -> AttributedString {
        var value = AttributedString(text)
        var attributes = AttributeContainer()
        let start = CMTime(seconds: startSeconds, preferredTimescale: 1_000)
        let end = CMTime(seconds: endSeconds, preferredTimescale: 1_000)
        attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = CMTimeRange(
            start: start,
            duration: CMTimeSubtract(end, start)
        )
        value[value.startIndex..<value.endIndex].mergeAttributes(attributes)
        return value
    }
}
