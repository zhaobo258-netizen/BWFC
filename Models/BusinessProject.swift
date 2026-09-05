import Foundation

/// 轻 CRM 业务项目（产品文档 12 号 §7.2）：阶段 D 引入的稳定实体。
/// 关联已有录音与人物，不复制录音；跟进项和项目记忆先内嵌。
/// 现有 `Project.businessCategory` 字符串保留为标签；迁移时同名仅提出归组建议。
struct BusinessProject: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    /// 目标说明：要达成什么
    var goalStatement: String?
    /// 参与人物（Person.id 列表）
    var participantPersonIDs: [UUID]
    /// 关联录音（Project.id 列表；不复制录音，只保存引用）
    var linkedProjectIDs: [UUID]
    /// 有效背景（人工确认的项目级背景）
    var backgroundContext: String?
    /// 跟进事项（内嵌；12 号 §7.3）
    var followUps: [FollowUp]
    /// 业务项目级记忆（作用域限定在本项目）
    var memoryEntries: [MemoryEntry]
    var status: BusinessProjectStatus
    var createdAt: Date
    var updatedAt: Date
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        goalStatement: String? = nil,
        participantPersonIDs: [UUID] = [],
        linkedProjectIDs: [UUID] = [],
        backgroundContext: String? = nil,
        followUps: [FollowUp] = [],
        memoryEntries: [MemoryEntry] = [],
        status: BusinessProjectStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.goalStatement = goalStatement
        self.participantPersonIDs = participantPersonIDs
        self.linkedProjectIDs = linkedProjectIDs
        self.backgroundContext = backgroundContext
        self.followUps = followUps
        self.memoryEntries = memoryEntries
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
    }

    /// 未完成跟进（待跟进或进行中）
    var openFollowUps: [FollowUp] {
        followUps.filter { $0.handlingStatus != .completed }
    }

    /// 已过期未完成的跟进
    var overdueFollowUps: [FollowUp] {
        let now = Date()
        return followUps.filter {
            $0.handlingStatus != .completed && ($0.dueDate ?? .distantFuture) < now
        }
    }

    var activeMemories: [MemoryEntry] {
        let now = Date()
        return memoryEntries.filter {
            $0.status == .active
                && ($0.effectiveFrom == nil || $0.effectiveFrom! <= now)
                && ($0.effectiveUntil == nil || $0.effectiveUntil! >= now)
        }
    }
}

enum BusinessProjectStatus: String, Codable, Sendable, CaseIterable {
    case active
    case archived

    var displayName: String {
        switch self {
        case .active: return "进行中"
        case .archived: return "已归档"
        }
    }
}

/// 跟进事项的确认状态（12 号 §7.3：AI 提取只生成候选，老板确认后才进入待跟进）
enum FollowUpConfirmationStatus: String, Codable, Sendable {
    case candidate   // 候选（AI 提出，未确认）
    case confirmed   // 老板已确认
}

/// 跟进事项的处理状态（12 号 §7.3：完成需要记录实际结果）
enum FollowUpHandlingStatus: String, Codable, Sendable, CaseIterable {
    case pending     // 待跟进
    case inProgress  // 进行中
    case completed   // 已完成（有结果记录）

    var displayName: String {
        switch self {
        case .pending: return "待跟进"
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        }
    }
}

/// 跟进事项来源证据
struct FollowUpSourceReference: Codable, Sendable, Equatable {
    var recordingID: UUID
    var segmentID: UUID
    var snippet: String
    var sourceVersion: String?

    init(recordingID: UUID, segmentID: UUID, snippet: String, sourceVersion: String? = nil) {
        self.recordingID = recordingID
        self.segmentID = segmentID
        self.snippet = String(snippet.prefix(300))
        self.sourceVersion = sourceVersion
    }
}

/// 跟进事项（12 号 §7.3，内嵌于业务项目）。
/// AI 提取只生成候选；原话没有责任人或期限时留空，不能补一个看似合理的值。
struct FollowUp: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    /// 事项内容
    var title: String
    /// 责任人（Person.id；老板本人时指向“我”的 Person）
    var ownerPersonID: UUID?
    /// 原话中的责任人文本（供展示；无证据时为 nil）
    var ownerDisplayText: String?
    /// 期限（原话明确出现才填；nil 表示未定期限）
    var dueDate: Date?
    /// 来源证据
    var source: FollowUpSourceReference?
    var confirmationStatus: FollowUpConfirmationStatus
    var handlingStatus: FollowUpHandlingStatus
    /// 实际结果（完成时记录；点击完成不等于客户已接受）
    var resultNote: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        ownerPersonID: UUID? = nil,
        ownerDisplayText: String? = nil,
        dueDate: Date? = nil,
        source: FollowUpSourceReference? = nil,
        confirmationStatus: FollowUpConfirmationStatus = .confirmed,
        handlingStatus: FollowUpHandlingStatus = .pending,
        resultNote: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.ownerPersonID = ownerPersonID
        self.ownerDisplayText = ownerDisplayText
        self.dueDate = dueDate
        self.source = source
        self.confirmationStatus = confirmationStatus
        self.handlingStatus = handlingStatus
        self.resultNote = resultNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

/// 跟进候选（AI 从录音提出、存放在来源 Project 上，确认后进入业务项目）
struct FollowUpCandidate: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    /// 事项内容
    var title: String
    /// 原话中的责任人文本（没有证据时为 nil——不能补一个看似合理的值）
    var ownerDisplayText: String?
    /// 原话中的期限（没有证据时为 nil）
    var dueDate: Date?
    var evidenceSegmentID: UUID
    var evidenceSnippet: String
    var sourceVersion: String?
    var status: PendingCandidateStatus
    var resolvedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        ownerDisplayText: String?,
        dueDate: Date?,
        evidenceSegmentID: UUID,
        evidenceSnippet: String,
        sourceVersion: String? = nil,
        status: PendingCandidateStatus = .pending,
        resolvedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.ownerDisplayText = ownerDisplayText
        self.dueDate = dueDate
        self.evidenceSegmentID = evidenceSegmentID
        self.evidenceSnippet = String(evidenceSnippet.prefix(300))
        self.sourceVersion = sourceVersion
        self.status = status
        self.resolvedAt = resolvedAt
        self.createdAt = createdAt
    }
}
