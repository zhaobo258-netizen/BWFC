import SwiftUI

/// 会议列表页（阶段 0：空状态 + 云端配置提示 + 新建入口）
struct MeetingListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var meetings: [Meeting] = []
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if environment.isPersistentStorageUnavailable {
                warningBanner(text: "本地数据库初始化失败，当前数据仅保存在内存中，退出后将丢失。")
            }
            if !environment.isCloudConfigured {
                cloudUnconfiguredBanner
            }
            if meetings.isEmpty {
                emptyState
            } else {
                meetingList
            }
        }
        .navigationTitle("帮我分析")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.showMeetingSetup()
                } label: {
                    Label("新建谈判", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    router.showSettings()
                } label: {
                    Label("设置", systemImage: "gear")
                }
            }
        }
        .task {
            reload()
        }
    }

    /// 从持久化存储重新加载（失败时只记录脱敏日志，界面显示空态）
    private func reload() {
        do {
            meetings = try environment.meetingStore.loadMeetings()
                .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            loadFailed = false
        } catch {
            meetings = []
            loadFailed = true
            AppLog.persistence.error("\(LogSanitizer.formatEvent("meeting_load_failed", error: String(describing: type(of: error))))")
        }
    }

    /// 空状态
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(loadFailed ? "会议数据读取失败" : "还没有谈判会议")
                .font(.title2)
                .fontWeight(.semibold)
            Text("新建一场谈判，会前录入背景与参会人，\n会中实时查看转写、结构总结与证据化分析。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("新建谈判") {
                router.showMeetingSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("提示：分析结果包含「明确表达」与「AI 推测」两类，\nAI 推测不等于事实，仅供辅助判断。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 会议列表
    private var meetingList: some View {
        List(meetings) { meeting in
            Button {
                switch meeting.status {
                case .completed:
                    router.showMeetingReview(meeting.id)
                case .recording, .paused, .finalizing:
                    router.showLiveMeeting(meeting.id)
                case .draft, .ready:
                    router.showMeetingSetup(editing: meeting.id)
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title)
                            .font(.headline)
                        Text(meeting.listSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(meeting.status.displayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    /// 云端未配置提示条（实施计划阶段 0 验收：无 API Key 时可进入本地界面，
    /// 但云端功能区明确标记「未配置」）
    private var cloudUnconfiguredBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
            Text("云端功能未配置：说话人识别与谈判分析暂不可用（本地录音与转写不受影响）。")
                .font(.callout)
            Spacer()
            Button("前往设置") {
                router.showSettings()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }

    private func warningBanner(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.red.opacity(0.12))
    }
}

private extension Meeting {
    /// 列表副标题：开始/创建时间的本地描述
    var listSubtitle: String {
        let date = startedAt ?? Date()
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
