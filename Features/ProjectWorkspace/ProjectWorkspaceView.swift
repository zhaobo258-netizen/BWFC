import SwiftUI
import AppKit

enum ProjectAssetBannerPolicy {
    static func shouldShow(project: Project) -> Bool {
        switch project.status {
        case .creating, .recording, .paused, .processing:
            return true
        case .ready, .readyWithWarnings, .failed:
            return !project.segments.contains { $0.state == .final || $0.state == .edited }
        }
    }
}

enum ProjectRecordingContinuationPolicy {
    static func canContinue(
        project: Project,
        meetingStatus: MeetingStatus,
        hasLiveRecorder: Bool
    ) -> Bool {
        guard project.sourceType == .liveRecording,
              project.status != .creating,
              !hasLiveRecorder else { return false }
        return meetingStatus == .recording
            || meetingStatus == .paused
            || meetingStatus == .finalizing
            || meetingStatus == .completed
    }
}

/// 项目工作台（阶段 B，方案 3「知识花园」三栏骨架，03 文档 §6.3）：
/// 左栏录音文稿 / 中栏 AI 工作区 / 右栏 AI 共创笔记。
///
/// 持久化权威为 ProjectStoring：现有录音、转写、分人、分析链路在内存中
/// 驱动同 id 的运行时 Meeting（ProjectRuntimeSession 桥接），状态变化回写 Project。
/// 技术状态（转写/分人/分析/Key/分片）收进「处理详情」弹层，不占据主工作区；
/// 异常（麦克风断开、语言资源缺失、云端暂停）才出现非阻塞横幅。
struct ProjectWorkspaceView: View {
    static let projectSidebarWidth: CGFloat = 232

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
    @State private var knowledgeGarden: KnowledgeGardenController?
    @State private var projectAIChat: ProjectAIChatController?
    @State private var noteController: NoteController?
    @State private var runtimePersistence: ProjectRuntimePersistenceController?
    @State private var operationError: String?
    @State private var playback = AudioPlaybackController()
    @State private var playbackTarget: ProjectAudioPlaybackTarget?
    @State private var isRetranscribing = false
    /// 收尾后 AI 全文复查的进行中/结果提示（非错误通道；10 号需求 1）
    @State private var reviewNotice: String?
    @State private var transcriptReviewCandidates: [TranscriptReviewCandidate] = []
    @State private var showTranscriptReviewCandidates = false
    /// 记忆/跟进候选（12 号 §6.3/§7.3）：录音结束后提出，确认后生效
    @State private var pendingMemoryCandidates: [BusinessMemoryCandidate] = []
    @State private var pendingFollowUpCandidates: [FollowUpCandidate] = []
    @State private var showMemoryCandidates = false
    @State private var isProposingMemoryCandidates = false
    @State private var needsCandidateStatusRecovery = false
    @State private var memoryProposalID: UUID?
    @State private var memoryProposalTask: Task<Void, Never>?
    /// 仅保存音频模式（本地转写不可用时不阻断录音；12 号 §4.1）
    @State private var isAudioOnlyRecording = false
    @State private var audioOnlyNotice: String?
    @State private var highlightedSegmentID: UUID?
    @State private var showEndConfirmation = false
    @State private var isFinishing = false
    @State private var showBackConfirmation = false
    @State private var showSpeakerPanel = false
    @State private var showPeopleLibrary = false
    @State private var showRelatedProjectContext = false
    @State private var showExportSheet = false
    /// 说话人指认弹层的锚点（09 号计划需求 2；总结条目或转写行进入）
    @State private var speakerAssignRequest: SpeakerAssignRequest?
    @State private var isRelabelingHistoricalSpeakers = false
    @State private var historicalSpeakerTask: Task<Void, Never>?
    @State private var newDeviceID: String?
    @State private var sidebarProjects: [Project] = []
    @AppStorage("bwfx.workspace.projectSidebarVisible") private var prefersProjectSidebarVisible = true
    @State private var isProjectSidebarOverlayPresented = false
    @State private var isNotesInspectorPresented = false
    @State private var centerTab: CenterTab = .summary
    @State private var liveAudioLevel: Float = 0
    @State private var audioQuality = RecordingAudioQualityTracker()
    @State private var hasResolvedAbnormalExit = false
    /// 本会话已在当前视图内实际开录（恢复横幅只在「打开时即异常」的旧会话上出现，
    /// 当前活动录音不算异常）
    @State private var didStartSessionThisView = false
    /// 本视图这次录音会话在采集服务上的归属令牌（Bug 3：单例回调按会话归属清理）
    @State private var audioSessionToken = UUID()
    @State private var timerAnchor = Date()
    private let chunkPollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private enum CenterTab: String, CaseIterable {
        case summary = "实时总结"
        case finalReport = "完整总结"
        case insights = "动机与目的"
        case bloom = "开花"

        /// 「开花」是自造术语，第一次看到的人不知道指什么，鼠标停留时给出解释
        var explanation: String {
            switch self {
            case .summary: return "录音过程中滚动更新的要点"
            case .finalReport: return "录音结束后生成的完整报告"
            case .insights: return "结合原话判断业务诉求、可能顾虑与待核实点"
            case .bloom: return "开花：把选中的内容展开成概念解释与延伸知识"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            workspaceBody(
                mode: WorkspaceLayoutMode.resolve(totalWidth: geometry.size.width)
            )
        }
        .navigationTitle(project?.title ?? "项目")
        .onAppear {
            loadProject()
            reloadSidebarProjects()
            openRequestedFinalReportIfNeeded()
            openRequestedEvidenceIfNeeded()
            playback.startTicker()
        }
        .onDisappear {
            historicalSpeakerTask?.cancel()
            historicalSpeakerTask = nil
            isRelabelingHistoricalSpeakers = false
            memoryProposalID = nil
            memoryProposalTask?.cancel()
            memoryProposalTask = nil
            isProposingMemoryCandidates = false
            playback.stop()
            playback.stopTicker()
            environment.audioCapture.onLevel = nil
            // 录音中直接返回首页时也必须撤回缓冲回调，否则旧闭包会把音频
            // 继续喂给已废弃的转写会话（只清自己登记的那份）
            environment.audioCapture.clearBufferHandler(token: audioSessionToken)
            // 回调已撤回，这个会话不再可能产生音频：注销「正在录」登记，
            // 首页不应再把它显示成活跃录音
            environment.clearProjectLive(projectID)
            projectAIChat?.saveDraftNow()
            noteController?.saveNow()
            runtimePersistence?.flush()
        }
        .onReceive(chunkPollTimer) { _ in
            diarization?.pollProgress()
            Task {
                guard runtimePersistence?.saveError == nil,
                      runtimePersistence?.flush() ?? true else { return }
                await analysis?.tick()
            }
        }
        .onChange(of: importJobsStatusKey) { _, _ in
            reloadImportedProjectFromStore()
        }
        .onChange(of: environment.finalReportCoordinator.revision) { _, _ in
            reloadFinalReportFromStore()
        }
        .onChange(of: environment.lexiconRevision) { _, _ in
            transcription?.correctionRules = environment.correctionRules
        }
        .onChange(of: environment.cloudConfigurationRevision) { _, _ in
            refreshSpeakerReferences()
            diarization?.resumeAfterKeyFix()
            analysis?.resumeAfterKeyFix()
        }
        .onChange(of: router.requestedEvidenceSegmentID) { _, _ in
            openRequestedEvidenceIfNeeded()
        }
        .onChange(of: router.requestedFinalReportProjectID) { _, _ in
            openRequestedFinalReportIfNeeded()
        }
        .confirmationDialog("结束录音？", isPresented: $showEndConfirmation, titleVisibility: .visible) {
            Button("结束录音", role: .destructive) { finishRecording() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("结束后将停止录音与转写，剩余分析在后台继续。录音与文稿已安全保存在本机。")
        }
        .sheet(isPresented: $showSpeakerPanel, onDismiss: refreshSpeakerReferences) {
            if let project, let meeting {
                SpeakerPanelView(
                    project: project,
                    meeting: meeting,
                    microphoneBusy: meeting.status == .recording,
                    onSpeakersChanged: {
                        persistProject(fields: .speakers)
                        diarization?.refreshKnownSpeakers()
                        let speakerIDs = Set(project.speakers.map(\.id))
                        let overriddenEvidenceIDs = project.analysisSpeakerOverrides
                            .filter { speakerIDs.contains($0.speakerId) }
                            .flatMap(\.evidenceSegmentIds)
                        analysis?.noteSpeakerContextChanged(
                            segmentIDs: meeting.segments.compactMap {
                                guard let id = $0.participantId,
                                      speakerIDs.contains(id) else { return nil }
                                return $0.id
                            } + overriddenEvidenceIDs
                        )
                    }
                )
                .environment(environment)
            }
        }
        .sheet(isPresented: $showPeopleLibrary, onDismiss: refreshSpeakerReferences) {
            HistoricalPeopleLibraryView(
                allowsProjectNavigation: false,
                managementEnabled: !isRecordingActive
            )
                .frame(minWidth: 820, minHeight: 680)
        }
        .sheet(isPresented: $showRelatedProjectContext) {
            if let project {
                RelatedProjectContextSheet(
                    project: project,
                    availableProjects: sidebarProjects,
                    onSave: applyRelatedProjectContext
                )
            }
        }
        .sheet(isPresented: $showExportSheet) {
            if let project {
                ProjectExportSheet(
                    project: project,
                    recordingURL: exportRecordingURL(for: project)
                )
            }
        }
        .sheet(item: $speakerAssignRequest) { request in
            if let project {
                SpeakerAssignSheet(
                    speakers: project.speakers,
                    anchorText: request.anchorText,
                    isAnalysisItem: request.isAnalysisItem,
                    canAlsoAssignTranscript: request.source.transcriptSegmentId != nil,
                    groupDescription: speakerGroupDescription(for: request),
                    onPickExisting: { speaker, alsoAssignTranscript, assignAllUnconfirmed in
                        performSpeakerAssign(
                            request: request,
                            speaker: speaker,
                            alsoAssignTranscript: alsoAssignTranscript,
                            assignAllUnconfirmed: assignAllUnconfirmed
                        )
                    },
                    onCreate: { name, role, alsoAssignTranscript, assignAllUnconfirmed in
                        createPersonAndAssignSpeaker(
                            name: name, role: role, request: request,
                            alsoAssignTranscript: alsoAssignTranscript,
                            assignAllUnconfirmed: assignAllUnconfirmed
                        )
                    }
                )
            }
        }
        .sheet(isPresented: $showTranscriptReviewCandidates) {
            TranscriptReviewCandidatesSheet(
                candidates: transcriptReviewCandidates,
                onApply: applyTranscriptReviewCandidates,
                onDiscardAll: discardTranscriptReviewCandidates
            )
        }
        .sheet(isPresented: $showMemoryCandidates) {
            MemoryCandidatesSheet(
                memoryItems: pendingMemoryCandidates.map { candidate in
                    MemoryCandidatesSheet.MemoryItem(
                        candidate: candidate,
                        isConfirmed: false,
                        editedStatement: candidate.statement,
                        personName: candidate.targetPersonDisplayName ?? "未关联人物"
                    )
                },
                followUpItems: pendingFollowUpCandidates.map { candidate in
                    MemoryCandidatesSheet.FollowUpItem(
                        candidate: candidate,
                        isConfirmed: false
                    )
                },
                existingBusinessProjects: (try? environment.businessProjectStore.load()) ?? [],
                suggestedBusinessProjectName: project?.businessCategory,
                operationError: operationError,
                canPropose: environment.isAnalysisConfigured && !isProposingMemoryCandidates,
                onRefresh: manuallyProposeMemoryCandidates,
                onConfirmMemories: confirmMemoryCandidates,
                onResolveMemory: resolveMemoryCandidate,
                onConfirmFollowUps: confirmFollowUpCandidates,
                onResolveFollowUp: resolveFollowUpCandidate
            )
            .environment(environment)
        }
        .confirmationDialog("录音仍在进行", isPresented: $showBackConfirmation, titleVisibility: .visible) {
            Button("结束录音并返回", role: .destructive) {
                finishRecording()
                attemptNavigateHome()
            }
            Button("继续录音", role: .cancel) {}
        } message: {
            Text("返回首页前需要先结束录音。此前笔记或共创草稿未保存成功时不会离开工作台。")
        }
    }

    @ViewBuilder
    private func workspaceBody(mode: WorkspaceLayoutMode) -> some View {
        if mode == .narrow {
            workspaceBase(mode: mode)
                .inspector(isPresented: $isNotesInspectorPresented) {
                    noteColumn
                        .background(BWTheme.columnBackground)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                }
        } else {
            workspaceBase(mode: mode)
        }
    }

    private func workspaceBase(mode: WorkspaceLayoutMode) -> some View {
        let showsPersistentSidebar = mode.showsPersistentSidebar(
            preference: prefersProjectSidebarVisible
        )
        return HStack(spacing: 0) {
            if showsPersistentSidebar {
                projectSidebar(isOverlay: false)
                    .frame(width: Self.projectSidebarWidth)
                Divider()
            }

            VStack(spacing: 0) {
                if let project, let meeting {
                    topBar(project: project, meeting: meeting, mode: mode)
                    Divider()
                    if recorder?.writeFailureInterrupted == true {
                        writeFailureBanner
                    } else if recorder?.deviceInterrupted == true {
                        deviceInterruptedBanner(meeting: meeting)
                    }
                    if ProjectAssetBannerPolicy.shouldShow(project: project),
                       (transcription?.availability?.assetState == .supportedNotInstalled
                        || transcription?.assetDownloadProgress != nil) {
                        assetDownloadBanner
                    }
                    if case .suspended(let reason) = diarization?.cloudState {
                        cloudSuspendedBanner(reason: reason)
                    }
                    if case .unconfigured = diarization?.cloudState,
                       meeting.status == .recording || meeting.status == .paused {
                        diarizationUnconfiguredBanner
                    }
                    if case .suspended(let reason) = analysis?.state {
                        analysisSuspendedBanner(reason: reason)
                    }
                    if meeting.status.isAbnormalIfAppRelaunched, !isFinishing, !didStartSessionThisView,
                       !isRetranscribing, !project.hasFailedProcessingJobs,
                       !hasResolvedAbnormalExit,
                       environment.importProcessing.activeProjectID != project.id {
                        abnormalBanner(project: project, meeting: meeting)
                    }
                    if let operationError {
                        errorBanner(text: operationError)
                    }
                    if isAudioOnlyRecording,
                       meeting.status == .recording || meeting.status == .paused,
                       let audioOnlyNotice {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.badge.exclamationmark")
                            Text(audioOnlyNotice).font(.callout)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.orange.opacity(0.12))
                    }
                    if let reviewNotice {
                        noticeBanner(text: reviewNotice)
                    }
                    if project.sourceType.isImportedMedia || isRetranscribing {
                        importProgressSection(project: project)
                    }
                    workspaceColumns(mode: mode, meeting: meeting)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if isLiveSessionActive(meeting: meeting) {
                        Divider()
                        bottomRecordBar(meeting: meeting)
                    }
                } else {
                    Text("项目不存在或已被删除")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .leading) {
            if mode != .wide, isProjectSidebarOverlayPresented {
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.14)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isProjectSidebarOverlayPresented = false
                        }
                    projectSidebar(isOverlay: true)
                        .frame(width: Self.projectSidebarWidth)
                        .background(BWTheme.columnBackground)
                        .shadow(color: .black.opacity(0.24), radius: 16, x: 5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .zIndex(10)
            }
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .wide {
                isProjectSidebarOverlayPresented = false
            }
            if newMode != .narrow {
                isNotesInspectorPresented = false
            }
        }
    }

    @ViewBuilder
    private func workspaceColumns(mode: WorkspaceLayoutMode, meeting: Meeting) -> some View {
        if mode == .narrow {
            TwoColumnLayout {
                transcriptColumn(meeting: meeting)
                    .background(BWTheme.columnBackground)
            } center: {
                analysisColumn(meeting: meeting)
                    .background(BWTheme.paper)
            }
        } else {
            ThreeColumnLayout(
                minimums: mode == .wide ? .wide : .compact
            ) {
                transcriptColumn(meeting: meeting)
                    .background(BWTheme.columnBackground)
            } center: {
                analysisColumn(meeting: meeting)
                    .background(BWTheme.paper)
            } right: {
                noteColumn
                    .background(BWTheme.columnBackground)
            }
        }
    }

    // MARK: - 项目侧栏

    private func projectSidebar(isOverlay: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BWBrandMark(size: 24)
                Text("项目")
                    .font(.headline)
                Spacer()
                Button {
                    if isOverlay {
                        isProjectSidebarOverlayPresented = false
                    } else {
                        prefersProjectSidebarVisible = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help(isOverlay ? "关闭项目列表" : "收起项目侧栏")
                .accessibilityLabel(isOverlay ? "关闭项目列表" : "收起项目侧栏")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)

            Divider()

            Button {
                if isOverlay {
                    isProjectSidebarOverlayPresented = false
                }
                if let meeting, meeting.status == .recording || meeting.status == .paused {
                    showBackConfirmation = true
                } else {
                    attemptNavigateHome()
                }
            } label: {
                Label("全部项目", systemImage: "square.grid.2x2")
                    .font(.callout)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(BWTheme.card, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(10)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(ProjectHomeSupport.sortedForDisplay(sidebarProjects)) { item in
                        Button {
                            switchProject(to: item.id)
                            if isOverlay {
                                isProjectSidebarOverlayPresented = false
                            }
                        } label: {
                            projectSidebarRow(item)
                        }
                        .buttonStyle(.plain)
                        .disabled(item.id != projectID && isRecordingActive)
                        .help(item.id != projectID && isRecordingActive
                              ? "录音进行中，结束后才能切换项目"
                              : item.title)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    environment.obsidianVaultURL == nil ? "本机保存" : "Obsidian 保存",
                    systemImage: environment.obsidianVaultURL == nil ? "internaldrive" : "square.stack.3d.up"
                )
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(Self.displayStoragePath(
                    baseDirectory: environment.fileStore.baseDirectory
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

                Button {
                    revealCurrentProjectInFinder()
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(12)

            Divider()

            Button {
                router.showSettings()
                if isOverlay {
                    isProjectSidebarOverlayPresented = false
                }
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .help("打开设置中心")
            .accessibilityLabel("打开设置中心")
        }
        .background(BWTheme.columnBackground)
    }

    private func projectSidebarRow(_ item: Project) -> some View {
        let isSelected = item.id == projectID
        return VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(.callout)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 5) {
                Circle()
                    .fill(sidebarStatusColor(item.status))
                    .frame(width: 6, height: 6)
                Text(item.processingStatusText)
                Text("·")
                Text(ProjectHomeSupport.sourceLabel(for: item.sourceType))
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isSelected ? BWTheme.accent.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(BWTheme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 7)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var isRecordingActive: Bool {
        meeting?.status == .recording || meeting?.status == .paused
    }

    /// 本次会话是否真的持有录音器（决定底部录音条是否出现）
    private func isLiveSessionActive(meeting: Meeting) -> Bool {
        ProjectRuntimeSession.showsRecordBar(
            status: meeting.status,
            hasLiveRecorder: recorder?.activeMeeting != nil
        )
    }

    private func sidebarStatusColor(_ status: ProjectStatus) -> Color {
        switch status {
        case .recording, .failed: return .red
        case .paused, .processing, .readyWithWarnings: return .orange
        case .ready: return .green
        case .creating: return .gray
        }
    }

    private func reloadSidebarProjects() {
        do {
            sidebarProjects = try environment.allProjects()
        } catch {
            operationError = "项目列表读取失败（\(String(describing: type(of: error)))）"
        }
    }

    private func switchProject(to id: UUID) {
        guard id != projectID else { return }
        guard !isRecordingActive else {
            operationError = "录音进行中，请结束录音后再切换项目。"
            return
        }
        let noteSaved = noteController?.saveNow() ?? true
        let draftSaved = projectAIChat?.saveDraftNow() ?? true
        guard Self.canNavigateHome(
            afterNoteSave: noteSaved,
            afterCoCreateDraftSave: draftSaved
        ) else {
            operationError = "此前笔记或共创草稿尚未保存成功，已阻止切换项目。请在右栏检查错误并重试。"
            return
        }
        runtimePersistence?.flush()
        router.showProjectWorkspace(id, autoStart: false)
    }

    static func displayStoragePath(
        baseDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let path = baseDirectory.standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
        guard path == homePath || path.hasPrefix(homePath + "/") else {
            return path
        }
        return "~" + String(path.dropFirst(homePath.count))
    }

    private func revealCurrentProjectInFinder() {
        let projectDirectory = environment.fileStore.meetingDirectory(for: projectID)
        let target = FileManager.default.fileExists(atPath: projectDirectory.path)
            ? projectDirectory
            : environment.fileStore.baseDirectory
        guard FileManager.default.fileExists(atPath: target.path) else {
            operationError = "本机保存目录尚未创建。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - 导航门禁

    /// 此前笔记与共创草稿任一保存失败时，不得离开工作台。
    static func canNavigateHome(
        afterNoteSave noteSaveSucceeded: Bool,
        afterCoCreateDraftSave draftSaveSucceeded: Bool = true
    ) -> Bool {
        noteSaveSucceeded && draftSaveSucceeded
    }

    /// 返回首页前强制落盘此前笔记与共创草稿。
    private func attemptNavigateHome() {
        let noteSaved = noteController?.saveNow() ?? true
        let draftSaved = projectAIChat?.saveDraftNow() ?? true
        guard Self.canNavigateHome(
            afterNoteSave: noteSaved,
            afterCoCreateDraftSave: draftSaved
        ) else {
            operationError = "此前笔记或共创草稿尚未保存成功，已阻止返回。请在右栏检查错误并重试。"
            return
        }
        router.showProjectHome()
    }

    // MARK: - 顶部栏（03 §6.3：只保留标题、录音状态、同步状态与少量全局动作）

    private func topBar(
        project: Project,
        meeting: Meeting,
        mode: WorkspaceLayoutMode
    ) -> some View {
        let showsPersistentSidebar = mode.showsPersistentSidebar(
            preference: prefersProjectSidebarVisible
        )
        return HStack(spacing: mode == .narrow ? 8 : 12) {
            if !showsPersistentSidebar {
                Button {
                    if mode == .wide {
                        prefersProjectSidebarVisible = true
                    } else {
                        isProjectSidebarOverlayPresented = true
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(mode == .wide ? "显示项目侧栏" : "打开项目列表")
                .accessibilityLabel(mode == .wide ? "显示项目侧栏" : "打开项目列表")
            }

            Button {
                if meeting.status == .recording || meeting.status == .paused {
                    showBackConfirmation = true
                } else {
                    attemptNavigateHome()
                }
            } label: {
                if mode == .narrow {
                    Image(systemName: "chevron.left")
                } else {
                    Label("项目", systemImage: "chevron.left")
                }
            }
            .help("返回全部项目")
            .accessibilityLabel("返回全部项目")

            // 项目标题：可单击修改
            TitleField(
                title: Binding(
                    get: { project.title },
                    set: { newTitle in
                        project.title = newTitle
                        meeting.title = newTitle
                        project.lastActivityAt = Date()
                        persistProject(fields: .title)
                    }
                ),
                maximumWidth: mode == .narrow ? 180 : 320
            )

            // 录音状态（录音中红点清晰可见）
            HStack(spacing: 6) {
                if meeting.status == .recording {
                    Circle().fill(.red).frame(width: 10, height: 10)
                }
                if isFinishing {
                    Text("正在收尾…可返回首页")
                        .foregroundStyle(.secondary)
                } else {
                    Text(project.processingStatusText)
                        .lineLimit(1)
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

            if meeting.status == .completed,
               ProjectRecordingContinuationPolicy.canContinue(
                    project: project,
                    meetingStatus: meeting.status,
                    hasLiveRecorder: recorder?.activeMeeting != nil
               ) {
                Button("继续录制") {
                    continueRecording(project: project, meeting: meeting)
                }
                .buttonStyle(.bordered)
                .disabled(environment.importProcessing.activeProjectID == project.id)
                .help("追加到同一项目，不覆盖原录音和文稿")
            }

            Spacer()

            if needsCandidateStatusRecovery {
                Button("恢复候选状态") { refreshPendingMemoryCandidates() }
                    .help("重试保存已写入记忆或跟进的确认状态，不调用模型")
            }

            // 记忆/跟进候选入口（录音结束或导入完成后可用；12 号 §6.3/§7.3）
            if meeting.status == .completed || meeting.status == .ready,
               project.segments.contains(where: {
                   ($0.state == .final || $0.state == .edited)
                       && !$0.text.trimmingCharacters(
                           in: .whitespacesAndNewlines
                       ).isEmpty
               }) {
                Button {
                    if pendingMemoryCandidates.isEmpty && pendingFollowUpCandidates.isEmpty {
                        manuallyProposeMemoryCandidates()
                    } else {
                        showMemoryCandidates = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Label("记忆候选", systemImage: "brain.head.profile")
                        let pendingCount = pendingMemoryCandidates.count
                            + pendingFollowUpCandidates.count
                        if pendingCount > 0 {
                            Text("\(pendingCount)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(BWTheme.accent.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }
                }
                .help(isProposingMemoryCandidates
                    ? "正在从原话提取候选…"
                    : "从本场已确认归属原话提出业务记忆与跟进候选；确认后生效")
                .disabled(isProposingMemoryCandidates || (!environment.isAnalysisConfigured
                    && pendingMemoryCandidates.isEmpty && pendingFollowUpCandidates.isEmpty))
            }

            Button {
                reloadSidebarProjects()
                showRelatedProjectContext = true
            } label: {
                HStack(spacing: 5) {
                    if mode == .narrow {
                        Image(systemName: "link")
                    } else {
                        Label("关联上下文", systemImage: "link")
                    }
                    if !project.relatedProjectIDs.isEmpty {
                        Text("\(project.relatedProjectIDs.count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(BWTheme.accent.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
            }
            .help("关联历史录音或项目，让 AI 理解业务背景")
            .accessibilityLabel("关联录音或项目上下文")

            Button {
                showPeopleLibrary = true
            } label: {
                if mode == .narrow {
                    Image(systemName: "person.2.wave.2")
                } else {
                    Label("人物库", systemImage: "person.2.wave.2")
                }
            }
            .help("查看历史人物、声纹、背景和表达画像")
            .accessibilityLabel("打开历史人物库")

            if mode == .narrow {
                Button {
                    isNotesInspectorPresented.toggle()
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .help(
                    isNotesInspectorPresented
                        ? "关闭 AI 共创笔记"
                        : "打开 AI 共创笔记"
                )
                .accessibilityLabel(
                    isNotesInspectorPresented
                        ? "关闭 AI 共创笔记"
                        : "打开 AI 共创笔记"
                )
                .accessibilityValue(isNotesInspectorPresented ? "已打开" : "已关闭")
            }

            // 说话人与声纹面板
            Button {
                showSpeakerPanel = true
            } label: {
                if mode == .narrow {
                    Image(systemName: "person.2")
                } else {
                    Label("说话人", systemImage: "person.2")
                }
            }
            .help("管理说话人与声纹样本")
            .accessibilityLabel("管理说话人")

            Button {
                showExportSheet = true
            } label: {
                if mode == .narrow {
                    Image(systemName: "square.and.arrow.up")
                } else {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
            }
            .help("选择并导出录音、转写和分析资料")
            .accessibilityLabel("导出项目资料")
            .disabled(
                meeting.status == .recording
                    || meeting.status == .paused
                    || isFinishing
            )

            // 技术状态收进处理详情弹层
            ProcessingDetailsButton(
                project: project,
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
        .padding(.horizontal, mode == .narrow ? 10 : 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 可单击编辑的项目标题
    private struct TitleField: View {
        @Binding var title: String
        let maximumWidth: CGFloat
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
                .frame(maxWidth: maximumWidth)
            } else {
                Button {
                    draft = title
                    isEditing = true
                } label: {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: maximumWidth, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("单击修改项目标题")
            }
        }
    }

    // MARK: - 三栏

    private var playbackBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if playback.isLoaded {
                        playback.togglePlay()
                    } else if let project {
                        preparePlayback(project: project)
                    }
                } label: {
                    Label(playback.isPlaying ? "暂停回听" : "回听原音频",
                          systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Spacer(minLength: 0)
                if project?.sourceType.isCombinedAnalysis != true {
                    Button(isRelabelingHistoricalSpeakers ? "停止识别" : "识别说话人") {
                        if isRelabelingHistoricalSpeakers {
                            historicalSpeakerTask?.cancel()
                        } else if let project, let meeting {
                            startHistoricalSpeakerRelabel(project: project, meeting: meeting)
                        }
                    }
                    .controlSize(.small)
                    .disabled(environment.importProcessing.isRunning)
                    .help("按整场声音分组，并自动匹配人物库中已启用的声纹")
                    Button("重新转写", action: retranscribeRecording)
                        .controlSize(.small)
                        .disabled(environment.importProcessing.isRunning || isRelabelingHistoricalSpeakers)
                }
            }
            if playback.isLoaded {
                HStack(spacing: 6) {
                    Text(LiveMeetingView.formatDuration(ms: Int64(playback.currentTime * 1_000)))
                    Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                           in: 0...max(0.001, playback.duration))
                        .accessibilityLabel("原音频播放进度")
                    Text(LiveMeetingView.formatDuration(ms: Int64(playback.duration * 1_000)))
                }
                .font(.caption.monospacedDigit())
                if project?.sourceType.isCombinedAnalysis == true, let playbackTarget {
                    Text("正在回听：\(playbackTarget.title)")
                        .font(.caption).lineLimit(1)
                }
            }
            Text(playback.errorMessage ?? "双击文稿或点击总结证据，从对应位置回听。")
                .font(.caption2)
                .foregroundStyle(playback.errorMessage == nil ? Color.secondary : Color.orange)
        }
        .padding(12)
        .background(BWTheme.accent.opacity(0.06))
    }

    private func preparePlayback(project: Project, segment: TranscriptSegment? = nil) {
        guard let target = ProjectAudioPlaybackTarget.resolve(
            project: project, segment: segment, sourceProjects: sidebarProjects
        ) else {
            playback.stop()
            operationError = "原音频或来源录音不可用；文稿仍可查看。"
            return
        }
        do {
            if playbackTarget?.relativePath != target.relativePath || !playback.isLoaded {
                let url = try environment.fileStore.absoluteURL(forRelativePath: target.relativePath)
                try playback.load(url: url)
            }
            playbackTarget = target
            playback.seek(to: target.seconds)
            playback.play()
        } catch {
            operationError = "原音频无法读取，请检查文件是否存在；文稿仍可查看。"
        }
    }

    private func retranscribeRecording() {
        guard let project, !isFinishing,
              meeting?.status != .recording, meeting?.status != .paused else { return }
        do {
            noteController?.saveNow()
            projectAIChat?.saveDraftNow()
            runtimePersistence?.flush()
            playback.stop()
            environment.finalReportCoordinator.cancel(projectID: project.id)
            try environment.importProcessing.retranscribe(projectID: project.id)
            isRetranscribing = true
            operationError = nil
            reloadImportedProjectFromStore()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func transcriptColumn(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("录音文稿")
            if meeting.status != .recording && meeting.status != .paused && !isFinishing {
                playbackBar
            }
            TranscriptPanelView(
                // 控制器只反映本会话实时转写；只读回看与导入项目用已持久化片段
                segments: (transcription?.segments.isEmpty ?? true) ? meeting.segments : (transcription?.segments ?? []),
                participants: meeting.participants,
                unknownSpeakerDisplay: { segment in
                    guard segment.participantId == nil else { return nil }
                    return diarization?.displayName(forRemoteLabel: segment.remoteSpeakerLabel)
                },
                highlightedSegmentID: highlightedSegmentID,
                liveAudioLevel: meeting.status == .recording ? liveAudioLevel : nil,
                emptyTitle: meeting.status == .recording ? "等待第一段发言" : "还没有可用文稿",
                emptyDetail: meeting.status == .recording
                    ? "开始说话后，实时转写会显示在这里"
                    : "先回听原音频检查收音，再尝试重新转写。",
                onPlaySegment: { segment in locateEvidence(segmentID: segment.id) },
                onAssignSpeaker: { segment, participant in
                    if let participant {
                        if let speaker = project?.speakers.first(where: { $0.id == participant.id }) {
                            _ = performTranscriptSpeakerAssign(
                                anchorSegmentId: segment.id,
                                speaker: speaker
                            )
                        } else {
                            MeetingTranscriptEditor.assignSpeaker(segment, to: participant)
                            persistAndRefresh(meeting)
                            analysis?.noteSpeakerContextChanged(segmentIDs: [segment.id])
                        }
                    } else {
                        MeetingTranscriptEditor.clearSpeaker(segment)
                        persistAndRefresh(meeting)
                        analysis?.noteSpeakerContextChanged(segmentIDs: [segment.id])
                    }
                },
                onEditText: { segment, newText in
                    MeetingTranscriptEditor.editText(segment, to: newText)
                    persistAndRefresh(meeting)
                    analysis?.noteSpeakerContextChanged(segmentIDs: [segment.id])
                },
                onToggleStar: { segment in
                    MeetingTranscriptEditor.toggleStar(segment)
                    persistAndRefresh(meeting)
                },
                onGlobalCorrect: { wrong, right in
                    globalCorrect(wrong: wrong, right: right, meeting: meeting)
                },
                onRequestSpeakerAssignment: { segment in
                    speakerAssignRequest = SpeakerAssignRequest(
                        source: .transcript(segmentId: segment.id),
                        anchorText: String(segment.text.prefix(80))
                    )
                },
                sourceRecordingTitle: { segment in
                    guard let project else { return nil }
                    return ProjectHomeSupport.sourceRecording(
                        for: segment,
                        in: project
                    )?.title
                },
                sourceRecordingStartMs: { segment in
                    guard let project else { return segment.startMs }
                    return ProjectHomeSupport.sourceRelativeStartMs(
                        for: segment,
                        in: project
                    )
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func analysisColumn(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 7) {
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
                    if centerTab == .finalReport, finalReportState == .generating {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("总结中")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if centerTab == .bloom, knowledgeGarden?.state == .expanding {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("开花中")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if analysis?.state == .analyzing {
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
                }

                Picker("", selection: $centerTab) {
                    ForEach(CenterTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue)
                            .help(tab.explanation)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                .labelsHidden()
                .tint(BWTheme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(minHeight: 72)
            .background(.bar)

            Group {
                analysisTabContent(meeting: meeting)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func analysisTabContent(meeting: Meeting) -> some View {
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
                    onEvidenceTap: locateEvidence,
                    segmentStartMs: { id in
                        currentSegments(of: meeting).first(where: { $0.id == id })?.startMs
                    },
                    onSpeakerTap: { item in
                        requestSpeakerAssign(for: item, meeting: meeting)
                    }
                )
            }
        case .finalReport:
            if let project {
                FinalReportView(
                    project: project,
                    state: finalReportState,
                    isAIConfigured: environment.isAnalysisConfigured,
                    onGenerate: startFinalReportGeneration,
                    onOpenSettings: router.showSettings,
                    onEvidenceTap: locateEvidence,
                    relatedProjects: sidebarProjects.filter { project.relatedProjectIDs.contains($0.id) }
                )
            } else {
                ContentUnavailableView(
                    "完整总结正在准备",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
        case .insights:
            if showLegacy {
                InsightCardListView(
                    snapshot: legacySnapshot,
                    participants: meeting.participants,
                    segments: transcription?.segments ?? meeting.segments,
                    onEvidenceTap: locateEvidence,
                    onSpeakerTap: { insight in
                        requestSpeakerAssign(for: insight, meeting: meeting)
                    }
                )
            } else {
                ConversationAnalysisView(
                    snapshot: analysis?.currentSnapshot,
                    summaryTab: false,
                    speakers: project?.speakers ?? [],
                    onEvidenceTap: locateEvidence,
                    segmentStartMs: { id in
                        currentSegments(of: meeting).first(where: { $0.id == id })?.startMs
                    },
                    onSpeakerTap: { item in
                        requestSpeakerAssign(for: item, meeting: meeting)
                    }
                )
            }
        case .bloom:
            if let knowledgeGarden {
                KnowledgeGardenView(
                    controller: knowledgeGarden,
                    onEvidenceTap: locateEvidence,
                    isAIConfigured: environment.isAnalysisConfigured,
                    hasConversationContent: !currentSegments(of: meeting).isEmpty
                )
            } else {
                ContentUnavailableView(
                    "开花功能正在准备",
                    systemImage: "leaf"
                )
            }
        }
    }

    /// 旧谈判快照（迁移项目回看）
    private var legacySnapshot: AnalysisSnapshot? {
        project?.legacySnapshots.max(by: { $0.version < $1.version })
    }

    /// 场景选择器（03 §3.2：自动建议 + 用户随时修正；不阻塞任何流程）
    private func scenarioPicker(project: Project) -> some View {
        Menu {
            Button {
                project.scenario = nil
                project.scenarioWasUserSelected = false
                persistProject(fields: .userScenario)
            } label: {
                if !project.scenarioWasUserSelected {
                    Label("自动判断", systemImage: "checkmark")
                } else {
                    Text("自动判断")
                }
            }
            Divider()
            ForEach(ProjectHomeSupport.recordingScenarioOrder, id: \.self) { scenario in
                Button {
                    project.scenario = scenario
                    project.scenarioWasUserSelected = true
                    persistProject(fields: .userScenario)
                } label: {
                    if project.scenarioWasUserSelected, project.scenario == scenario {
                        Label(scenario.displayName, systemImage: "checkmark")
                    } else {
                        Text(scenario.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "tag")
                if project.scenarioWasUserSelected, let scenario = project.scenario {
                    Text(scenario.displayName)
                } else if let suggested = project.scenario {
                    Text("自动 · \(suggested.displayName)")
                } else {
                    Text("场景：自动")
                }
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(project.scenarioWasUserSelected ? "场景（已手动选择）" : "场景（自动建议，可修正）")
        .accessibilityLabel("项目场景")
        .accessibilityValue(
            project.scenarioWasUserSelected
                ? (project.scenario?.displayName ?? "未设置")
                : "自动判断"
        )
    }

    private var noteColumn: some View {
        Group {
            if let projectAIChat, let project {
                ProjectAIChatView(
                    controller: projectAIChat,
                    legacyNoteMarkdown: noteController?.markdown
                        ?? project.note.markdown,
                    legacyNoteContextEnabled: project.noteAIContextEnabled,
                    canReanalyze: project.segments.contains {
                        ($0.state == .final || $0.state == .edited)
                            && !$0.text.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    },
                    onLegacyNoteContextChanged: setNoteAIContextEnabled,
                    onReanalyze: {
                        Task { await analysis?.generateFinalAnalysis() }
                    },
                    onOpenSettings: router.showSettings,
                    speechController: environment.answerSpeechController
                )
            } else {
                ContentUnavailableView(
                    "AI 共创笔记正在准备",
                    systemImage: "bubble.left.and.text.bubble.right"
                )
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
        .frame(minHeight: 44)
        .background(.bar)
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

            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(audioQuality.isPersistentlyLow ? .orange : .secondary)
                ProgressView(value: Double(liveAudioLevel))
                    .frame(width: 70)
                if audioQuality.isPersistentlyLow {
                    Text("声音偏小，请靠近麦克风或提高播放音量")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .help("持续偏小会显著降低专有名词和数字的识别准确率")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                audioQuality.isPersistentlyLow
                    ? "录音声音持续偏小，建议靠近麦克风或提高播放音量"
                    : "当前录音电平"
            )

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
            Text("高精度转写与说话人识别暂停；当前仍保留本地 Apple Speech 文稿。\(reason)")
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

    private var diarizationUnconfiguredBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.slash")
            Text("说话人识别未连接；当前只有 Apple Speech 文稿，不会自动产生可靠的说话人归属。")
                .font(.callout)
            Spacer()
            Button("去连接") { router.showSettings() }
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
    private func abnormalBanner(project: Project, meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            Text("此项目上次未正常结束（\(meeting.status.displayName)）。录音与文稿已保留在本机。")
                .font(.callout)
            Spacer()
            if ProjectRecordingContinuationPolicy.canContinue(
                project: project,
                meetingStatus: meeting.status,
                hasLiveRecorder: recorder?.activeMeeting != nil
            ) {
                Button("继续录制") {
                    continueRecording(project: project, meeting: meeting)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("标记为已结束") {
                do {
                    try MeetingRecovery.markCompletedAfterAbnormalExit(meeting)
                    try ProjectRuntimeSession.applyRuntime(meeting, to: project)
                    try environment.persist(project, fields: .recordingRuntime)
                    hasResolvedAbnormalExit = true
                    reloadSidebarProjects()
                } catch {
                    operationError = error.localizedDescription
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.yellow.opacity(0.12))
    }

    /// 中性提示条（复查进行中/结果；与错误红条区分）
    private func noticeBanner(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
            Text(text).font(.callout)
            Spacer()
            if !transcriptReviewCandidates.isEmpty {
                Button("查看候选") { showTranscriptReviewCandidates = true }
            }
            if !pendingMemoryCandidates.isEmpty || !pendingFollowUpCandidates.isEmpty {
                Button("记忆候选") { showMemoryCandidates = true }
            }
            if transcriptReviewCandidates.isEmpty
                && pendingMemoryCandidates.isEmpty
                && pendingFollowUpCandidates.isEmpty {
                Button("知道了") { reviewNotice = nil }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(BWTheme.accent.opacity(0.1))
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
        case .finalReport: return "完整总结"
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
                        let reportState = environment.finalReportCoordinator.state(
                            for: project.id
                        )
                        Button(
                            reportState == .generating ? "完整总结生成中" : "继续处理"
                        ) {
                            environment.importProcessing.resume(projectID: project.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(reportState == .generating)
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
        guard let project, project.sourceType.isImportedMedia || isRetranscribing,
              let fresh = try? environment.allProjects().first(where: { $0.id == projectID }) else {
            return
        }
        Self.applyImportedStorageRefresh(from: fresh, to: project)
        if let meeting {
            meeting.status = ProjectRuntimeSession.runtimeStatus(for: fresh.status)
            meeting.segments = fresh.segments
            meeting.pauseIntervals = fresh.pauseIntervals
            meeting.audioRelativePath = fresh.runtimeAssetRelativePath
            SpeakerPanelLogic.syncRuntimeParticipants(speakers: fresh.speakers, meeting: meeting)
            diarization?.attach(to: meeting)
            meeting.snapshots = fresh.legacySnapshots
            // 分析快照刷新（导入流水线的最终分析在后台生成；V2 快照直接挂在 Project 上）
            analysis?.attach(to: project)
            knowledgeGarden?.attach(to: project)
        }
        reloadSidebarProjects()
    }

    static func applyImportedStorageRefresh(from fresh: Project, to project: Project) {
        project.status = fresh.status
        project.processingJobs = fresh.processingJobs
        project.runtimeAssetRelativePath = fresh.runtimeAssetRelativePath
        project.endedAt = fresh.endedAt
        project.legacySnapshots = fresh.legacySnapshots
        project.analysisSnapshots = fresh.analysisSnapshots
        project.analysisSpeakerOverrides = fresh.analysisSpeakerOverrides
        project.transcriptReviewCandidates = fresh.transcriptReviewCandidates
        project.businessMemoryCandidates = fresh.businessMemoryCandidates
        project.followUpCandidates = fresh.followUpCandidates
        project.finalReportSnapshots = fresh.finalReportSnapshots
        project.knowledgeSeeds = fresh.knowledgeSeeds
        project.segments = fresh.segments
        project.speakers = fresh.speakers
        project.scenario = fresh.scenario
        project.scenarioWasUserSelected = fresh.scenarioWasUserSelected
        project.businessCategory = fresh.businessCategory
        project.projectBackgroundContext = fresh.projectBackgroundContext
        project.relatedProjectIDs = fresh.relatedProjectIDs
    }

    // MARK: - 装配与持久化桥接

    private func loadProject() {
        guard project == nil else { return }
        guard let loaded = try? environment.allProjects().first(where: { $0.id == projectID }) else {
            return
        }
        project = loaded
        if !autoStart {
            operationError = environment.consumePendingWarning(for: projectID)
        }
        transcriptReviewCandidates = loaded.transcriptReviewCandidates
        if !loaded.transcriptReviewCandidates.isEmpty {
            reviewNotice = "有 \(loaded.transcriptReviewCandidates.count) 处 AI 转写更正候选待确认，原文尚未修改。"
        }
        refreshPendingMemoryCandidates()
        if !pendingMemoryCandidates.isEmpty || !pendingFollowUpCandidates.isEmpty {
            reviewNotice = "有 \(pendingMemoryCandidates.count) 条记忆候选、"
                + "\(pendingFollowUpCandidates.count) 条跟进候选待确认；确认后才生效。"
        }
        let notes = NoteController(project: loaded) { [environment] in
            try environment.persist($0, fields: .note)
        }
        noteController = notes
        do {
            let runtime = try ProjectRuntimeSession.makeRuntimeMeeting(from: loaded)
            meeting = runtime
            wireControllers(to: runtime, project: loaded, noteController: notes)
        } catch {
            operationError = "项目读取失败（\(String(describing: type(of: error)))"
        }
        // 进入界面即检查本地转写可用性（不可用时显示真实原因）
        Task { await transcription?.checkAvailability() }
        // 首页「开始录音」直达：进入即开录（第二次交互即录音中）
        if autoStart, let meeting, meeting.status == .ready {
            startRecording(meeting: meeting)
        }
    }

    private func wireControllers(
        to meeting: Meeting,
        project: Project,
        noteController: NoteController
    ) {
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
                let fields: ProjectFieldOwnership = self.didStartSessionThisView && !self.isRetranscribing
                    ? .recordingRuntime
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

        let diarizationConfiguration = environment.diarizationConfigurationSnapshot()
        diarization = DiarizationController(
            diarization: environment.makeDiarizationService(for: diarizationConfiguration),
            fileStore: environment.fileStore,
            transcriptController: controller,
            keyStore: environment.diarizationKeyStore(for: diarizationConfiguration),
            configurationSnapshot: diarizationConfiguration
        )
        diarization?.attach(to: meeting)

        let knowledgeController = KnowledgeGardenController(
            expansionService: environment.knowledgeExpansion,
            providerFactory: { [environment] in
                environment.makeKnowledgeProviders()
            },
            automaticallyBloomNewSeeds: false
        )
        knowledgeController.noteContextProvider = { [weak noteController, weak project] in
            project?.note.combinedMarkdown(manualMarkdown: noteController?.markdown)
        }
        knowledgeController.onUpdated = { [environment] in
            do {
                try environment.persist(project, fields: .knowledgeGarden)
            } catch {
                self.operationError = "知识开花保存失败（\(String(describing: type(of: error)))）"
            }
        }
        knowledgeController.attach(to: project)
        knowledgeGarden = knowledgeController

        let chatController = ProjectAIChatController(
            service: environment.projectAIChat,
            persist: { [environment] project in
                try environment.persist(project, fields: .aiContext)
            }
        )
        chatController.noteContextProvider = { [weak noteController, weak project] in
            project?.note.combinedMarkdown(manualMarkdown: noteController?.markdown)
        }
        chatController.relatedProjectsProvider = { [environment, weak project] in
            guard let project else { return [] }
            let projects = (try? environment.allProjects()) ?? []
            let relatedIDs = Set(project.relatedProjectIDs)
            return projects.filter { relatedIDs.contains($0.id) }
        }
        chatController.confirmedMemoriesProvider = { [environment, weak project] in
            guard let project else { return [] }
            return (try? environment.applicableMemories(for: project)) ?? []
        }
        chatController.prepareRequestContext = {
            self.syncAndPersist(meeting)
        }
        chatController.onTranscriptCorrection = { correction in
            guard TranscriptCorrector.hasVerifiedMatch(
                wrong: correction.wrong,
                right: correction.right,
                evidenceSegmentIDs: correction.evidenceSegmentIDs,
                segments: meeting.segments
            ) else {
                return 0
            }
            return self.globalCorrect(
                wrong: correction.wrong,
                right: correction.right,
                meeting: meeting
            )
        }
        chatController.onConversationUpdated = { [environment, weak project] in
            guard let project,
                  project.status == .ready
                    || project.status == .readyWithWarnings,
                  project.segments.contains(where: {
                      ($0.state == .final || $0.state == .edited)
                          && !$0.text.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ).isEmpty
                  }),
                  environment.isAnalysisConfigured else {
                return
            }
            environment.finalReportCoordinator.start(
                projectID: project.id,
                refreshIfRunning: true
            )
        }
        chatController.attach(to: project)
        projectAIChat = chatController

        let analysisController = ConversationAnalysisController(
            service: environment.conversationAnalysis,
            triggerConfig: project.sourceType == .liveRecording ? .liveRecording : AnalysisTrigger()
        )
        analysisController.knownTermsProvider = { [environment] in environment.lexiconTerms }
        analysisController.relatedProjectsProvider = { [environment, weak project] in
            guard let project else { return [] }
            let projects = (try? environment.allProjects()) ?? []
            let relatedIDs = Set(project.relatedProjectIDs)
            return projects.filter { relatedIDs.contains($0.id) }
        }
        // 实时尾巴（09 号计划需求 3-②）：把「识别中」的最新片段作为补充上下文
        // 交给分析，实时总结/开花不再等云端说话人确认。太短的尾巴没有分析价值。
        analysisController.provisionalTailProvider = { [weak controller] in
            guard let tail = controller?.segments.last(where: { $0.state == .provisional }),
                  tail.text.count >= 10 else { return nil }
            return tail
        }
        analysisController.attach(to: project)
        analysisController.onSnapshotUpdated = { [environment] in
            // V2 快照直接写在 Project 上，无需运行时桥接
            do {
                try environment.persist(project, fields: .analysis)
                knowledgeController.refreshCandidates()
            } catch {
                Task { @MainActor in self.operationError = "项目保存失败（\(String(describing: type(of: error)))）" }
            }
        }
        analysisController.persistManualSpeakerConfirmation = { [environment] in
            try environment.persist(project, fields: .analysis)
            knowledgeController.refreshCandidates()
        }
        // 新最终片段驱动分析调度
        controller.onNewFinalSegment = { [weak analysisController] segmentID in
            analysisController?.noteNewFinalSegment(segmentID: segmentID)
        }
        analysis = analysisController
    }

    /// 运行时 → Project 回写并落库（所有状态变化的统一出口）
    @discardableResult
    private func syncAndPersist(_ meeting: Meeting) -> Bool {
        guard let project else { return false }
        if let runtimePersistence {
            if runtimePersistence.flush(force: true) {
                operationError = nil
                reloadSidebarProjects()
                return true
            }
            return false
        }
        do {
            try ProjectRuntimeSession.applyRuntime(meeting, to: project)
            let fields: ProjectFieldOwnership = didStartSessionThisView && !isRetranscribing
                ? .recordingRuntime
                : .manualSegments
            try environment.persist(project, fields: fields)
            operationError = nil
            reloadSidebarProjects()
            return true
        } catch {
            operationError = "项目保存失败（\(String(describing: type(of: error)))）"
            return false
        }
    }

    @discardableResult
    private func persistProject(fields: ProjectFieldOwnership) -> Bool {
        guard let project else { return false }
        do {
            try environment.persist(project, fields: fields)
            reloadSidebarProjects()
            return true
        } catch {
            operationError = "项目保存失败（\(String(describing: type(of: error)))）"
            return false
        }
    }

    private func applyRelatedProjectContext(
        businessCategory: String?,
        backgroundContext: String?,
        relatedProjectIDs: [UUID]
    ) -> Bool {
        guard let project else { return false }
        let previousCategory = project.businessCategory
        let previousBackground = project.projectBackgroundContext
        let previousRelatedIDs = project.relatedProjectIDs
        let previousLastActivityAt = project.lastActivityAt
        project.businessCategory = businessCategory
        project.projectBackgroundContext = backgroundContext
        project.relatedProjectIDs = relatedProjectIDs
        project.lastActivityAt = Date()
        guard persistProject(fields: .relatedContext) else {
            project.businessCategory = previousCategory
            project.projectBackgroundContext = previousBackground
            project.relatedProjectIDs = previousRelatedIDs
            project.lastActivityAt = previousLastActivityAt
            return false
        }
        operationError = nil
        analysis?.noteProjectContextChanged()
        if environment.isAnalysisConfigured,
           project.status == .ready || project.status == .readyWithWarnings,
           project.segments.contains(where: {
               ($0.state == .final || $0.state == .edited)
                   && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) {
            environment.finalReportCoordinator.start(
                projectID: project.id,
                refreshIfRunning: true
            )
        }
        return true
    }

    private func setNoteAIContextEnabled(_ enabled: Bool) {
        guard let project else { return }
        let previous = project.noteAIContextEnabled
        project.noteAIContextEnabled = enabled
        do {
            try environment.persist(project, fields: .aiContext)
            operationError = nil
            if environment.isAnalysisConfigured,
               project.status == .ready
                || project.status == .readyWithWarnings,
               project.segments.contains(where: {
                   ($0.state == .final || $0.state == .edited)
                       && !$0.text.trimmingCharacters(
                           in: .whitespacesAndNewlines
                       ).isEmpty
               }) {
                environment.finalReportCoordinator.start(
                    projectID: project.id,
                    refreshIfRunning: true
                )
            }
        } catch {
            project.noteAIContextEnabled = previous
            operationError = "笔记 AI 授权保存失败，设置未改变。"
        }
    }

    /// 人工编辑后持久化并刷新转写视图
    @discardableResult
    private func persistAndRefresh(_ meeting: Meeting) -> Bool {
        let didPersist = syncAndPersist(meeting)
        transcription?.refreshSegments()
        return didPersist
    }

    /// 点击中栏证据：左栏滚动并高亮对应片段
    private func locateEvidence(segmentID: UUID) {
        highlightedSegmentID = segmentID
        guard let project,
              let segment = project.segments.first(where: { $0.id == segmentID }),
              meeting?.status != .recording, meeting?.status != .paused,
              !isFinishing else { return }
        preparePlayback(project: project, segment: segment)
    }

    // MARK: - 说话人指认（09 号计划需求 2）

    /// 当前生效的片段序列（与转写面板同一口径：运行时优先，回看用已持久化）
    private func currentSegments(of meeting: Meeting) -> [TranscriptSegment] {
        (transcription?.segments.isEmpty ?? true) ? meeting.segments : (transcription?.segments ?? [])
    }

    /// 从总结条目发起指认：条目归属可独立确认；只有唯一证据时才允许用户另选回写原话。
    private func requestSpeakerAssign(for item: AnalysisItem, meeting: Meeting) {
        let segments = currentSegments(of: meeting)
        let evidence = item.evidenceSegmentIds
            .compactMap { id in segments.first(where: { $0.id == id }) }
        guard !evidence.isEmpty else {
            operationError = "这条内容的原话已被更新，暂时无法定位说话人；请稍候在新的总结上操作。"
            return
        }
        let uniqueEvidenceSegmentId = evidence.count == 1 ? evidence[0].id : nil
        speakerAssignRequest = SpeakerAssignRequest(
            source: .analysisItem(
                itemId: item.id,
                uniqueEvidenceSegmentId: uniqueEvidenceSegmentId
            ),
            anchorText: String(item.text.prefix(100))
        )
    }

    private func requestSpeakerAssign(for insight: Insight, meeting: Meeting) {
        let segments = currentSegments(of: meeting)
        let evidence = insight.evidenceSegmentIds
            .compactMap { id in segments.first(where: { $0.id == id }) }
        guard !evidence.isEmpty else {
            operationError = "这条内容的原话已被更新，暂时无法定位说话人。"
            return
        }
        speakerAssignRequest = SpeakerAssignRequest(
            source: .legacyInsight(
                insightId: insight.id,
                uniqueEvidenceSegmentId: evidence.count == 1 ? evidence[0].id : nil
            ),
            anchorText: String(insight.statement.prefix(100))
        )
    }

    @discardableResult
    private func createPersonAndAssignSpeaker(
        name: String, role: String?, request: SpeakerAssignRequest,
        alsoAssignTranscript: Bool, assignAllUnconfirmed: Bool
    ) -> Bool {
        guard let project else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let personID = UUID()
        let speaker = Speaker(
            cloudAlias: SpeakerPanelLogic.nextCloudAlias(existing: project.speakers),
            displayName: trimmed, role: role,
            colorToken: SpeakerPanelLogic.nextColorToken(existing: project.speakers),
            isUserConfirmed: true, personId: personID
        )
        let person = Person(id: personID, displayName: trimmed, role: role,
            colorToken: speaker.colorToken,
            speakerLinks: [PersonSpeakerLink(projectID: project.id, speakerID: speaker.id,
                speakerDisplayName: trimmed, linkedAt: Date())])
        do {
            _ = try environment.personLibraryStore.insert(person)
        } catch {
            operationError = "人物未保存，未执行指认：\(error.localizedDescription)"
            return false
        }
        project.speakers.append(speaker)
        let didAssign = performSpeakerAssign(request: request, speaker: speaker,
            alsoAssignTranscript: alsoAssignTranscript, assignAllUnconfirmed: assignAllUnconfirmed)
        if !didAssign {
            project.speakers.removeAll { $0.id == speaker.id }
            if let meeting {
                SpeakerPanelLogic.syncRuntimeParticipants(speakers: project.speakers, meeting: meeting)
            }
            if persistProject(fields: .speakers) {
                do {
                    try environment.personLibraryStore.deletePerson(personID: personID)
                } catch {
                    operationError = "指认未保存；新人物回滚失败，请在人物库复核。"
                }
            } else {
                operationError = "指认未完成且回滚保存失败；新人物已保留，请在人物库复核关联。"
            }
            diarization?.refreshKnownSpeakers()
        }
        return didAssign
    }

    private func performSpeakerAssign(
        request: SpeakerAssignRequest,
        speaker: Speaker,
        alsoAssignTranscript: Bool,
        assignAllUnconfirmed: Bool
    ) -> Bool {
        switch request.source {
        case .transcript(let segmentId):
            return performTranscriptSpeakerAssign(
                anchorSegmentId: segmentId,
                speaker: speaker,
                includeAllUnconfirmed: assignAllUnconfirmed
            )
        case .analysisItem(let itemId, let uniqueEvidenceSegmentId):
            guard let project, let meeting,
                  analysis?.currentSnapshot?.items.contains(where: { $0.id == itemId }) == true else {
                operationError = "这条总结已更新，请在最新内容上重新标注说话人。"
                return false
            }
            SpeakerPanelLogic.syncRuntimeParticipants(speakers: project.speakers, meeting: meeting)
            guard persistProject(fields: .speakers) else { return false }
            diarization?.refreshKnownSpeakers()
            guard analysis?.confirmSubjectSpeaker(itemID: itemId, speakerID: speaker.id) == true else {
                operationError = analysis?.lastErrorDescription
                    ?? "这条总结已更新，请在最新内容上重新标注说话人。"
                return false
            }
            if alsoAssignTranscript, let uniqueEvidenceSegmentId {
                _ = performTranscriptSpeakerAssign(
                    anchorSegmentId: uniqueEvidenceSegmentId,
                    speaker: speaker
                )
            }
            return true
        case .legacyInsight(let insightId, let uniqueEvidenceSegmentId):
            guard let project, let meeting,
                  let snapshot = project.legacySnapshots.max(by: { $0.version < $1.version }),
                  let insight = snapshot.insights.first(where: { $0.id == insightId }) else {
                operationError = "这条总结已更新，请在最新内容上重新标注说话人。"
                return false
            }
            SpeakerPanelLogic.syncRuntimeParticipants(speakers: project.speakers, meeting: meeting)
            guard persistProject(fields: .speakers) else { return false }
            diarization?.refreshKnownSpeakers()
            let previousSpeakerID = insight.subjectParticipantId
            let previousUpdatedAt = insight.lastUpdatedAt
            insight.subjectParticipantId = speaker.id
            insight.lastUpdatedAt = Date()
            guard persistProject(fields: .legacyAnalysis) else {
                insight.subjectParticipantId = previousSpeakerID
                insight.lastUpdatedAt = previousUpdatedAt
                return false
            }
            if alsoAssignTranscript, let uniqueEvidenceSegmentId {
                _ = performTranscriptSpeakerAssign(
                    anchorSegmentId: uniqueEvidenceSegmentId,
                    speaker: speaker
                )
            }
            return true
        }
    }

    /// 指认落地：回填同标签历史片段 + 自动提取声纹 + 前向匹配。
    /// 声纹提取失败不阻断指认（回填仍生效，样本可后续手录）。
    private func performTranscriptSpeakerAssign(
        anchorSegmentId: UUID,
        speaker: Speaker,
        includeAllUnconfirmed: Bool = false
    ) -> Bool {
        guard let project, let meeting else { return false }
        // 指认操作永远作用在权威片段上（meeting.segments 与运行时是同一批实例；
        // 回看场景 transcription 为空，meeting.segments 即持久化片段的运行时拷贝）
        let segments = meeting.segments
        guard segments.contains(where: { $0.id == anchorSegmentId }) else {
            // 锚点是「识别中」的临时片段（只在转写控制器内存里）：定稿前无法指认
            operationError = "这句话还在识别中，等它确认后（几秒内）再指认说话人。"
            return false
        }
        let previousAttribution = Dictionary(uniqueKeysWithValues: segments.map {
            ($0.id, ($0.participantId, $0.speakerWasUserConfirmed, $0.updatedAt))
        })
        let plan = SpeakerAssignPlanner.makePlan(
            anchorSegmentId: anchorSegmentId,
            speaker: speaker,
            segments: segments,
            pauseIntervals: meeting.pauseIntervals,
            includeAllUnconfirmed: includeAllUnconfirmed
        )

        guard persistAndRefresh(meeting) else {
            for segment in meeting.segments + project.segments {
                if let previous = previousAttribution[segment.id] {
                    segment.participantId = previous.0
                    segment.speakerWasUserConfirmed = previous.1
                    segment.updatedAt = previous.2
                }
            }
            transcription?.refreshSegments()
            reviewNotice = "说话人标注未保存，未启动全场历史回查；请重试。"
            return false
        }

        // 先把人工指认落盘，再学习声纹；声纹存储失败不能反过来让已保存的标注失效。
        var canRelabelWithVoice = SpeakerPanelLogic.voiceReferencePath(for: speaker) != nil
        if let window = plan.sampleWindow {
            let previousProfileID = speaker.voiceProfileId
            let previousSamplePath = speaker.voiceSamplePath
            let previousSampleDurationMs = speaker.voiceSampleDurationMs
            let previousBackground = speaker.backgroundContext
            let previousCommunicationProfile = speaker.communicationProfile
            let previousIFlytekFeatureID = speaker.iflytekFeatureID
            if let profile = extractVoiceSample(window: window, for: speaker, meeting: meeting) {
                if persistProject(fields: .speakers) {
                    canRelabelWithVoice = true
                } else {
                    if previousProfileID == nil {
                        try? environment.speakerVoiceProfileStore.delete(profileID: profile.id)
                    }
                    speaker.voiceProfileId = previousProfileID
                    speaker.voiceSamplePath = previousSamplePath
                    speaker.voiceSampleDurationMs = previousSampleDurationMs
                    speaker.backgroundContext = previousBackground
                    speaker.communicationProfile = previousCommunicationProfile
                    speaker.iflytekFeatureID = previousIFlytekFeatureID
                    reviewNotice = "说话人标注已保存，但声纹未完整关联；未启动全场历史回查，请稍后重新标注声纹。"
                    canRelabelWithVoice = false
                }
            }
        }

        // 只在项目与会议均落盘后启用前向映射，避免保存失败后运行时继续按未保存归属标注。
        if let label = plan.remoteLabel {
            diarization?.assignRemoteLabel(label, to: speaker.id)
        }
        SpeakerPanelLogic.syncRuntimeParticipants(speakers: project.speakers, meeting: meeting)
        diarization?.refreshKnownSpeakers()
        analysis?.noteSpeakerContextChanged(segmentIDs: plan.changedSegmentIds)
        if canRelabelWithVoice {
            startHistoricalSpeakerRelabel(project: project, meeting: meeting)
        }
        return true
    }

    /// 从完整录音切出声纹样本（失败只提示，不阻断指认）
    private func extractVoiceSample(
        window: SpeakerSampleWindowPlanner.Window,
        for speaker: Speaker,
        meeting: Meeting
    ) -> SpeakerVoiceProfile? {
        guard let project,
              SpeakerPanelLogic.canActivateVoiceReference(
                for: speaker.id,
                in: project.speakers
              ) else {
            operationError = "已指认说话人，但本场已启用 4 个声纹，未自动录入第 5 份样本。可在「说话人」面板替换本场人员。"
            return nil
        }
        do {
            guard let audioURL = try environment.fileStore.audioFileURL(for: meeting),
                  FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
            let relativePath = environment.fileStore.relativeVoiceSamplePath(
                meetingID: meeting.id,
                participantID: speaker.id
            )
            let sampleURL = try environment.fileStore.absoluteURL(forRelativePath: relativePath)
            try FileManager.default.createDirectory(
                at: sampleURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AudioChunkExtractor.extract(
                from: audioURL,
                startMs: window.audioStartMs,
                endMs: window.audioEndMs,
                to: sampleURL
            )
            speaker.voiceSamplePath = relativePath
            speaker.voiceSampleDurationMs = window.audioEndMs - window.audioStartMs
            let profile = try environment.speakerVoiceProfileStore.enroll(
                profileID: speaker.voiceProfileId,
                displayName: speaker.displayName,
                role: speaker.role,
                colorToken: speaker.colorToken,
                sourceSampleURL: sampleURL,
                durationMs: window.audioEndMs - window.audioStartMs
            )
            speaker.voiceProfileId = profile.id
            speaker.voiceSamplePath = profile.sampleRelativePath
            speaker.voiceSampleDurationMs = profile.sampleDurationMs
            speaker.backgroundContext = profile.backgroundContext
            speaker.communicationProfile = profile.communicationProfile
            speaker.isCurrentUser = profile.isCurrentUser
            speaker.iflytekFeatureID = profile.iflytekFeatureID
            reviewNotice = profile.isAutoEnabled
                ? "已标注并保存 \(speaker.displayName) 的本地声纹样本。"
                : "已保存 \(speaker.displayName) 的永久声纹；自动识别名额已满。"
            return profile
        } catch {
            // 指认本身已生效；样本提取或永久保存失败如实提示，可去说话人面板手录
            operationError = "已批量标注同组发言，但自动学习声纹失败（\(String(describing: type(of: error)))）；可在「说话人」面板手动录制样本。"
            AppLog.logError(AppLog.diarization, LogSanitizer.formatEvent(
                "voice_sample_extract_failed", error: String(describing: type(of: error))
            ))
            return nil
        }
    }

    private func refreshSpeakerReferences() {
        guard let project, let meeting else { return }
        do {
            project.speakers = try environment.refreshAutomaticSpeakerReferences(for: project.id)
            SpeakerPanelLogic.syncRuntimeParticipants(speakers: project.speakers, meeting: meeting)
            diarization?.refreshKnownSpeakers()
        } catch {
            reviewNotice = "人物声纹未能刷新：\(error.localizedDescription)；录音与人工标注仍可使用。"
        }
    }

    private func speakerGroupDescription(for request: SpeakerAssignRequest) -> String? {
        guard !request.isAnalysisItem,
              let id = request.source.transcriptSegmentId,
              let anchor = meeting?.segments.first(where: { $0.id == id }) else { return nil }
        guard let label = anchor.remoteSpeakerLabel, !label.isEmpty else {
            return "当前原话尚未分组，本次只确认这一条；可先用“识别说话人”按声音分组。"
        }
        let count = meeting?.segments.filter { $0.remoteSpeakerLabel == label }.count ?? 1
        let name = diarization?.displayName(forRemoteLabel: label) ?? "本声音组"
        return "\(name) · 本组 \(count) 条原话，一次指认即可批量归属；已确认给其他人的原话会保留。"
    }

    private func startHistoricalSpeakerRelabel(project: Project, meeting: Meeting) {
        guard !isRelabelingHistoricalSpeakers,
              meeting.status != .recording, meeting.status != .paused,
              !environment.importProcessing.isRunning else { return }
        let configuration = environment.diarizationConfigurationSnapshot()
        let service = environment.makeDiarizationService(for: configuration)
        guard service.recordingLimits != nil else {
            reviewNotice = "整场声音分组与人物库匹配需要启用讯飞或 OpenAI 兼容分人服务。"
            return
        }
        guard environment.diarizationKeyStore(for: configuration).hasConfiguredKey else {
            reviewNotice = "分人服务尚未连接，请先在设置中配置；原文与人工标注已保留。"
            return
        }
        guard !meeting.segments.isEmpty,
              let audioURL = try? environment.fileStore.audioFileURL(for: meeting) else {
            reviewNotice = "没有可识别的文稿或原音频，请先完成转写。"
            return
        }
        do {
            project.speakers = try environment.refreshAutomaticSpeakerReferences(for: project.id)
        } catch {
            reviewNotice = "人物库读取失败，尚未开始识别：\(error.localizedDescription)"
            return
        }
        SpeakerPanelLogic.syncRuntimeParticipants(speakers: project.speakers, meeting: meeting)
        diarization?.refreshKnownSpeakers()
        let references = project.speakers.compactMap { speaker -> HistoricalSpeakerRelabeler.SpeakerReference? in
            if configuration.selectedProvider == .iflytek,
               speaker.iflytekFeatureID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return nil
            }
            guard let path = SpeakerPanelLogic.voiceReferencePath(for: speaker),
                  let url = try? environment.fileStore.absoluteURL(forRelativePath: path) else { return nil }
            return .init(speakerID: speaker.id, alias: speaker.cloudAlias, sampleURL: url,
                         iflytekFeatureID: speaker.iflytekFeatureID)
        }
        let snapshots = meeting.segments.map {
            HistoricalSpeakerRelabeler.SegmentSnapshot(id: $0.id, startMs: $0.startMs, endMs: $0.endMs,
                text: $0.text, participantId: $0.participantId,
                speakerWasUserConfirmed: $0.speakerWasUserConfirmed == true)
        }
        let relabeler = HistoricalSpeakerRelabeler(diarization: service)
        isRelabelingHistoricalSpeakers = true
        reviewNotice = references.isEmpty
            ? "正在识别整场声音分组；当前没有可供此服务比对的已登记声纹。"
            : "正在识别整场声音，并比对人物库中的 \(references.count) 位人物…"
        historicalSpeakerTask = Task {
            defer {
                isRelabelingHistoricalSpeakers = false
                historicalSpeakerTask = nil
            }
            do {
                let result = try await relabeler.diarizeRecording(audioURL: audioURL,
                    pauseIntervals: meeting.pauseIntervals, existingSegments: snapshots,
                    speakerReferences: Array(references.prefix(KnownSpeakerReference.maximumCount)))
                try Task.checkCancellation()
                guard (try environment.allProjects()).contains(where: { $0.id == project.id }) else { return }
                let changed = Self.applySpeakerRecognition(result, snapshots: snapshots, to: meeting.segments,
                    validSpeakerIDs: Set(project.speakers.map(\.id)))
                if !changed.isEmpty {
                    guard persistAndRefresh(meeting) else {
                        reviewNotice = "识别完成，但保存失败；请重试。"
                        return
                    }
                    diarization?.attach(to: meeting)
                    analysis?.noteSpeakerContextChanged(segmentIDs: changed)
                }
                let groups = Set(result.remoteLabels.values).count
                reviewNotice = groups == 0
                    ? "识别完成，未找到可可靠对齐的声音分组；原文与人工标注已保留。"
                    : "已区分 \(groups) 个声音组，匹配人物 \(result.assignments.count) 条原话；未识别的组可一次性指认。"
            } catch is CancellationError {
                reviewNotice = "已停止识别，原文与人工标注已保留。"
            } catch {
                reviewNotice = "说话人识别未完成：\(error.localizedDescription)"
            }
        }
    }

    static func applySpeakerRecognition(
        _ result: HistoricalSpeakerRelabeler.Result,
        snapshots: [HistoricalSpeakerRelabeler.SegmentSnapshot],
        to segments: [TranscriptSegment],
        validSpeakerIDs: Set<UUID>? = nil
    ) -> [UUID] {
        let originals = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unchanged = Set(segments.compactMap { segment -> UUID? in
            guard let original = originals[segment.id], original.text == segment.text,
                  original.startMs == segment.startMs, original.endMs == segment.endMs,
                  original.participantId == segment.participantId,
                  original.speakerWasUserConfirmed == (segment.speakerWasUserConfirmed == true) else { return nil }
            return segment.id
        })
        let invalidAnchorLabels = Set(snapshots.filter {
            $0.speakerWasUserConfirmed && !unchanged.contains($0.id)
        }.compactMap { result.remoteLabels[$0.id] })
        var changed: [UUID] = []
        for segment in segments {
            guard unchanged.contains(segment.id) else { continue }
            var didChange = false
            if let label = result.remoteLabels[segment.id], label != segment.remoteSpeakerLabel {
                segment.remoteSpeakerLabel = label
                didChange = true
            }
            if segment.speakerWasUserConfirmed != true,
               let id = result.assignments[segment.id], id != segment.participantId,
               validSpeakerIDs?.contains(id) ?? true,
               !invalidAnchorLabels.contains(result.remoteLabels[segment.id] ?? "") {
                segment.participantId = id
                segment.speakerConfidence = .high
                didChange = true
            }
            if didChange {
                segment.updatedAt = Date()
                changed.append(segment.id)
            }
        }
        return changed
    }

    /// 全局纠错（老板 2026-07-27 需求 2）：
    /// 整场替换 + 规则入库（后续转写自动纠正、正词进词库）+ 运行中控制器同步。
    /// 修改过的片段标记人工已修订，不再被云端结果覆盖。
    private func globalCorrect(wrong: String, right: String, meeting: Meeting) -> Int {
        let originalTexts = Dictionary(
            meeting.segments.map { ($0.id, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )
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
            analysis?.noteSpeakerContextChanged(
                segmentIDs: meeting.segments.compactMap { segment in
                    originalTexts[segment.id] == segment.text ? nil : segment.id
                }
            )
        }
        return changed
    }

    // MARK: - 录音控制

    private func startRecording(meeting: Meeting) {
        beginRecordingSession(meeting: meeting, continuationOffsetMs: nil)
    }

    private func continueRecording(project: Project, meeting: Meeting) {
        guard ProjectRecordingContinuationPolicy.canContinue(
            project: project,
            meetingStatus: meeting.status,
            hasLiveRecorder: recorder?.activeMeeting != nil
        ) else {
            operationError = "当前项目不能继续录制。"
            return
        }
        beginRecordingSession(meeting: meeting, continuationOffsetMs: project.durationMs)
    }

    private func beginRecordingSession(meeting: Meeting, continuationOffsetMs: Int64?) {
        guard !environment.isPersistentStorageUnavailable else {
            operationError = ProjectWriteError.storageUnavailable.localizedDescription
            return
        }
        guard !isRelabelingHistoricalSpeakers else {
            operationError = "请先停止说话人识别，再继续录音。"
            return
        }
        guard environment.importProcessing.activeProjectID != projectID else {
            operationError = "当前录音正在重新处理，请完成后再继续录制。"
            return
        }
        playback.stop()
        // 麦克风权限：拒绝时不阻塞界面，给出系统设置入口
        guard MicrophonePermission.currentStatus == .authorized else {
            operationError = "未获得麦克风权限。请在「系统设置 → 隐私与安全性 → 麦克风」中允许「帮我分析」后重试。"
            MicrophonePermission.openSystemSettings()
            return
        }

        Task {
            // 本地转写不可用时不再阻断开录（12 号 §4.1）：
            // 仍保存音频，结束后可用「重新转写」补文稿。
            var transcriptionIssue: String?
            if let availability = transcription?.availability, !availability.isReady {
                transcriptionIssue = availability.issueSummary ?? ""
            } else if transcription?.availability == nil {
                let result = await transcription?.checkAvailability()
                if result?.isReady == false {
                    transcriptionIssue = result?.issueSummary ?? ""
                }
            }

            do {
                refreshSpeakerReferences()
                audioQuality.reset()
                liveAudioLevel = 0
                if let continuationOffsetMs {
                    try recorder?.continueRecording(
                        for: meeting,
                        deviceID: meeting.preferredInputDeviceID,
                        timelineOffsetMs: continuationOffsetMs
                    )
                } else {
                    try recorder?.startRecording(
                        for: meeting,
                        deviceID: meeting.preferredInputDeviceID
                    )
                }
                environment.finalReportCoordinator.cancel(projectID: projectID)
                memoryProposalID = nil
                memoryProposalTask?.cancel()
                isProposingMemoryCandidates = false
                isRetranscribing = false
                didStartSessionThisView = true
                hasResolvedAbnormalExit = true
                environment.markProjectLive(projectID)
                syncAndPersist(meeting)
                operationError = environment.consumePendingWarning(for: projectID)
                isAudioOnlyRecording = transcriptionIssue != nil
                if transcriptionIssue != nil {
                    audioOnlyNotice = "仅保存音频模式：本地转写不可用（\(transcriptionIssue ?? "原因未知")）。"
                        + "音频会正常保存；结束后可用「重新转写」生成文稿。"
                } else {
                    audioOnlyNotice = nil
                }
                environment.audioCapture.onLevel = { level in
                    Task { @MainActor in
                        liveAudioLevel = level
                        audioQuality.observe(level)
                    }
                }

                if let recorder, let transcription, transcriptionIssue == nil {
                    do {
                        try await transcription.start(for: meeting) { [weak recorder] in
                            recorder?.timeline
                        }
                    } catch {
                        await transcription.cancel()
                        environment.audioCapture.clearBufferHandler(token: audioSessionToken)
                        isAudioOnlyRecording = true
                        audioOnlyNotice = "仅保存音频模式：本地转写启动失败；音频仍在保存，结束后可重新转写。"
                        return
                    }
                    let transcriptionService = environment.localTranscription
                    let token = UUID()
                    audioSessionToken = token
                    environment.audioCapture.setBufferHandler(token: token) { buffer in
                        let boxed = SendableAudioBuffer(buffer)
                        Task { await transcriptionService.feed(boxed.buffer) }
                    }
                    diarization?.start(for: meeting) { [weak recorder] in
                        recorder?.timeline
                    }
                }
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    /// 录音收尾后的 AI 全文转写复查（10 号需求 1）：
    /// 整场最终文稿交给分析模型找识别错误，只生成候选；用户确认前绝不改权威文本。
    private func reviewTranscriptAfterRecording(meeting: Meeting) async {
        let eligible = meeting.segments.filter { $0.state == .final || $0.state == .edited }
        guard !eligible.isEmpty else { return }
        reviewNotice = "AI 正在复查全文转写，更正识别错误…"
        do {
            let agent = TranscriptReviewAgent(generationService: environment.aiProviderRegistry)
            let request = try TranscriptReviewer.makeRequest(
                segments: eligible,
                globalTerms: environment.lexiconTerms,
                meetingGlossary: meeting.glossary
            )
            let candidates = try await agent.review(request)
            guard let project else { return }
            let previousCandidates = project.transcriptReviewCandidates
            project.transcriptReviewCandidates = candidates
            do {
                try environment.persist(project, fields: .transcriptReview)
                transcriptReviewCandidates = candidates
            } catch {
                project.transcriptReviewCandidates = previousCandidates
                transcriptReviewCandidates = previousCandidates
                reviewNotice = "AI 已完成复查，但候选保存失败；原文保持不变。"
                return
            }
            if candidates.isEmpty {
                reviewNotice = "AI 已复查全文：未发现需要更正的识别错误。"
            } else {
                reviewNotice = "AI 找到 \(candidates.count) 处疑似错字；尚未修改，请逐条确认。"
            }
            AppLog.logInfo(AppLog.analysis, LogSanitizer.formatEvent(
                "transcript_review_ok",
                error: "candidates=\(candidates.count) applied=0"
            ))
        } catch {
            reviewNotice = "AI 复查未完成（\(TranscriptReviewFailureText.message(for: error))），转写保持原样；完整总结不受影响。"
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "transcript_review_failed", error: String(describing: type(of: error))
            ))
        }
    }

    private func applyTranscriptReviewCandidates(
        _ selected: [TranscriptReviewCandidate]
    ) -> String? {
        guard let meeting, let project else { return "项目已关闭，无法应用更正。" }
        let previousCandidates = project.transcriptReviewCandidates
        let selectedIDs = Set(selected.map(\.id))
        let remainingCandidates = previousCandidates.filter { !selectedIDs.contains($0.id) }
        do {
            let commit = try TranscriptReviewer.applyConfirmed(
                selected,
                to: meeting.segments
            ) { commit in
                project.transcriptReviewCandidates = remainingCandidates
                do {
                    try environment.applyTranscriptReviewCommit(commit) {
                        guard syncAndPersist(meeting) else {
                            throw TranscriptReviewPersistenceFailure()
                        }
                    }
                } catch {
                    project.transcriptReviewCandidates = previousCandidates
                    throw error
                }
            }
            transcription?.correctionRules = environment.correctionRules
            transcription?.refreshSegments()
            transcriptReviewCandidates = remainingCandidates
            reviewNotice = transcriptReviewCandidates.isEmpty
                ? "已确认并更正 \(commit.candidates.count) 处，纠错规则已保存。"
                : "已更正 \(commit.candidates.count) 处；还有 \(transcriptReviewCandidates.count) 处候选未处理。"
            analysis?.noteSpeakerContextChanged(
                segmentIDs: Array(Set(commit.candidates.map(\.segmentId)))
            )
            if environment.isAnalysisConfigured {
                environment.finalReportCoordinator.start(
                    projectID: project.id,
                    refreshIfRunning: true
                )
            }
            return nil
        } catch TranscriptReviewConfirmationError.segmentChanged {
            project.transcriptReviewCandidates = previousCandidates
            return "原文已在复查后发生变化，请关闭并重新复查。"
        } catch TranscriptReviewConfirmationError.conflictingCorrection(let wrong) {
            project.transcriptReviewCandidates = previousCandidates
            return "「\(wrong)」同时有多个不同改法，请只选其中一种。"
        } catch TranscriptReviewCommitPersistenceError.rollbackFailed {
            project.transcriptReviewCandidates = previousCandidates
            return "文稿已恢复，但纠错词库的磁盘回滚失败；本次未视为保存成功，请重试或检查存储位置。"
        } catch {
            project.transcriptReviewCandidates = previousCandidates
            return "更正未保存（\(String(describing: type(of: error)))），文稿保持原样。"
        }
    }

    private func discardTranscriptReviewCandidates() -> String? {
        guard let project else { return "项目已关闭，无法清除候选。" }
        let previous = project.transcriptReviewCandidates
        project.transcriptReviewCandidates = []
        do {
            try environment.persist(project, fields: .transcriptReview)
            transcriptReviewCandidates = []
            reviewNotice = "已忽略全部更正候选，原文未修改。"
            return nil
        } catch {
            project.transcriptReviewCandidates = previous
            return "候选清除失败，未做任何修改。"
        }
    }

    // MARK: - 记忆与跟进候选（12 号 §6.3 / §7.3）

    private func proposeMemoryCandidatesIfNeeded(manual: Bool = false) async {
        guard let project, !isProposingMemoryCandidates else { return }
        guard environment.isAnalysisConfigured else {
            if manual { operationError = "请先配置分析模型，再提取候选；已保存候选仍可确认。" }
            return
        }
        let requestID = UUID()
        memoryProposalID = requestID
        isProposingMemoryCandidates = true
        operationError = nil
        defer {
            if memoryProposalID == requestID {
                memoryProposalID = nil
                isProposingMemoryCandidates = false
            }
        }
        do {
            let existing = try environment.activeMemoryContents(for: project)
            let linked = try environment.businessProjectStore.load().filter {
                $0.linkedProjectIDs.contains(project.id)
            }
            let outcome = try await environment.businessMemoryCandidateAgent.propose(
                project: project,
                existingActiveMemoryContents: existing,
                businessProjectID: linked.count == 1 ? linked.first?.id : nil
            )
            try Task.checkCancellation()
            guard memoryProposalID == requestID, self.project?.id == project.id else { return }
            guard let stored = try environment.allProjects().first(where: { $0.id == project.id }),
                  BusinessMemoryCandidateBuilder.proposalVersion(project: stored)
                    == BusinessMemoryCandidateBuilder.proposalVersion(project: project) else {
                throw BusinessMemoryCandidateError.sourceChanged
            }
            let previousMemory = project.businessMemoryCandidates
            let previousFollowUps = project.followUpCandidates
            project.businessMemoryCandidates.removeAll {
                $0.status == .pending && !BusinessMemoryCandidateBuilder.sourceIsCurrent(
                    project: project, segmentID: $0.evidenceSegmentID,
                    version: $0.sourceVersion, personID: $0.targetPersonID
                )
            }
            project.followUpCandidates.removeAll {
                $0.status == .pending && !BusinessMemoryCandidateBuilder.sourceIsCurrent(
                    project: project, segmentID: $0.evidenceSegmentID, version: $0.sourceVersion
                )
            }
            project.businessMemoryCandidates.append(contentsOf: outcome.memoryCandidates)
            project.followUpCandidates.append(contentsOf: outcome.followUpCandidates)
            do {
                try environment.persist(project, fields: .memoryCandidates)
            } catch {
                project.businessMemoryCandidates = previousMemory
                project.followUpCandidates = previousFollowUps
                throw error
            }
            refreshPendingMemoryCandidates()
            if pendingMemoryCandidates.isEmpty && pendingFollowUpCandidates.isEmpty {
                if manual {
                    reviewNotice = "本次没有新的候选。需要至少两条已确认人物归属的最终原话；已处置的同来源候选不会重复提出。"
                }
            } else {
                reviewNotice = "有 \(pendingMemoryCandidates.count) 条记忆候选、"
                    + "\(pendingFollowUpCandidates.count) 条跟进候选待确认。"
                if manual { showMemoryCandidates = true }
            }
        } catch {
            guard memoryProposalID == requestID, !Task.isCancelled else { return }
            let detail = error is BusinessMemoryCandidateError
                ? error.localizedDescription : TranscriptReviewFailureText.message(for: error)
            operationError = "候选提取未完成：\(detail)；可以重试。"
            AppLog.logWarning(AppLog.analysis, LogSanitizer.formatEvent(
                "memory_candidate_proposal_failed", error: String(describing: type(of: error))
            ))
        }
    }

    private func manuallyProposeMemoryCandidates() {
        guard !isProposingMemoryCandidates else { return }
        memoryProposalTask = Task { await proposeMemoryCandidatesIfNeeded(manual: true) }
    }

    @discardableResult
    private func refreshPendingMemoryCandidates() -> Bool {
        guard let project else { return false }
        do {
            let memories = try environment.personLibraryStore.load().flatMap(\.memoryEntries)
            let followUps = try environment.businessProjectStore.load().flatMap(\.followUps)
            let recovered = BusinessMemoryCandidateBuilder.reconcileCommittedCandidates(
                project: project, memories: memories, followUps: followUps
            )
            if recovered || needsCandidateStatusRecovery {
                do {
                    try environment.persist(project, fields: .memoryCandidates)
                    needsCandidateStatusRecovery = false
                    reviewNotice = "已恢复记忆与跟进的确认状态；已写入内容请在人物库或业务项目页管理。"
                } catch {
                    needsCandidateStatusRecovery = true
                    operationError = "记忆或跟进已写入，候选状态待恢复；请点击“恢复候选状态”。"
                }
            }
        } catch {
            needsCandidateStatusRecovery = true
            pendingMemoryCandidates = []
            pendingFollowUpCandidates = []
            operationError = "无法核验已写入的记忆与跟进，候选处置暂不可用；请点击“恢复候选状态”重试。"
            return false
        }
        pendingMemoryCandidates = project.businessMemoryCandidates.filter {
            $0.status == .pending
        }
        pendingFollowUpCandidates = project.followUpCandidates.filter {
            $0.status == .pending
        }
        if pendingMemoryCandidates.isEmpty && pendingFollowUpCandidates.isEmpty {
            showMemoryCandidates = false
        }
        return true
    }

    private func confirmMemoryCandidates(_ items: [MemoryCandidatesSheet.MemoryItem]) {
        guard refreshPendingMemoryCandidates(), let project else { return }
        operationError = nil
        let now = Date()
        var confirmedCount = 0
        for item in items {
            do {
                let statement = item.editedStatement.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !statement.isEmpty,
                      let index = project.businessMemoryCandidates.firstIndex(where: { $0.id == item.id }),
                      project.businessMemoryCandidates[index].status == .pending else { continue }
                let candidate = project.businessMemoryCandidates[index]
                guard let personID = candidate.targetPersonID,
                      BusinessMemoryCandidateBuilder.sourceIsCurrent(
                        project: project, segmentID: candidate.evidenceSegmentID,
                        version: candidate.sourceVersion, personID: personID
                      ),
                      let stored = try environment.allProjects().first(where: { $0.id == project.id }),
                      BusinessMemoryCandidateBuilder.sourceIsCurrent(
                        project: stored, segmentID: candidate.evidenceSegmentID,
                        version: candidate.sourceVersion, personID: personID
                      ) else { throw BusinessMemoryCandidateError.sourceChanged }
                let businessProjectID = item.candidate.targetBusinessProjectID
                var scopeText = "人物（\(candidate.targetPersonDisplayName ?? "已关联人物")）"
                if candidate.requiresBusinessProjectScope == true {
                    guard let businessProjectID,
                          let target = try environment.businessProjectStore.load().first(where: {
                              $0.id == businessProjectID
                          }) else {
                        operationError = "请选择真实业务项目；该候选不能作为全部项目通用记忆。"
                        continue
                    }
                    scopeText += " + 业务项目（\(target.name)）"
                }
                guard var person = try environment.personLibraryStore.person(id: personID) else {
                    operationError = "人物已不存在，请重新关联人物并提取候选。"
                    continue
                }
                if let written = person.memoryEntries.first(where: { $0.id == candidate.id }),
                   written.status != .active {
                    operationError = "该记忆已在人物库被另行处置，请先复核；不会重复新增。"
                    continue
                }
                if !person.memoryEntries.contains(where: { $0.id == candidate.id }) {
                    let entry = MemoryEntry(
                        id: candidate.id,
                        content: statement,
                        kind: candidate.kind,
                        scope: MemoryScope(personID: personID,
                            businessProjectID: candidate.requiresBusinessProjectScope == true ? businessProjectID : nil,
                            displayText: scopeText),
                        source: MemorySourceReference(recordingID: project.id,
                            segmentID: candidate.evidenceSegmentID, snippet: candidate.evidenceSnippet,
                            sourceVersion: candidate.sourceVersion),
                        status: .active, confirmedAt: now, effectiveFrom: now,
                        createdAt: now, updatedAt: now
                    )
                    person.memoryEntries.append(entry)
                    _ = try environment.personLibraryStore.replaceMemoryEntries(
                        personID: personID, entries: person.memoryEntries, now: now
                    )
                }
                project.businessMemoryCandidates[index].status = .confirmed
                project.businessMemoryCandidates[index].resolvedAt = now
                confirmedCount += 1
                do {
                    try environment.persist(project, fields: .memoryCandidates)
                } catch {
                    needsCandidateStatusRecovery = true
                    operationError = "记忆已写入人物库，候选状态待恢复；该条不会再作为未确认候选。"
                }
            } catch {
                operationError = "记忆未确认：\(error.localizedDescription)"
            }
        }
        refreshPendingMemoryCandidates()
        if confirmedCount > 0 {
            reviewNotice = "已确认 \(confirmedCount) 条记忆，可在人物库查看和撤回。"
        }
    }

    private func resolveMemoryCandidate(_ id: UUID, _ status: PendingCandidateStatus) {
        guard refreshPendingMemoryCandidates() else { return }
        guard status == .rejected || status == .keptLocalOnly,
              let project,
              let index = project.businessMemoryCandidates.firstIndex(where: { $0.id == id }),
              project.businessMemoryCandidates[index].status == .pending else { return }
        let previous = project.businessMemoryCandidates[index]
        project.businessMemoryCandidates[index].status = status
        project.businessMemoryCandidates[index].resolvedAt = Date()
        do {
            try environment.persist(project, fields: .memoryCandidates)
        } catch {
            project.businessMemoryCandidates[index] = previous
            operationError = "候选处置保存失败：\(error.localizedDescription)"
        }
        refreshPendingMemoryCandidates()
    }

    private func confirmFollowUpCandidates(
        _ items: [MemoryCandidatesSheet.FollowUpItem],
        target: MemoryCandidatesSheet.FollowUpTarget
    ) {
        guard refreshPendingMemoryCandidates(), let project, !items.isEmpty else { return }
        let now = Date()
        do {
            guard let stored = try environment.allProjects().first(where: { $0.id == project.id }) else {
                throw BusinessMemoryCandidateError.sourceChanged
            }
            let selectedIDs = Set(items.map(\.id))
            let candidates = project.followUpCandidates.filter {
                selectedIDs.contains($0.id) && $0.status == .pending
            }
            guard !candidates.isEmpty else { return }
            guard candidates.allSatisfy({ candidate in
                BusinessMemoryCandidateBuilder.sourceIsCurrent(
                    project: project, segmentID: candidate.evidenceSegmentID, version: candidate.sourceVersion
                ) && BusinessMemoryCandidateBuilder.sourceIsCurrent(
                    project: stored, segmentID: candidate.evidenceSegmentID, version: candidate.sourceVersion
                )
            }) else { throw BusinessMemoryCandidateError.sourceChanged }
            let projects = try environment.businessProjectStore.load()
            let writtenProjects = projects.filter { business in
                business.followUps.contains { selectedIDs.contains($0.id) }
            }
            guard writtenProjects.count <= 1 else {
                operationError = "所选跟进已分别写入不同业务项目，请逐条确认状态。"
                return
            }
            var businessProject: BusinessProject
            if let written = writtenProjects.first {
                businessProject = written
            } else if let id = target.existingBusinessProjectID,
                      let existing = projects.first(where: { $0.id == id }) {
                businessProject = existing
            } else if let name = target.newBusinessProjectName {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let existing = projects.first(where: { $0.name == trimmed }) {
                    businessProject = existing
                } else {
                    businessProject = try environment.businessProjectStore.create(
                        name: trimmed, linkedProjectIDs: [project.id], now: now
                    )
                }
            } else {
                operationError = "请选择跟进的目标业务项目。"
                return
            }
            for candidate in candidates where !businessProject.followUps.contains(where: { $0.id == candidate.id }) {
                // 原话中的姓名只保留文本，不能用同名人物的首个结果自动决定负责人。
                businessProject.followUps.append(FollowUp(
                    id: candidate.id, title: candidate.title,
                    ownerDisplayText: candidate.ownerDisplayText, dueDate: candidate.dueDate,
                    source: FollowUpSourceReference(recordingID: project.id,
                        segmentID: candidate.evidenceSegmentID, snippet: candidate.evidenceSnippet,
                        sourceVersion: candidate.sourceVersion),
                    confirmationStatus: .confirmed, handlingStatus: .pending,
                    createdAt: now, updatedAt: now
                ))
            }
            if !businessProject.linkedProjectIDs.contains(project.id) {
                businessProject.linkedProjectIDs.append(project.id)
            }
            _ = try environment.businessProjectStore.update(businessProject, now: now)
            for index in project.followUpCandidates.indices where selectedIDs.contains(project.followUpCandidates[index].id) {
                project.followUpCandidates[index].status = .confirmed
                project.followUpCandidates[index].resolvedAt = now
            }
            do {
                try environment.persist(project, fields: .memoryCandidates)
                reviewNotice = "已把 \(candidates.count) 条跟进写入「\(businessProject.name)」；完成时请记录实际结果。"
            } catch {
                needsCandidateStatusRecovery = true
                operationError = "跟进已写入业务项目，候选状态待恢复；该条不会再作为未确认候选。"
            }
        } catch {
            operationError = "跟进未确认：\(error.localizedDescription)"
        }
        refreshPendingMemoryCandidates()
    }

    private func resolveFollowUpCandidate(_ id: UUID, _ status: PendingCandidateStatus) {
        guard refreshPendingMemoryCandidates() else { return }
        guard status == .rejected || status == .keptLocalOnly,
              let project,
              let index = project.followUpCandidates.firstIndex(where: { $0.id == id }),
              project.followUpCandidates[index].status == .pending else { return }
        let previous = project.followUpCandidates[index]
        project.followUpCandidates[index].status = status
        project.followUpCandidates[index].resolvedAt = Date()
        do {
            try environment.persist(project, fields: .memoryCandidates)
        } catch {
            project.followUpCandidates[index] = previous
            operationError = "候选处置保存失败：\(error.localizedDescription)"
        }
        refreshPendingMemoryCandidates()
    }

    private func finishRecording() {
        guard let meeting, !isFinishing else { return }
        noteController?.saveNow()
        projectAIChat?.saveDraftNow()
        isFinishing = true
        Task {
            var shouldRecognizeSpeakers = false
            do {
                environment.audioCapture.onLevel = nil
                try recorder?.beginFinish()
                syncAndPersist(meeting)
                environment.audioCapture.clearBufferHandler(token: audioSessionToken)
                await transcription?.finish()
                await diarization?.finishAndDrain()
                try recorder?.completeFinalizing()
                syncAndPersist(meeting)
                environment.clearProjectLive(projectID)
                if isAudioOnlyRecording {
                    isAudioOnlyRecording = false
                    audioOnlyNotice = nil
                }
                let transcriptionFailed = transcription?.lastErrorDescription != nil
                    || project?.hasUsableTranscript != true
                let configuration = environment.diarizationConfigurationSnapshot()
                shouldRecognizeSpeakers = !transcriptionFailed
                    && environment.diarizationKeyStore(for: configuration).hasConfiguredKey
                    && environment.makeDiarizationService(for: configuration).recordingLimits != nil
                if let project {
                    project.processingJobs.removeAll { $0.kind == .transcription }
                    project.processingJobs.append(ProcessingJob(
                        kind: .transcription,
                        status: transcriptionFailed ? .failedRetryable : .completed,
                        progress: transcriptionFailed ? nil : 1,
                        lastErrorCategory: transcriptionFailed ? "transcription_incomplete" : nil
                    ))
                    if transcriptionFailed { project.status = .readyWithWarnings }
                    try environment.persist(project, fields: .importPipeline)
                }
                operationError = nil
                if transcriptionFailed {
                    operationError = "录音已保存，但转写未完成。请先回听原音频，再使用“重新转写”；本次未自动生成总结。"
                } else if environment.isAnalysisConfigured {
                    // 先复查全文更正识别错误，再生成完整总结（报告用的是更正后文稿）。
                    // 复查失败不阻断——转写保持原样，总结照常生成。
                    await reviewTranscriptAfterRecording(meeting: meeting)
                    environment.finalReportCoordinator.start(projectID: projectID)
                    await proposeMemoryCandidatesIfNeeded()
                    if let project {
                        Task {
                            do {
                                if let count = try await environment
                                    .refreshCurrentUserCommunicationProfile(
                                        from: project
                                    ) {
                                    reviewNotice = "已从 \(count) 条人工确认原话更新“我”的表达画像，下次对话会继续使用。"
                                }
                            } catch {
                                reviewNotice = "录音已安全结束；“我”的表达画像本次未更新，可在人物库重试。"
                            }
                        }
                    }
                } else {
                    // 静默跳过会让人误以为「完整总结」功能缺失；必须说清原因和补救入口
                    operationError = "AI 未连接，完整总结未生成；可前往设置连接后在「完整总结」页签手动生成。"
                }
            } catch {
                operationError = error.localizedDescription
            }
            isFinishing = false
            if shouldRecognizeSpeakers, let project {
                startHistoricalSpeakerRelabel(project: project, meeting: meeting)
            }
        }
    }

    private var finalReportState: FinalReportCoordinator.State {
        let coordinatorState = environment.finalReportCoordinator.state(for: projectID)
        guard coordinatorState == .idle,
              let job = project?.processingJobs.last(where: { $0.kind == .finalReport }) else {
            return coordinatorState
        }
        switch job.status {
        case .running:
            return environment.importProcessing.activeProjectID == projectID
                ? .generating
                : .idle
        case .failedRetryable, .failedFinal:
            return .failed(message: "完整总结暂时生成失败，可重试")
        case .pending, .completed:
            return coordinatorState
        }
    }

    private func startFinalReportGeneration() {
        guard environment.isAnalysisConfigured else {
            router.showSettings()
            return
        }
        guard let project,
              project.segments.contains(where: {
                  ($0.state == .final || $0.state == .edited)
                      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            operationError = "还没有可用于完整总结的最终文稿。"
            return
        }
        guard meeting?.status != .recording,
              meeting?.status != .paused,
              !isFinishing else {
            operationError = "请先结束录音，完成收尾后再生成完整总结。"
            return
        }
        guard environment.importProcessing.activeProjectID != projectID else {
            operationError = "录音正在重新处理，请完成后再生成总结。"
            return
        }
        if project.sourceType.isImportedMedia,
           project.status == .processing,
           environment.importProcessing.activeProjectID == nil,
           project.processingJobs.contains(where: {
               $0.kind == .finalReport
                   && ($0.status == .running || $0.status == .pending)
           }) {
            environment.importProcessing.resume(projectID: projectID)
            return
        }
        if project.sourceType.isImportedMedia,
           project.status == .processing
            || environment.importProcessing.activeProjectID == projectID {
            operationError = "导入处理尚未结束，请等待当前流水线完成。"
            return
        }
        environment.finalReportCoordinator.start(projectID: projectID)
    }

    private func openRequestedEvidenceIfNeeded() {
        guard let segmentID = router.consumeEvidenceRequest(for: projectID) else { return }
        guard project?.segments.contains(where: { $0.id == segmentID }) == true else {
            operationError = "来源片段已不存在，请复核该记忆或跟进。"
            return
        }
        locateEvidence(segmentID: segmentID)
    }

    private func openRequestedFinalReportIfNeeded() {
        if router.consumeFinalReportRequest(for: projectID) {
            centerTab = .finalReport
        }
    }

    private func reloadFinalReportFromStore() {
        guard let project,
              let fresh = try? environment.allProjects().first(where: {
                  $0.id == projectID
              }) else {
            return
        }
        project.analysisSnapshots = fresh.analysisSnapshots
        project.analysisSpeakerOverrides = fresh.analysisSpeakerOverrides
        project.transcriptReviewCandidates = fresh.transcriptReviewCandidates
        transcriptReviewCandidates = fresh.transcriptReviewCandidates
        project.finalReportSnapshots = fresh.finalReportSnapshots
        project.processingJobs = fresh.processingJobs
        if !project.scenarioWasUserSelected {
            project.scenario = fresh.scenario
        }
        analysis?.attach(to: project)
        knowledgeGarden?.refreshCandidates()
        reloadSidebarProjects()
    }

    private func exportRecordingURL(for project: Project) -> URL? {
        let relativePath = project.runtimeAssetRelativePath
            ?? environment.fileStore.relativeAudioPath(for: project.id)
        return try? environment.fileStore.absoluteURL(forRelativePath: relativePath)
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

}

private struct TranscriptReviewPersistenceFailure: Error {}

/// 处理详情弹层（03 §6.3：Provider Key 状态、分片计数等技术细节不占据主工作区，仅在此查看）
private struct ProcessingDetailsButton: View {
    let project: Project
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
        var count = project.processingJobs.filter {
            $0.status == .failedRetryable || $0.status == .failedFinal
        }.count
        if (project.status == .ready || project.status == .readyWithWarnings) && !project.hasUsableTranscript {
            count += 1
        }
        if case .unavailable = transcription?.runState { count += 1 }
        if case .suspended = diarization?.cloudState { count += 1 }
        if case .unconfigured = diarization?.cloudState { count += 1 }
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
                Text(project.processingStatusText).font(.headline)
                row("麦克风", microphoneName ?? "当前未采集")
                row("本地转写", transcriptionStatusText)
                row("高精度转写与说话人", diarizationStatusText)
                row("云端分析", savedStatus(for: .analysis) ?? analysis?.statusDescription ?? "本场未运行")
                row("完整总结", savedStatus(for: .finalReport) ?? (project.finalReportSnapshots.isEmpty ? "尚未生成" : "已有历史总结"))
                Divider()
                row("文字分析模型", isAnalysisConfigured ? "已配置" : "未配置")
                row(
                    "高精度音频服务",
                    isDiarizationConfigured
                        ? "已配置"
                        : "未配置（当前仅 Apple Speech）"
                )
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

    private func savedStatus(for kind: ProcessingJobKind) -> String? {
        guard project.status != .recording, project.status != .paused,
              let job = project.processingJobs.last(where: { $0.kind == kind }) else { return nil }
        switch job.status {
        case .pending: return "等待处理"
        case .running: return "处理未完成"
        case .completed: return "已完成"
        case .failedRetryable: return "失败 · 可重试"
        case .failedFinal: return "失败 · 需检查素材"
        }
    }

    private var transcriptionStatusText: String {
        if let stored = savedStatus(for: .transcription) { return stored }
        guard let transcription else { return "本场未运行" }
        switch transcription.runState {
        case .idle: return project.hasUsableTranscript ? "已有文稿 · 无本场运行记录" : "本场未运行"
        case .running: return "转写中"
        case .unavailable(let reason): return "不可用：\(reason)"
        }
    }

    private var diarizationStatusText: String {
        if let stored = savedStatus(for: .diarization) { return stored }
        guard let diarization else { return "本场未运行" }
        switch diarization.cloudState {
        case .idle: return "本场未运行"
        case .working(let pending): return pending > 0 ? "识别中（待处理 \(pending)）" : "本场队列已处理"
        case .suspended: return "已暂停"
        case .unconfigured: return "未配置（仅本地转写）"
        }
    }
}
