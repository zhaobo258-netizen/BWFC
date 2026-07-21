import Foundation
import Testing
@testable import BangWoFenXi

/// 分片规划：20 秒分片、2 秒重叠、窗口闭合才产出、尾部残缺窗口（实施计划 7.4）
@Suite("分片规划")
struct ChunkPlannerTests {
    let planner = ChunkPlanner()

    @Test("窗口边界：起点间距 18 秒，长度 20 秒，重叠 2 秒")
    func windowBoundaries() {
        let w0 = planner.window(forIndex: 0)
        #expect(w0.audioStartMs == 0)
        #expect(w0.audioEndMs == 20_000)
        let w1 = planner.window(forIndex: 1)
        #expect(w1.audioStartMs == 18_000)
        #expect(w1.audioEndMs == 38_000)
        // 相邻重叠恰好 2 秒
        #expect(w0.audioEndMs - w1.audioStartMs == 2_000)
    }

    @Test("只产出已闭合窗口")
    func pendingWindowsOnlyComplete() {
        // 19.9 秒：第一个窗口（0–20s）未闭合
        #expect(planner.pendingWindows(uptoAudioMs: 19_900, nextIndex: 0).isEmpty)
        // 20 秒：窗口 0 闭合
        let at20 = planner.pendingWindows(uptoAudioMs: 20_000, nextIndex: 0)
        #expect(at20.map(\.index) == [0])
        // 45 秒：窗口 0（0–20）、1（18–38）闭合；窗口 2（36–56）未闭合
        let at45 = planner.pendingWindows(uptoAudioMs: 45_000, nextIndex: 0)
        #expect(at45.map(\.index) == [0, 1])
    }

    @Test("从指定序号续产（不重复产出）")
    func pendingWindowsFromIndex() {
        let windows = planner.pendingWindows(uptoAudioMs: 45_000, nextIndex: 1)
        #expect(windows.map(\.index) == [1])
        #expect(planner.pendingWindows(uptoAudioMs: 45_000, nextIndex: 2).isEmpty)
    }

    @Test("尾部残缺窗口：不足 1 秒不产生")
    func finalWindow() {
        // 45 秒进度、已产出到 2 号（36s 起）：尾部 36–45s（9 秒）
        let tail = planner.finalWindow(uptoAudioMs: 45_000, nextIndex: 2)
        #expect(tail == ChunkWindow(index: 2, audioStartMs: 36_000, audioEndMs: 45_000))
        // 仅 0.5 秒尾巴：不产生
        #expect(planner.finalWindow(uptoAudioMs: 36_500, nextIndex: 2) == nil)
    }

    @Test("20 分钟会议：分片数与总覆盖符合预期")
    func twentyMinuteCoverage() {
        // 1,200,000ms：完整窗口数 = floor((1200000-20000)/18000)+1 = 66
        let windows = planner.pendingWindows(uptoAudioMs: 1_200_000, nextIndex: 0)
        #expect(windows.count == 66)
        // 尾部（最后一个完整窗口结束后到 1,200,000）
        let tail = planner.finalWindow(uptoAudioMs: 1_200_000, nextIndex: 66)
        #expect(tail != nil)
        #expect(tail!.audioStartMs == 66 * 18_000)
        #expect(tail!.audioEndMs == 1_200_000)
    }
}

/// 退避策略：指数增长、上限封顶、最大尝试次数（实施计划 7.4）
@Suite("退避策略")
struct RetryPolicyTests {
    let policy = RetryPolicy()

    @Test("首次尝试无延迟，之后指数退避")
    func exponentialDelays() {
        #expect(policy.delayMs(beforeAttempt: 1) == 0)
        #expect(policy.delayMs(beforeAttempt: 2) == 1_000)
        #expect(policy.delayMs(beforeAttempt: 3) == 2_000)
        #expect(policy.delayMs(beforeAttempt: 4) == 4_000)
        #expect(policy.delayMs(beforeAttempt: 5) == 8_000)
    }

    @Test("延迟封顶 30 秒")
    func delayCapped() {
        #expect(policy.delayMs(beforeAttempt: 20) == 30_000)
    }

    @Test("最大尝试次数：5 次失败后进入待用户重试")
    func maxAttempts() {
        #expect(policy.shouldRetry(afterFailures: 1))
        #expect(policy.shouldRetry(afterFailures: 4))
        #expect(!policy.shouldRetry(afterFailures: 5), "第 5 次失败后不得再自动重试")
        #expect(!policy.shouldRetry(afterFailures: 10))
    }
}

/// 说话人映射：已知代号、未知标签稳定分配字母（实施计划 7.5）
@Suite("说话人映射")
struct SpeakerMapperTests {
    @Test("已知代号映射到参会人")
    func knownAlias() {
        let participant = Participant(cloudAlias: "p_01", displayName: "测试", side: .counterpart)
        var mapper = SpeakerMapper(participants: [participant])
        #expect(mapper.resolve(remoteLabel: "p_01") == .known(participantId: participant.id))
    }

    @Test("未知标签按出现顺序分配「待识别 A/B」，同一标签稳定")
    func unknownLabels() {
        var mapper = SpeakerMapper(participants: [])
        #expect(mapper.resolve(remoteLabel: "spk_x") == .unknown(displayName: "待识别 A"))
        #expect(mapper.resolve(remoteLabel: "spk_y") == .unknown(displayName: "待识别 B"))
        // 同一标签再次解析：仍是 A
        #expect(mapper.resolve(remoteLabel: "spk_x") == .unknown(displayName: "待识别 A"))
        #expect(mapper.unknownCount == 2)
    }

    @Test("空标签显示「识别中」")
    func nilLabel() {
        var mapper = SpeakerMapper(participants: [])
        #expect(mapper.resolve(remoteLabel: nil) == .unknown(displayName: "识别中"))
        #expect(mapper.resolve(remoteLabel: "") == .unknown(displayName: "识别中"))
    }

    @Test("字母序号：0→A，25→Z，26→AA")
    func letters() {
        #expect(SpeakerMapper.letter(forIndex: 0) == "A")
        #expect(SpeakerMapper.letter(forIndex: 25) == "Z")
        #expect(SpeakerMapper.letter(forIndex: 26) == "AA")
    }
}

/// 声音样本校验：2–10 秒 + 有效音量（实施计划 7.5）
@Suite("声音样本校验")
struct VoiceSampleValidatorTests {
    @Test("时长边界")
    func durationBounds() {
        #expect(VoiceSampleValidator.validate(durationMs: 1_999, peakLevel: 0.5) == .tooShort)
        #expect(VoiceSampleValidator.validate(durationMs: 2_000, peakLevel: 0.5) == .ok)
        #expect(VoiceSampleValidator.validate(durationMs: 10_000, peakLevel: 0.5) == .ok)
        #expect(VoiceSampleValidator.validate(durationMs: 10_001, peakLevel: 0.5) == .tooLong)
    }

    @Test("音量不足")
    func quietSample() {
        #expect(VoiceSampleValidator.validate(
            durationMs: 5_000,
            peakLevel: VoiceSampleValidator.minPeakLevel - 0.001
        ) == .tooQuiet)
        #expect(VoiceSampleValidator.validate(
            durationMs: 5_000,
            peakLevel: VoiceSampleValidator.minPeakLevel
        ) == .ok)
    }
}
