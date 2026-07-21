import Foundation

/// 顶层路由（阶段 1：会议列表 / 设置 / 新建与编辑会议 / 会中 / 会后）
enum AppRoute: Hashable {
    case meetingList
    /// 会议表单：nil = 新建；有 id = 编辑既有草稿
    case meetingSetup(UUID?)
    case settings
    case liveMeeting(UUID)
    case meetingReview(UUID)
}

/// App 级路由状态
@MainActor
@Observable
final class AppRouter {
    var route: AppRoute = .meetingList

    func showMeetingList() { route = .meetingList }
    func showMeetingSetup(editing id: UUID? = nil) { route = .meetingSetup(id) }
    func showSettings() { route = .settings }
    func showLiveMeeting(_ id: UUID) { route = .liveMeeting(id) }
    func showMeetingReview(_ id: UUID) { route = .meetingReview(id) }
}
