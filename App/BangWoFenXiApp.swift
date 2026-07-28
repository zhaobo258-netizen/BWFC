import SwiftUI

/// App 入口（阶段 1：会前准备与本地录音）
@main
struct BangWoFenXiApp: App {
    @State private var environment: AppEnvironment
    @State private var router = AppRouter()

    init() {
        _environment = State(initialValue: AppEnvironment.live())
    }

    var body: some Scene {
        WindowGroup {
            RootView {
                router.showProjectHome()
                environment = AppEnvironment.live()
            }
                .environment(environment)
                .environment(router)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
    }
}

/// 顶层视图：按路由切换页面；启动时检查麦克风权限与未正常结束的会议
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment
    let onStorageLocationChanged: () -> Void

    /// 启动时发现的未正常结束会议（实施计划 11.1 恢复提示）
    @State private var abnormalMeetings: [Meeting] = []
    @State private var finalReportNotification: FinalReportCoordinator.Completion?

    var body: some View {
        Group {
            switch router.route {
            case .projectHome:
                ProjectHomeView()
            case .projectWorkspace(let id, let autoStart):
                ProjectWorkspaceView(projectID: id, autoStart: autoStart)
                    .id(id)
            case .meetingList:
                MeetingListView()
            case .meetingSetup(let id):
                MeetingSetupView(meetingID: id)
            case .liveMeeting(let id):
                LiveMeetingView(meetingID: id)
            case .meetingReview(let id):
                MeetingReviewView(meetingID: id)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { router.isSettingsPresented },
                set: { if !$0 { router.closeSettings() } }
            )
        ) {
            SettingsView(onStorageLocationChanged: {
                router.closeSettings()
                onStorageLocationChanged()
            })
            .environment(environment)
            .environment(router)
            .frame(minWidth: 780, minHeight: 620)
        }
        .task {
            // 首次启动：申请麦克风权限（实施计划 5.1）。
            // 拒绝时不阻断进入本地界面，录音前会再次校验并给出系统设置入口。
            _ = await MicrophonePermission.requestAccess()
            // 异常退出恢复：发现 recording/paused/finalizing 状态的会议时提示，
            // 保留已写入音频和片段，不自动删除（实施计划 11.1）。
            if let meetings = try? environment.allMeetings() {
                abnormalMeetings = MeetingRecovery.abnormalMeetings(from: meetings)
            }
        }
        .sheet(isPresented: .constant(!abnormalMeetings.isEmpty)) {
            AbnormalRecoveryView(meetings: abnormalMeetings) { meeting, action in
                handleRecovery(meeting: meeting, action: action)
            }
            .interactiveDismissDisabled()
        }
        .onChange(of: environment.finalReportCoordinator.revision) { _, _ in
            finalReportNotification = environment.finalReportCoordinator.latestCompletion
        }
        .onChange(
            of: environment.importProcessing.finalReportNotificationRevision
        ) { _, _ in
            finalReportNotification = environment.importProcessing
                .latestFinalReportCompletion
        }
        .overlay(alignment: .top) {
            if let completion = finalReportNotification {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("完整总结已生成（第 \(completion.version) 版）")
                        .font(.callout)
                    Spacer()
                    Button("查看") {
                        router.showProjectFinalReport(completion.projectID)
                        finalReportNotification = nil
                    }
                    Button {
                        finalReportNotification = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭完整总结提示")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                .padding(.top, 10)
                .padding(.horizontal, 18)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// 处理恢复动作：标记已结束 / 查看 / 稍后处理
    private func handleRecovery(meeting: Meeting?, action: AbnormalRecoveryView.Action) {
        switch action {
        case .markCompleted:
            if let meeting {
                try? MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
                try? environment.persist(meeting)
            }
        case .openMeeting:
            if let meeting {
                try? MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
                try? environment.persist(meeting)
                router.showMeetingReview(meeting.id)
            }
        case .later:
            break
        }
        if let meeting {
            abnormalMeetings.removeAll { $0.id == meeting.id }
        } else {
            abnormalMeetings = []
        }
    }
}
