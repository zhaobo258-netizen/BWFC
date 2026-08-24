import Foundation

/// 通用分析条目类别（产品文档 03 号 §8.4）：
/// 单一枚举覆盖四类场景，UI 按场景与类别分组，避免四套 JSON。
enum AnalysisItemCategory: String, Codable, Sendable, CaseIterable {
    // 整理层（总结页签）
    case summary              // 一句话/段落摘要
    case topic                // 主题/章节
    case fact                 // 事实点
    case decision             // 决定
    case actionItem           // 行动项
    case openQuestion         // 待确认问题
    // 语义层（动机与目的页签）
    case explicitNeed         // 明确诉求
    case possibleConcern      // 可能顾虑
    case possibleMotive       // 可能动机
    case expressionPurpose    // 表达目的
    case stanceChange         // 立场变化
    case contradictionEvasion // 矛盾与回避
    // 场景增强
    case keyQuote             // 关键引语（采访）
    case factCheck            // 待核实事实（采访）
    case followUpQuestion     // 追问线索（采访）
    case concept              // 概念（课堂）
    case example              // 例子（课堂）
    case confusingPoint       // 易混淆点（课堂）
    case reviewQuestion       // 复习问题（课堂）
    case knowledgeSeed        // 知识种子（发芽候选，阶段 F 消费）

    /// 中文显示名
    var displayName: String {
        switch self {
        case .summary: return "摘要"
        case .topic: return "主题"
        case .fact: return "事实"
        case .decision: return "决定"
        case .actionItem: return "行动项"
        case .openQuestion: return "待确认"
        case .explicitNeed: return "明确诉求"
        case .possibleConcern: return "可能顾虑"
        case .possibleMotive: return "可能动机"
        case .expressionPurpose: return "表达目的"
        case .stanceChange: return "立场变化"
        case .contradictionEvasion: return "矛盾与回避"
        case .keyQuote: return "关键引语"
        case .factCheck: return "待核实"
        case .followUpQuestion: return "追问线索"
        case .concept: return "概念"
        case .example: return "例子"
        case .confusingPoint: return "易混淆点"
        case .reviewQuestion: return "复习问题"
        case .knowledgeSeed: return "知识种子"
        }
    }

    /// 默认归属页签：整理层 → 总结；语义层与场景增强 → 动机与目的。
    /// 课堂的概念/例子/易错点/复习问题属于整理层语义，归总结页签。
    var belongsToSummaryTab: Bool {
        switch self {
        case .summary, .topic, .fact, .decision, .actionItem, .openQuestion,
             .concept, .example, .confusingPoint, .reviewQuestion, .keyQuote:
            return true
        case .explicitNeed, .possibleConcern, .possibleMotive, .expressionPurpose,
             .stanceChange, .contradictionEvasion, .factCheck, .followUpQuestion,
             .knowledgeSeed:
            return false
        }
    }
}

/// 通用分析条目（产品文档 03 号 §8.4）。
/// 纪律与 V1 一致：evidenceSegmentIds 为空或引用不存在片段的项不进 UI。
struct AnalysisItem: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var category: AnalysisItemCategory
    var text: String
    /// 涉及说话人（本地 Speaker id；模型只见代号，回来后映射）
    var subjectSpeakerId: UUID?
    /// 明确表达 / AI 推断
    var epistemicStatus: EpistemicStatus
    var confidence: Confidence
    var evidenceSegmentIds: [UUID]
    var firstObservedAt: Date
    var lastUpdatedAt: Date

    init(
        id: UUID = UUID(),
        category: AnalysisItemCategory,
        text: String,
        subjectSpeakerId: UUID? = nil,
        epistemicStatus: EpistemicStatus,
        confidence: Confidence,
        evidenceSegmentIds: [UUID],
        firstObservedAt: Date = Date(),
        lastUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.text = text
        self.subjectSpeakerId = subjectSpeakerId
        self.epistemicStatus = epistemicStatus
        self.confidence = confidence
        self.evidenceSegmentIds = evidenceSegmentIds
        self.firstObservedAt = firstObservedAt
        self.lastUpdatedAt = lastUpdatedAt
    }
}

/// 用户对分析卡片说话人归属的确认。卡片 id 会随模型重建，因此用类别与
/// 精确证据集合做稳定签名；证据变化时不把旧确认冒险迁移到新判断。
struct AnalysisSpeakerOverride: Codable, Sendable, Equatable {
    var category: AnalysisItemCategory
    var evidenceSegmentIds: [UUID]
    var speakerId: UUID
    var confirmedAt: Date

    init(
        category: AnalysisItemCategory,
        evidenceSegmentIds: [UUID],
        speakerId: UUID,
        confirmedAt: Date = Date()
    ) {
        self.category = category
        self.evidenceSegmentIds = evidenceSegmentIds.sorted {
            $0.uuidString < $1.uuidString
        }
        self.speakerId = speakerId
        self.confirmedAt = confirmedAt
    }

    func matches(_ item: AnalysisItem) -> Bool {
        category == item.category
            && evidenceSegmentIds == item.evidenceSegmentIds.sorted {
                $0.uuidString < $1.uuidString
            }
    }
}

/// 通用分析快照（产品文档 03 号 §8.4）：一次原子更新的完整结果。
/// UI 以整个快照替换，不逐字段闪烁。
final class ConversationAnalysisSnapshot: Identifiable, Codable, Sendable {
    let id: UUID
    let version: Int
    let createdAt: Date
    /// 已分析到的片段结束时间（毫秒，增量游标）
    let analyzedThroughMs: Int64
    /// 一句话总览（可空：内容不足时如实为空）
    let headline: String?
    /// 模型建议的场景（用户未手选时可采纳）
    let detectedScenario: ProjectScenario?
    let scenarioConfidence: Confidence?
    let items: [AnalysisItem]

    init(
        id: UUID = UUID(),
        version: Int,
        createdAt: Date = Date(),
        analyzedThroughMs: Int64,
        headline: String? = nil,
        detectedScenario: ProjectScenario? = nil,
        scenarioConfidence: Confidence? = nil,
        items: [AnalysisItem]
    ) {
        self.id = id
        self.version = version
        self.createdAt = createdAt
        self.analyzedThroughMs = analyzedThroughMs
        self.headline = headline
        self.detectedScenario = detectedScenario
        self.scenarioConfidence = scenarioConfidence
        self.items = items
    }
}
