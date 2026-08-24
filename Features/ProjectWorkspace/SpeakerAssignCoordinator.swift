import Foundation

/// 说话人指认请求（sheet(item:) 的载体）：
/// 从总结条目（证据片段）或转写行发起，记录锚点片段与展示原文。
struct SpeakerAssignRequest: Identifiable {
    enum Source {
        case transcript(segmentId: UUID)
        case analysisItem(itemId: UUID, uniqueEvidenceSegmentId: UUID?)
        case legacyInsight(insightId: UUID, uniqueEvidenceSegmentId: UUID?)

        var transcriptSegmentId: UUID? {
            switch self {
            case .transcript(let segmentId): return segmentId
            case .analysisItem(_, let segmentId): return segmentId
            case .legacyInsight(_, let segmentId): return segmentId
            }
        }
    }

    let id = UUID()
    let source: Source
    /// 弹层展示的原话
    let anchorText: String

    var isAnalysisItem: Bool {
        switch source {
        case .analysisItem, .legacyInsight: return true
        case .transcript: return false
        }
    }
}

/// 指认编排纯逻辑（09 号计划需求 2，可单测）：
/// 回填 + 声纹窗口规划打包成一个可测试的步骤序列，
/// 文件 IO（切音频）与控制器通知留在工作台。
enum SpeakerAssignPlanner {
    struct Plan: Equatable {
        /// 回填修改的片段 id
        var changedSegmentIds: [UUID]
        /// 涉及的云端标签（后续分片直接解析用；无标签为 nil）
        var remoteLabel: String?
        /// 需要提取的声纹窗口（音频流时间；说话人已有样本或无合格候选为 nil）
        var sampleWindow: SpeakerSampleWindowPlanner.Window?
    }

    /// 计算一次指认的完整计划。
    /// - Parameters:
    ///   - anchorSegmentId: 用户点的那句话
    ///   - speaker: 指认给谁
    ///   - segments: 全部片段（会被回填就地修改）
    ///   - pauseIntervals: 已闭合暂停区间（墙钟 → 音频流换算）
    static func makePlan(
        anchorSegmentId: UUID,
        speaker: Speaker,
        segments: [TranscriptSegment],
        pauseIntervals: [PauseInterval],
        now: Date = Date()
    ) -> Plan {
        let outcome = SpeakerBackfill.assign(
            anchorSegmentId: anchorSegmentId,
            to: speaker.id,
            segments: segments,
            now: now
        )
        // 已有声纹样本不覆盖（用户手录的样本质量优先）
        var window: SpeakerSampleWindowPlanner.Window?
        if SpeakerPanelLogic.voiceReferencePath(for: speaker) == nil {
            // 候选：该说话人名下全部片段（含刚回填的）；无标签指认时只有锚点这一段
            let candidates = segments.filter { $0.participantId == speaker.id }
            window = SpeakerSampleWindowPlanner.plan(segments: candidates) { wallMs in
                SpeakerSampleWindowPlanner.audioMs(forWallMs: wallMs, pauseIntervals: pauseIntervals)
            }
        }
        return Plan(
            changedSegmentIds: outcome.changedSegmentIds,
            remoteLabel: outcome.remoteLabel,
            sampleWindow: window
        )
    }
}
