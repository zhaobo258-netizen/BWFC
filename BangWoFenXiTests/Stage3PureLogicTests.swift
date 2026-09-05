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

/// 说话人映射：已知代号、未知标签稳定分配编号（实施计划 7.5）。
/// 含渲染路径纯度保证：resolve 为非 mutating 纯函数（自激死循环根因修复）。
@Suite("说话人映射")
struct SpeakerMapperTests {
    @Test("已知代号映射到参会人")
    func knownAlias() {
        let participant = Participant(cloudAlias: "p_01", displayName: "测试", side: .counterpart)
        let mapper = SpeakerMapper(participants: [participant])
        #expect(mapper.resolve(remoteLabel: "p_01") == .known(participantId: participant.id))
    }

    @Test("resolve 为非 mutating 纯函数：可在不可变绑定上调用（渲染路径安全证明）")
    func resolveIsPure() {
        let participant = Participant(cloudAlias: "p_01", displayName: "测试", side: .counterpart)
        var mutableMapper = SpeakerMapper(participants: [participant])
        mutableMapper.register(remoteLabel: "spk_x")
        // 关键证明：let 绑定上可调用 resolve（若 resolve 是 mutating，此行无法编译）
        let frozenMapper = mutableMapper
        #expect(frozenMapper.resolve(remoteLabel: "spk_x") == .unknown(displayName: "人物 1（待识别）"))
        #expect(frozenMapper.resolve(remoteLabel: nil) == .unknown(displayName: "识别中"))
        // 纯解析绝不分配编号：未登记标签返回通用「待识别」，且不改变内部状态
        #expect(frozenMapper.resolve(remoteLabel: "spk_new") == .unknown(displayName: "待识别"))
        #expect(frozenMapper.unknownCount == 1, "纯解析不得登记新标签（视图求期零写入）")
    }

    @Test("未知标签：显式登记后按出现顺序分配编号，同一标签稳定")
    func registerThenResolve() {
        var mapper = SpeakerMapper(participants: [])
        // 未登记：通用「待识别」，不分配
        #expect(mapper.resolve(remoteLabel: "spk_x") == .unknown(displayName: "待识别"))
        #expect(mapper.unknownCount == 0)
        // 登记：按顺序分配
        mapper.register(remoteLabel: "spk_x")
        mapper.register(remoteLabel: "spk_y")
        #expect(mapper.resolve(remoteLabel: "spk_x") == .unknown(displayName: "人物 1（待识别）"))
        #expect(mapper.resolve(remoteLabel: "spk_y") == .unknown(displayName: "人物 2（待识别）"))
        // 重复登记幂等
        mapper.register(remoteLabel: "spk_x")
        #expect(mapper.unknownCount == 2)
        #expect(mapper.resolve(remoteLabel: "spk_x") == .unknown(displayName: "人物 1（待识别）"))
    }

    @Test("空标签显示「识别中」")
    func nilLabel() {
        let mapper = SpeakerMapper(participants: [])
        #expect(mapper.resolve(remoteLabel: nil) == .unknown(displayName: "识别中"))
        #expect(mapper.resolve(remoteLabel: "") == .unknown(displayName: "识别中"))
    }

    @Test("超过二十六个匿名组仍使用数字编号")
    func numbersBeyondTwentySix() {
        var mapper = SpeakerMapper(participants: [])
        for index in 0..<27 { mapper.register(remoteLabel: "group-\(index)") }
        #expect(mapper.resolve(remoteLabel: "group-26") == .unknown(displayName: "人物 27（待识别）"))
    }

    @Test("generic label 作用域对同一 chunk 稳定、跨 chunk 隔离")
    func genericLabelScope() {
        let first = SpeakerMapper.scopedRemoteLabel("speaker_0", chunkIndex: 3)
        #expect(first == SpeakerMapper.scopedRemoteLabel("speaker_0", chunkIndex: 3))
        #expect(first != SpeakerMapper.scopedRemoteLabel("speaker_0", chunkIndex: 4))
    }

    @Test("相邻分片有重叠原话时沿用稳定说话人标签")
    func stitchesOverlappingGenericLabels() {
        let stable = SpeakerMapper.scopedRemoteLabel("speaker_0", chunkIndex: 3)
        let existing = TranscriptSegment(
            startMs: 19_000,
            endMs: 21_000,
            text: "这段话跨过了分片边界",
            remoteSpeakerLabel: stable,
            source: .cloud,
            state: .final
        )
        let labels = SpeakerMapper.stitchedRemoteLabels(
            for: [
                .init(
                    startMs: 0,
                    endMs: 2_000,
                    text: "这段话跨过了分片边界",
                    speakerLabel: "speaker_7"
                )
            ],
            chunkIndex: 4,
            wallStartMs: 19_000,
            existingSegments: [existing]
        )

        #expect(labels["speaker_7"] == stable)
    }

    @Test("重叠原话对应多个旧组时不贪心合并身份")
    func ambiguousOverlapDoesNotMergePeople() {
        let existing = ["old-a", "old-b"].map { label in
            TranscriptSegment(startMs: 19_000, endMs: 21_000, text: "这个方案可以",
                              remoteSpeakerLabel: label, source: .cloud, state: .final)
        }
        let result = SpeakerMapper.stitchedRemoteLabels(
            for: [.init(startMs: 0, endMs: 2_000, text: "这个方案可以", speakerLabel: "new")],
            chunkIndex: 2, wallStartMs: 19_000, existingSegments: existing
        )
        #expect(result["new"] == SpeakerMapper.scopedRemoteLabel("new", chunkIndex: 2))
    }

    @Test("两个新组争用同一旧组时都保留独立身份")
    func competingGroupsAreNotAssignedByLabelOrder() {
        let existing = TranscriptSegment(startMs: 19_000, endMs: 21_000, text: "这个方案可以",
                                         remoteSpeakerLabel: "old", source: .cloud, state: .final)
        let result = SpeakerMapper.stitchedRemoteLabels(
            for: ["new-a", "new-b"].map {
                .init(startMs: 0, endMs: 2_000, text: "这个方案可以", speakerLabel: $0)
            },
            chunkIndex: 2, wallStartMs: 19_000, existingSegments: [existing]
        )
        #expect(result["new-a"] == SpeakerMapper.scopedRemoteLabel("new-a", chunkIndex: 2))
        #expect(result["new-b"] == SpeakerMapper.scopedRemoteLabel("new-b", chunkIndex: 2))
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
