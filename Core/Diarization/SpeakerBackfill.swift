import Foundation

/// 说话人指认的范围与保护规则（说话人左键指认计划 20261007）：
/// - 单条快捷与多选批量：只改明确指定的片段（句级确认，scope=.segment），
///   不同组回填、不登记声纹、不启动整场回查；
/// - 高级入口（同组回填/本录音其余未确认）：组级语义（scope=.group），
///   沿用既有链路，但输出实际修改数与排除原因，不拿标签总数冒充修改数。
///
/// 纪律：
/// - 预览（previewExplicit）是纯计算，不得修改真实模型；
/// - 已人工确认给其他人的语句在批量中受保护，预览列出并跳过；
/// - 不置 state = .edited：指认不是对文字的人工修订，不锁死后续文字更新；
/// - 文字、星标、来源、时间、声音标签一律不动。
enum SpeakerBackfill {
    /// 指认结果
    struct Outcome: Equatable, Sendable {
        /// 实际被修改的片段 id
        var changedSegmentIds: [UUID]
        /// 参与回填的云端标签（显式选段或无标签指认为 nil）
        var remoteLabel: String?
        /// 未修改条目及原因（含幂等跳过），供预览与反馈展示
        var exclusions: [Exclusion]
    }

    /// 排除原因（用户可读，逐条列出）
    struct Exclusion: Equatable, Sendable {
        var segmentId: UUID
        var reason: Reason

        enum Reason: Equatable, Sendable {
            /// 已人工确认给其他人（批量保护；单条入口可显式改判）
            case confirmedToOther
            /// 临时片段（识别中），定稿前禁止指认
            case provisional
            /// 已确认属于此人且无冲突（幂等，无需写入）
            case alreadySamePerson
            /// 片段已不存在（失效 ID 或重切后消失）
            case missingSegment
        }

        var displayText: String {
            switch reason {
            case .confirmedToOther: return "已人工确认给其他人，批量不覆盖"
            case .provisional: return "本句定稿后可指认（识别中）"
            case .alreadySamePerson: return "已属于该人物，无需修改"
            case .missingSegment: return "片段已不存在或已重新分段"
            }
        }
    }

    /// 预览结果（纯计算；不修改模型）
    struct Preview: Equatable, Sendable {
        /// 可以修改的片段 id（按传入顺序）
        var applicableSegmentIds: [UUID]
        var exclusions: [Exclusion]
    }

    // MARK: - 显式选段（单条快捷 / 多选批量）

    /// 预览显式选段的实际影响范围；不修改任何片段。
    /// allowOverride 仅用于单条显式改判入口：已确认他人的这一句允许改判（用户直接点选）。
    static func previewExplicit(
        segmentIds: [UUID],
        to speakerId: UUID,
        segments: [TranscriptSegment],
        allowOverride: Bool = false
    ) -> Preview {
        let byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var applicable: [UUID] = []
        var exclusions: [Exclusion] = []
        var seen = Set<UUID>()
        for id in segmentIds {
            guard seen.insert(id).inserted else { continue }
            guard let segment = byID[id] else {
                exclusions.append(Exclusion(segmentId: id, reason: .missingSegment))
                continue
            }
            // 临时片段定稿前禁止指认；final/edited/failed 均为权威片段，
            // failed 的失败提示保留，但人工指认不依赖识别重试成功
            guard segment.state != .provisional else {
                exclusions.append(Exclusion(segmentId: id, reason: .provisional))
                continue
            }
            if segment.speakerWasUserConfirmed == true,
               segment.participantId != nil, segment.participantId != speakerId,
               !allowOverride {
                exclusions.append(Exclusion(segmentId: id, reason: .confirmedToOther))
                continue
            }
            if segment.participantId == speakerId,
               segment.speakerWasUserConfirmed == true,
               segment.speakerAttributionConflict != true {
                exclusions.append(Exclusion(segmentId: id, reason: .alreadySamePerson))
                continue
            }
            applicable.append(id)
        }
        return Preview(applicableSegmentIds: applicable, exclusions: exclusions)
    }

    /// 把明确指定的片段指认为 speakerId（句级确认）。
    /// 只修改通过校验的片段；同标签未选中的句子一律不动。
    @discardableResult
    static func assignExplicit(
        segmentIds: [UUID],
        to speakerId: UUID,
        segments: [TranscriptSegment],
        now: Date = Date(),
        allowOverride: Bool = false
    ) -> Outcome {
        let preview = previewExplicit(
            segmentIds: segmentIds, to: speakerId, segments: segments,
            allowOverride: allowOverride
        )
        let applicable = Set(preview.applicableSegmentIds)
        guard !applicable.isEmpty else {
            return Outcome(changedSegmentIds: [], remoteLabel: nil, exclusions: preview.exclusions)
        }
        var changed: [UUID] = []
        for segment in segments where applicable.contains(segment.id) {
            segment.participantId = speakerId
            segment.speakerWasUserConfirmed = true
            segment.speakerAttributionConflict = false
            segment.speakerConfirmationScope = .segment
            segment.updatedAt = now
            changed.append(segment.id)
        }
        return Outcome(
            changedSegmentIds: changed,
            remoteLabel: nil,
            exclusions: preview.exclusions
        )
    }

    /// 单条显式改判（计划 20261007 §四）：用户直接点选，允许把已确认给他人的
    /// 这一句改给别人；与批量保护不同——改判是用户对这一条的明确决定。
    /// 仍为句级确认（scope=.segment），不同组回填。
    @discardableResult
    static func assignExplicitAllowingOverride(
        segmentId: UUID,
        to speakerId: UUID,
        segments: [TranscriptSegment],
        now: Date = Date()
    ) -> Outcome {
        guard let segment = segments.first(where: { $0.id == segmentId }) else {
            return Outcome(changedSegmentIds: [], remoteLabel: nil,
                           exclusions: [Exclusion(segmentId: segmentId, reason: .missingSegment)])
        }
        guard segment.state != .provisional else {
            return Outcome(changedSegmentIds: [], remoteLabel: nil,
                           exclusions: [Exclusion(segmentId: segmentId, reason: .provisional)])
        }
        if segment.participantId == speakerId,
           segment.speakerWasUserConfirmed == true,
           segment.speakerAttributionConflict != true {
            return Outcome(changedSegmentIds: [], remoteLabel: nil,
                           exclusions: [Exclusion(segmentId: segmentId, reason: .alreadySamePerson)])
        }
        return assignExplicit(
            segmentIds: [segmentId], to: speakerId, segments: segments,
            now: now, allowOverride: true
        )
    }

    // MARK: - 组级回填（高级入口保留）

    /// 把 anchor 片段指认为 speakerId，并回填同标签片段（组级确认，scope=.group）。
    /// - Returns: 修改与排除明细；anchor 已是该说话人时可能为空数组
    @discardableResult
    static func assign(
        anchorSegmentId: UUID,
        to speakerId: UUID,
        segments: [TranscriptSegment],
        includeAllUnconfirmed: Bool = false,
        now: Date = Date()
    ) -> Outcome {
        guard let anchor = segments.first(where: { $0.id == anchorSegmentId }) else {
            return Outcome(changedSegmentIds: [], remoteLabel: nil, exclusions: [])
        }
        let label = anchor.remoteSpeakerLabel
        var changed: [UUID] = []
        var exclusions: [Exclusion] = []
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
                exclusions.append(Exclusion(segmentId: segment.id, reason: .confirmedToOther))
                continue
            }
            if segment.participantId != speakerId || segment.speakerWasUserConfirmed != true {
                segment.participantId = speakerId
                segment.speakerWasUserConfirmed = true
                segment.speakerAttributionConflict = false
                segment.speakerConfirmationScope = .group
                segment.updatedAt = now
                changed.append(segment.id)
            } else if segment.speakerAttributionConflict == true {
                // 幂等指认也解除历史冲突标记：人工确认优先
                segment.speakerAttributionConflict = false
                segment.speakerConfirmationScope = .group
                segment.updatedAt = now
                changed.append(segment.id)
            } else {
                exclusions.append(Exclusion(segmentId: segment.id, reason: .alreadySamePerson))
            }
        }
        return Outcome(changedSegmentIds: changed, remoteLabel: label, exclusions: exclusions)
    }
}
