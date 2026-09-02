import Foundation

/// 参会人阵营（实施计划 9.2）
enum ParticipantSide: String, Codable, Sendable, CaseIterable {
    case ours        // 我方
    case counterpart // 对方
    case neutral     // 中立

    var displayName: String {
        switch self {
        case .ours: return "我方"
        case .counterpart: return "对方"
        case .neutral: return "中立"
        }
    }
}

/// 参会人（实施计划 9.2）
/// 注意：真实姓名只存本地，云端接口只使用 cloudAlias 代号（实施计划 7.5）。
final class Participant: Identifiable, Codable {
    /// 本地主键
    var id: UUID
    /// 云端代号，如 p_01；真实姓名不作为云端参数
    var cloudAlias: String
    /// 本地显示姓名
    var displayName: String
    /// 阵营：我方 / 对方 / 中立
    var side: ParticipantSide
    /// 职位或谈判角色
    var role: String
    /// UI 颜色令牌
    var colorToken: String
    /// 本地声音样本路径（相对路径）
    var voiceReferencePath: String?
    /// 声音样本时长（毫秒），合格范围 2–10 秒
    var voiceReferenceDurationMs: Int64?
    /// 讯飞历史声纹特征 ID，随运行时会议快照固定。
    var iflytekFeatureID: String?

    init(
        id: UUID = UUID(),
        cloudAlias: String,
        displayName: String,
        side: ParticipantSide,
        role: String = "",
        colorToken: String = "gray",
        voiceReferencePath: String? = nil,
        voiceReferenceDurationMs: Int64? = nil,
        iflytekFeatureID: String? = nil
    ) {
        self.id = id
        self.cloudAlias = cloudAlias
        self.displayName = displayName
        self.side = side
        self.role = role
        self.colorToken = colorToken
        self.voiceReferencePath = voiceReferencePath
        self.voiceReferenceDurationMs = voiceReferenceDurationMs
        self.iflytekFeatureID = iflytekFeatureID
    }
}
