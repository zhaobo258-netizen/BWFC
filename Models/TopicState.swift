import Foundation

/// 议题推进状态
enum TopicStatus: String, Codable, Sendable, CaseIterable {
    case discussing // 讨论中
    case confirmed  // 已达成一致
    case open       // 未决

    var displayName: String {
        switch self {
        case .discussing: return "讨论中"
        case .confirmed: return "已确认"
        case .open: return "未决"
        }
    }
}

/// 议题状态（左侧结构总结的议题树节点）
final class TopicState: Identifiable, Codable {
    /// 主键
    var id: UUID
    /// 议题标题
    var title: String
    /// 推进状态
    var status: TopicStatus
    /// 证据片段 ID 列表
    var evidenceSegmentIds: [UUID]
    /// 显示顺序
    var order: Int

    init(
        id: UUID = UUID(),
        title: String,
        status: TopicStatus = .discussing,
        evidenceSegmentIds: [UUID] = [],
        order: Int = 0
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.evidenceSegmentIds = evidenceSegmentIds
        self.order = order
    }

    /// 证据有效性：空证据视为无效
    var hasValidEvidence: Bool { !evidenceSegmentIds.isEmpty }
}
