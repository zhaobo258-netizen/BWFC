import Foundation

/// 独立人物（产品文档 12 号 §5）：跨录音的稳定身份，独立于声纹。
/// `Person.id` 是跨录音关联的唯一依据；姓名只是可修改的显示字段。
/// 声音样本是 Person 的可选附件（`linkedVoiceProfileID`），不是存在前提。
struct Person: Identifiable, Codable, Sendable, Equatable {
    /// 永久人物 ID；一经创建不再变化
    var id: UUID
    /// 显示姓名（可修改；同名不自动合并）
    var displayName: String
    /// 职位或角色（人工背景）
    var role: String?
    /// UI 颜色令牌
    var colorToken: String
    /// 人工背景：老板确认的长期背景与偏好（来源恒为“人工背景”，不冒充录音原话）
    var backgroundContext: String?
    /// 老板明确指定的“这是我”；同一人物库最多一个
    var isCurrentUser: Bool
    /// 可选的声纹附件（SpeakerVoiceProfile.id）；无声纹的人物该值为 nil
    var linkedVoiceProfileID: UUID?
    var additionalVoiceProfileIDs: [UUID]?

    var voiceProfileIDs: Set<UUID> {
        Set(([linkedVoiceProfileID].compactMap { $0 }) + (additionalVoiceProfileIDs ?? []))
    }
    /// 跨录音说话人关联（Speaker.personId -> Person.id 的反向账本）
    var speakerLinks: [PersonSpeakerLink]
    /// 内嵌业务记忆（12 号 §6.4：先作为值对象，不另建通用记忆平台）
    var memoryEntries: [MemoryEntry]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        role: String? = nil,
        colorToken: String = "gray",
        backgroundContext: String? = nil,
        isCurrentUser: Bool = false,
        linkedVoiceProfileID: UUID? = nil,
        additionalVoiceProfileIDs: [UUID]? = nil,
        speakerLinks: [PersonSpeakerLink] = [],
        memoryEntries: [MemoryEntry] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.colorToken = colorToken
        self.backgroundContext = backgroundContext
        self.isCurrentUser = isCurrentUser
        self.linkedVoiceProfileID = linkedVoiceProfileID
        self.additionalVoiceProfileIDs = additionalVoiceProfileIDs
        self.speakerLinks = speakerLinks
        self.memoryEntries = memoryEntries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 当前有效（active 且未过期）的记忆，读取侧统一从这里取。
    var activeMemories: [MemoryEntry] {
        let now = Date()
        return memoryEntries.filter { entry in
            entry.status == .active
                && (entry.effectiveFrom == nil || entry.effectiveFrom! <= now)
                && (entry.effectiveUntil == nil || entry.effectiveUntil! >= now)
        }
    }
}

/// 人物与某一场录音里某个说话人槽位的关联账本。
/// lifecycle：建立于人工指认/迁移；删除录音只解除关联，不删人物。
struct PersonSpeakerLink: Codable, Sendable, Equatable, Identifiable {
    var projectID: UUID
    var speakerID: UUID
    /// 冗余的显示名，供人物页在不加载项目时展示
    var speakerDisplayName: String
    var linkedAt: Date

    var id: String { "\(projectID.uuidString)-\(speakerID.uuidString)" }
}

/// 记忆种类（12 号 §6.2 四种高价值信息）。
/// rawValue 对齐模型输出合同（snake_case）。
enum MemoryKind: String, Codable, Sendable, CaseIterable {
    case manualBackground = "manual_background"      // 人工背景
    case terminology                               // 口径与术语
    case confirmedConstraint = "confirmed_constraint" // 已确认约束
    case ongoingTopic = "ongoing_topic"              // 持续事项

    var displayName: String {
        switch self {
        case .manualBackground: return "人工背景"
        case .terminology: return "口径与术语"
        case .confirmedConstraint: return "已确认约束"
        case .ongoingTopic: return "持续事项"
        }
    }
}

/// 记忆状态（12 号 §6.4：没有自动永久有效的默认值）
enum MemoryStatus: String, Codable, Sendable, CaseIterable {
    case candidate    // 候选：等待老板确认
    case active       // 有效：参与后续上下文
    case needsReview  // 需复核：来源或依赖发生变化
    case superseded   // 已取代：被新版本顶替，仍可查看
    case rejected     // 已拒绝：退出上下文，且不得被自动重建

    var displayName: String {
        switch self {
        case .candidate: return "候选"
        case .active: return "有效"
        case .needsReview: return "需复核"
        case .superseded: return "已取代"
        case .rejected: return "已拒绝"
        }
    }
}

/// 记忆作用域：适用范围（12 号 §6.2 默认作用域）
struct MemoryScope: Codable, Sendable, Equatable {
    /// 人物作用域（nil 表示不限定人物）
    var personID: UUID?
    /// 业务项目作用域（nil 表示不限定业务项目）
    var businessProjectID: UUID?
    /// 展示用说明（如“人物：张三”或“业务项目：满分便利店”）
    var displayText: String

    /// 是否适用于给定上下文（人物与业务项目双匹配）
    func applies(toPerson personID: UUID?, businessProjectID: UUID?) -> Bool {
        if let scopedPerson = self.personID, scopedPerson != personID { return false }
        if let scopedProject = self.businessProjectID, scopedProject != businessProjectID {
            return false
        }
        return true
    }
}

/// 可定位证据引用（12 号 §3.2）：保存稳定引用与必要摘要，不复制全部原文。
struct MemorySourceReference: Codable, Sendable, Equatable {
    /// 来源录音（Project.id）
    var recordingID: UUID
    var segmentID: UUID
    /// 原话必要摘要（复核用；定位以 recordingID+segmentID 为准）
    var snippet: String
    /// 建立该记忆时的源内容版本标记（如报告版本号）
    var sourceVersion: String?

    init(recordingID: UUID, segmentID: UUID, snippet: String, sourceVersion: String? = nil) {
        self.recordingID = recordingID
        self.segmentID = segmentID
        self.snippet = String(snippet.prefix(300))
        self.sourceVersion = sourceVersion
    }
}

/// 一条业务记忆（12 号 §6.4）。更新保留“取代哪一条”的关系，
/// 读取时只选适用范围内的有效版本。
struct MemoryEntry: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    /// 拟收录/已收录内容（用老板视角的陈述句）
    var content: String
    var kind: MemoryKind
    var scope: MemoryScope
    var source: MemorySourceReference?
    /// 人工直接创建（无录音来源）时为 true；来源类别是“人工背景”
    var isManuallyAuthored: Bool
    var status: MemoryStatus
    var confirmedAt: Date?
    var effectiveFrom: Date?
    var effectiveUntil: Date?
    var version: Int
    /// 本条取代的旧条目 ID
    var supersedesEntryID: UUID?
    var createdAt: Date
    var updatedAt: Date
    /// 需复核原因（status == .needsReview 时显示）
    var reviewReason: String?

    init(
        id: UUID = UUID(),
        content: String,
        kind: MemoryKind,
        scope: MemoryScope,
        source: MemorySourceReference? = nil,
        isManuallyAuthored: Bool = false,
        status: MemoryStatus = .candidate,
        confirmedAt: Date? = nil,
        effectiveFrom: Date? = nil,
        effectiveUntil: Date? = nil,
        version: Int = 1,
        supersedesEntryID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        reviewReason: String? = nil
    ) {
        self.id = id
        self.content = content
        self.kind = kind
        self.scope = scope
        self.source = source
        self.isManuallyAuthored = isManuallyAuthored
        self.status = status
        self.confirmedAt = confirmedAt
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.version = version
        self.supersedesEntryID = supersedesEntryID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reviewReason = reviewReason
    }
}

/// 待确认候选的处置状态（记忆候选与跟进候选共用）
enum PendingCandidateStatus: String, Codable, Sendable, CaseIterable {
    case pending       // 待确认
    case confirmed     // 已确认（已进入人物/业务项目）
    case keptLocalOnly // 仅留本场（不升级为长期记忆）
    case rejected      // 已拒绝

    var displayName: String {
        switch self {
        case .pending: return "待确认"
        case .confirmed: return "已确认"
        case .keptLocalOnly: return "仅留本场"
        case .rejected: return "已拒绝"
        }
    }
}

/// 业务记忆候选（12 号 §6.3）：录音完成后 AI 提出、默认不写入有效记忆。
/// 存放在来源 Project 上；确认后升级为 Person.memoryEntries（active）。
struct BusinessMemoryCandidate: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    /// 拟归属人物（证据片段说话人的 personId；未关联人物时为 nil）
    var targetPersonID: UUID?
    /// 拟归属人物显示名（说话人显示名，供 UI 展示）
    var targetPersonDisplayName: String?
    var kind: MemoryKind
    /// 拟收录内容
    var statement: String
    /// 作用域说明（默认“人物”或“人物 + 业务项目”）
    var scopeDescription: String
    var targetBusinessProjectID: UUID?
    var requiresBusinessProjectScope: Bool?
    var sourceVersion: String?
    /// 收录原因
    var reason: String
    var evidenceSegmentID: UUID
    var evidenceSnippet: String
    /// 与现有有效记忆是否冲突
    var conflictsWithExisting: Bool
    var status: PendingCandidateStatus
    var resolvedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        targetPersonID: UUID?,
        targetPersonDisplayName: String?,
        kind: MemoryKind,
        statement: String,
        scopeDescription: String,
        reason: String,
        evidenceSegmentID: UUID,
        evidenceSnippet: String,
        targetBusinessProjectID: UUID? = nil,
        requiresBusinessProjectScope: Bool? = nil,
        sourceVersion: String? = nil,
        conflictsWithExisting: Bool = false,
        status: PendingCandidateStatus = .pending,
        resolvedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetPersonID = targetPersonID
        self.targetPersonDisplayName = targetPersonDisplayName
        self.kind = kind
        self.statement = statement
        self.scopeDescription = scopeDescription
        self.targetBusinessProjectID = targetBusinessProjectID
        self.requiresBusinessProjectScope = requiresBusinessProjectScope
        self.sourceVersion = sourceVersion
        self.reason = reason
        self.evidenceSegmentID = evidenceSegmentID
        self.evidenceSnippet = String(evidenceSnippet.prefix(300))
        self.conflictsWithExisting = conflictsWithExisting
        self.status = status
        self.resolvedAt = resolvedAt
        self.createdAt = createdAt
    }
}
