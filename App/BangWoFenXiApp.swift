import SwiftUI

/// App 入口（阶段 0：工程骨架与运行基线）
@main
struct BangWoFenXiApp: App {
    @State private var environment: AppEnvironment
    @State private var router = AppRouter()

    init() {
        _environment = State(initialValue: AppEnvironment.live())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(router)
                .frame(minWidth: 1280, minHeight: 800)
        }
        .defaultSize(width: 1440, height: 900)
    }
}

/// 顶层视图：按路由切换页面
struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            switch router.route {
            case .meetingList:
                MeetingListView()
            case .meetingSetup:
                MeetingSetupView()
            case .settings:
                SettingsView()
            case .liveMeeting(let id):
                LiveMeetingPlaceholderView(meetingID: id)
            case .meetingReview(let id):
                MeetingReviewPlaceholderView(meetingID: id)
            }
        }
        .task {
            // 首次启动：申请麦克风权限（实施计划 5.1）。
            // 拒绝时不阻断进入本地界面，录音前会再次校验并给出系统设置入口。
            _ = await MicrophonePermission.requestAccess()
        }
    }
}
