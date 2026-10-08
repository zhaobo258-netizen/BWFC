import Foundation

/// 顶层路由。
/// 知识花园版主流程：projectHome / projectWorkspace；
/// 旧谈判页面（meetingList / meetingSetup / liveMeeting / meetingReview）保留至阶段 B 验收后再评估退场。
enum AppRoute: Hashable {
    /// 新首页：开始录音 / 导入音视频 / 最近项目
    case projectHome
    /// 项目工作台（三栏）；autoStart=true 时进入即开始录音
    case projectWorkspace(UUID, autoStart: Bool)
    /// 跨录音的历史人物、声纹、背景与表达画像
    case peopleLibrary
    /// 轻 CRM 业务项目（人物、录音与跟进闭环）
    case businessProjects
    // 旧版路由（保留兼容，不再作为主流程入口）
    case meetingList
    /// 会议表单：nil = 新建；有 id = 编辑既有草稿
    case meetingSetup(UUID?)
    case liveMeeting(UUID)
    case meetingReview(UUID)
}

/// App 级路由状态
@MainActor
@Observable
final class AppRouter {
    var route: AppRoute = .projectHome
    var isSettingsPresented = false
    var requestedFinalReportProjectID: UUID?
    private var requestedEvidence: (projectID: UUID, segmentID: UUID)?
    var requestedEvidenceSegmentID: UUID? { requestedEvidence?.segmentID }
    /// 边栏「开始录音」一次性请求令牌：由首页消费，
    /// 复用首页既有知情确认与建项目链路，不另起第二条开录路径（界面定稿 v1.0 接线）。
    private(set) var startRecordingRequestToken: UUID?

    func showProjectHome() {
        requestedEvidence = nil
        requestedFinalReportProjectID = nil
        route = .projectHome
    }

    func showProjectWorkspace(_ id: UUID, autoStart: Bool, evidenceSegmentID: UUID? = nil) {
        requestedEvidence = evidenceSegmentID.map { (id, $0) }
        requestedFinalReportProjectID = nil
        route = .projectWorkspace(id, autoStart: autoStart)
    }

    func showProjectFinalReport(_ id: UUID) {
        requestedEvidence = nil
        requestedFinalReportProjectID = id
        route = .projectWorkspace(id, autoStart: false)
    }

    func showPeopleLibrary() {
        requestedEvidence = nil
        requestedFinalReportProjectID = nil
        route = .peopleLibrary
    }

    func showBusinessProjects() {
        requestedEvidence = nil
        requestedFinalReportProjectID = nil
        route = .businessProjects
    }

    func consumeFinalReportRequest(for id: UUID) -> Bool {
        guard requestedFinalReportProjectID == id else { return false }
        requestedFinalReportProjectID = nil
        return true
    }

    func consumeEvidenceRequest(for id: UUID) -> UUID? {
        guard requestedEvidence?.projectID == id else { return nil }
        let segmentID = requestedEvidence?.segmentID
        requestedEvidence = nil
        return segmentID
    }

    func showSettings() {
        isSettingsPresented = true
    }

    /// 边栏「开始录音」：先回首页，再由首页消费一次性令牌启动录音
    func requestStartRecording() {
        requestedEvidence = nil
        requestedFinalReportProjectID = nil
        route = .projectHome
        startRecordingRequestToken = UUID()
    }

    /// 首页消费开录令牌；每个令牌只生效一次
    func consumeStartRecordingRequest() -> Bool {
        guard startRecordingRequestToken != nil else { return false }
        startRecordingRequestToken = nil
        return true
    }

    func closeSettings() {
        isSettingsPresented = false
    }

    // 旧版导航（保留）
    func showMeetingList() { route = .meetingList }
    func showMeetingSetup(editing id: UUID? = nil) { route = .meetingSetup(id) }
    func showLiveMeeting(_ id: UUID) { route = .liveMeeting(id) }
    func showMeetingReview(_ id: UUID) { route = .meetingReview(id) }
}
