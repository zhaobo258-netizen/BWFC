import Foundation

// 注意：本机 Command Line Tools 工具链缺少 SwiftDataMacros 编译器插件（仅随 Xcode 分发），
// @Model 宏无法展开。模型先以纯 Swift 类实现，字段与实施计划第 9 节一致；
// 安装 Xcode 后这些类将恢复为 SwiftData @Model（字段不变，仅加回宏标注与关系声明）。

/// 录音暂停区间（会议时间轴，毫秒）。
/// 阶段 1：用于回放时标注暂停区间、校验「暂停区间无异常音频」。
struct PauseInterval: Codable, Hashable, Sendable {
    /// 暂停开始的会议时间轴毫秒
    var startMs: Int64
    /// 恢复录音的会议时间轴毫秒
    var endMs: Int64

    /// 区间时长（毫秒）
    var durationMs: Int64 { endMs - startMs }
}

/// 会议状态（实施计划 9.1 / 11.1）
enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    case draft       // 草稿：背景或参与人尚未准备好
    case ready       // 就绪：麦克风、权限、声音样本和上传确认已满足
    case recording   // 录音中
    case paused      // 已暂停
    case finalizing  // 正在收尾：处理剩余缓冲、分片和分析
    case completed   // 已结束：可回放、修订、重新分析和导出

    /// 中文显示名（顶部状态栏使用）
    var displayName: String {
        switch self {
        case .draft: return "草稿"
        case .ready: return "准备就绪"
        case .recording: return "录音中"
        case .paused: return "已暂停"
        case .finalizing: return "正在收尾"
        case .completed: return "已结束"
        }
    }

    /// 异常退出恢复时需要提示用户的「未正常结束」状态（实施计划 11.1）
    var isAbnormalIfAppRelaunched: Bool {
        switch self {
        case .recording, .paused, .finalizing: return true
        case .draft, .ready, .completed: return false
        }
    }
}

/// 非法状态转换错误
enum MeetingTransitionError: Error, Equatable {
    case illegalTransition(from: MeetingStatus, to: MeetingStatus)
}

extension MeetingTransitionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .illegalTransition(let from, let to):
            return "不允许从「\(from.displayName)」切换到「\(to.displayName)」"
        }
    }
}

/// 会议状态机（实施计划 11.1）：
/// draft → ready → recording ⇄ paused → finalizing → completed
/// 图示之外的转换一律拒绝。
enum MeetingStateMachine {
    /// 合法转换表
    static let allowedTransitions: [MeetingStatus: Set<MeetingStatus>] = [
        .draft: [.ready],
        .ready: [.recording],
        .recording: [.paused, .finalizing],
        .paused: [.recording, .finalizing],
        .finalizing: [.completed],
        .completed: []
    ]

    /// 判断 from → to 是否合法
    static func canTransition(from: MeetingStatus, to: MeetingStatus) -> Bool {
        allowedTransitions[from]?.contains(to) ?? false
    }

    /// 校验转换，非法时抛出错误
    static func validateTransition(from: MeetingStatus, to: MeetingStatus) throws {
        guard canTransition(from: from, to: to) else {
            throw MeetingTransitionError.illegalTransition(from: from, to: to)
        }
    }
}

/// 会议（实施计划 9.1）
final class Meeting: Identifiable, Codable {
    /// 主键
    var id: UUID
    /// 会议名称
    var title: String
    /// 谈判背景
    var background: String
    /// 我方目标
    var ourGoal: String
    /// 我方底线：只参与分析，不直接显示给对方
    var ourBottomLine: String
    /// 对方背景
    var counterpartContext: String
    /// 专业词汇和专有名词
    var glossary: [String]
    /// 会议状态（状态机见 MeetingStateMachine）
    var status: MeetingStatus
    /// 会议开始时间
    var startedAt: Date?
    /// 会议结束时间
    var endedAt: Date?
    /// 完整录音相对路径（仅存相对路径，实施计划 7.1）
    var audioRelativePath: String?
    /// 用户确认云端音频处理的时间
    var audioUploadConsentAt: Date?
    /// 增量分析游标：已分析到的片段结束毫秒
    var lastAnalyzedSegmentEndMs: Int64

    // MARK: - 阶段 1 新增字段（录音与会前准备）

    /// 会前选择的音频输入设备 ID（AVCaptureDevice.uniqueID；nil 表示系统默认）
    var preferredInputDeviceID: String?
    /// 录音暂停区间（会议时间轴），回放与审计使用
    var pauseIntervals: [PauseInterval]

    /// 参会人
    var participants: [Participant] = []
    /// 转写片段
    var segments: [TranscriptSegment] = []
    /// 分析快照
    var snapshots: [AnalysisSnapshot] = []

    /// 最新一版分析快照（UI 与会后页面使用；无快照时为 nil）
    var latestSnapshot: AnalysisSnapshot? {
        snapshots.max { $0.version < $1.version }
    }

    init(
        id: UUID = UUID(),
        title: String,
        background: String = "",
        ourGoal: String = "",
        ourBottomLine: String = "",
        counterpartContext: String = "",
        glossary: [String] = [],
        status: MeetingStatus = .draft,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        audioRelativePath: String? = nil,
        audioUploadConsentAt: Date? = nil,
        lastAnalyzedSegmentEndMs: Int64 = 0,
        preferredInputDeviceID: String? = nil,
        pauseIntervals: [PauseInterval] = []
    ) {
        self.id = id
        self.title = title
        self.background = background
        self.ourGoal = ourGoal
        self.ourBottomLine = ourBottomLine
        self.counterpartContext = counterpartContext
        self.glossary = glossary
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioRelativePath = audioRelativePath
        self.audioUploadConsentAt = audioUploadConsentAt
        self.lastAnalyzedSegmentEndMs = lastAnalyzedSegmentEndMs
        self.preferredInputDeviceID = preferredInputDeviceID
        self.pauseIntervals = pauseIntervals
    }

    // 自定义解码：新增字段允许缺失并回退默认值，保证旧版本 JSON 可读
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        background = try container.decodeIfPresent(String.self, forKey: .background) ?? ""
        ourGoal = try container.decodeIfPresent(String.self, forKey: .ourGoal) ?? ""
        ourBottomLine = try container.decodeIfPresent(String.self, forKey: .ourBottomLine) ?? ""
        counterpartContext = try container.decodeIfPresent(String.self, forKey: .counterpartContext) ?? ""
        glossary = try container.decodeIfPresent([String].self, forKey: .glossary) ?? []
        status = try container.decode(MeetingStatus.self, forKey: .status)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        audioRelativePath = try container.decodeIfPresent(String.self, forKey: .audioRelativePath)
        audioUploadConsentAt = try container.decodeIfPresent(Date.self, forKey: .audioUploadConsentAt)
        lastAnalyzedSegmentEndMs = try container.decodeIfPresent(Int64.self, forKey: .lastAnalyzedSegmentEndMs) ?? 0
        preferredInputDeviceID = try container.decodeIfPresent(String.self, forKey: .preferredInputDeviceID)
        pauseIntervals = try container.decodeIfPresent([PauseInterval].self, forKey: .pauseIntervals) ?? []
        participants = try container.decodeIfPresent([Participant].self, forKey: .participants) ?? []
        segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        snapshots = try container.decodeIfPresent([AnalysisSnapshot].self, forKey: .snapshots) ?? []
    }

    /// 经状态机校验的状态转换；非法转换抛出错误并保持原状态
    func transition(to newStatus: MeetingStatus) throws {
        try MeetingStateMachine.validateTransition(from: status, to: newStatus)
        status = newStatus
        switch newStatus {
        case .recording where startedAt == nil:
            startedAt = Date()
        case .completed:
            endedAt = Date()
        default:
            break
        }
    }
}
