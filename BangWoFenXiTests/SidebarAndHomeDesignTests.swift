import Foundation
import Testing
@testable import BangWoFenXi

/// 界面设计定稿 v1.0（2026-10-08）新增纯逻辑的测试：
/// 边栏徽标投影（S02）、首页全库搜索、导入流水线步骤展示、边栏开录令牌。
@Suite("边栏徽标投影")
final class SidebarBadgeProviderTests {

    private func makeProject(
        title: String,
        status: ProjectStatus = .ready,
        speakers: [Speaker] = [],
        lastActivityAt: Date = Date()
    ) -> Project {
        Project(
            title: title, sourceType: .liveRecording, status: status,
            createdAt: lastActivityAt, lastActivityAt: lastActivityAt,
            speakers: speakers
        )
    }

    @Test("LIVE 徽标来自运行时录音集合，不凭磁盘状态猜")
    func liveBadgeFromRuntimeIDs() {
        let recording = makeProject(title: "进行中", status: .recording)
        // 磁盘上有 recording 但运行时未登记（崩溃残留）→ 不是 LIVE
        let notLive = SidebarBadgeProvider.snapshot(
            projects: [recording], businessProjects: [], persons: [],
            liveProjectIDs: []
        )
        #expect(notLive.liveProjectID == nil)
        #expect(notLive.resumableProjectID == recording.id)

        // 运行时登记后才亮 LIVE
        let live = SidebarBadgeProvider.snapshot(
            projects: [recording], businessProjects: [], persons: [],
            liveProjectIDs: [recording.id]
        )
        #expect(live.liveProjectID == recording.id)
    }

    @Test("待确认人物数 = 未人工确认的说话人槽位总数")
    func pendingPersonsCount() {
        let confirmed = Speaker(cloudAlias: "p_01", displayName: "赵总", isUserConfirmed: true)
        let anonymous = Speaker(cloudAlias: "p_02", displayName: "人物 2", isUserConfirmed: false)
        let project = makeProject(title: "拜访", speakers: [confirmed, anonymous])
        let snapshot = SidebarBadgeProvider.snapshot(
            projects: [project], businessProjects: [], persons: [],
            liveProjectIDs: []
        )
        #expect(snapshot.pendingPersons == 1)
    }

    @Test("逾期徽标只统计 active 业务项目的逾期跟进")
    func overdueBadge() {
        let overdue = FollowUp(
            title: "验收清单", dueDate: Date(timeIntervalSinceNow: -3_600),
            handlingStatus: .inProgress
        )
        let done = FollowUp(
            title: "已完成事项", dueDate: Date(timeIntervalSinceNow: -3_600),
            handlingStatus: .completed, completedAt: Date()
        )
        let active = BusinessProject(name: "A", followUps: [overdue, done])
        let archived = BusinessProject(
            name: "归档",
            followUps: [FollowUp(title: "旧逾期", dueDate: Date(timeIntervalSinceNow: -86_400))],
            status: .archived
        )
        let snapshot = SidebarBadgeProvider.snapshot(
            projects: [], businessProjects: [active, archived], persons: [],
            liveProjectIDs: []
        )
        #expect(snapshot.overdueFollowUps == 1)
    }

    @Test("「当前交流」落点：进行中录音优先，其次可恢复项目，都没有则不可用")
    func currentSessionTarget() {
        let live = makeProject(title: "直播中", status: .recording)
        let paused = makeProject(title: "暂停中", status: .paused)
        let snapshot = SidebarBadgeProvider.snapshot(
            projects: [paused, live], businessProjects: [], persons: [],
            liveProjectIDs: [live.id]
        )
        #expect(snapshot.currentSessionTarget == live.id)

        let empty = SidebarBadgeProvider.snapshot(
            projects: [makeProject(title: "已完成")], businessProjects: [], persons: [],
            liveProjectIDs: []
        )
        #expect(empty.currentSessionTarget == nil)
    }

    @Test("用户卡取人物库中「这是我」的人物")
    func currentUserPerson() {
        let me = Person(displayName: "赵总", isCurrentUser: true)
        let other = Person(displayName: "李工")
        let snapshot = SidebarBadgeProvider.snapshot(
            projects: [], businessProjects: [], persons: [other, me],
            liveProjectIDs: []
        )
        #expect(snapshot.currentUserPerson?.displayName == "赵总")
    }
}

@Suite("首页全库搜索")
final class ProjectHomeSearchTests {

    private func makeProject(title: String, segmentText: String? = nil) -> Project {
        let project = Project(title: title, sourceType: .liveRecording, status: .ready)
        if let segmentText {
            project.segments = [
                TranscriptSegment(startMs: 0, endMs: 500, text: segmentText,
                                  source: .local, state: .final)
            ]
        }
        return project
    }

    @Test("空搜索词不过滤")
    func emptyQueryPassesAll() {
        let project = makeProject(title: "任意")
        #expect(ProjectHomeSupport.matchesSearch(project, query: ""))
        #expect(ProjectHomeSupport.matchesSearch(project, query: "   "))
    }

    @Test("标题命中")
    func titleMatch() {
        let project = makeProject(title: "渠道政策沟通")
        #expect(ProjectHomeSupport.matchesSearch(project, query: "渠道"))
        #expect(!ProjectHomeSupport.matchesSearch(project, query: "验收"))
    }

    @Test("最终文稿命中；实时草稿不参与搜索")
    func transcriptMatch() {
        let final = makeProject(title: "无关标题", segmentText: "验收口径先定边界")
        #expect(ProjectHomeSupport.matchesSearch(final, query: "验收口径"))

        let provisional = Project(title: "无关标题", sourceType: .liveRecording, status: .ready)
        provisional.segments = [
            TranscriptSegment(startMs: 0, endMs: 500, text: "草稿里的验收",
                              source: .local, state: .provisional)
        ]
        #expect(!ProjectHomeSupport.matchesSearch(provisional, query: "验收"))
    }
}

@Suite("首页流水线展示")
final class ProjectPipelineDisplayTests {

    @Test("没有处理任务的项目不显示流水线")
    func noJobsNoPipeline() {
        let project = Project(title: "空", sourceType: .liveRecording, status: .ready)
        #expect(ProjectHomeSupport.pipelineSteps(for: project).isEmpty)
    }

    @Test("全部完成不刷屏（正常 = 不可见）")
    func allDoneHidden() {
        let project = Project(title: "完成", sourceType: .importedAudio, status: .ready)
        project.processingJobs = [
            ProcessingJob(kind: .transcription, status: .completed),
            ProcessingJob(kind: .diarization, status: .completed)
        ]
        #expect(ProjectHomeSupport.pipelineSteps(for: project).isEmpty)
    }

    @Test("失败与进行中保留展示，按流水线顺序排列")
    func failedAndRunningShown() {
        let project = Project(title: "处理中", sourceType: .importedAudio, status: .processing)
        project.processingJobs = [
            ProcessingJob(kind: .audioExtraction, status: .completed),
            ProcessingJob(kind: .transcription, status: .completed),
            ProcessingJob(kind: .diarization, status: .failedRetryable),
            ProcessingJob(kind: .analysis, status: .pending)
        ]
        let steps = ProjectHomeSupport.pipelineSteps(for: project)
        #expect(steps.map(\.title) == ["提取音轨", "本地转写", "分人识别", "分析"])
        #expect(steps.map(\.state) == [.done, .done, .failed, .running])
    }
}

@Suite("边栏开录令牌")
@MainActor
final class SidebarRecordingRequestTests {

    @Test("请求开录先回首页，令牌只消费一次")
    func requestConsumedOnce() {
        let router = AppRouter()
        router.showBusinessProjects()
        router.requestStartRecording()
        #expect(router.route == .projectHome)
        #expect(router.startRecordingRequestToken != nil)
        #expect(router.consumeStartRecordingRequest())
        #expect(!router.consumeStartRecordingRequest())
        #expect(router.startRecordingRequestToken == nil)
    }

    @Test("没有令牌时消费返回 false")
    func noTokenNoConsume() {
        let router = AppRouter()
        #expect(!router.consumeStartRecordingRequest())
    }
}
