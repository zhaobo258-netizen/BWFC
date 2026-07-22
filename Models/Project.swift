import Foundation

/// 项目来源类型（产品文档 03 号 §8.1）
enum ProjectSourceType: String, Codable, Sendable, CaseIterable {
    case liveRecording  // 实时录音
    case importedAudio  // 导入音频
    case importedVideo  // 导入视频
}

/// 项目场景（产品文档 03 号 §8.1）
enum ProjectScenario: String, Codable, Sendable, CaseIterable {
    case clientVisit         // 客户拜访
    case classLearning       // 课堂学习
    case journalistInterview // 记者采访
    case freeform            // 自由记录

    /// 中文显示名
    var displayName: String {
        switch self {
        case .clientVisit: return "客户拜访"
        case .classLearning: return "课堂学习"
        case .journalistInterview: return "记者采访"
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

/// V2 项目（产品文档 03 号 §8.1）：一次对话/一份素材的完整载体。
/// schemaVersion 当前为 2；V1（Meeting）数据经 ProjectMigration 一次性迁移。
final class Project: Identifiable, Codable {
    /// 数据结构版本（V2 恒为 2）
    var schemaVersion: Int
    /// 主键（迁移时保留旧 Meeting id）
    var id: UUID
    /// 项目标题
    var title: String
    /// 来源类型
    var sourceType: ProjectSourceType
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
    /// 旧谈判分析快照：按 legacy 原样保留，供历史数据回看；
    /// V2 通用 ConversationAnalysisSnapshot 属阶段 D，本阶段不实现
    var legacySnapshots: [AnalysisSnapshot] = []
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
        sourceType: ProjectSourceType,
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
        legacyMetadata: LegacyMeetingMetadata? = nil,
        note: NoteDocument = NoteDocument(markdown: "", updatedAt: Date()),
        processingJobs: [ProcessingJob] = [],
        archive: ArchiveState = ArchiveState()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.sourceType = sourceType
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
        sourceType = try container.decode(ProjectSourceType.self, forKey: .sourceType)
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
        // 兼容补强前生成的 Project JSON（无 legacyMetadata 键）
        legacyMetadata = try container.decodeIfPresent(LegacyMeetingMetadata.self, forKey: .legacyMetadata)
        note = try container.decodeIfPresent(NoteDocument.self, forKey: .note) ?? NoteDocument(markdown: "", updatedAt: createdAt)
        processingJobs = try container.decodeIfPresent([ProcessingJob].self, forKey: .processingJobs) ?? []
        archive = try container.decodeIfPresent(ArchiveState.self, forKey: .archive) ?? ArchiveState()
    }
}
