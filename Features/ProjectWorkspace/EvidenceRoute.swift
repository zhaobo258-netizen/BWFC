import Foundation

/// 统一「按需证据」路由（A 版 M2，纯逻辑部分）。
/// 整体理解 / 人物 / 主题 / 原话 / AI 历史来源都会解析成一个目标片段；
/// sheet/抽屉只呈现一个路由，关闭后回到原来的阅读状态。
struct EvidenceRouteTarget: Identifiable, Equatable {
    var id: String {
        switch origin {
        case .live:
            return "live:\(segmentID.uuidString)"
        case .aiHistory(let turnID, _, _):
            return "history:\(turnID.uuidString):\(segmentID.uuidString)"
        }
    }

    enum Origin: Equatable {
        /// 现场/分析条目证据：可直接定位当前原话
        case live(sourceLabel: String)
        /// AI 历史轮次的冻结来源：可能已被修订/改归属/移除
        case aiHistory(turnID: UUID, requestScopeLabel: String, historicalText: String)
    }

    let segmentID: UUID
    let origin: Origin
    /// 历史轮的冻结值副本（M1 快照；nil = 现场条目）
    let historicalCopy: ProjectAIChatEvidenceSnapshot.SegmentCopy?

    static func live(sourceLabel: String, segmentID: UUID) -> EvidenceRouteTarget {
        EvidenceRouteTarget(segmentID: segmentID, origin: .live(sourceLabel: sourceLabel),
                            historicalCopy: nil)
    }

    static func aiHistory(
        turnID: UUID,
        requestScopeLabel: String,
        copy: ProjectAIChatEvidenceSnapshot.SegmentCopy
    ) -> EvidenceRouteTarget {
        EvidenceRouteTarget(segmentID: copy.id,
                            origin: .aiHistory(turnID: turnID,
                                               requestScopeLabel: requestScopeLabel,
                                               historicalText: copy.text),
                            historicalCopy: copy)
    }

    var isHistorical: Bool {
        if case .aiHistory = origin { return true }
        return false
    }
}

/// 某一片段在某时刻的可信上下文（时间轴毫秒 + 文本 + 说话人身份副本）。
struct EvidenceContext: Equatable {
    struct Speaker: Equatable {
        let displayName: String?
        let isUserConfirmed: Bool
    }

    let text: String
    let startMs: Int64
    let speaker: Speaker?
}

/// 当前说话人信息提供器（由工作台按模型真实字段提供；片段归属为空时 nil）
struct EvidenceSpeakerInfo: Equatable {
    let displayName: String?
    let isUserConfirmed: Bool
}

/// 历史冻结来源与当前逐字稿的对照状态。
enum EvidenceCurrentStatus: Equatable {
    /// 当前片段存在且与冻结来源一致（含文本/归属/时间）：可定位
    case intact(historical: EvidenceContext?, current: EvidenceContext)
    /// 当前片段存在但文本/归属/时间任一已变：显示「当时依据 / 当前原话」两条
    case revised(historical: EvidenceContext, current: EvidenceContext)
    /// 当前片段已不存在：保留快照原文，禁止假定位
    case missing(historical: EvidenceContext)

    var canLocate: Bool {
        switch self {
        case .intact, .revised: return true
        case .missing: return false
        }
    }

    /// 与当时依据相比，归属/时间/文本是否发生变化（修订提示需要）。
    /// 现场条目（无历史）恒为 false，不臆报变化。
    var speakerOrTimeChanged: Bool {
        switch self {
        case .intact(let historical, let current):
            guard let historical else { return false }
            return historical.speaker != current.speaker
                || historical.startMs != current.startMs
                || historical.text != current.text
        case .revised:
            return true
        case .missing:
            return true
        }
    }
}

enum EvidenceRouteResolver {
    /// 从当前片段构建“现在”的可信上下文。
    static func context(
        segment: TranscriptSegment,
        speakerInfo: EvidenceSpeakerInfo?
    ) -> EvidenceContext {
        EvidenceContext(text: segment.text,
                        startMs: segment.startMs,
                        speaker: speakerInfo.map {
                            EvidenceContext.Speaker(displayName: $0.displayName,
                                                    isUserConfirmed: $0.isUserConfirmed)
                        })
    }

    /// 对照当前片段集，判定路由在「现在」的可信状态。
    /// - Parameters:
    ///   - currentSegments: 当前有效片段（与转写面板同一口径）
    ///   - currentSpeakerInfo: 片段归属 → 当前说话人身份真源
    static func currentStatus(
        of target: EvidenceRouteTarget,
        currentSegments: [TranscriptSegment],
        currentSpeakerInfo: (UUID?) -> EvidenceSpeakerInfo?
    ) -> EvidenceCurrentStatus {
        let historical: EvidenceContext?
        if let copy = target.historicalCopy {
            historical = EvidenceContext(
                text: copy.text,
                startMs: copy.startMs,
                speaker: copy.speakerDisplayName.map { name in
                    EvidenceContext.Speaker(displayName: name,
                                            isUserConfirmed: copy.speakerWasUserConfirmed ?? false)
                }
            )
        } else {
            historical = nil
        }

        guard let now = currentSegments.first(where: { $0.id == target.segmentID }) else {
            let fallback = EvidenceContext(text: target.historicalCopy?.text ?? "",
                                           startMs: target.historicalCopy?.startMs ?? 0,
                                           speaker: historical?.speaker)
            return .missing(historical: fallback)
        }
        let current = context(segment: now, speakerInfo: currentSpeakerInfo(now.participantId))

        guard let historical else { return .intact(historical: nil, current: current) }
        let changed = historical.text != current.text
            || historical.startMs != current.startMs
            || historical.speaker != current.speaker
        if changed {
            return .revised(historical: historical, current: current)
        }
        return .intact(historical: historical, current: current)
    }
}
