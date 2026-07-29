import Foundation

/// 异常退出恢复（实施计划 11.1）：
/// App 重新打开时发现 recording / paused / finalizing 状态的会议，
/// 提示为「未正常结束的会议」，保留已写入音频和片段，不自动删除。
enum MeetingRecovery {
    /// 过滤出未正常结束的会议
    static func abnormalMeetings(from meetings: [Meeting]) -> [Meeting] {
        meetings.filter { $0.status.isAbnormalIfAppRelaunched }
    }

    /// 将未正常结束的会议标记为已结束。
    /// 路径：recording/paused → finalizing → completed；finalizing → completed。
    /// 保留录音文件与片段，仅修正状态；非法状态抛错并保持原状态。
    static func markCompletedAfterAbnormalExit(_ meeting: Meeting) throws {
        switch meeting.status {
        case .recording, .paused:
            try meeting.transition(to: .finalizing)
            try meeting.transition(to: .completed)
        case .finalizing:
            try meeting.transition(to: .completed)
        case .completed:
            return
        case .draft, .ready:
            throw MeetingRecoveryError.notAnAbnormalMeeting(meeting.status)
        }
    }
}

/// 恢复操作错误
enum MeetingRecoveryError: Error, Equatable {
    /// 该会议并非未正常结束状态
    case notAnAbnormalMeeting(MeetingStatus)
    /// 该项目并非未正常结束状态
    case notAnAbnormalProject(ProjectStatus)
}

extension MeetingRecoveryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notAnAbnormalMeeting(let status):
            return "当前项目状态为“\(status.displayName)”，无需执行异常恢复。"
        case .notAnAbnormalProject(let status):
            return "当前项目状态为“\(status.displayName)”，无需执行异常恢复。"
        }
    }
}

// MARK: - V2 项目侧恢复

extension MeetingRecovery {
    /// 过滤出未正常结束的 V2 项目（recording / paused / processing）
    static func abnormalProjects(from projects: [Project]) -> [Project] {
        projects.filter { $0.status.isAbnormalIfAppRelaunched }
    }

    /// 将未正常结束的 V2 项目收口为可回看状态。
    /// 状态口径复用 ProjectRuntimeSession 的 MeetingStatus → ProjectStatus 映射
    /// （completed → ready），不新增第三套映射；录音与文稿一律保留。
    /// endedAt 缺失时补为 now，并按墙钟口径兜底 durationMs（含暂停，不与媒体真实时长混用）。
    static func markResolvedAfterAbnormalExit(
        _ project: Project,
        at now: Date = Date()
    ) throws {
        guard project.status.isAbnormalIfAppRelaunched else {
            if project.status == ProjectRuntimeSession.projectStatus(for: .completed) {
                return
            }
            throw MeetingRecoveryError.notAnAbnormalProject(project.status)
        }
        let endedAt = project.endedAt ?? now
        project.endedAt = endedAt
        project.durationMs = ProjectRuntimeSession.wallClockDurationMs(
            startedAt: project.startedAt,
            endedAt: endedAt,
            segmentEndMs: project.segments.map(\.endMs).max() ?? 0,
            pauseEndMs: project.pauseIntervals.map(\.endMs).max() ?? 0,
            fallbackDurationMs: project.durationMs,
            now: now
        )
        project.status = ProjectRuntimeSession.projectStatus(for: .completed)
        project.lastActivityAt = now
    }
}

/// 启动恢复弹窗用的统一条目：不绑定 Meeting 或 Project 具体类型，
/// 只携带展示与派发所需的最小信息（V1 / V2 两条来源共用一个界面）。
struct AbnormalRecoveryItem: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// V1 遗留会议（meetings.json）
        case meeting
        /// V2 项目（projects.json，当前权威存储）
        case project
    }

    let id: UUID
    let title: String
    /// 中断时状态的中文显示名
    let statusText: String
    /// 已记录时长（毫秒，墙钟口径）
    let durationMs: Int64
    let source: Source

    init(project: Project) {
        self.id = project.id
        self.title = project.title
        self.statusText = project.status.displayName
        self.durationMs = project.durationMs
        self.source = .project
    }

    init(meeting: Meeting) {
        self.id = meeting.id
        self.title = meeting.title
        self.statusText = meeting.status.displayName
        let segmentEnd = meeting.segments.map(\.endMs).max() ?? 0
        let pauseEnd = meeting.pauseIntervals.map(\.endMs).max() ?? 0
        self.durationMs = max(segmentEnd, pauseEnd)
        self.source = .meeting
    }
}
