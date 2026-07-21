import Foundation
import Testing
@testable import BangWoFenXi

/// 录音时间线测试：暂停区间与「会议时间轴 ↔ 文件时长」换算（阶段 1 验收的纯逻辑部分）
@Suite("录音时间线")
struct RecordingTimelineTests {

    @Test("无暂停时文件时长等于墙钟时长")
    func noPause() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timeline = RecordingTimeline(startedAt: start)
        let now = start.addingTimeInterval(10)
        #expect(timeline.wallMs(at: now) == 10_000)
        #expect(timeline.totalPausedMs(at: now) == 0)
        #expect(timeline.effectiveAudioMs(at: now) == 10_000)
        #expect(!timeline.isPaused)
    }

    @Test("单次暂停：文件时长扣除暂停区间")
    func singlePause() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var timeline = RecordingTimeline(startedAt: start)

        // 第 5 秒暂停，第 8 秒恢复
        try timeline.beginPause(at: start.addingTimeInterval(5))
        #expect(timeline.isPaused)
        let interval = try timeline.endPause(at: start.addingTimeInterval(8))
        #expect(!timeline.isPaused)

        #expect(interval.startMs == 5_000)
        #expect(interval.endMs == 8_000)
        #expect(interval.durationMs == 3_000)

        let now = start.addingTimeInterval(10)
        #expect(timeline.wallMs(at: now) == 10_000)
        #expect(timeline.totalPausedMs(at: now) == 3_000)
        #expect(timeline.effectiveAudioMs(at: now) == 7_000)
        #expect(timeline.intervals.count == 1)
    }

    @Test("多次暂停：累计扣除所有区间")
    func multiplePauses() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var timeline = RecordingTimeline(startedAt: start)

        try timeline.beginPause(at: start.addingTimeInterval(5))
        _ = try timeline.endPause(at: start.addingTimeInterval(8))   // 3 秒
        try timeline.beginPause(at: start.addingTimeInterval(12))
        _ = try timeline.endPause(at: start.addingTimeInterval(14))  // 2 秒

        let now = start.addingTimeInterval(20)
        #expect(timeline.totalPausedMs(at: now) == 5_000)
        #expect(timeline.effectiveAudioMs(at: now) == 15_000)
        #expect(timeline.intervals.count == 2)
    }

    @Test("暂停进行中：累计暂停计到当前时刻")
    func ongoingPauseCountsUpToNow() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var timeline = RecordingTimeline(startedAt: start)
        try timeline.beginPause(at: start.addingTimeInterval(5))

        let now = start.addingTimeInterval(9)
        #expect(timeline.totalPausedMs(at: now) == 4_000)
        // 暂停期间不应有新的音频写入：文件时长冻结在暂停开始处
        #expect(timeline.effectiveAudioMs(at: now) == 5_000)
    }

    @Test("重复暂停抛错")
    func doublePauseThrows() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var timeline = RecordingTimeline(startedAt: start)
        try timeline.beginPause(at: start.addingTimeInterval(5))
        #expect(throws: RecordingTimelineError.self) {
            try timeline.beginPause(at: start.addingTimeInterval(6))
        }
    }

    @Test("未暂停时结束暂停抛错")
    func endPauseWithoutPauseThrows() {
        var timeline = RecordingTimeline(startedAt: Date(timeIntervalSince1970: 1_000))
        #expect(throws: RecordingTimelineError.self) {
            try timeline.endPause(at: Date(timeIntervalSince1970: 1_001))
        }
    }
}
