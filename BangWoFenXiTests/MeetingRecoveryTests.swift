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

    @Test("正常状态不允许恢复操作", arguments: [MeetingStatus.draft, .ready, .completed])
    func recoverRejectsNormalStatus(status: MeetingStatus) {
        let meeting = Meeting(title: "正常会议", status: status)
        #expect(throws: MeetingRecoveryError.self) {
            try MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
        }
        #expect(meeting.status == status, "非法恢复不得改变原状态")
    }
}
