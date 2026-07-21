import SwiftUI

/// 会中界面（阶段 2）：
/// 顶部状态栏（录音状态、时长、麦克风、本地转写状态）、录音控制、
/// 底部同声转写（本地即时文字 + 临时/最终状态）。
/// 左右两栏分析为阶段 4 占位。
struct LiveMeetingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    let meetingID: UUID

    @State private var meeting: Meeting?
    @State private var recorder: MeetingRecordingService?
    @State private var transcription: LocalTranscriptionController?
    @State private var diarization: DiarizationController?
    @State private var showEndConfirmation = false
    @State private var operationError: String?
    @State private var newDeviceID: String?
    /// 分片轮询定时器（录音中每 2 秒检查一次分片产出）
    private let chunkPollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if let meeting {
                statusBar(meeting: meeting)
                Divider()
                if recorder?.deviceInterrupted == true {
                    deviceInterruptedBanner(meeting: meeting)
                }
                if case .suspended(let reason) = diarization?.cloudState {
                    cloudSuspendedBanner(reason: reason)
                }
                if let operationError {
                    errorBanner(text: operationError)
                }
                workingArea(meeting: meeting)
                Divider()
                TranscriptPanelView(
                    segments: transcription?.segments ?? [],
                    participants: meeting.participants,
                    unknownSpeakerDisplay: { segment in
                        guard segment.participantId == nil else { return nil }
                        return diarization?.displayName(forRemoteLabel: segment.remoteSpeakerLabel)
                    },
                    onAssignSpeaker: { segment, participant in
                        if let participant {
                            MeetingTranscriptEditor.assignSpeaker(segment, to: participant)
                        } else {
                            MeetingTranscriptEditor.clearSpeaker(segment)
                        }
                        persistAndRefresh(meeting)
                    },
                    onEditText: { segment, newText in
                        MeetingTranscriptEditor.editText(segment, to: newText)
                        persistAndRefresh(meeting)
                    },
                    onToggleStar: { segment in
                        MeetingTranscriptEditor.toggleStar(segment)
                        persistAndRefresh(meeting)
                    }
                )
                .frame(height: 220)
            } else {
                Text("会议不存在或已被删除")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(meeting?.title ?? "会中")
        .onAppear {
            loadMeetingAndRecorder()
        }
        .onReceive(chunkPollTimer) { _ in
            diarization?.pollProgress()
        }
        .confirmationDialog(
            "结束本场会议？",
            isPresented: $showEndConfirmation,
            titleVisibility: .visible
        ) {
            Button("结束会议", role: .destructive) {
                finishRecording()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("结束后将停止录音与转写并进入会后页面，不能重新开始。")
        }
    }

    // MARK: - 顶部状态栏（实施计划 6.2）

    private func statusBar(meeting: Meeting) -> some View {
        HStack(spacing: 16) {
            // 录音状态：录音中使用清晰红点，不允许隐蔽录音界面
            HStack(spacing: 6) {
                if meeting.status == .recording {
                    Circle().fill(.red).frame(width: 10, height: 10)
                }
                Text(meeting.status.displayName)
                    .fontWeight(.medium)
            }

            // 录音时长（墙钟，含暂停）
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.formatDuration(ms: recorder?.elapsedWallMs(at: context.date) ?? 0))
                    .monospacedDigit()
            }

            Divider().frame(height: 16)

            // 当前麦克风
            Label(recorder?.activeMicrophoneName ?? "未选择麦克风", systemImage: "mic")
                .font(.callout)
                .foregroundStyle(.secondary)

            // 本地转写状态
            Label(transcriptionStatusText, systemImage: "text.bubble")
                .font(.callout)
                .foregroundStyle(transcriptionStatusColor)

            // 云端说话人识别状态（实施计划 6.2）
            Label(diarizationStatusText, systemImage: "person.2.waveform")
                .font(.callout)
                .foregroundStyle(diarizationStatusColor)

            Spacer()

            // 待用户重试的分片（超过自动重试上限）
            if let diarization, diarization.awaitingUserRetryCount > 0 {
                Button("重试 \(diarization.awaitingUserRetryCount) 个失败分片") {
                    diarization.retryAwaitingUserChunks()
                }
                .font(.caption)
            }

            // 云端 Key 配置状态（未配置时明确标记）
            Text(environment.isCloudConfigured ? "云端已配置" : "云端未配置")
                .font(.caption)
                .foregroundStyle(environment.isCloudConfigured ? .green : .orange)

            // 控制按钮
            switch meeting.status {
            case .ready:
                Button("开始录音") {
                    startRecording(meeting: meeting)
                }
                .buttonStyle(.borderedProminent)
            case .recording:
                Button("暂停") {
                    run { try recorder?.pauseRecording(); persist(meeting) }
                }
                Button("结束") { showEndConfirmation = true }
                    .foregroundStyle(.red)
            case .paused:
                Button("继续") {
                    run { try recorder?.resumeRecording(); persist(meeting) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder?.deviceInterrupted == true)
                Button("结束") { showEndConfirmation = true }
                    .foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 本地转写状态文案（实施计划 6.2：本地转写状态必须始终显示）
    private var transcriptionStatusText: String {
        guard let transcription else { return "本地转写待启动" }
        switch transcription.runState {
        case .idle: return "本地转写就绪"
        case .running: return "本地转写中"
        case .unavailable(let reason): return "本地转写不可用：\(reason)"
        }
    }

    private var transcriptionStatusColor: Color {
        guard let transcription else { return .secondary }
        switch transcription.runState {
        case .idle: return .secondary
        case .running: return .green
        case .unavailable: return .orange
        }
    }

    /// 云端说话人识别状态文案（实施计划 6.2：云端说话人识别状态）
    private var diarizationStatusText: String {
        guard let diarization else { return "云端识别待启动" }
        switch diarization.cloudState {
        case .idle:
            return "云端识别正常"
        case .working(let pending):
            return pending > 0 ? "云端识别中（待处理 \(pending)）" : "云端识别正常"
        case .suspended:
            return "云端识别暂停"
        }
    }

    private var diarizationStatusColor: Color {
        guard let diarization else { return .secondary }
        switch diarization.cloudState {
        case .idle, .working: return .green
        case .suspended: return .orange
        }
    }

    // MARK: - 设备中断提示（实施计划 11.2：麦克风拔出）

    private func deviceInterruptedBanner(meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash")
            Text("麦克风已断开。录音已自动暂停，请选择新设备后继续。")
                .font(.callout)
            Picker("新设备", selection: $newDeviceID) {
                Text("选择设备").tag(String?.none)
                ForEach(environment.audioCapture.inputDevices(), id: \.id) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
            }
            .frame(maxWidth: 240)
            Button("使用该设备") {
                guard let newDeviceID else { return }
                run {
                    try recorder?.switchInputDevice(to: newDeviceID)
                    meeting.preferredInputDeviceID = newDeviceID
                    persist(meeting)
                }
            }
            .disabled(newDeviceID == nil)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }

    // MARK: - 云端暂停提示（401 / 未配置 Key：本地录音继续，修复后可重试）

    private func cloudSuspendedBanner(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
            Text("云端分析暂停，本地录音与转写正常。\(reason)")
                .font(.callout)
            Spacer()
            Button("已修复，重试") {
                Task { @MainActor in
                    environment.refreshCloudConfiguration()
                    diarization?.resumeAfterKeyFix()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }

    // MARK: - 工作区占位（阶段 4 实现左侧结构与右侧分析）

    private func workingArea(meeting: Meeting) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("结构总结")
                    .font(.headline)
                Text("议题、双方立场、已确认与未决事项将在阶段 4 由分析快照驱动。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 8) {
                Text("谈判分析")
                    .font(.headline)
                Text("诉求、顾虑、动机、态度、让步与矛盾的证据化分析将在阶段 4 实现。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 行为

    private func errorBanner(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(text).font(.callout)
            Spacer()
            Button("知道了") { operationError = nil }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.red.opacity(0.1))
    }

    private func loadMeetingAndRecorder() {
        guard meeting == nil else { return }
        guard let loaded = try? environment.allMeetings().first(where: { $0.id == meetingID }) else {
            return
        }
        meeting = loaded
        let recordingService = MeetingRecordingService(
            capture: environment.audioCapture,
            fileStore: environment.fileStore
        )
        recorder = recordingService
        let controller = LocalTranscriptionController(service: environment.localTranscription)
        controller.onFinalSegment = { [environment, loaded] in
            try? environment.persist(loaded)
        }
        transcription = controller
        diarization = DiarizationController(
            diarization: environment.diarization,
            fileStore: environment.fileStore,
            transcriptController: controller
        )
        // 进入界面即检查本地转写可用性（不可用时在状态栏显示真实原因）
        Task { await controller.checkAvailability() }
    }

    private func startRecording(meeting: Meeting) {
        // 录音前再次校验麦克风权限；拒绝时给出系统设置入口（实施计划 11.2）
        guard MicrophonePermission.currentStatus == .authorized else {
            operationError = "未获得麦克风权限。请在「系统设置 → 隐私与安全性 → 麦克风」中允许「帮我分析」后重试。"
            MicrophonePermission.openSystemSettings()
            return
        }

        // Apple 中文模型不可用：阻止开始并显示真实原因，不静默切换（实施计划 11.2）
        if let availability = transcription?.availability, !availability.isReady {
            operationError = "无法开始：本地中文转写不可用。\n\(availability.issueSummary ?? "")"
            return
        }

        Task {
            // 可用性尚未返回时先等待一次检查结果
            if transcription?.availability == nil {
                let result = await transcription?.checkAvailability()
                if result?.isReady == false {
                    operationError = "无法开始：本地中文转写不可用。\n\(result?.issueSummary ?? "")"
                    return
                }
            }

            do {
                try recorder?.startRecording(for: meeting, deviceID: meeting.preferredInputDeviceID)
                persist(meeting)
                operationError = nil

                // 录音成功后启动本地转写，并把缓冲分发给 SpeechAnalyzer
                if let recorder, let transcription {
                    try await transcription.start(for: meeting) { [weak recorder] in
                        recorder?.timeline
                    }
                    // 采集线程直接喂给转写服务（服务内部按会话状态丢弃空转输入）
                    let transcriptionService = environment.localTranscription
                    environment.audioCapture.onBuffer = { buffer in
                        let boxed = SendableAudioBuffer(buffer)
                        Task { await transcriptionService.feed(boxed.buffer) }
                    }
                    // 启动云端说话人识别编排（恢复既有队列；未配置 Key 时进入暂停态）
                    if environment.isCloudConfigured {
                        diarization?.start(for: meeting) { [weak recorder] in
                            recorder?.timeline
                        }
                    }
                }
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func finishRecording() {
        guard let meeting else { return }
        Task {
            do {
                // 阶段 3：先进入 finalizing，等待分片队列处理完毕再 completed
                try recorder?.beginFinish()
                persist(meeting)
                environment.audioCapture.onBuffer = nil
                await transcription?.finish()
                await diarization?.finishAndDrain()
                try recorder?.completeFinalizing()
                persist(meeting)
                operationError = nil
            } catch {
                operationError = error.localizedDescription
                return
            }
            persist(meeting)
            router.showMeetingReview(meeting.id)
        }
    }

    /// 执行可失败操作并把错误转为界面提示
    private func run(_ operation: () throws -> Void) {
        do {
            try operation()
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func persist(_ meeting: Meeting) {
        try? environment.persist(meeting)
    }

    /// 人工编辑后持久化并刷新转写视图
    private func persistAndRefresh(_ meeting: Meeting) {
        try? environment.persist(meeting)
        transcription?.refreshSegments()
    }

    /// 毫秒 → hh:mm:ss
    static func formatDuration(ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
