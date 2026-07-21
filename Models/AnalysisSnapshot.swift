import Foundation

/// 左侧结构总结中的一条记录（议题立场、确认事项、未决事项、关键数字等）。
/// 每条都必须携带证据片段 ID；无证据的记录视为无效，不进入 UI（实施计划 9.4）。
struct StructureEntry: Codable, Hashable, Sendable {
    /// 简洁结论文本
    var text: String
    /// 证据片段 ID 列表
    var evidenceSegmentIds: [UUID]

    /// 证据有效性：不允许空证据
    var hasValidEvidence: Bool { !evidenceSegmentIds.isEmpty }
}

/// 分析快照（实施计划 9.4）：一次原子更新，UI 以整个快照替换，不逐字段闪烁。
final class AnalysisSnapshot: Identifiable, Codable {
    /// 主键
    var id: UUID
    /// 版本号（同一会话内递增）
    var version: Int
    /// 生成时间
    var createdAt: Date
    /// 已处理到哪个片段（会议时间轴毫秒）
    var analyzedThroughMs: Int64
    /// 当前议题标题
    var currentTopicTitle: String?

    /// 我方明确立场
    var ourPositions: [StructureEntry]
    /// 对方明确立场
    var counterpartPositions: [StructureEntry]
    /// 已确认事项
    var confirmedItems: [StructureEntry]
    /// 未决事项
    var openItems: [StructureEntry]
    /// 关键数字、日期和承诺
    var keyFacts: [StructureEntry]

    /// 议题列表
    var topics: [TopicState] = []
    /// 右侧分析项
    var insights: [Insight] = []

    init(
        id: UUID = UUID(),
        version: Int,
        createdAt: Date = Date(),
        analyzedThroughMs: Int64,
        currentTopicTitle: String? = nil,
        ourPositions: [StructureEntry] = [],
        counterpartPositions: [StructureEntry] = [],
        confirmedItems: [StructureEntry] = [],
        openItems: [StructureEntry] = [],
        keyFacts: [StructureEntry] = []
    ) {
        self.id = id
        self.version = version
        self.createdAt = createdAt
        self.analyzedThroughMs = analyzedThroughMs
        self.currentTopicTitle = currentTopicTitle
        self.ourPositions = ourPositions
        self.counterpartPositions = counterpartPositions
        self.confirmedItems = confirmedItems
        self.openItems = openItems
        self.keyFacts = keyFacts
    }
}
