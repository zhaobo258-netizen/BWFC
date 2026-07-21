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
        case .draft, .ready, .completed:
            throw MeetingRecoveryError.notAnAbnormalMeeting(meeting.status)
        }
    }
}

/// 恢复操作错误
enum MeetingRecoveryError: Error, Equatable {
    /// 该会议并非未正常结束状态
    case notAnAbnormalMeeting(MeetingStatus)
}
