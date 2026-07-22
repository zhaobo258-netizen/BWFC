import Foundation

/// V2 说话人（产品文档 03 号 §8.2）。
/// 由旧 Participant 迁移而来；真实姓名只存本地，云端只使用 cloudAlias 代号。
final class Speaker: Identifiable, Codable {
    /// 本地主键（迁移时保留旧 Participant id）
    var id: UUID
    /// 云端代号，如 p_01；真实姓名不作为云端参数
    var cloudAlias: String
    /// 本地显示姓名
    var displayName: String
    /// 职位或角色（可空）
    var role: String?
    /// UI 颜色令牌
    var colorToken: String
    /// 是否为用户手工确认（旧参与者均为用户录入，迁移时为 true）
    var isUserConfirmed: Bool
    /// 旧 Participant.side 的原始值，仅作 legacy metadata 保留，不进入主 UI
    var legacySide: String?
    /// 旧声音样本相对路径（仅 legacy 保留，指向未被移动的旧样本文件；V2 不再强依赖会前样本）
    var legacyVoiceReferencePath: String?
    /// 旧声音样本时长（毫秒）
    var legacyVoiceReferenceDurationMs: Int64?

    init(
        id: UUID = UUID(),
        cloudAlias: String,
        displayName: String,
        role: String? = nil,
        colorToken: String = "gray",
        isUserConfirmed: Bool = false,
        legacySide: String? = nil,
        legacyVoiceReferencePath: String? = nil,
        legacyVoiceReferenceDurationMs: Int64? = nil
    ) {
        self.id = id
        self.cloudAlias = cloudAlias
        self.displayName = displayName
        self.role = role
        self.colorToken = colorToken
        self.isUserConfirmed = isUserConfirmed
        self.legacySide = legacySide
        self.legacyVoiceReferencePath = legacyVoiceReferencePath
        self.legacyVoiceReferenceDurationMs = legacyVoiceReferenceDurationMs
    }
}
