import Foundation

/// 顶层路由。
/// 知识花园版主流程：projectHome / projectWorkspace / settings；
/// 旧谈判页面（meetingList / meetingSetup / liveMeeting / meetingReview）保留至阶段 B 验收后再评估退场。
enum AppRoute: Hashable {
    /// 新首页：开始录音 / 导入音视频 / 最近项目
    case projectHome
    /// 项目工作台（三栏）；autoStart=true 时进入即开始录音
    case projectWorkspace(UUID, autoStart: Bool)
    case settings

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

    /// 进入设置前的路由（设置页「返回」回到这里；Codex 审计补强）
    private(set) var settingsReturnRoute: AppRoute?

    func showProjectHome() { route = .projectHome }
    func showProjectWorkspace(_ id: UUID, autoStart: Bool) { route = .projectWorkspace(id, autoStart: autoStart) }

    /// 进入设置：记录来源路由，返回时恢复
    func showSettings() {
        if route != .settings {
            settingsReturnRoute = route
        }
        route = .settings
    }

    /// 离开设置：回到进入前的路由（缺省回首页）
    func closeSettings() {
        route = settingsReturnRoute ?? .projectHome
        settingsReturnRoute = nil
    }

    // 旧版导航（保留）
    func showMeetingList() { route = .meetingList }
    func showMeetingSetup(editing id: UUID? = nil) { route = .meetingSetup(id) }
    func showLiveMeeting(_ id: UUID) { route = .liveMeeting(id) }
    func showMeetingReview(_ id: UUID) { route = .meetingReview(id) }
}
