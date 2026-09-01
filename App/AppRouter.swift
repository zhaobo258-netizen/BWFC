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

    func showProjectHome() {
        requestedFinalReportProjectID = nil
        route = .projectHome
    }

    func showProjectWorkspace(_ id: UUID, autoStart: Bool) {
        requestedFinalReportProjectID = nil
        route = .projectWorkspace(id, autoStart: autoStart)
    }

    func showProjectFinalReport(_ id: UUID) {
        requestedFinalReportProjectID = id
        route = .projectWorkspace(id, autoStart: false)
    }

    func showPeopleLibrary() {
        requestedFinalReportProjectID = nil
        route = .peopleLibrary
    }

    func consumeFinalReportRequest(for id: UUID) -> Bool {
        guard requestedFinalReportProjectID == id else { return false }
        requestedFinalReportProjectID = nil
        return true
    }

    func showSettings() {
        isSettingsPresented = true
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
