import Foundation
import Testing
@testable import BangWoFenXi

/// 会议状态机测试（实施计划 11.1 / 14.1）：
/// draft → ready → recording ⇄ paused → finalizing → completed，
/// 图示之外的转换一律拒绝。
@Suite("会议状态机")
struct MeetingStateMachineTests {

    /// 全部合法转换必须被允许
    @Test("合法转换全部允许")
    func legalTransitionsAreAllowed() {
        let legal: [(MeetingStatus, MeetingStatus)] = [
            (.draft, .ready),
            (.ready, .recording),
            (.recording, .paused),
            (.paused, .recording),
            (.recording, .finalizing),
            (.paused, .finalizing),
            (.finalizing, .completed)
        ]
        for (from, to) in legal {
            #expect(
                MeetingStateMachine.canTransition(from: from, to: to),
                "\(from) → \(to) 应当是合法转换"
            )
            #expect(throws: Never.self) {
                try MeetingStateMachine.validateTransition(from: from, to: to)
            }
        }
    }

    /// 全部非法转换必须被拒绝：枚举两两组合，凡不在合法表中的一律非法
    @Test("非法转换全部拒绝")
    func illegalTransitionsAreRejected() {
        for from in MeetingStatus.allCases {
            for to in MeetingStatus.allCases {
                let isLegal = MeetingStateMachine.allowedTransitions[from]?.contains(to) ?? false
                #expect(
                    MeetingStateMachine.canTransition(from: from, to: to) == isLegal,
                    "\(from) → \(to) 的合法性判断与转换表不一致"
                )
                if !isLegal {
                    #expect(throws: MeetingTransitionError.self) {
                        try MeetingStateMachine.validateTransition(from: from, to: to)
                    }
                }
            }
        }
    }

    /// 典型非法路径抽查：跳过环节、回退、结束后重启
    @Test("典型非法路径", arguments: [
        (MeetingStatus.draft, MeetingStatus.recording),     // 未 ready 直接录音
        (.draft, .completed),     // 草稿直接完成
        (.ready, .paused),        // 未录音先暂停
        (.ready, .finalizing),    // 未录音直接收尾
        (.paused, .ready),        // 回退
        (.finalizing, .recording),// 收尾中重新开始录音
        (.completed, .recording), // 结束后复活
        (.completed, .draft),
        (.recording, .completed)  // 录音中直接完成（必须先收尾）
    ])
    func typicalIllegalPaths(from: MeetingStatus, to: MeetingStatus) {
        #expect(
            MeetingStateMachine.canTransition(from: from, to: to) == false,
            "\(from) → \(to) 应当被拒绝"
        )
    }

    /// Meeting 模型的转换入口：合法转换生效，非法转换抛错且保持原状态
    @Test("Meeting 转换入口")
    func meetingTransitionMethod() throws {
        let meeting = Meeting(title: "状态机测试会议")
        #expect(meeting.status == .draft)

        // 非法：draft → recording
        #expect(throws: MeetingTransitionError.self) {
            try meeting.transition(to: .recording)
        }
        #expect(meeting.status == .draft, "非法转换后状态必须保持不变")

        // 合法链路：draft → ready → recording → paused → recording → finalizing → completed
        try meeting.transition(to: .ready)
        #expect(meeting.status == .ready)
        try meeting.transition(to: .recording)
        #expect(meeting.status == .recording)
        #expect(meeting.startedAt != nil, "进入录音时应记录开始时间")
        try meeting.transition(to: .paused)
        #expect(meeting.status == .paused)
        try meeting.transition(to: .recording)
        #expect(meeting.status == .recording)
        try meeting.transition(to: .finalizing)
        #expect(meeting.status == .finalizing)
        try meeting.transition(to: .completed)
        #expect(meeting.status == .completed)
        #expect(meeting.endedAt != nil, "完成时应记录结束时间")

        // 完成后不允许再转换
        #expect(throws: MeetingTransitionError.self) {
            try meeting.transition(to: .recording)
        }
        #expect(meeting.status == .completed)
    }

    /// 异常退出恢复标记（实施计划 11.1）
    @Test("异常退出恢复标记")
    func abnormalRelaunchFlags() {
        #expect(MeetingStatus.recording.isAbnormalIfAppRelaunched)
        #expect(MeetingStatus.paused.isAbnormalIfAppRelaunched)
        #expect(MeetingStatus.finalizing.isAbnormalIfAppRelaunched)
        #expect(!MeetingStatus.draft.isAbnormalIfAppRelaunched)
        #expect(!MeetingStatus.ready.isAbnormalIfAppRelaunched)
        #expect(!MeetingStatus.completed.isAbnormalIfAppRelaunched)
    }
}
