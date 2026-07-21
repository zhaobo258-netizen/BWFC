import Foundation
import Testing
@testable import BangWoFenXi

/// 云端片段合并（阶段 3）：本地 → 云端确认流转、判重、人工保护
@Suite("云端片段合并")
struct TranscriptReconcilerCloudTests {

    @Test("本地临时 → 云端最终：临时被清除，插入云端片段")
    func cloudReplacesProvisional() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.upsertProvisional(startMs: 1000, endMs: 3000, text: "如果年度")
        let outcome = reconciler.applyCloudFinal(
            startMs: 1000, endMs: 3000,
            text: "如果年度量能能保证。", participantId: nil, remoteSpeakerLabel: "p_01"
        )
        guard case .inserted(let segment) = outcome else {
            Issue.record("应插入云端片段")
            return
        }
        #expect(segment.source == .cloud)
        #expect(segment.state == .final)
        #expect(segment.remoteSpeakerLabel == "p_01")
        #expect(reconciler.provisional == nil)
        #expect(reconciler.finalized.count == 1)
    }

    @Test("本地最终 → 云端确认：就地更新，ID 稳定，来源转 cloud")
    func cloudUpdatesLocalFinalInPlace() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyFinal(startMs: 1000, endMs: 3000, text: "如果年度量能能保证")
        let localID = reconciler.finalized.first!.id

        let participantID = UUID()
        let outcome = reconciler.applyCloudFinal(
            startMs: 1100, endMs: 3100,
            text: "如果年度量能能保证。", participantId: participantID, remoteSpeakerLabel: "p_01"
        )
        guard case .updated(let segment) = outcome else {
            Issue.record("应就地更新本地片段")
            return
        }
        #expect(segment.id == localID, "云端确认必须保持片段 ID 稳定（分析证据 ID）")
        #expect(segment.source == .cloud)
        #expect(segment.state == .final)
        #expect(segment.participantId == participantID)
        #expect(reconciler.finalized.count == 1)
    }

    @Test("云端片段重发 → 判重跳过")
    func cloudDuplicateSkipped() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyCloudFinal(startMs: 0, endMs: 2000,
                                       text: "量能可以谈。", participantId: nil, remoteSpeakerLabel: "p_01")
        let outcome = reconciler.applyCloudFinal(startMs: 500, endMs: 2500,
                                                 text: "量能可以谈。", participantId: nil, remoteSpeakerLabel: "p_01")
        guard case .duplicate = outcome else {
            Issue.record("云端重发必须判重")
            return
        }
        #expect(reconciler.finalized.count == 1)
    }

    @Test("人工已修订片段：云端重叠结果不覆盖（实施计划 7.4 人工优先）")
    func manualEditProtected() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyFinal(startMs: 1000, endMs: 3000, text: "如果年度量能能保证")
        let segment = reconciler.finalized.first!
        // 人工修改文字
        MeetingTranscriptEditor.editText(segment, to: "如果年度量能能保证，我们就讨论返点。")
        #expect(segment.state == .edited)
        #expect(segment.source == .manual)

        let outcome = reconciler.applyCloudFinal(
            startMs: 1000, endMs: 3000,
            text: "如果年度量能能保证。", participantId: nil, remoteSpeakerLabel: "p_01"
        )
        guard case .skippedManual(let skipped) = outcome else {
            Issue.record("人工已修订片段必须跳过云端覆盖")
            return
        }
        #expect(skipped.id == segment.id)
        #expect(segment.text == "如果年度量能能保证，我们就讨论返点。", "人工文字不得被覆盖")
        #expect(segment.state == .edited)
    }

    @Test("人工修改说话人后：云端同片段结果不覆盖映射")
    func manualSpeakerMappingProtected() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyCloudFinal(startMs: 0, endMs: 2000,
                                       text: "返点需要确认。", participantId: nil, remoteSpeakerLabel: "spk_x")
        let segment = reconciler.finalized.first!
        let participant = Participant(cloudAlias: "p_01", displayName: "张总", side: .counterpart)
        MeetingTranscriptEditor.assignSpeaker(segment, to: participant)

        let outcome = reconciler.applyCloudFinal(startMs: 0, endMs: 2000,
                                                 text: "返点需要确认。", participantId: nil, remoteSpeakerLabel: "spk_x")
        guard case .skippedManual = outcome else {
            Issue.record("人工映射必须被保护")
            return
        }
        #expect(segment.participantId == participant.id)
    }

    @Test("重叠但文本不同的云端片段保留")
    func cloudDifferentTextKept() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyCloudFinal(startMs: 0, endMs: 4000,
                                       text: "如果年度量能能保证我们可以再讨论两个点",
                                       participantId: nil, remoteSpeakerLabel: nil)
        let outcome = reconciler.applyCloudFinal(startMs: 2000, endMs: 6000,
                                                 text: "返点需要和回款周期放在一起确认",
                                                 participantId: nil, remoteSpeakerLabel: nil)
        guard case .inserted = outcome else {
            Issue.record("文本明显不同的云端片段必须保留")
            return
        }
        #expect(reconciler.finalized.count == 2)
    }
}

/// 转写片段人工编辑（说话人、文字、星标）
@Suite("转写人工编辑")
struct MeetingTranscriptEditorTests {
    @Test("修改说话人：映射参会人并标记人工已修订")
    func assignSpeaker() {
        let segment = TranscriptSegment(startMs: 0, endMs: 1000, text: "测试",
                                        source: .cloud, state: .final)
        let participant = Participant(cloudAlias: "p_01", displayName: "张总", side: .counterpart)
        MeetingTranscriptEditor.assignSpeaker(segment, to: participant)
        #expect(segment.participantId == participant.id)
        #expect(segment.state == .edited)
        #expect(segment.source == .manual)
    }

    @Test("清除说话人映射")
    func clearSpeaker() {
        let segment = TranscriptSegment(startMs: 0, endMs: 1000, text: "测试",
                                        participantId: UUID(), source: .cloud, state: .final)
        MeetingTranscriptEditor.clearSpeaker(segment)
        #expect(segment.participantId == nil)
        #expect(segment.state == .edited)
    }

    @Test("修改文字：内容更新并标记人工已修订；空白拒绝")
    func editText() {
        let segment = TranscriptSegment(startMs: 0, endMs: 1000, text: "原文",
                                        source: .cloud, state: .final)
        MeetingTranscriptEditor.editText(segment, to: "  修订后的文字  ")
        #expect(segment.text == "修订后的文字")
        #expect(segment.state == .edited)
        #expect(segment.source == .manual)

        MeetingTranscriptEditor.editText(segment, to: "   ")
        #expect(segment.text == "修订后的文字", "空白修改不得生效")
    }

    @Test("星标切换不改变来源与状态")
    func toggleStar() {
        let segment = TranscriptSegment(startMs: 0, endMs: 1000, text: "测试",
                                        source: .cloud, state: .final)
        MeetingTranscriptEditor.toggleStar(segment)
        #expect(segment.isStarred)
        #expect(segment.source == .cloud)
        #expect(segment.state == .final)
        MeetingTranscriptEditor.toggleStar(segment)
        #expect(!segment.isStarred)
    }
}
