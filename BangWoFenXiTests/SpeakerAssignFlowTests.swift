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

    @Test("用户明确选择后可一次标注全部未确认发言")
    func assignAllUnconfirmedWhenExplicitlyRequested() {
        let me = UUID()
        let other = UUID()
        let anchor = segment(startMs: 0, endMs: 2_000, label: "spk_a")
        let anotherLabel = segment(startMs: 3_000, endMs: 5_000, label: "spk_b")
        let protected = segment(
            startMs: 6_000,
            endMs: 8_000,
            participantId: other,
            label: "spk_c"
        )
        protected.speakerWasUserConfirmed = true

        let outcome = SpeakerBackfill.assign(
            anchorSegmentId: anchor.id,
            to: me,
            segments: [anchor, anotherLabel, protected],
            includeAllUnconfirmed: true
        )

        #expect(Set(outcome.changedSegmentIds) == [anchor.id, anotherLabel.id])
        #expect(anotherLabel.participantId == me)
        #expect(protected.participantId == other)
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

    // MARK: - 显式选段指认（说话人左键指认计划 20261007）

    @Test("显式选段只改指定语句并写入句级作用域；同标签未选句不动")
    func explicitAssignTouchesOnlySelectedSegments() {
        let me = UUID()
        let other = UUID()
        let selected = TranscriptSegment(startMs: 0, endMs: 1_000, text: "被选中",
            remoteSpeakerLabel: "chunk:0:speaker_1", source: .cloud, state: .final)
        let sameLabelNotSelected = TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "同标签未选",
            remoteSpeakerLabel: "chunk:0:speaker_1", source: .cloud, state: .final)
        let noLabelSelected = TranscriptSegment(startMs: 2_000, endMs: 3_000, text: "无标签被选",
            source: .local, state: .final)
        let segments = [selected, sameLabelNotSelected, noLabelSelected]

        let outcome = SpeakerBackfill.assignExplicit(
            segmentIds: [selected.id, noLabelSelected.id], to: me, segments: segments)

        #expect(outcome.changedSegmentIds == [selected.id, noLabelSelected.id])
        #expect(outcome.remoteLabel == nil, "显式选段不参与组级标签传播")
        #expect(selected.participantId == me)
        #expect(selected.speakerWasUserConfirmed == true)
        #expect(selected.speakerConfirmationScope == .segment)
        #expect(selected.speakerAttributionConflict == false)
        #expect(selected.remoteSpeakerLabel == "chunk:0:speaker_1", "声音标签保留")
        #expect(selected.state == .final, "指认不得把文字标为人工修订")
        #expect(sameLabelNotSelected.participantId == nil, "同标签未选句不动")
        #expect(sameLabelNotSelected.speakerConfirmationScope == nil)
        #expect(noLabelSelected.participantId == me)
    }

    @Test("显式选段预览逐条列出保护原因，且不修改模型")
    func explicitPreviewListsExclusionsWithoutMutating() {
        let me = UUID()
        let other = UUID()
        let protected = TranscriptSegment(startMs: 0, endMs: 1_000, text: "已确认他人",
            participantId: other, source: .cloud, state: .final, speakerWasUserConfirmed: true)
        let provisional = TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "识别中",
            source: .local, state: .provisional)
        let same = TranscriptSegment(startMs: 2_000, endMs: 3_000, text: "已是此人",
            participantId: me, source: .cloud, state: .final, speakerWasUserConfirmed: true)
        let failed = TranscriptSegment(startMs: 3_000, endMs: 4_000, text: "识别失败但有稳定片段",
            source: .cloud, state: .failed)
        let missing = UUID()
        let segments = [protected, provisional, same, failed]

        let preview = SpeakerBackfill.previewExplicit(
            segmentIds: [protected.id, provisional.id, same.id, failed.id, missing],
            to: me, segments: segments)

        #expect(preview.applicableSegmentIds == [failed.id], "失败但有稳定片段的可指认")
        let reasons = Dictionary(uniqueKeysWithValues: preview.exclusions.map { ($0.segmentId, $0.reason) })
        #expect(reasons[protected.id] == .confirmedToOther)
        #expect(reasons[provisional.id] == .provisional)
        #expect(reasons[same.id] == .alreadySamePerson)
        #expect(reasons[missing] == .missingSegment)
        // 预览不修改模型
        #expect(protected.participantId == other && protected.speakerWasUserConfirmed == true)
        #expect(failed.participantId == nil)
        #expect(provisional.state == .provisional)
    }

    @Test("批量保护已确认他人；单条入口可显式改判（改判后 scope 仍为句级）")
    func explicitAssignProtectsConfirmedButSingleCanOverride() {
        let me = UUID()
        let other = UUID()
        let confirmedOther = TranscriptSegment(startMs: 0, endMs: 1_000, text: "确认给乙",
            participantId: other, remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerWasUserConfirmed: true)

        // 批量：包含该条 → 排除并说明，不修改
        let batch = SpeakerBackfill.assignExplicit(
            segmentIds: [confirmedOther.id], to: me, segments: [confirmedOther])
        #expect(batch.changedSegmentIds.isEmpty)
        #expect(batch.exclusions.map(\.reason) == [.confirmedToOther])
        #expect(confirmedOther.participantId == other)

        // 单条入口（显式改判）：同样走 assignExplicit——计划允许单条改判已确认句，
        // 由 UI 层用“单条模式”区分（不进入批量保护检查）
        let override = SpeakerBackfill.assignExplicitAllowingOverride(
            segmentId: confirmedOther.id, to: me, segments: [confirmedOther])
        #expect(override.changedSegmentIds == [confirmedOther.id])
        #expect(confirmedOther.participantId == me)
        #expect(confirmedOther.speakerWasUserConfirmed == true)
        #expect(confirmedOther.speakerConfirmationScope == .segment)
    }

    @Test("旧组级回填写入 group 作用域并输出排除原因")
    func legacyGroupAssignWritesGroupScopeWithExclusions() {
        let me = UUID()
        let other = UUID()
        let anchor = TranscriptSegment(startMs: 0, endMs: 1_000, text: "锚点",
            remoteSpeakerLabel: "chunk:0:speaker_1", source: .cloud, state: .final)
        let sameGroup = TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "同组",
            remoteSpeakerLabel: "chunk:0:speaker_1", source: .cloud, state: .final)
        let confirmedOther = TranscriptSegment(startMs: 2_000, endMs: 3_000, text: "他人已确认",
            participantId: other, remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerWasUserConfirmed: true)
        let again = TranscriptSegment(startMs: 3_000, endMs: 4_000, text: "已是此人",
            participantId: me, remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerWasUserConfirmed: true)

        let outcome = SpeakerBackfill.assign(
            anchorSegmentId: anchor.id, to: me, segments: [anchor, sameGroup, confirmedOther, again])

        #expect(outcome.changedSegmentIds == [anchor.id, sameGroup.id])
        #expect(outcome.remoteLabel == "chunk:0:speaker_1")
        #expect(anchor.speakerConfirmationScope == .group)
        #expect(sameGroup.speakerConfirmationScope == .group)
        let reasons = Dictionary(uniqueKeysWithValues: outcome.exclusions.map { ($0.segmentId, $0.reason) })
        #expect(reasons[confirmedOther.id] == .confirmedToOther)
        #expect(reasons[again.id] == .alreadySamePerson)
    }

    @Test("高级组级回填不跨来源：合并项目两来源同标签只改锚点来源（审查修复 A）")
    func groupAssignConfinedToAnchorSource() {
        let me = UUID()
        let sourceA = UUID()
        let sourceB = UUID()
        let label = "chunk:0:speaker_1"
        let anchorA = TranscriptSegment(startMs: 0, endMs: 1_000, text: "A来源锚点",
            participantId: nil, remoteSpeakerLabel: label, source: .cloud, state: .final)
        anchorA.sourceAssetId = sourceA
        let sameSource = TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "A来源同组",
            remoteSpeakerLabel: label, source: .cloud, state: .final)
        sameSource.sourceAssetId = sourceA
        let otherSourceSameLabel = TranscriptSegment(startMs: 2_000, endMs: 3_000, text: "B来源同标签",
            remoteSpeakerLabel: label, source: .cloud, state: .final)
        otherSourceSameLabel.sourceAssetId = sourceB
        let otherUnconfirmed = TranscriptSegment(startMs: 3_000, endMs: 4_000, text: "B来源未确认",
            source: .cloud, state: .final)
        otherUnconfirmed.sourceAssetId = sourceB
        let segments = [anchorA, sameSource, otherSourceSameLabel, otherUnconfirmed]

        // 预览按选定目标算实际范围，不含 B 来源
        let preview = SpeakerBackfill.previewGroupAssign(
            anchorSegmentId: anchorA.id, to: me, segments: segments,
            includeAllUnconfirmed: true)
        #expect(preview != nil)
        #expect(Set(preview!.plan.applicableSegmentIds) == Set([anchorA.id, sameSource.id]))
        #expect(preview!.plan.anchorSourceAssetId == sourceA)
        // 执行与预览一致；B 来源同标签/未确认一律不动
        let outcome = SpeakerBackfill.assign(
            anchorSegmentId: anchorA.id, to: me, segments: segments,
            includeAllUnconfirmed: true)
        #expect(outcome.changedSegmentIds == [anchorA.id, sameSource.id])
        #expect(otherSourceSameLabel.participantId == nil)
        #expect(otherUnconfirmed.participantId == nil)
        #expect(otherSourceSameLabel.speakerConfirmationScope == nil)
        #expect(anchorA.speakerConfirmationScope == .group)
    }

    @Test("组级预览按选定目标统计保护数，与执行排除一致")
    func groupPreviewCountsProtectedByTarget() {
        let target = UUID()
        let other = UUID()
        let anchor = TranscriptSegment(startMs: 0, endMs: 1_000, text: "锚点",
            remoteSpeakerLabel: "chunk:0:speaker_1", source: .cloud, state: .final)
        let confirmedToOther = TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "已确认他人",
            participantId: other, remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerWasUserConfirmed: true)
        let alreadySame = TranscriptSegment(startMs: 2_000, endMs: 3_000, text: "已是目标",
            participantId: target, remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerWasUserConfirmed: true)

        let preview = SpeakerBackfill.previewGroupAssign(
            anchorSegmentId: anchor.id, to: target, segments: [anchor, confirmedToOther, alreadySame])
        #expect(preview?.preview.applicableSegmentIds == [anchor.id])
        let reasons = Dictionary(uniqueKeysWithValues: preview!.preview.exclusions.map {
            ($0.segmentId, $0.reason)
        })
        #expect(reasons[confirmedToOther.id] == .confirmedToOther)
        #expect(reasons[alreadySame.id] == .alreadySamePerson)
    }

    @Test("作用域字段随旧 JSON 缺省为 nil，新记录可往返")
    func scopeFieldBackwardCompatible() throws {
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","startMs":0,"endMs":1000,"text":"旧片段",
         "source":"cloud","state":"final","isStarred":false,
         "createdAt":700000000,"updatedAt":700000000}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let segment = try decoder.decode(TranscriptSegment.self, from: Data(legacyJSON.utf8))
        #expect(segment.speakerConfirmationScope == nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let fresh = TranscriptSegment(startMs: 0, endMs: 1_000, text: "新片段",
            source: .cloud, state: .final, speakerConfirmationScope: .segment)
        let restored = try decoder.decode(
            TranscriptSegment.self, from: encoder.encode(fresh))
        #expect(restored.speakerConfirmationScope == .segment)
    }
}
