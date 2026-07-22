import Foundation

/// 旧 Meeting 专属字段的完整存档（产品文档 03 号 §15.1：旧字段不得丢失）。
///
/// 知识花园版不再把"谈判背景 / 我方目标 / 底线 / 对方背景"作为主流程字段，
/// 但迁移时必须完整保留，供历史项目回看与后续可能的再利用。
/// 这些字段不进入主 UI，只作为 legacy metadata 挂载在 Project 上。
struct LegacyMeetingMetadata: Codable, Sendable, Hashable {
    /// 旧谈判背景
    var background: String
    /// 旧我方目标
    var ourGoal: String
    /// 旧我方底线
    var ourBottomLine: String
    /// 旧对方背景
    var counterpartContext: String
    /// 旧专业词汇表
    var glossary: [String]
    /// 旧用户确认云端音频处理的时间
    var audioUploadConsentAt: Date?
    /// 旧增量分析游标：已分析到的片段结束毫秒
    var lastAnalyzedSegmentEndMs: Int64

    init(
        background: String = "",
        ourGoal: String = "",
        ourBottomLine: String = "",
        counterpartContext: String = "",
        glossary: [String] = [],
        audioUploadConsentAt: Date? = nil,
        lastAnalyzedSegmentEndMs: Int64 = 0
    ) {
        self.background = background
        self.ourGoal = ourGoal
        self.ourBottomLine = ourBottomLine
        self.counterpartContext = counterpartContext
        self.glossary = glossary
        self.audioUploadConsentAt = audioUploadConsentAt
        self.lastAnalyzedSegmentEndMs = lastAnalyzedSegmentEndMs
    }
}
