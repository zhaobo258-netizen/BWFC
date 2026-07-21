import Foundation

/// 分析卡片类别（实施计划 6.4，固定六类）
enum InsightCategory: String, Codable, Sendable, CaseIterable {
    case explicitDemand       // 明确诉求
    case possibleConcern      // 可能顾虑
    case possibleMotive       // 可能动机
    case attitudeChange       // 态度变化
    case concessionSignal     // 让步信号
    case contradictionEvasion // 矛盾与回避

    var displayName: String {
        switch self {
        case .explicitDemand: return "明确诉求"
        case .possibleConcern: return "可能顾虑"
        case .possibleMotive: return "可能动机"
        case .attitudeChange: return "态度变化"
        case .concessionSignal: return "让步信号"
        case .contradictionEvasion: return "矛盾与回避"
        }
    }

    /// 默认判断类型（实施计划 6.4 表格）
    var defaultEpistemicStatus: EpistemicStatus {
        switch self {
        case .explicitDemand:
            return .explicit
        case .possibleConcern, .possibleMotive:
            return .inference
        case .attitudeChange, .concessionSignal, .contradictionEvasion:
            return .inference // 可为明确表达或 AI 推测，默认按推测展示
        }
    }
}

/// 判断类型：明确表达 / AI 推测（实施计划 2.1）
enum EpistemicStatus: String, Codable, Sendable {
    case explicit  // 明确表达：原话直接支持
    case inference // AI 推测：不等于事实

    var displayName: String {
        switch self {
        case .explicit: return "明确表达"
        case .inference: return "AI 推测"
        }
    }
}

/// 置信度（实施计划 6.4：低/中/高，不显示伪精确百分比）
enum Confidence: String, Codable, Sendable, CaseIterable {
    case low, medium, high

    var displayName: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

/// 单条分析项（实施计划 9.4）
final class Insight: Identifiable, Codable {
    /// 主键
    var id: UUID
    /// 分析类别
    var category: InsightCategory
    /// 涉及的参会人 ID
    var subjectParticipantId: UUID?
    /// 一句简洁判断
    var statement: String
    /// 明确表达 / AI 推测
    var epistemicStatus: EpistemicStatus
    /// 置信度
    var confidence: Confidence
    /// 证据片段 ID（至少一个，否则该分析无效）
    var evidenceSegmentIds: [UUID]
    /// 首次观察到的时间
    var firstObservedAt: Date
    /// 最近更新时间
    var lastUpdatedAt: Date

    init(
        id: UUID = UUID(),
        category: InsightCategory,
        subjectParticipantId: UUID? = nil,
        statement: String,
        epistemicStatus: EpistemicStatus,
        confidence: Confidence,
        evidenceSegmentIds: [UUID],
        firstObservedAt: Date = Date(),
        lastUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.subjectParticipantId = subjectParticipantId
        self.statement = statement
        self.epistemicStatus = epistemicStatus
        self.confidence = confidence
        self.evidenceSegmentIds = evidenceSegmentIds
        self.firstObservedAt = firstObservedAt
        self.lastUpdatedAt = lastUpdatedAt
    }

    /// 实施计划 9.4：evidenceSegmentIds 为空或引用不存在片段的分析结果视为无效，不进入 UI。
    var hasValidEvidence: Bool { !evidenceSegmentIds.isEmpty }

    /// 校验证据是否全部存在于给定片段 ID 集合中
    func evidenceExists(in validSegmentIds: Set<UUID>) -> Bool {
        hasValidEvidence && evidenceSegmentIds.allSatisfy { validSegmentIds.contains($0) }
    }
}
