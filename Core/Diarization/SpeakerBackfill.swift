import Foundation

/// 说话人回填（纯逻辑，09 号计划需求 2）：
/// 用户把某个片段（或总结条目的证据片段）指认为某说话人后，
/// 把同一云端标签下所有尚未被用户明确确认给其他人的历史片段一并映射过去。
///
/// 纪律：
/// - 云端暂定或未识别归属随本次人工确认一起纠正；
/// - 另一位用户已明确确认过的归属不动；
/// - 回填不置 state = .edited：这不是对文字内容的人工修订；云端仍可更新文字和分段，
///   但不得覆盖这次人工确认的说话人归属；
/// - 直接指认的片段本身也走这里（含无标签片段：只改这一条）。
enum SpeakerBackfill {
    /// 回填结果
    struct Outcome: Equatable, Sendable {
        /// 实际被修改的片段 id
        var changedSegmentIds: [UUID]
        /// 参与回填的云端标签（直接指认的片段无标签时为 nil）
        var remoteLabel: String?
    }

    /// 把 anchor 片段指认为 speakerId，并回填同标签片段。
    /// - Returns: 修改明细；anchor 已是该说话人时可能为空数组
    @discardableResult
    static func assign(
        anchorSegmentId: UUID,
        to speakerId: UUID,
        segments: [TranscriptSegment],
        includeAllUnconfirmed: Bool = false,
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
            let eligibleUnconfirmed = includeAllUnconfirmed
                && segment.speakerWasUserConfirmed != true
                && (segment.state == .final || segment.state == .edited)
            guard isAnchor || sameLabel || eligibleUnconfirmed else { continue }
            // 另一位用户明确确认过的片段不能被一次批量操作覆盖；锚点允许改判。
            if !isAnchor,
               segment.speakerWasUserConfirmed == true,
               segment.participantId != speakerId {
                continue
            }
            if segment.participantId != speakerId || segment.speakerWasUserConfirmed != true {
                segment.participantId = speakerId
                segment.speakerWasUserConfirmed = true
                segment.updatedAt = now
                changed.append(segment.id)
            }
        }
        return Outcome(changedSegmentIds: changed, remoteLabel: label)
    }
}
