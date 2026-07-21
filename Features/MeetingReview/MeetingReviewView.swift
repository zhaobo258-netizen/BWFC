import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 会后页面（阶段 5，实施计划 5.4）：
/// 完整按人转写（可修订）、最终结构总结与证据化分析、证据回放联动、
/// 重新生成最终分析、Markdown/JSON 导出、整场会议删除（二次确认）。
struct MeetingReviewView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    let meetingID: UUID

    @State private var meeting: Meeting?
    @State private var playback = AudioPlaybackController()
    @State private var audioUnavailableNote: String?
    @State private var highlightedSegmentID: UUID?
    @State private var reanalysis: NegotiationAnalysisController?
    @State private var showDeleteConfirmation = false
    @State private var operationError: String?
    /// 待识别说话人展示名缓存（片段 ID → 「待识别 A」）
    @State private var unknownSpeakerNames: [UUID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if let meeting {
                headerBar(meeting: meeting)
                Divider()
                playbackBar(meeting: meeting)
                Divider()
                workingArea(meeting: meeting)
                Divider()
                TranscriptPanelView(
                    segments: meeting.segments
                        .filter { $0.state != .provisional }
                        .sorted { $0.startMs < $1.startMs },
                    participants: meeting.participants,
                    unknownSpeakerDisplay: { segment in
                        guard segment.participantId == nil else { return nil }
                        return unknownSpeakerNames[segment.id] ?? "识别中"
                    },
                    highlightedSegmentID: highlightedSegmentID,
                    onAssignSpeaker: { segment, participant in
                        if let participant {
                            MeetingTranscriptEditor.assignSpeaker(segment, to: participant)
                        } else {
                            MeetingTranscriptEditor.clearSpeaker(segment)
                        }
                        persistAndRebuild(meeting)
                    },
                    onEditText: { segment, newText in
                        MeetingTranscriptEditor.editText(segment, to: newText)
                        persistAndRebuild(meeting)
                    },
                    onToggleStar: { segment in
                        MeetingTranscriptEditor.toggleStar(segment)
                        persist(meeting)
                    }
                )
                .frame(height: 240)
            } else {
                Text("会议不存在或已被删除")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(meeting?.title ?? "会后")
        .onAppear { loadMeeting() }
        .onDisappear { playback.stopTicker() }
        .confirmationDialog(
            "删除本场会议？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                deleteMeeting()
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let meeting {
                Text(deletionSummary(for: meeting))
            }
        }
    }

    // MARK: - 头部操作区

    private func headerBar(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.title2)
                        .fontWeight(.bold)
                    HStack(spacing: 12) {
                        Text("状态：\(meeting.status.displayName)")
                        if let startedAt = meeting.startedAt {
                            Text("开始于 \(startedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        if let snapshot = meeting.latestSnapshot {
                            Text("分析版本 v\(snapshot.version)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("导出 Markdown") { exportMarkdown(meeting: meeting) }
                Button("导出 JSON") { exportJSON(meeting: meeting) }
                Button {
                    regenerateFinalAnalysis(meeting: meeting)
                } label: {
                    if reanalysis?.state == .analyzing {
                        Text("重新生成中…")
                    } else {
                        Text("重新生成最终分析")
                    }
                }
                .disabled(reanalysis?.state == .analyzing || !environment.isCloudConfigured)
                Button("删除会议", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
            if !environment.isCloudConfigured {
                Text("云端未配置：「重新生成最终分析」不可用。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let lastError = reanalysis?.lastErrorDescription {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let operationError {
                Text(operationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 回放条

    private func playbackBar(meeting: Meeting) -> some View {
        HStack(spacing: 12) {
            if playback.isLoaded {
                Button {
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                Text(formatSeconds(playback.currentTime)).monospacedDigit().font(.caption)
                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 0.01)
                )
                Text(formatSeconds(playback.duration)).monospacedDigit().font(.caption)
                if !meeting.pauseIntervals.isEmpty {
                    Text("含 \(meeting.pauseIntervals.count) 段暂停")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "waveform.slash")
                Text(audioUnavailableNote ?? "正在加载录音…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 工作区（复用会中组件）

    private func workingArea(meeting: Meeting) -> some View {
        HSplitView {
            StructureSummaryView(
                snapshot: meeting.latestSnapshot,
                participants: meeting.participants,
                segments: meeting.segments,
                onEvidenceTap: { locateAndPlay(segmentID: $0, in: meeting) }
            )
            .frame(minWidth: 280, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            InsightCardListView(
                snapshot: meeting.latestSnapshot,
                participants: meeting.participants,
                segments: meeting.segments,
                onEvidenceTap: { locateAndPlay(segmentID: $0, in: meeting) }
            )
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 行为

    private func loadMeeting() {
        guard meeting == nil else { return }
        guard let loaded = try? environment.allMeetings().first(where: { $0.id == meetingID }) else {
            return
        }
        meeting = loaded
        rebuildUnknownSpeakerNames(for: loaded)
        // 加载录音用于回放
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
        // 准备「重新生成最终分析」控制器
        let controller = NegotiationAnalysisController(service: environment.negotiationAnalysis)
        controller.attach(to: loaded)
        reanalysis = controller
    }

    /// 点击证据：定位到转写片段并从对应时间播放录音（实施计划 5.4）
    private func locateAndPlay(segmentID: UUID, in meeting: Meeting) {
        highlightedSegmentID = segmentID
        guard playback.isLoaded,
              let segment = meeting.segments.first(where: { $0.id == segmentID }) else {
            return
        }
        playback.seek(to: TimeInterval(segment.startMs) / 1000)
        if !playback.isPlaying {
            playback.togglePlay()
        }
    }

    /// 人工修订后重新生成最终分析（完整最终转写，替换快照，实施计划 5.4）
    private func regenerateFinalAnalysis(meeting: Meeting) {
        guard let reanalysis else { return }
        Task {
            await reanalysis.generateFinalAnalysis()
            persist(meeting)
        }
    }

    /// 导出 Markdown（NSSavePanel 由用户选择位置；导出内容不含 API Key）
    private func exportMarkdown(meeting: Meeting) {
        do {
            let markdown = try environment.exporter.makeMarkdown(for: meeting.id)
            let panel = NSSavePanel()
            panel.title = "导出 Markdown 纪要"
            panel.nameFieldStringValue = "\(meeting.title)-纪要.md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md")].compactMap { $0 }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            operationError = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 导出 JSON（NSSavePanel 由用户选择位置）
    private func exportJSON(meeting: Meeting) {
        do {
            let data = try environment.exporter.makeJSONData(for: meeting.id)
            let panel = NSSavePanel()
            panel.title = "导出 JSON 原始结构"
            panel.nameFieldStringValue = "\(meeting.title)-原始结构.json"
            panel.allowedContentTypes = [UTType.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            operationError = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 删除确认文案：明确列明将删除的内容（实施计划 12.1）
    private func deletionSummary(for meeting: Meeting) -> String {
        let sampleCount = meeting.participants.filter { $0.voiceReferencePath != nil }.count
        return """
        将永久删除「\(meeting.title)」的以下全部内容，且不可恢复：
        · 本地完整录音文件
        · \(sampleCount) 份声音样本
        · 全部临时分片与上传队列状态
        · 数据库中的会议、参会人、\(meeting.segments.count) 条转写与 \(meeting.snapshots.count) 版分析记录
        """
    }

    private func deleteMeeting() {
        guard let meeting else { return }
        do {
            playback.stopTicker()
            try environment.deleteMeeting(meeting)
            router.showMeetingList()
        } catch {
            operationError = "删除失败：\(error.localizedDescription)"
        }
    }

    private func persist(_ meeting: Meeting) {
        try? environment.persist(meeting)
    }

    /// 修订后持久化并重建待识别展示名缓存
    private func persistAndRebuild(_ meeting: Meeting) {
        persist(meeting)
        rebuildUnknownSpeakerNames(for: meeting)
    }

    /// 按时间序解析未知说话人标签，稳定分配「待识别 A/B」
    private func rebuildUnknownSpeakerNames(for meeting: Meeting) {
        var mapper = SpeakerMapper(participants: meeting.participants)
        var names: [UUID: String] = [:]
        for segment in meeting.segments.sorted(by: { $0.startMs < $1.startMs })
        where segment.participantId == nil {
            if case .unknown(let displayName) = mapper.resolve(remoteLabel: segment.remoteSpeakerLabel) {
                names[segment.id] = displayName
            }
        }
        unknownSpeakerNames = names
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
