import SwiftUI

/// 项目工作台（阶段 B，方案 3「知识花园」三栏骨架，03 文档 §6.3）：
/// 左栏录音文稿 / 中栏 AI 工作区 / 右栏我的笔记。
///
/// 持久化权威为 ProjectStoring：现有录音、转写、分人、分析链路在内存中
/// 驱动同 id 的运行时 Meeting（ProjectRuntimeSession 桥接），状态变化回写 Project。
/// 技术状态（转写/分人/分析/Key/分片）收进「处理详情」弹层，不占据主工作区；
/// 异常（麦克风断开、语言资源缺失、云端暂停）才出现非阻塞横幅。
struct ProjectWorkspaceView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    let projectID: UUID
    /// 来自首页「开始录音」：进入即开始录音（两次交互内开录）
    let autoStart: Bool

    @State private var project: Project?
    @State private var meeting: Meeting?
    @State private var recorder: MeetingRecordingService?
    @State private var transcription: LocalTranscriptionController?
    @State private var diarization: DiarizationController?
    @State private var analysis: ConversationAnalysisController?
    @State private var noteController: NoteController?
    @State private var runtimePersistence: ProjectRuntimePersistenceController?
    @State private var operationError: String?
    @State private var highlightedSegmentID: UUID?
    @State private var showEndConfirmation = false
    @State private var isFinishing = false
    @State private var showBackConfirmation = false
    @State private var showSpeakerPanel = false
    @State private var newDeviceID: String?
    /// 中栏页签：结构总结 / 分析卡片（阶段 D 换通用分析后扩展四页签）
    @State private var centerTab: CenterTab = .summary
    /// 本会话已在当前视图内实际开录（恢复横幅只在「打开时即异常」的旧会话上出现，
    /// 当前活动录音不算异常）
    @State private var didStartSessionThisView = false
    @State private var timerAnchor = Date()
    private let chunkPollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private enum CenterTab: String, CaseIterable {
        case summary = "实时总结"
        case insights = "动机与目的"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let project, let meeting {
                topBar(project: project, meeting: meeting)
                Divider()
                if recorder?.writeFailureInterrupted == true {
                    writeFailureBanner
                } else if recorder?.deviceInterrupted == true {
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
                if meeting.status.isAbnormalIfAppRelaunched, !isFinishing, !didStartSessionThisView,
                   environment.importProcessing.activeProjectID != project.id {
                    abnormalBanner(meeting: meeting)
                }
                if let operationError {
                    errorBanner(text: operationError)
                }
                if project.sourceType != .liveRecording {
                    importProgressSection(project: project)
                }
                ThreeColumnLayout {
                    transcriptColumn(meeting: meeting)
                        .background(BWTheme.columnBackground)
                } center: {
                    analysisColumn(meeting: meeting)
                        .background(BWTheme.paper)
                } right: {
                    noteColumn
                        .background(BWTheme.columnBackground)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if meeting.status == .recording || meeting.status == .paused {
                    Divider()
                    bottomRecordBar(meeting: meeting)
                }
            } else {
                Text("项目不存在或已被删除")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(project?.title ?? "项目")
        .onAppear { loadProject() }
        .onDisappear {
            noteController?.saveNow()
            runtimePersistence?.flush()
        }
        .onReceive(chunkPollTimer) { _ in
            diarization?.pollProgress()
            Task { await analysis?.tick() }
        }
        .onChange(of: importJobsStatusKey) { _, _ in
            reloadImportedProjectFromStore()
        }
        .confirmationDialog("结束录音？", isPresented: $showEndConfirmation, titleVisibility: .visible) {
            Button("结束录音", role: .destructive) { finishRecording() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("结束后将停止录音与转写，剩余分析在后台继续。录音与文稿已安全保存在本机。")
        }
        .sheet(isPresented: $showSpeakerPanel) {
            if let project, let meeting {
                SpeakerPanelView(
                    project: project,
                    meeting: meeting,
                    microphoneBusy: meeting.status == .recording,
                    onSpeakersChanged: {
                        persistProject(fields: .speakers)
                        diarization?.refreshKnownSpeakers()
                    }
                )
                .environment(environment)
            }
        }
        .confirmationDialog("录音仍在进行", isPresented: $showBackConfirmation, titleVisibility: .visible) {
            Button("结束录音并返回", role: .destructive) {
                finishRecording()
                attemptNavigateHome()
            }
            Button("继续录音", role: .cancel) {}
        } message: {
            Text("返回首页前需要先结束录音。笔记未保存成功时不会离开工作台。")
        }
    }

    // MARK: - 导航门禁

    /// 笔记保存门禁（Codex 审计补强）：保存失败不得离开工作台
    static func canNavigateHome(afterNoteSave saveSucceeded: Bool) -> Bool {
        saveSucceeded
    }

    /// 返回首页前强制落盘笔记；失败则停留并显示错误与重试入口
    private func attemptNavigateHome() {
        let saved = noteController?.saveNow() ?? true
        guard Self.canNavigateHome(afterNoteSave: saved) else {
            operationError = "笔记尚未保存成功，已阻止返回。请在右栏检查错误并重试保存。"
            return
        }
        router.showProjectHome()
    }

    // MARK: - 顶部栏（03 §6.3：只保留标题、录音状态、同步状态与少量全局动作）

    private func topBar(project: Project, meeting: Meeting) -> some View {
        HStack(spacing: 12) {
            Button {
                if meeting.status == .recording || meeting.status == .paused {
                    showBackConfirmation = true
                } else {
                    attemptNavigateHome()
                }
            } label: {
                Label("项目", systemImage: "chevron.left")
            }

            // 项目标题：可单击修改
            TitleField(title: Binding(
                get: { project.title },
                set: { newTitle in
                    project.title = newTitle
                    meeting.title = newTitle
                    project.lastActivityAt = Date()
                    persistProject(fields: .title)
                }
            ))

            // 录音状态（录音中红点清晰可见）
            HStack(spacing: 6) {
                if meeting.status == .recording {
                    Circle().fill(.red).frame(width: 10, height: 10)
                }
                if isFinishing {
                    Text("正在收尾…可返回首页")
                        .foregroundStyle(.secondary)
                } else {
                    Text(project.status.displayName)
                }
            }
            .font(.callout)

            // 录音时长（墙钟，含暂停；与 durationMs 口径一致）
            if meeting.status == .recording || meeting.status == .paused {
                TimelineView(.periodic(from: timerAnchor, by: 1)) { context in
                    Text(LiveMeetingView.formatDuration(ms: recorder?.elapsedWallMs(at: context.date) ?? 0))
                        .monospacedDigit()
                        .font(.callout)
                }
            }

            // ready：显示开始/重试开始（麦克风授权、资源下载或临时错误修复后可在原项目重试）
            if meeting.status == .ready {
                Button("开始录音") {
                    startRecording(meeting: meeting)
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            // 说话人与声纹面板
            Button {
                showSpeakerPanel = true
            } label: {
                Label("说话人", systemImage: "person.2")
            }
            .help("管理说话人与声纹样本")

            // 技术状态收进处理详情弹层
            ProcessingDetailsButton(
                transcription: transcription,
                diarization: diarization,
                analysis: analysis,
                microphoneName: recorder?.activeMicrophoneName,
                isAnalysisConfigured: environment.isAnalysisConfigured,
                isDiarizationConfigured: environment.isDiarizationConfigured,
                onRetryChunks: { diarization?.retryAwaitingUserChunks() },
                onFixDiarization: {
                    environment.refreshCloudConfiguration()
                    diarization?.resumeAfterKeyFix()
                },
                onFixAnalysis: {
                    environment.refreshCloudConfiguration()
                    analysis?.resumeAfterKeyFix()
                }
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 可单击编辑的项目标题
    private struct TitleField: View {
        @Binding var title: String
        @State private var draft: String = ""
        @State private var isEditing = false

        var body: some View {
            if isEditing {
                TextField("项目标题", text: $draft, onCommit: {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { title = trimmed }
                    isEditing = false
                })
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            } else {
                Button {
                    draft = title
                    isEditing = true
                } label: {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("单击修改项目标题")
            }
        }
    }

    // MARK: - 三栏

    private func transcriptColumn(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("录音文稿")
            TranscriptPanelView(
                // 控制器只反映本会话实时转写；只读回看与导入项目用已持久化片段
                segments: (transcription?.segments.isEmpty ?? true) ? meeting.segments : (transcription?.segments ?? []),
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
                },
                onGlobalCorrect: { wrong, right in
                    globalCorrect(wrong: wrong, right: right, meeting: meeting)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func analysisColumn(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(BWTheme.accent)
                    .frame(width: 3, height: 13)
                Text("AI 工作区")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let project {
                    scenarioPicker(project: project)
                }
                Spacer()
                if analysis?.state == .analyzing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("分析中")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if analysis?.hasRecentFailure == true {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(analysis?.statusDescription ?? "")
                }
                Picker("", selection: $centerTab) {
                    ForEach(CenterTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // 旧谈判项目（仅有迁移快照、无 V2 快照）继续用旧渲染（03 §16D 兼容显示）
            let showLegacy = analysis?.currentSnapshot == nil
                && !(project?.legacySnapshots.isEmpty ?? true)
            switch centerTab {
            case .summary:
                if showLegacy {
                    StructureSummaryView(
                        snapshot: legacySnapshot,
                        participants: meeting.participants,
                        segments: transcription?.segments ?? meeting.segments,
                        onEvidenceTap: locateEvidence
                    )
                } else {
                    ConversationAnalysisView(
                        snapshot: analysis?.currentSnapshot,
                        summaryTab: true,
                        speakers: project?.speakers ?? [],
                        onEvidenceTap: locateEvidence
                    )
                }
            case .insights:
                if showLegacy {
                    InsightCardListView(
                        snapshot: legacySnapshot,
                        participants: meeting.participants,
                        segments: transcription?.segments ?? meeting.segments,
                        onEvidenceTap: locateEvidence
                    )
                } else {
                    ConversationAnalysisView(
                        snapshot: analysis?.currentSnapshot,
                        summaryTab: false,
                        speakers: project?.speakers ?? [],
                        onEvidenceTap: locateEvidence
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 旧谈判快照（迁移项目回看）
    private var legacySnapshot: AnalysisSnapshot? {
        project?.legacySnapshots.max(by: { $0.version < $1.version })
    }

    /// 场景选择器（03 §3.2：自动建议 + 用户随时修正；不阻塞任何流程）
    private func scenarioPicker(project: Project) -> some View {
        Menu {
            ForEach(ProjectScenario.allCases, id: \.self) { scenario in
                Button {
                    project.scenario = scenario
                    project.scenarioWasUserSelected = true
                    persistProject(fields: .userScenario)
                } label: {
                    if project.scenario == scenario {
                        Label(scenario.displayName, systemImage: "checkmark")
                    } else {
                        Text(scenario.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "tag")
                Text(project.scenario?.displayName ?? "场景：自动")
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(project.scenarioWasUserSelected ? "场景（已手动选择）" : "场景（自动建议，可修正）")
    }

    private var noteColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("我的笔记")
            if let noteController {
                TextEditor(text: Binding(
                    get: { noteController.markdown },
                    set: { noteController.update(markdown: $0) }
                ))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                // 保存状态：成功显示时间；失败如实显示（不静默丢失）
                HStack(spacing: 6) {
                    if let saveError = noteController.saveError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("笔记保存失败（\(saveError)），内容仍保留在编辑区，请重试")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("重试") { noteController.saveNow() }
                            .font(.caption)
                    } else if let savedAt = noteController.lastSavedAt {
                        Text("已自动保存 \(Self.timeString(savedAt))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    } else {
                        Text("输入后自动保存")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func columnHeader(_ title: String) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(BWTheme.accent)
                .frame(width: 3, height: 13)
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 底部录音条（录音/暂停时始终可达：暂停 / 继续 / 标记 / 结束）

    private func bottomRecordBar(meeting: Meeting) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                if meeting.status == .recording {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text("录音中")
                } else {
                    Circle().fill(.orange).frame(width: 10, height: 10)
                    Text("已暂停")
                }
            }
            .font(.callout)

            TimelineView(.periodic(from: timerAnchor, by: 1)) { context in
                Text(LiveMeetingView.formatDuration(ms: recorder?.elapsedWallMs(at: context.date) ?? 0))
                    .monospacedDigit()
                    .font(.callout)
            }

            Spacer()

            Button("标记") {
                if let latest = meeting.segments.last {
                    MeetingTranscriptEditor.toggleStar(latest)
                    persistAndRefresh(meeting)
                }
            }
            .disabled(meeting.segments.isEmpty)

            if meeting.status == .recording {
                Button("暂停") {
                    run { try recorder?.pauseRecording(); syncAndPersist(meeting) }
                }
            } else {
                Button("继续") {
                    run { try recorder?.resumeRecording(); syncAndPersist(meeting) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder?.deviceInterrupted == true)
            }

            Button("结束录音", role: .destructive) {
                showEndConfirmation = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 横幅（仅异常时出现，非阻塞）

    private var writeFailureBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
            Text(RecordingInterruptionReason.fileWriteFailure.userMessage)
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.red.opacity(0.1))
    }

    private func deviceInterruptedBanner(meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash")
            Text(RecordingInterruptionReason.deviceDisconnected.userMessage)
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
                    syncAndPersist(meeting)
                }
            }
            .disabled(newDeviceID == nil)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }

    private var assetDownloadBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
            if let progress = transcription?.assetDownloadProgress {
                Text("正在下载中文语言资源…")
                    .font(.callout)
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
            } else {
                Text("本地中文转写需要下载语言资源。下载后即可开始录音转写。")
                    .font(.callout)
                Button("下载中文语言资源") {
                    Task { await transcription?.installChineseAssets() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(transcription?.canInstallChineseAssets != true)
            }
            if transcription?.assetInstallError != nil {
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

    private func cloudSuspendedBanner(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.waveform")
            Text("说话人识别暂停，本地录音与转写正常。\(reason)")
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

    /// 未正常结束项目的恢复提示（恢复中心语义：查看 / 标记已结束，不自动删除任何内容）
    private func abnormalBanner(meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            Text("此项目上次未正常结束（\(meeting.status.displayName)）。录音与文稿已保留在本机。")
                .font(.callout)
            Spacer()
            Button("标记为已结束") {
                do {
                    try MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
                    syncAndPersist(meeting)
                } catch {
                    operationError = error.localizedDescription
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.yellow.opacity(0.12))
    }

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

    // MARK: - 导入处理进度（阶段 C，03 §6.2：每个阶段独立显示进度，失败可从失败阶段重试）

    /// 导入 Job 阶段的中文名
    static func importStageName(_ kind: ProcessingJobKind) -> String {
        switch kind {
        case .audioExtraction: return "提取音轨"
        case .transcription: return "转写"
        case .diarization: return "分人"
        case .analysis: return "分析"
        case .knowledgeExpansion: return "知识关联"
        case .obsidianArchive: return "归档"
        }
    }

    private func importProgressSection(project: Project) -> some View {
        let importer = environment.importProcessing
        let isActive = importer.activeProjectID == project.id
        let jobs = isActive ? importer.jobs : project.processingJobs
        let hasRetryable = jobs.contains { $0.status == .failedRetryable }
        let needsAttention = project.status == .processing || hasRetryable

        return Group {
            if isActive || needsAttention {
                HStack(spacing: 12) {
                    if isActive {
                        ProgressView().controlSize(.small)
                    }
                    ForEach(jobs) { job in
                        HStack(spacing: 4) {
                            switch job.status {
                            case .completed:
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .running:
                                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
                            case .pending:
                                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                            case .failedRetryable, .failedFinal:
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                            }
                            Text(Self.importStageName(job.kind))
                            if job.status == .running, let progress = job.progress, progress > 0 {
                                Text("\(Int(progress * 100))%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                    Spacer()
                    if let message = importer.lastErrorMessage, !isActive {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    if !isActive, needsAttention {
                        Button("继续处理") {
                            environment.importProcessing.resume(projectID: project.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if isActive {
                        Button("暂停处理") {
                            environment.importProcessing.cancel()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.blue.opacity(0.06))
            }
        }
    }

    /// 导入 Job 状态签名（进度百分比变化不触发重载，状态迁移才触发）
    private var importJobsStatusKey: String {
        environment.importProcessing.jobs
            .map { "\($0.kind.rawValue):\($0.status.rawValue)" }
            .joined(separator: ",")
    }

    /// 流水线阶段完成后，从存储刷新本视图的项目副本（字段级更新，不重建控制器；
    /// 笔记与标题归工作台所有，不从存储回灌，避免覆盖正在编辑的内容）
    private func reloadImportedProjectFromStore() {
        guard let project, project.sourceType != .liveRecording,
              let fresh = try? environment.allProjects().first(where: { $0.id == projectID }) else {
            return
        }
        Self.applyImportedStorageRefresh(from: fresh, to: project)
        if let meeting {
            meeting.status = ProjectRuntimeSession.runtimeStatus(for: fresh.status)
            meeting.segments = fresh.segments
            meeting.snapshots = fresh.legacySnapshots
            // 分析快照刷新（导入流水线的最终分析在后台生成；V2 快照直接挂在 Project 上）
            analysis?.attach(to: project)
        }
    }

    static func applyImportedStorageRefresh(from fresh: Project, to project: Project) {
        project.status = fresh.status
        project.processingJobs = fresh.processingJobs
        project.runtimeAssetRelativePath = fresh.runtimeAssetRelativePath
        project.endedAt = fresh.endedAt
        project.legacySnapshots = fresh.legacySnapshots
        project.analysisSnapshots = fresh.analysisSnapshots
        project.segments = fresh.segments
        project.scenario = fresh.scenario
        project.scenarioWasUserSelected = fresh.scenarioWasUserSelected
    }

    // MARK: - 装配与持久化桥接

    private func loadProject() {
        guard project == nil else { return }
        guard let loaded = try? environment.allProjects().first(where: { $0.id == projectID }) else {
            return
        }
        project = loaded
        do {
            let runtime = try ProjectRuntimeSession.makeRuntimeMeeting(from: loaded)
            meeting = runtime
            wireControllers(to: runtime, project: loaded)
        } catch {
            operationError = "项目读取失败（\(String(describing: type(of: error)))"
        }
        noteController = NoteController(project: loaded) { [environment] in
            try environment.persist($0, fields: .note)
        }
        // 进入界面即检查本地转写可用性（不可用时显示真实原因）
        Task { await transcription?.checkAvailability() }
        // 首页「开始录音」直达：进入即开录（第二次交互即录音中）
        if autoStart, let meeting, meeting.status == .ready {
            startRecording(meeting: meeting)
        }
    }

    private func wireControllers(to meeting: Meeting, project: Project) {
        let recordingService = MeetingRecordingService(
            capture: environment.audioCapture,
            fileStore: environment.fileStore
        )
        recorder = recordingService

        let controller = LocalTranscriptionController(service: environment.localTranscription)
        controller.extraContextualStrings = environment.lexiconTerms
        controller.correctionRules = environment.correctionRules
        let runtimePersistence = ProjectRuntimePersistenceController(
            meeting: meeting,
            project: project,
            persist: { [environment] project in
                // 实时录音没有并发导入流水线，工作台持有唯一写副本，可整对象保存。
                let fields: ProjectFieldOwnership = project.sourceType == .liveRecording
                    ? .all
                    : .manualSegments
                try environment.persist(project, fields: fields)
            },
            onFailure: { error in
                self.operationError = "项目保存失败（\(String(describing: type(of: error)))）"
            }
        )
        self.runtimePersistence = runtimePersistence
        controller.onFinalSegment = {
            runtimePersistence.schedule()
        }
        transcription = controller

        diarization = DiarizationController(
            diarization: environment.diarization,
            fileStore: environment.fileStore,
            transcriptController: controller,
            keyStore: environment.keyStore(for: .diarization)
        )

        let analysisController = ConversationAnalysisController(
            service: environment.conversationAnalysis,
            triggerConfig: project.sourceType == .liveRecording ? .liveRecording : AnalysisTrigger()
        )
        analysisController.knownTermsProvider = { [environment] in environment.lexiconTerms }
        analysisController.attach(to: project)
        analysisController.onSnapshotUpdated = { [environment] in
            // V2 快照直接写在 Project 上，无需运行时桥接
            do {
                try environment.persist(project, fields: .analysis)
            } catch {
                Task { @MainActor in self.operationError = "项目保存失败（\(String(describing: type(of: error)))）" }
            }
        }
        // 新最终片段驱动分析调度
        controller.onNewFinalSegment = { [weak analysisController] in
            analysisController?.noteNewFinalSegment()
        }
        analysis = analysisController
    }

    /// 运行时 → Project 回写并落库（所有状态变化的统一出口）
    private func syncAndPersist(_ meeting: Meeting) {
        guard let project else { return }
        if let runtimePersistence {
            if runtimePersistence.flush(force: true) {
                operationError = nil
            }
            return
        }
        do {
            try ProjectRuntimeSession.applyRuntime(meeting, to: project)
            let fields: ProjectFieldOwnership = project.sourceType == .liveRecording
                ? .all
                : .manualSegments
            try environment.persist(project, fields: fields)
            operationError = nil
        } catch {
            operationError = "项目保存失败（\(String(describing: type(of: error)))）"
        }
    }

    private func persistProject(fields: ProjectFieldOwnership) {
        guard let project else { return }
        do {
            try environment.persist(project, fields: fields)
        } catch {
            operationError = "项目保存失败（\(String(describing: type(of: error)))）"
        }
    }

    /// 人工编辑后持久化并刷新转写视图
    private func persistAndRefresh(_ meeting: Meeting) {
        syncAndPersist(meeting)
        transcription?.refreshSegments()
    }

    /// 点击中栏证据：左栏滚动并高亮对应片段
    private func locateEvidence(segmentID: UUID) {
        highlightedSegmentID = segmentID
    }

    /// 全局纠错（老板 2026-07-27 需求 2）：
    /// 整场替换 + 规则入库（后续转写自动纠正、正词进词库）+ 运行中控制器同步。
    /// 修改过的片段标记人工已修订，不再被云端结果覆盖。
    private func globalCorrect(wrong: String, right: String, meeting: Meeting) -> Int {
        let changed = TranscriptCorrector.applyGlobal(
            wrong: wrong, right: right, segments: meeting.segments)
        do {
            try environment.addCorrectionRule(wrong: wrong, right: right)
        } catch {
            operationError = "纠错规则保存失败（\(String(describing: type(of: error)))）"
        }
        transcription?.correctionRules = environment.correctionRules
        if changed > 0 {
            persistAndRefresh(meeting)
        }
        return changed
    }

    // MARK: - 录音控制

    private func startRecording(meeting: Meeting) {
        // 麦克风权限：拒绝时不阻塞界面，给出系统设置入口
        guard MicrophonePermission.currentStatus == .authorized else {
            operationError = "未获得麦克风权限。请在「系统设置 → 隐私与安全性 → 麦克风」中允许「帮我分析」后重试。"
            MicrophonePermission.openSystemSettings()
            return
        }

        // 本地中文转写不可用：阻止开始并显示真实原因，不静默切换
        if let availability = transcription?.availability, !availability.isReady {
            operationError = "无法开始：本地中文转写不可用。\n\(availability.issueSummary ?? "")"
            return
        }

        Task {
            if transcription?.availability == nil {
                let result = await transcription?.checkAvailability()
                if result?.isReady == false {
                    operationError = "无法开始：本地中文转写不可用。\n\(result?.issueSummary ?? "")"
                    return
                }
            }

            do {
                try recorder?.startRecording(for: meeting, deviceID: meeting.preferredInputDeviceID)
                didStartSessionThisView = true
                syncAndPersist(meeting)
                operationError = nil

                if let recorder, let transcription {
                    try await transcription.start(for: meeting) { [weak recorder] in
                        recorder?.timeline
                    }
                    let transcriptionService = environment.localTranscription
                    environment.audioCapture.onBuffer = { buffer in
                        let boxed = SendableAudioBuffer(buffer)
                        Task { await transcriptionService.feed(boxed.buffer) }
                    }
                    if environment.isConfigured(.diarization) {
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

    /// 结束录音：收尾流水线在后台继续，用户可立即返回首页
    private func finishRecording() {
        guard let meeting else { return }
        noteController?.saveNow()
        isFinishing = true
        Task {
            do {
                try recorder?.beginFinish()
                syncAndPersist(meeting)
                environment.audioCapture.onBuffer = nil
                await transcription?.finish()
                await diarization?.finishAndDrain()
                await analysis?.generateFinalAnalysis()
                try recorder?.completeFinalizing()
                syncAndPersist(meeting)
                operationError = nil
            } catch {
                operationError = error.localizedDescription
            }
            isFinishing = false
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

    /// HH:mm:ss（笔记保存状态）
    static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// 处理详情弹层（03 §6.3：Provider Key 状态、分片计数等技术细节不占据主工作区，仅在此查看）
private struct ProcessingDetailsButton: View {
    let transcription: LocalTranscriptionController?
    let diarization: DiarizationController?
    let analysis: ConversationAnalysisController?
    let microphoneName: String?
    let isAnalysisConfigured: Bool
    let isDiarizationConfigured: Bool
    let onRetryChunks: () -> Void
    let onFixDiarization: () -> Void
    let onFixAnalysis: () -> Void

    @State private var isPresented = false

    /// 异常计数（有异常时按钮以橙色提示）
    private var issueCount: Int {
        var count = 0
        if case .unavailable = transcription?.runState { count += 1 }
        if case .suspended = diarization?.cloudState { count += 1 }
        if case .suspended = analysis?.state { count += 1 }
        if (diarization?.awaitingUserRetryCount ?? 0) > 0 { count += 1 }
        return count
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("处理详情", systemImage: issueCount > 0 ? "exclamationmark.gearshape" : "gearshape")
                .foregroundStyle(issueCount > 0 ? .orange : .secondary)
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                row("麦克风", microphoneName ?? "系统默认")
                row("本地转写", transcriptionStatusText)
                row("说话人识别", diarizationStatusText)
                row("云端分析", analysis?.statusDescription ?? "分析待启动")
                Divider()
                row("分析 Key", isAnalysisConfigured ? "已配置" : "未配置")
                row("分人 Key", isDiarizationConfigured ? "已配置" : "未配置（可手动标注）")
                if let diarization, diarization.awaitingUserRetryCount > 0 {
                    Button("重试 \(diarization.awaitingUserRetryCount) 个失败分片", action: onRetryChunks)
                }
            }
            .padding(16)
            .frame(minWidth: 300)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private var transcriptionStatusText: String {
        guard let transcription else { return "待启动" }
        switch transcription.runState {
        case .idle: return "就绪"
        case .running: return "转写中"
        case .unavailable(let reason): return "不可用：\(reason)"
        }
    }

    private var diarizationStatusText: String {
        guard let diarization else { return "待启动" }
        switch diarization.cloudState {
        case .idle: return "正常"
        case .working(let pending): return pending > 0 ? "识别中（待处理 \(pending)）" : "正常"
        case .suspended: return "已暂停"
        case .unconfigured: return "未配置"
        }
    }
}
