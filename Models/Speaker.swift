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
    /// V2 声纹样本相对路径（工作台「说话人」面板录制，2–10 秒；仅本地保存，
    /// 云端识别时随分片上传用于已知说话人匹配）
    var voiceSamplePath: String?
    /// V2 声纹样本时长（毫秒）
    var voiceSampleDurationMs: Int64?
    /// 应用级永久声纹 id；有值时样本来自独立 VoiceProfiles 目录，删除项目不删除该样本。
    var voiceProfileId: UUID?
    /// 跨录音人物 id（Person.id，12 号 §5.2 目标关联）。voiceProfileId 仅作迁移线索，
    /// 不再要求每个人都具备声音样本；两者可以同时有值（迁移后 personId == voiceProfileId）。
    var personId: UUID?
    /// 讯飞声纹分离特征 ID；不是姓名或密钥。
    var iflytekFeatureID: String?
    /// 用户人工补充的人物背景；随永久人物档案跨会议复用。
    var backgroundContext: String?
    /// 基于已标注原话生成的可观察表达与沟通画像。
    var communicationProfile: SpeakerCommunicationProfile?
    /// 全局人物库中经用户确认的“我”，供 AI 跨项目读取连续上下文。
    var isCurrentUser: Bool?

    init(
        id: UUID = UUID(),
        cloudAlias: String,
        displayName: String,
        role: String? = nil,
        colorToken: String = "gray",
        isUserConfirmed: Bool = false,
        legacySide: String? = nil,
        legacyVoiceReferencePath: String? = nil,
        legacyVoiceReferenceDurationMs: Int64? = nil,
        voiceSamplePath: String? = nil,
        voiceSampleDurationMs: Int64? = nil,
        voiceProfileId: UUID? = nil,
        personId: UUID? = nil,
        iflytekFeatureID: String? = nil,
        backgroundContext: String? = nil,
        communicationProfile: SpeakerCommunicationProfile? = nil,
        isCurrentUser: Bool? = nil
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
        self.voiceSamplePath = voiceSamplePath
        self.voiceSampleDurationMs = voiceSampleDurationMs
        self.voiceProfileId = voiceProfileId
        self.personId = personId
        self.iflytekFeatureID = iflytekFeatureID
        self.backgroundContext = backgroundContext
        self.communicationProfile = communicationProfile
        self.isCurrentUser = isCurrentUser
    }
}
