import Foundation
import Testing
@testable import BangWoFenXi

/// 异常退出恢复测试（实施计划 11.1）
@Suite("异常退出恢复")
struct MeetingRecoveryTests {

    @Test("过滤未正常结束的会议")
    func abnormalFiltering() throws {
        let draft = Meeting(title: "草稿")
        let ready = Meeting(title: "就绪")
        try ready.transition(to: .ready)
        let recording = Meeting(title: "录音中")
        try recording.transition(to: .ready)
        try recording.transition(to: .recording)
        let paused = Meeting(title: "已暂停")
        try paused.transition(to: .ready)
        try paused.transition(to: .recording)
        try paused.transition(to: .paused)
        let completed = Meeting(title: "已结束", status: .completed)

        let abnormal = MeetingRecovery.abnormalMeetings(from: [draft, ready, recording, paused, completed])
        #expect(abnormal.map(\.title).sorted() == ["已暂停", "录音中"])
    }

    @Test("录音中恢复：recording → finalizing → completed")
    func recoverFromRecording() throws {
        let meeting = Meeting(title: "恢复测试")
        try meeting.transition(to: .ready)
        try meeting.transition(to: .recording)

        try MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
        #expect(meeting.status == .completed)
        #expect(meeting.endedAt != nil)
    }

    @Test("暂停中恢复：paused → finalizing → completed")
    func recoverFromPaused() throws {
        let meeting = Meeting(title: "恢复测试")
        try meeting.transition(to: .ready)
        try meeting.transition(to: .recording)
        try meeting.transition(to: .paused)

        try MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
        #expect(meeting.status == .completed)
    }

    @Test("收尾中恢复：finalizing → completed")
    func recoverFromFinalizing() throws {
        let meeting = Meeting(title: "恢复测试", status: .finalizing)
        try MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
        #expect(meeting.status == .completed)
    }

    @Test("重复标记已结束保持幂等")
    func repeatedRecoveryIsIdempotent() throws {
        let meeting = Meeting(title: "恢复测试")
        try meeting.transition(to: .ready)
        try meeting.transition(to: .recording)

        try MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
        let endedAt = meeting.endedAt
        try MeetingRecovery.markCompletedAfterAbnormalExit(meeting)

        #expect(meeting.status == .completed)
        #expect(meeting.endedAt == endedAt)
    }

    @Test("正常状态不允许恢复操作", arguments: [MeetingStatus.draft, .ready])
    func recoverRejectsNormalStatus(status: MeetingStatus) {
        let meeting = Meeting(title: "正常会议", status: status)
        #expect(throws: MeetingRecoveryError.self) {
            try MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
        }
        #expect(meeting.status == status, "非法恢复不得改变原状态")
    }
}

/// V2 项目异常退出恢复（Bug 1）：权威存储是 projects.json，
/// 启动恢复必须覆盖 Project，否则新项目永远卡在「录音中」。
@Suite("V2 项目异常退出恢复")
struct ProjectRecoveryTests {

    private func makeProject(
        status: ProjectStatus,
        title: String = "项目",
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationMs: Int64 = 0
    ) -> Project {
        Project(
            title: title, sourceType: .liveRecording, status: status,
            startedAt: startedAt, endedAt: endedAt, durationMs: durationMs
        )
    }

    @Test("识别未正常结束的项目：recording / paused / processing")
    func abnormalProjectFiltering() {
        let projects = [
            makeProject(status: .creating, title: "创建中"),
            makeProject(status: .recording, title: "录音中"),
            makeProject(status: .paused, title: "已暂停"),
            makeProject(status: .processing, title: "处理中"),
            makeProject(status: .ready, title: "就绪"),
            makeProject(status: .readyWithWarnings, title: "有告警"),
            makeProject(status: .failed, title: "失败")
        ]
        let abnormal = MeetingRecovery.abnormalProjects(from: projects)
        #expect(abnormal.map(\.title).sorted() == ["处理中", "已暂停", "录音中"])
    }

    @Test(
        "恢复后状态落到 ready，口径与运行时映射一致",
        arguments: [ProjectStatus.recording, .paused, .processing]
    )
    func markResolvedLandsOnReady(status: ProjectStatus) throws {
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)
        let project = makeProject(status: status, startedAt: startedAt)
        let now = startedAt.addingTimeInterval(120)

        try MeetingRecovery.markResolvedAfterAbnormalExit(project, at: now)

        #expect(project.status == .ready)
        #expect(project.status == ProjectRuntimeSession.projectStatus(for: .completed))
        #expect(project.endedAt == now)
        #expect(project.lastActivityAt == now)
    }

    @Test("恢复时补齐 durationMs，不把崩溃项目固化成 0")
    func markResolvedFillsDuration() throws {
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)
        let project = makeProject(status: .recording, startedAt: startedAt)
        let now = startedAt.addingTimeInterval(94)

        try MeetingRecovery.markResolvedAfterAbnormalExit(project, at: now)

        #expect(project.durationMs == 94_000)
    }

    @Test("已有 endedAt 时不被 now 覆盖")
    func markResolvedKeepsExistingEndedAt() throws {
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)
        let endedAt = startedAt.addingTimeInterval(600)
        let project = makeProject(status: .processing, startedAt: startedAt, endedAt: endedAt)

        try MeetingRecovery.markResolvedAfterAbnormalExit(
            project, at: endedAt.addingTimeInterval(86_400)
        )

        #expect(project.endedAt == endedAt)
        #expect(project.durationMs == 600_000)
    }

    @Test("已就绪项目幂等；其他正常状态拒绝恢复")
    func markResolvedRejectsNormalStatus() throws {
        let ready = makeProject(status: .ready, durationMs: 1_000)
        try MeetingRecovery.markResolvedAfterAbnormalExit(ready)
        #expect(ready.status == .ready)
        #expect(ready.durationMs == 1_000)

        for status in [ProjectStatus.creating, .readyWithWarnings, .failed] {
            let project = makeProject(status: status)
            #expect(throws: MeetingRecoveryError.self) {
                try MeetingRecovery.markResolvedAfterAbnormalExit(project)
            }
            #expect(project.status == status, "非法恢复不得改变原状态")
        }
    }

    @Test("统一恢复条目：来源与展示字段正确")
    func recoveryItemMapping() throws {
        let project = makeProject(status: .recording, title: "未命名录音", durationMs: 94_000)
        let projectItem = AbnormalRecoveryItem(project: project)
        #expect(projectItem.id == project.id)
        #expect(projectItem.title == "未命名录音")
        #expect(projectItem.statusText == "录音中")
        #expect(projectItem.durationMs == 94_000)
        #expect(projectItem.source == .project)

        let meeting = Meeting(title: "旧会议")
        try meeting.transition(to: .ready)
        try meeting.transition(to: .recording)
        meeting.pauseIntervals = [PauseInterval(startMs: 1_000, endMs: 30_000)]
        let meetingItem = AbnormalRecoveryItem(meeting: meeting)
        #expect(meetingItem.source == .meeting)
        #expect(meetingItem.durationMs == 30_000)
    }

    @Test("时长展示：不足一小时用 mm:ss，超过用 hh:mm:ss")
    func durationFormatting() {
        #expect(AbnormalRecoveryView.formatDuration(ms: 94_000) == "01:34")
        #expect(AbnormalRecoveryView.formatDuration(ms: 3_723_000) == "01:02:03")
    }
}
