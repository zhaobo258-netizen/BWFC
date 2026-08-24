import Foundation

/// 说话人回填（纯逻辑，09 号计划需求 2）：
/// 用户把某个片段（或总结条目的证据片段）指认为某说话人后，
/// 把同一云端标签下所有「尚未识别」的历史片段一并映射过去。
///
/// 纪律：
/// - 只回填 participantId 为空的片段——已被云端或人工确认的归属不动；
/// - 回填不置 state = .edited：这不是对内容的人工修订，云端后续如果给出
///   更准确的归属仍应生效（与 MeetingTranscriptEditor.assignSpeaker 的语义不同，
///   那是用户对「这一条」的显式修订，这里是标签级的批量推断）；
/// - 直接指认的片段本身也走这里（含无标签片段：只改这一条）。
enum SpeakerBackfill {
    /// 回填结果
    struct Outcome: Equatable, Sendable {
        /// 实际被修改的片段 id
        var changedSegmentIds: [UUID]
        /// 参与回填的云端标签（直接指认的片段无标签时为 nil）
        var remoteLabel: String?
    }

    /// 把 anchor 片段指认为 speakerId，并回填同标签的未识别片段。
    /// - Returns: 修改明细；anchor 已是该说话人时可能为空数组
    @discardableResult
    static func assign(
        anchorSegmentId: UUID,
        to speakerId: UUID,
        segments: [TranscriptSegment],
        now: Date = Date()
    ) -> Outcome {
        guard let anchor = segments.first(where: { $0.id == anchorSegmentId }) else {
            return Outcome(changedSegmentIds: [], remoteLabel: nil)
        }
        let label = anchor.remoteSpeakerLabel
        var changed: [UUID] = []
        for segment in segments {
            let isAnchor = segment.id == anchorSegmentId
            let sameLabel = label != nil && segment.remoteSpeakerLabel == label
            guard isAnchor || sameLabel else { continue }
            // 非 anchor 的同标签片段：已有归属不动；anchor 本身允许改判
            if !isAnchor && segment.participantId != nil { continue }
            if segment.participantId == speakerId { continue }
            segment.participantId = speakerId
            if isAnchor { segment.speakerWasUserConfirmed = true }
            segment.updatedAt = now
            changed.append(segment.id)
        }
        return Outcome(changedSegmentIds: changed, remoteLabel: label)
    }
}
