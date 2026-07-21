import Foundation

/// 顶层路由（阶段 0：会议列表 / 设置 / 新建会议；会中与会后为占位页）
enum AppRoute: Hashable {
    case meetingList
    case meetingSetup
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
    func showMeetingSetup() { route = .meetingSetup }
    func showSettings() { route = .settings }
    func showLiveMeeting(_ id: UUID) { route = .liveMeeting(id) }
    func showMeetingReview(_ id: UUID) { route = .meetingReview(id) }
}
