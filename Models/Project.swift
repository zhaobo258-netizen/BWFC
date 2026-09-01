import Foundation

/// 项目来源类型（产品文档 03 号 §8.1）
enum ProjectSourceType: String, Codable, Sendable, CaseIterable {
    case liveRecording  // 实时录音
    case importedAudio  // 导入音频
    case importedVideo  // 导入视频
    case combinedRecordings // 由多段录音派生的跨录音分析

    var isImportedMedia: Bool {
        self == .importedAudio || self == .importedVideo
    }

    var isCombinedAnalysis: Bool {
        self == .combinedRecordings
    }
}

/// 合并分析中的原始录音引用。时间偏移让汇总文稿保持先后顺序，
/// 同时可以还原到每段录音内的原始时间戳。
struct SourceRecordingReference: Identifiable, Codable, Sendable, Hashable {
    var projectID: UUID
    var title: String
    var recordedAt: Date
    var timelineOffsetMs: Int64
    var durationMs: Int64

    var id: UUID { projectID }
}

/// 项目场景（产品文档 03 号 §8.1）
enum ProjectScenario: String, Codable, Sendable, CaseIterable {
    case clientVisit         // 客户拜访
    case internalMeeting     // 内部会议
    case classLearning       // 课堂培训
    case journalistInterview // 访谈采访
    case freeform            // 自由记录

    /// 中文显示名
    var displayName: String {
        switch self {
        case .clientVisit: return "客户拜访"
        case .internalMeeting: return "内部会议"
        case .classLearning: return "课堂培训"
        case .journalistInterview: return "访谈采访"
        case .freeform: return "自由记录"
        }
    }
}

/// 项目状态（产品文档 03 号 §7.1 / §8.1）
enum ProjectStatus: String, Codable, Sendable, CaseIterable {
    case creating           // 创建中：资产准备或信息未齐
    case recording          // 录音中
    case paused             // 已暂停
    case processing         // 处理中（转写 / 分人 / 分析）
    case ready              // 就绪：可浏览、修订与归档
    case readyWithWarnings  // 就绪但存在告警（部分任务失败等）
    case failed             // 失败：资产损坏或处理不可恢复

    /// 中文显示名
    var displayName: String {
        switch self {
        case .creating: return "创建中"
        case .recording: return "录音中"
        case .paused: return "已暂停"
        case .processing: return "处理中"
        case .ready: return "就绪"
        case .readyWithWarnings: return "就绪（有告警）"
        case .failed: return "失败"
        }
    }

    /// 异常退出恢复时需要提示用户的「未正常结束」状态（产品文档 03 号 §7.1 的 Recoverable）
    var isAbnormalIfAppRelaunched: Bool {
        switch self {
        case .recording, .paused, .processing: return true
        case .creating, .ready, .readyWithWarnings, .failed: return false
        }
    }
}

/// 项目笔记文档（产品文档 03 号 §8.4）
struct NoteDocument: Codable, Sendable, Hashable {
    /// Markdown 正文
    var markdown: String
    /// 最近更新时间
    var updatedAt: Date
    /// 最近一次同步到归档的正文哈希（用于变更检测）
    var lastSyncedHash: String?

    init(markdown: String = "", updatedAt: Date = Date(), lastSyncedHash: String? = nil) {
        self.markdown = markdown
        self.updatedAt = updatedAt
        self.lastSyncedHash = lastSyncedHash
    }
}

enum ConversationAnalysisSnapshotRetention {
    static let maximumCount = 5

    static func keepingMostRecent(
        _ snapshots: [ConversationAnalysisSnapshot]
    ) -> [ConversationAnalysisSnapshot] {
        Array(snapshots.suffix(maximumCount))
    }
}

/// V2 项目（产品文档 03 号 §8.1）：一次对话/一份素材的完整载体。
/// schemaVersion 当前为 2；V1（Meeting）数据经 ProjectMigration 一次性迁移。
/// 新增存储属性必须同步登记 ProjectRuntimeSession.applyRuntime、
/// ProjectPersistence.fieldOwnership 与 ProjectWorkspaceView.reloadImportedProjectFromStore。
final class Project: Identifiable, Codable {
    /// 数据结构版本（V2 恒为 2）
    var schemaVersion: Int
    /// 主键（迁移时保留旧 Meeting id）
    var id: UUID
    /// 项目标题
    var title: String
    /// 业务项目/业务范畴。nil 表示尚未分组。
    var businessCategory: String?
    /// 来源类型
    var sourceType: ProjectSourceType
    /// 跨录音合并分析的原始录音。普通录音/导入项目为空。
    var sourceRecordings: [SourceRecordingReference]
    /// 场景（未识别或未选择时为 nil）
    var scenario: ProjectScenario?
    /// 场景是否为用户手工选择（区别于自动推断）
    var scenarioWasUserSelected: Bool
    /// 项目状态
    var status: ProjectStatus
    /// 创建时间
    var createdAt: Date
    /// 开始时间（录音开始 / 素材开始处理）
    var startedAt: Date?
    /// 结束时间
    var endedAt: Date?
    /// 最近活动时间（列表排序用）
    var lastActivityAt: Date
    /// 运行时资产相对路径（录音 / 提取音频等，仅存相对路径）
    var runtimeAssetRelativePath: String?
    /// 导入素材的原始文件名（实时录音为 nil）
    var originalFileName: String?
    /// 时长（毫秒）。口径：会议墙钟时间轴，包含暂停区间；
    /// 不等于媒体文件实际时长——阶段 B 播放条必须另行获取真实媒体时长，两个口径不得混用
    var durationMs: Int64
    /// 会前选择的音频输入设备 ID（nil 表示系统默认）
    var preferredInputDeviceID: String?
    /// 录音暂停区间（时间轴毫秒）
    var pauseIntervals: [PauseInterval]
    /// 说话人
    var speakers: [Speaker] = []
    /// 转写片段
    var segments: [TranscriptSegment] = []
    /// 旧谈判分析快照：按 legacy 原样保留，供历史数据回看
    var legacySnapshots: [AnalysisSnapshot] = []
    /// V2 通用分析快照（阶段 D，03 §8.4）：新分析的权威存储
    var analysisSnapshots: [ConversationAnalysisSnapshot] = []
    /// 用户确认的分析卡片说话人归属；跨后续增量快照保留。
    var analysisSpeakerOverrides: [AnalysisSpeakerOverride] = []
    /// AI 全文复查产生、尚未由用户处理的转写更正候选。
    var transcriptReviewCandidates: [TranscriptReviewCandidate] = []
    /// 录音或导入完成后的完整总结；与实时分析快照分开版本化
    var finalReportSnapshots: [FinalReportSnapshot] = []
    /// 由分析条目继续延展的知识种子、联想分支与真实来源
    var knowledgeSeeds: [KnowledgeSeed] = []
    /// 用户在 AI 工作区补充的背景/纠正，以及 AI 的项目级回应
    var aiChatMessages: [ProjectAIChatMessage] = []
    /// AI 共创笔记中尚未发送的本机草稿
    var aiChatDraft: String = ""
    /// 用户是否明确允许 AI 共创、开花和完整总结读取此前笔记
    var noteAIContextEnabled: Bool = false
    /// 旧 Meeting 专属字段存档（谈判背景/目标/底线/词汇等）；迁移时必有值，新建 V2 项目为 nil
    var legacyMetadata: LegacyMeetingMetadata?
    /// 项目笔记
    var note: NoteDocument
    /// 后台处理任务流水
    var processingJobs: [ProcessingJob]
    /// Obsidian 归档状态
    var archive: ArchiveState

    init(
        schemaVersion: Int = 2,
        id: UUID = UUID(),
        title: String,
        businessCategory: String? = nil,
        sourceType: ProjectSourceType,
        sourceRecordings: [SourceRecordingReference] = [],
        scenario: ProjectScenario? = nil,
        scenarioWasUserSelected: Bool = false,
        status: ProjectStatus = .creating,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        lastActivityAt: Date = Date(),
        runtimeAssetRelativePath: String? = nil,
        originalFileName: String? = nil,
        durationMs: Int64 = 0,
        preferredInputDeviceID: String? = nil,
        pauseIntervals: [PauseInterval] = [],
        speakers: [Speaker] = [],
        segments: [TranscriptSegment] = [],
        legacySnapshots: [AnalysisSnapshot] = [],
        analysisSnapshots: [ConversationAnalysisSnapshot] = [],
        analysisSpeakerOverrides: [AnalysisSpeakerOverride] = [],
        transcriptReviewCandidates: [TranscriptReviewCandidate] = [],
        finalReportSnapshots: [FinalReportSnapshot] = [],
        knowledgeSeeds: [KnowledgeSeed] = [],
        aiChatMessages: [ProjectAIChatMessage] = [],
        aiChatDraft: String = "",
        noteAIContextEnabled: Bool = false,
        legacyMetadata: LegacyMeetingMetadata? = nil,
        note: NoteDocument = NoteDocument(markdown: "", updatedAt: Date()),
        processingJobs: [ProcessingJob] = [],
        archive: ArchiveState = ArchiveState()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.businessCategory = businessCategory
        self.sourceType = sourceType
        self.sourceRecordings = sourceRecordings
        self.scenario = scenario
        self.scenarioWasUserSelected = scenarioWasUserSelected
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastActivityAt = lastActivityAt
        self.runtimeAssetRelativePath = runtimeAssetRelativePath
        self.originalFileName = originalFileName
        self.durationMs = durationMs
        self.preferredInputDeviceID = preferredInputDeviceID
        self.pauseIntervals = pauseIntervals
        self.speakers = speakers
        self.segments = segments
        self.legacySnapshots = legacySnapshots
        self.analysisSnapshots = analysisSnapshots
        self.analysisSpeakerOverrides = analysisSpeakerOverrides
        self.transcriptReviewCandidates = transcriptReviewCandidates
        self.finalReportSnapshots = finalReportSnapshots
        self.knowledgeSeeds = knowledgeSeeds
        self.aiChatMessages = aiChatMessages
        self.aiChatDraft = aiChatDraft
        self.noteAIContextEnabled = noteAIContextEnabled
        self.legacyMetadata = legacyMetadata
        self.note = note
        self.processingJobs = processingJobs
        self.archive = archive
    }

    // 自定义解码：可选/新增字段允许缺失并回退默认值，保证旧 JSON 可读
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        businessCategory = try container.decodeIfPresent(String.self, forKey: .businessCategory)
        sourceType = try container.decode(ProjectSourceType.self, forKey: .sourceType)
        sourceRecordings = try container.decodeIfPresent(
            [SourceRecordingReference].self,
            forKey: .sourceRecordings
        ) ?? []
        scenario = try container.decodeIfPresent(ProjectScenario.self, forKey: .scenario)
        scenarioWasUserSelected = try container.decodeIfPresent(Bool.self, forKey: .scenarioWasUserSelected) ?? false
        status = try container.decode(ProjectStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        runtimeAssetRelativePath = try container.decodeIfPresent(String.self, forKey: .runtimeAssetRelativePath)
        originalFileName = try container.decodeIfPresent(String.self, forKey: .originalFileName)
        durationMs = try container.decode(Int64.self, forKey: .durationMs)
        preferredInputDeviceID = try container.decodeIfPresent(String.self, forKey: .preferredInputDeviceID)
        pauseIntervals = try container.decodeIfPresent([PauseInterval].self, forKey: .pauseIntervals) ?? []
        speakers = try container.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        legacySnapshots = try container.decodeIfPresent([AnalysisSnapshot].self, forKey: .legacySnapshots) ?? []
        // 兼容阶段 D 之前的 Project JSON（无 analysisSnapshots 键）
        analysisSnapshots = try container.decodeIfPresent([ConversationAnalysisSnapshot].self, forKey: .analysisSnapshots) ?? []
        analysisSpeakerOverrides = try container.decodeIfPresent(
            [AnalysisSpeakerOverride].self,
            forKey: .analysisSpeakerOverrides
        ) ?? []
        transcriptReviewCandidates = try container.decodeIfPresent(
            [TranscriptReviewCandidate].self,
            forKey: .transcriptReviewCandidates
        ) ?? []
        finalReportSnapshots = try container.decodeIfPresent(
            [FinalReportSnapshot].self,
            forKey: .finalReportSnapshots
        ) ?? []
        knowledgeSeeds = try container.decodeIfPresent([KnowledgeSeed].self, forKey: .knowledgeSeeds) ?? []
        aiChatMessages = try container.decodeIfPresent(
            [ProjectAIChatMessage].self,
            forKey: .aiChatMessages
        ) ?? []
        aiChatDraft = try container.decodeIfPresent(
            String.self,
            forKey: .aiChatDraft
        ) ?? ""
        noteAIContextEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .noteAIContextEnabled
        ) ?? false
        // 兼容补强前生成的 Project JSON（无 legacyMetadata 键）
        legacyMetadata = try container.decodeIfPresent(LegacyMeetingMetadata.self, forKey: .legacyMetadata)
        note = try container.decodeIfPresent(NoteDocument.self, forKey: .note) ?? NoteDocument(markdown: "", updatedAt: createdAt)
        processingJobs = try container.decodeIfPresent([ProcessingJob].self, forKey: .processingJobs) ?? []
        archive = try container.decodeIfPresent(ArchiveState.self, forKey: .archive) ?? ArchiveState()
    }
}
