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
    @State private var analysis: NegotiationAnalysisController?
    @State private var showEndConfirmation = false
    @State private var operationError: String?
    @State private var newDeviceID: String?
    /// 证据定位高亮（点击左右两栏证据 → 底部片段滚动 + 高亮）
    @State private var highlightedSegmentID: UUID?
    /// 结束时分片未处理完毕的选择弹窗（实施计划 11.2：允许稍后继续处理）
    @State private var showPendingChunksChoice = false
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
                if transcription?.availability?.assetState == .supportedNotInstalled
                    || transcription?.assetDownloadProgress != nil {
                    assetDownloadBanner
                }
                if case .suspended(let reason) = diarization?.cloudState {
                    cloudSuspendedBanner(reason: reason)
                }
                if case .suspended(let reason) = analysis?.state {
                    analysisSuspendedBanner(reason: reason)
                }
                if let operationError {
                    errorBanner(text: operationError)
                }
                if PerfCounters.isDebugOverlayEnabled {
                    debugCountersBar
                }
                workingArea(meeting: meeting)
                Divider()
                TranscriptPanelView(
                    segments: transcription?.segments ?? meeting.segments,
                    participants: meeting.participants,
                    unknownSpeakerDisplay: { segment in
                        guard segment.participantId == nil else { return nil }
                        return diarization?.displayName(forRemoteLabel: segment.remoteSpeakerLabel)
                    },
                    highlightedSegmentID: highlightedSegmentID,
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
            // 分析调度器周期驱动（触发条件与防抖由 AnalysisTrigger 判定）
            Task { await analysis?.tick() }
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
        .alert("还有分片未能上传处理", isPresented: $showPendingChunksChoice) {
            Button("重试并继续等待") {
                retryAndContinueFinish()
            }
            Button("稍后继续处理") {
                completeFinishAnyway()
            }
        } message: {
            Text("录音已安全保存在本机。失败分片已保留在本机队列中：选择「稍后继续处理」将先结束会议，下次打开时可继续补传；选择「重试并继续等待」将立即重试。")
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
                let _ = PerfCounters.increment(.timerTick) // 计时器存证（渲染风暴排查）
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

            // 云端分析状态（实施计划 6.2：含上次更新时间）
            Label(analysisStatusText, systemImage: "brain")
                .font(.callout)
                .foregroundStyle(analysisStatusColor)

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

    /// 云端分析状态文案（实施计划 6.2：云端分析状态及上次更新时间）
    private var analysisStatusText: String {
        guard let analysis else { return "分析待启动" }
        switch analysis.state {
        case .idle:
            if let lastSuccessAt = analysis.lastSuccessAt {
                return "分析正常（更新于 \(lastSuccessAt.formatted(date: .omitted, time: .shortened))）"
            }
            return "分析待内容积累"
        case .analyzing:
            return "分析中…"
        case .suspended:
            return "云端分析暂停"
        }
    }

    private var analysisStatusColor: Color {
        guard let analysis else { return .secondary }
        switch analysis.state {
        case .idle: return .secondary
        case .analyzing: return .green
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

    // MARK: - 调试计数条（渲染风暴排查；UserDefaults bwfxDebugCounters=YES 开启）

    private var debugCountersBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PerfCounters.snapshot(), id: \.counter) { item in
                        Text("\(item.counter.rawValue) \(item.count)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 4)
            .background(.black.opacity(0.05))
        }
    }

    // MARK: - 中文语言资源下载横幅（supported 但未安装：一键下载）

    private var assetDownloadBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
            if let progress = transcription?.assetDownloadProgress {
                Text("正在下载中文语言资源…")
                    .font(.callout)
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("本地中文转写需要下载语言资源。下载后即可开始录音转写。")
                    .font(.callout)
                Button("下载中文语言资源") {
                    Task { await transcription?.installChineseAssets() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(transcription?.canInstallChineseAssets != true)
            }
            if let error = transcription?.assetInstallError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("重试") {
                    Task { await transcription?.installChineseAssets() }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.blue.opacity(0.08))
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

    // MARK: - 云端分析暂停提示（401：本地继续，修复后可重试）

    private func analysisSuspendedBanner(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
            Text("云端分析暂停，本地录音与转写正常。\(reason)")
                .font(.callout)
            Spacer()
            Button("已修复，重试") {
                Task { @MainActor in
                    environment.refreshCloudConfiguration()
                    analysis?.resumeAfterKeyFix()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }

    // MARK: - 工作区（实施计划 6.1：左结构总结 32% / 右谈判分析 68%）

    private func workingArea(meeting: Meeting) -> some View {
        HSplitView {
            StructureSummaryView(
                snapshot: analysis?.currentSnapshot,
                participants: meeting.participants,
                segments: transcription?.segments ?? meeting.segments,
                onEvidenceTap: locateEvidence
            )
            .frame(minWidth: 280, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            InsightCardListView(
                snapshot: analysis?.currentSnapshot,
                participants: meeting.participants,
                segments: transcription?.segments ?? meeting.segments,
                onEvidenceTap: locateEvidence
            )
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    /// 点击证据：定位到底部对应片段（滚动 + 高亮，实施计划 6.4）
    private func locateEvidence(segmentID: UUID) {
        highlightedSegmentID = segmentID
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
        let analysisController = NegotiationAnalysisController(service: environment.negotiationAnalysis)
        analysisController.attach(to: loaded)
        analysisController.onSnapshotUpdated = { [environment, loaded] in
            try? environment.persist(loaded)
        }
        // 新最终片段驱动分析调度（本地与云端确认都会触发）
        controller.onNewFinalSegment = { [weak analysisController] in
            analysisController?.noteNewFinalSegment()
        }
        analysis = analysisController
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
                try recorder?.beginFinish()
                persist(meeting)
                environment.audioCapture.onBuffer = nil
                await transcription?.finish()
                await diarization?.finishAndDrain()
                // 仍有待处理分片：由用户选择稍后处理或重试等待（实施计划 11.2）
                if (diarization?.awaitingUserRetryCount ?? 0) > 0 {
                    showPendingChunksChoice = true
                    return
                }
                await analysis?.generateFinalAnalysis()
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

    /// 重试失败分片并继续收尾（用户选择「重试并继续等待」）
    private func retryAndContinueFinish() {
        guard let meeting else { return }
        Task {
            diarization?.retryAwaitingUserChunks()
            diarization?.resumeAfterKeyFix()
            await diarization?.finishAndDrain()
            if (diarization?.awaitingUserRetryCount ?? 0) > 0 {
                // 仍未成功：再次交给用户选择
                showPendingChunksChoice = true
                return
            }
            await analysis?.generateFinalAnalysis()
            try? recorder?.completeFinalizing()
            persist(meeting)
            router.showMeetingReview(meeting.id)
        }
    }

    /// 稍后继续处理：先结束会议，分片队列保留在本机（实施计划 11.2）
    private func completeFinishAnyway() {
        guard let meeting else { return }
        Task {
            await analysis?.generateFinalAnalysis()
            try? recorder?.completeFinalizing()
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
