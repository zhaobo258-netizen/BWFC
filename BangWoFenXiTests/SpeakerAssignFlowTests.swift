import Foundation
import Testing
@testable import BangWoFenXi

/// 说话人指认链路纯逻辑（09 号计划需求 2）：
/// 窗口规划、回填、mapper 手工指认、编排计划。
@Suite("说话人指认与自动声纹")
struct SpeakerAssignFlowTests {

    private func segment(
        startMs: Int64, endMs: Int64, text: String = "内容",
        participantId: UUID? = nil, label: String? = nil
    ) -> TranscriptSegment {
        let s = TranscriptSegment(
            startMs: startMs, endMs: endMs, text: text,
            participantId: participantId, source: .cloud, state: .final
        )
        s.remoteSpeakerLabel = label
        return s
    }

    // MARK: - SpeakerSampleWindowPlanner

    @Test("挑最长片段作声纹窗口；不足 2 秒的候选剔除")
    func plannerPicksLongest() {
        let speakerId = UUID()
        let segments = [
            segment(startMs: 0, endMs: 1_500, participantId: speakerId, label: "spk_a"),
            segment(startMs: 10_000, endMs: 14_000, participantId: speakerId, label: "spk_a"),
            segment(startMs: 20_000, endMs: 23_000, participantId: speakerId, label: "spk_a"),
        ]
        let window = SpeakerSampleWindowPlanner.plan(segments: segments) { $0 }
        #expect(window == .init(audioStartMs: 10_000, audioEndMs: 14_000))
    }

    @Test("超过 10 秒的片段不裁猜子区间，改选完整合格片段")
    func plannerRejectsLongSegment() {
        let speakerId = UUID()
        let segments = [
            segment(startMs: 0, endMs: 30_000, participantId: speakerId, label: "spk_a"),
            segment(startMs: 40_000, endMs: 46_000, participantId: speakerId, label: "spk_a"),
        ]
        let window = SpeakerSampleWindowPlanner.plan(segments: segments) { $0 }
        #expect(window == .init(audioStartMs: 40_000, audioEndMs: 46_000))
    }

    @Test("无合格候选返回 nil")
    func plannerNoCandidate() {
        let segments = [
            segment(startMs: 0, endMs: 1_000, participantId: UUID(), label: "spk_a")
        ]
        #expect(SpeakerSampleWindowPlanner.plan(segments: segments) { $0 } == nil)
    }

    @Test("自动声纹只允许 cloud/final、已确认归属且有云端标签的片段")
    func plannerRequiresCloudConfirmedSingleSpeaker() {
        let speakerId = UUID()
        let local = segment(
            startMs: 0, endMs: 5_000,
            participantId: speakerId, label: "spk_a"
        )
        local.source = .local
        let provisional = segment(
            startMs: 10_000, endMs: 15_000,
            participantId: speakerId, label: "spk_a"
        )
        provisional.state = .provisional
        let missingOwner = segment(startMs: 20_000, endMs: 25_000, label: "spk_a")
        let missingLabel = segment(
            startMs: 30_000, endMs: 35_000,
            participantId: speakerId
        )

        #expect(
            SpeakerSampleWindowPlanner.plan(
                segments: [local, provisional, missingOwner, missingLabel]
            ) { $0 } == nil
        )
    }

    @Test("墙钟 → 音频流：暂停区间被扣减，暂停中时刻映射到暂停起点")
    func wallToAudioConversion() {
        let pauses = [PauseInterval(startMs: 5_000, endMs: 8_000)]
        #expect(SpeakerSampleWindowPlanner.audioMs(forWallMs: 4_000, pauseIntervals: pauses) == 4_000)
        #expect(SpeakerSampleWindowPlanner.audioMs(forWallMs: 6_000, pauseIntervals: pauses) == 5_000)
        #expect(SpeakerSampleWindowPlanner.audioMs(forWallMs: 10_000, pauseIntervals: pauses) == 7_000)
    }

    @Test("跨暂停被压缩到不足 2 秒的候选被跳过，换下一个")
    func plannerSkipsPauseCompressed() {
        // 墙钟 4s，但中间 3s 在暂停：有效音频只有 1s → 跳过；备选 2.5s 中选
        let pauses = [PauseInterval(startMs: 1_000, endMs: 4_000)]
        let speakerId = UUID()
        let segments = [
            segment(startMs: 500, endMs: 4_500, participantId: speakerId, label: "spk_a"),
            segment(startMs: 10_000, endMs: 12_500, participantId: speakerId, label: "spk_a"),
        ]
        let window = SpeakerSampleWindowPlanner.plan(segments: segments) { wall in
            SpeakerSampleWindowPlanner.audioMs(forWallMs: wall, pauseIntervals: pauses)
        }
        #expect(window == .init(audioStartMs: 7_000, audioEndMs: 9_500))
    }

    // MARK: - SpeakerBackfill

    @Test("同标签的片段全部回填；只保护另一位用户已确认的归属")
    func backfillSameLabel() {
        let me = UUID(), other = UUID()
        let anchor = segment(startMs: 0, endMs: 2_000, label: "spk_a")
        let sameLabel = segment(startMs: 3_000, endMs: 5_000, label: "spk_a")
        let taken = segment(startMs: 6_000, endMs: 8_000, participantId: other, label: "spk_a")
        let userConfirmed = segment(
            startMs: 8_000, endMs: 9_000, participantId: other, label: "spk_a"
        )
        userConfirmed.speakerWasUserConfirmed = true
        let otherLabel = segment(startMs: 9_000, endMs: 11_000, label: "spk_b")
        let all = [anchor, sameLabel, taken, userConfirmed, otherLabel]

        let outcome = SpeakerBackfill.assign(anchorSegmentId: anchor.id, to: me, segments: all)

        #expect(Set(outcome.changedSegmentIds) == Set([anchor.id, sameLabel.id, taken.id]))
        #expect(outcome.remoteLabel == "spk_a")
        #expect(anchor.participantId == me)
        #expect(sameLabel.participantId == me)
        #expect(taken.participantId == me, "云端暂定归属应随本次人工确认一起纠正")
        #expect(userConfirmed.participantId == other, "另一位用户明确确认过的归属不能被覆盖")
        #expect(otherLabel.participantId == nil)
    }

    @Test("无标签锚点：只改这一条")
    func backfillNoLabel() {
        let me = UUID()
        let anchor = segment(startMs: 0, endMs: 2_000)
        let another = segment(startMs: 3_000, endMs: 5_000)
        let outcome = SpeakerBackfill.assign(anchorSegmentId: anchor.id, to: me, segments: [anchor, another])
        #expect(outcome.changedSegmentIds == [anchor.id])
        #expect(outcome.remoteLabel == nil)
        #expect(another.participantId == nil)
    }

    @Test("锚点允许改判（已有归属的锚点直接换人）")
    func backfillAnchorReassign() {
        let me = UUID(), wrong = UUID()
        let anchor = segment(startMs: 0, endMs: 2_000, participantId: wrong, label: "spk_a")
        let outcome = SpeakerBackfill.assign(anchorSegmentId: anchor.id, to: me, segments: [anchor])
        #expect(outcome.changedSegmentIds == [anchor.id])
        #expect(anchor.participantId == me)
    }

    @Test("云端已猜对时，人工点击仍写入确认状态")
    func backfillConfirmsExistingAssignment() {
        let me = UUID()
        let anchor = segment(
            startMs: 0,
            endMs: 3_000,
            participantId: me,
            label: "spk_a"
        )

        let outcome = SpeakerBackfill.assign(
            anchorSegmentId: anchor.id,
            to: me,
            segments: [anchor]
        )

        #expect(outcome.changedSegmentIds == [anchor.id])
        #expect(anchor.speakerWasUserConfirmed == true)
    }

    @Test("回填不置 edited：云端仍可更新文字和分段")
    func backfillKeepsState() {
        let me = UUID()
        let anchor = segment(startMs: 0, endMs: 2_000, label: "spk_a")
        _ = SpeakerBackfill.assign(anchorSegmentId: anchor.id, to: me, segments: [anchor])
        #expect(anchor.state == .final)
        #expect(anchor.source == .cloud)
    }

    // MARK: - SpeakerMapper 手工指认

    @Test("手工指认后同标签解析为该参会人；重建回灌保留")
    func mapperManualAssign() {
        let participant = Participant(cloudAlias: "p_01", displayName: "王总", side: .neutral)
        var mapper = SpeakerMapper(participants: [participant])
        let me = UUID()

        mapper.assign(remoteLabel: "spk_x", to: me)
        #expect(mapper.resolve(remoteLabel: "spk_x") == .known(participantId: me))
        #expect(mapper.resolve(remoteLabel: "p_01") == .known(participantId: participant.id),
                "代号匹配不受影响")

        var rebuilt = SpeakerMapper(participants: [participant])
        rebuilt.restoreManualAssignments(mapper.manualAssignments)
        #expect(rebuilt.resolve(remoteLabel: "spk_x") == .known(participantId: me))
    }

    @Test("代号已能匹配的标签不允许手工指认覆盖")
    func mapperAliasWins() {
        let participant = Participant(cloudAlias: "p_01", displayName: "王总", side: .neutral)
        var mapper = SpeakerMapper(participants: [participant])
        let someoneElse = UUID()
        mapper.assign(remoteLabel: "p_01", to: someoneElse)
        #expect(mapper.resolve(remoteLabel: "p_01") == .known(participantId: participant.id))
    }

    // MARK: - SpeakerAssignPlanner 编排

    @Test("完整计划：回填 + 声纹窗口；已有样本的说话人不再切样本")
    func plannerFullPlan() {
        let speaker = Speaker(cloudAlias: "p_01", displayName: "王总")
        let anchor = segment(startMs: 0, endMs: 3_000, label: "spk_a")
        let more = segment(startMs: 5_000, endMs: 12_000, label: "spk_a")
        let plan = SpeakerAssignPlanner.makePlan(
            anchorSegmentId: anchor.id, speaker: speaker,
            segments: [anchor, more], pauseIntervals: []
        )
        #expect(Set(plan.changedSegmentIds) == Set([anchor.id, more.id]))
        #expect(plan.remoteLabel == "spk_a")
        #expect(plan.sampleWindow == .init(audioStartMs: 5_000, audioEndMs: 12_000),
                "从回填后名下片段挑最长的一段")

        speaker.voiceSamplePath = "Meetings/x/samples/y.wav"
        let anchor2 = segment(startMs: 20_000, endMs: 23_000, label: "spk_b")
        let plan2 = SpeakerAssignPlanner.makePlan(
            anchorSegmentId: anchor2.id, speaker: speaker,
            segments: [anchor2], pauseIntervals: []
        )
        #expect(plan2.sampleWindow == nil, "已有声纹样本不覆盖")
    }
}
