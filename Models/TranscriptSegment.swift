import Foundation

/// 片段来源（实施计划 9.3）
enum SegmentSource: String, Codable, Sendable {
    case local  // Apple Speech 本地转写
    case cloud  // 云端说话人识别确认
    case manual // 人工修改
}

/// 片段状态（实施计划 9.3）
enum SegmentState: String, Codable, Sendable {
    case provisional // 临时（本地即时文字，较浅颜色显示）
    case final       // 最终（云端已确认）
    case edited      // 人工已修订（不再被云端结果覆盖）
    case failed      // 云端处理失败，待重试

    var displayName: String {
        switch self {
        case .provisional: return "识别中"
        case .final: return "已确认"
        case .edited: return "人工已修订"
        case .failed: return "待重试"
        }
    }
}

/// 转写片段（实施计划 9.3）
final class TranscriptSegment: Identifiable, Codable {
    /// 稳定片段 ID，也是分析证据 ID
    var id: UUID
    /// 相对会议开始时间的起始毫秒
    var startMs: Int64
    /// 相对会议开始时间的结束毫秒
    var endMs: Int64
    /// 当前权威文本
    var text: String
    /// 已映射参会人 ID（未匹配时为空，显示「待识别」）
    var participantId: UUID?
    /// 云端原始说话人标签（本地代号）
    var remoteSpeakerLabel: String?
    /// 片段来源
    var source: SegmentSource
    /// 片段状态
    var state: SegmentState
    /// 用户星标
    var isStarred: Bool
    /// 审计时间：创建
    var createdAt: Date
    /// 审计时间：最近更新
    var updatedAt: Date

    // MARK: - V2 新增可选字段（产品文档 03 号 §8.3；合成 Codable 自动容忍缺失）

    /// 说话人识别置信度（低/中/高；未识别时为 nil）
    var speakerConfidence: Confidence?
    /// 片段语言代码（如 zh-CN；未识别时为 nil）
    var languageCode: String?
    /// 来源资产 ID（多资产项目中标注片段出自哪份素材）
    var sourceAssetId: UUID?
    /// 仅文字被用户人工修改时为 true；说话人确认不能再锁死云端分段与文字更新。
    var textWasUserEdited: Bool?
    /// 说话人由用户明确确认；云端可更新文字/边界，但不得覆盖此归属。
    var speakerWasUserConfirmed: Bool?

    init(
        id: UUID = UUID(),
        startMs: Int64,
        endMs: Int64,
        text: String,
        participantId: UUID? = nil,
        remoteSpeakerLabel: String? = nil,
        source: SegmentSource,
        state: SegmentState,
        isStarred: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        speakerConfidence: Confidence? = nil,
        languageCode: String? = nil,
        sourceAssetId: UUID? = nil,
        textWasUserEdited: Bool? = nil,
        speakerWasUserConfirmed: Bool? = nil
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.participantId = participantId
        self.remoteSpeakerLabel = remoteSpeakerLabel
        self.source = source
        self.state = state
        self.isStarred = isStarred
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.speakerConfidence = speakerConfidence
        self.languageCode = languageCode
        self.sourceAssetId = sourceAssetId
        self.textWasUserEdited = textWasUserEdited
        self.speakerWasUserConfirmed = speakerWasUserConfirmed
    }
}
