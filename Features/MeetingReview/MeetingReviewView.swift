import SwiftUI

/// 会后页面（阶段 1）：
/// 会议信息查看 + 录音本地回放与时间跳转。
/// 完整转写（阶段 2/3）、结构总结与分析（阶段 4）、导出与删除（阶段 5）暂为占位说明。
struct MeetingReviewView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    let meetingID: UUID

    @State private var meeting: Meeting?
    @State private var playback = AudioPlaybackController()
    @State private var audioUnavailableNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let meeting {
                    headerSection(meeting: meeting)
                    playbackSection(meeting: meeting)
                    infoSection(meeting: meeting)
                    participantsSection(meeting: meeting)
                    placeholderSection
                } else {
                    Text("会议不存在或已被删除")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(meeting?.title ?? "会后")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回列表") {
                    router.showMeetingList()
                }
            }
        }
        .onAppear {
            loadMeeting()
        }
        .onDisappear {
            playback.stopTicker()
        }
    }

    // MARK: - 头部

    private func headerSection(meeting: Meeting) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.title)
                    .fontWeight(.bold)
                Text("状态：\(meeting.status.displayName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let startedAt = meeting.startedAt {
                    Text("开始于 \(startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - 回放

    private func playbackSection(meeting: Meeting) -> some View {
        GroupBox("会议录音回放") {
            VStack(alignment: .leading, spacing: 8) {
                if playback.isLoaded {
                    HStack(spacing: 12) {
                        Button {
                            playback.togglePlay()
                        } label: {
                            Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 28))
                        }
                        .buttonStyle(.plain)

                        Text(formatSeconds(playback.currentTime))
                            .monospacedDigit()
                        Slider(
                            value: Binding(
                                get: { playback.currentTime },
                                set: { playback.seek(to: $0) }
                            ),
                            in: 0...max(playback.duration, 0.01)
                        )
                        Text(formatSeconds(playback.duration))
                            .monospacedDigit()
                    }

                    if !meeting.pauseIntervals.isEmpty {
                        Text("录音中有 \(meeting.pauseIntervals.count) 段暂停区间（暂停期间无音频）：")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(Array(meeting.pauseIntervals.enumerated()), id: \.offset) { index, interval in
                            Text("第 \(index + 1) 段：\(Self.formatMs(interval.startMs)) — \(Self.formatMs(interval.endMs))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let audioUnavailableNote {
                    Label(audioUnavailableNote, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    ProgressView("正在加载录音…")
                }
            }
            .padding(8)
        }
    }

    // MARK: - 会议信息

    private func infoSection(meeting: Meeting) -> some View {
        GroupBox("会议信息") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("谈判背景", value: meeting.background)
                infoRow("我方目标", value: meeting.ourGoal)
                infoRow("我方底线", value: meeting.ourBottomLine)
                infoRow("对方背景", value: meeting.counterpartContext)
                if !meeting.glossary.isEmpty {
                    infoRow("专业词汇", value: meeting.glossary.joined(separator: "、"))
                }
            }
            .padding(8)
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "（未填写）" : value)
                .font(.callout)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
        }
    }

    // MARK: - 参会人

    private func participantsSection(meeting: Meeting) -> some View {
        GroupBox("参会人") {
            VStack(alignment: .leading, spacing: 6) {
                if meeting.participants.isEmpty {
                    Text("未录入参会人")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(meeting.participants) { participant in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(colorForToken(participant.colorToken))
                                .frame(width: 10, height: 10)
                            Text(participant.displayName).font(.headline)
                            Text(participant.side.displayName)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            if !participant.role.isEmpty {
                                Text(participant.role)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - 后续阶段占位

    private var placeholderSection: some View {
        GroupBox("后续功能") {
            VStack(alignment: .leading, spacing: 6) {
                Label("完整按人转写：阶段 2–3 实现", systemImage: "text.alignleft")
                Label("结构总结与证据化分析：阶段 4 实现", systemImage: "brain")
                Label("Markdown / JSON 导出与会议删除：阶段 5 实现", systemImage: "square.and.arrow.up")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(8)
        }
    }

    // MARK: - 行为

    private func loadMeeting() {
        guard meeting == nil else { return }
        guard let loaded = try? environment.allMeetings().first(where: { $0.id == meetingID }) else {
            return
        }
        meeting = loaded
        // 加载录音文件用于回放
        do {
            if let url = try environment.fileStore.audioFileURL(for: loaded),
               FileManager.default.fileExists(atPath: url.path) {
                try playback.load(url: url)
                playback.startTicker()
            } else {
                audioUnavailableNote = "没有找到本场会议的录音文件。"
            }
        } catch {
            audioUnavailableNote = "录音文件加载失败：\(error.localizedDescription)"
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        Self.formatMs(Int64(seconds * 1000))
    }

    /// 毫秒 → mm:ss
    static func formatMs(_ ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
