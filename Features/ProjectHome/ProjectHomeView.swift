import SwiftUI
import UniformTypeIdentifiers

/// 首页（阶段 B/C，03 文档 §6.1）：开始录音 / 导入音视频 双入口 + 最近项目。
/// 开始录音：零预填，首次仅一次录音知情确认，随后直达工作台并立即开录。
/// 导入音视频（阶段 C）：文件选择或拖放；检查通过即创建项目直达工作台，
/// 提取/转写/分析在后台流水线执行，重启后可续跑。
struct ProjectHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var projects: [Project] = []
    @State private var loadError: String?
    @State private var showConsent = false
    @State private var importErrorMessage: String?
    @State private var isDropTargeted = false
    @State private var selectedRecordingScenario: ProjectScenario?
    @State private var isScenarioExpanded = false
    @State private var isResolvingLeftover = false
    @State private var renameTarget: Project?
    @State private var renameDraft = ""
    @State private var groupingTarget: Project?
    @State private var isSelectingForMerge = false
    @State private var selectedMergeProjectIDs: Set<UUID> = []
    @State private var deleteTarget: Project?
    /// 删除等操作的失败原因。不复用 loadError：那条带死板的「项目读取失败：」前缀，
    /// 拿它显示「正在录音，先结束再删」会变成一句读不通的假错误。
    @State private var operationError: String?
    /// 首次录音知情确认只做一次（03 §6.1）
    @AppStorage("bwfx.recordingConsentConfirmed") private var consentConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    actionArea
                    recordingScenarioSection
                    if let loadError {
                        Label("项目读取失败：\(loadError)", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if let operationError {
                        Label(operationError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    abnormalNotice
                    recentSection
                }
                .padding(24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
        }
        .background(BWTheme.paper)
        .navigationTitle("帮我分析")
        .onAppear {
            selectedRecordingScenario = nil
            isScenarioExpanded = false
            reload()
        }
        .confirmationDialog("开始录音前请确认", isPresented: $showConsent, titleVisibility: .visible) {
            Button("已告知，开始录音") {
                consentConfirmed = true
                startRecordingProject()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请确认参与者已知晓本次录音。\n录音、文稿与笔记默认只保存在本机；配置云端分析或说话人识别服务后，仅对应内容按需发送给对应服务，API Key 明文保存在本机配置中。")
        }
        .alert("无法导入", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert("重命名项目", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("项目标题", text: $renameDraft)
            Button("保存") { commitRename() }
            Button("取消", role: .cancel) { renameTarget = nil }
        } message: {
            Text("只改标题，不影响录音文件与已生成的分析。")
        }
        .sheet(item: $groupingTarget) { project in
            BusinessProjectPickerSheet(
                project: project,
                projects: projects,
                onSelect: { category in
                    commitBusinessGrouping(project, category: category)
                }
            )
        }
        .confirmationDialog(
            "删除这个项目？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) { commitDelete() }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            if let deleteTarget {
                Text(ProjectHomeSupport.deletionSummary(for: deleteTarget))
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            BWBrandMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("帮我分析")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("录音 · 转写 · 实时分析")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                router.showBusinessProjects()
            } label: {
                Label("业务项目", systemImage: "briefcase")
            }
            .buttonStyle(.bordered)
            .help("人物、录音与已确认跟进的业务项目闭环")
            Button {
                router.showPeopleLibrary()
            } label: {
                Label("人物库", systemImage: "person.2.wave.2")
            }
            .buttonStyle(.bordered)
            Button {
                router.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 主动作区

    private var actionArea: some View {
        HStack(spacing: 16) {
            Button {
                if consentConfirmed {
                    startRecordingProject()
                } else {
                    showConsent = true
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.18), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开始录音")
                            .font(.headline)
                        Text("边录边转写，AI 实时分析")
                            .font(.caption)
                            .opacity(0.85)
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(BWTheme.accentGradient, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: BWTheme.accent.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)

            Button {
                pickAndImportFile()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: environment.importProcessing.isRunning
                          ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BWTheme.accent)
                        .frame(width: 46, height: 46)
                        .background(BWTheme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(environment.importProcessing.isRunning ? "导入处理中…" : "导入音视频")
                            .font(.headline)
                        Text("m4a / mp3 / wav / mp4 · 可直接拖入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(BWTheme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isDropTargeted ? BWTheme.accent : BWTheme.cardStroke,
                                      lineWidth: isDropTargeted ? 2 : 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(environment.importProcessing.isRunning)
            .onDrop(of: ProjectHomeSupport.importContentTypes + [.fileURL],
                    isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - 录音场景

    /// 可选项不该占满一屏：默认折叠成一行，纵向空间留给项目列表（界面 3）
    private var recordingScenarioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isScenarioExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("录音场景")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(selectedRecordingScenario?.displayName ?? "自动判断")
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(selectedRecordingScenario == nil ? .primary : BWTheme.accent)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isScenarioExpanded ? 180 : 0))
                    Spacer()
                    Text("仅用于现场录音")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("录音场景：\(selectedRecordingScenario?.displayName ?? "自动判断")")
            .help(isScenarioExpanded ? "收起录音场景选项" : "展开选择录音场景")

            if isScenarioExpanded {
                HStack(spacing: 8) {
                    recordingScenarioButton(nil)
                    ForEach(ProjectHomeSupport.recordingScenarioOrder, id: \.self) { scenario in
                        recordingScenarioButton(scenario)
                    }
                }

                Text("默认由 AI 根据内容判断，也可以提前指定；进入工作台后仍可随时修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(BWTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(BWTheme.cardStroke, lineWidth: 1)
        )
    }

    private func recordingScenarioButton(_ scenario: ProjectScenario?) -> some View {
        let isSelected = selectedRecordingScenario == scenario
        let label = scenario?.displayName ?? "自动判断"
        return Button {
            selectedRecordingScenario = scenario
        } label: {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                }
                Text(label)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .foregroundStyle(isSelected ? BWTheme.accent : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? BWTheme.accent.opacity(0.13) : Color.clear,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? BWTheme.accent.opacity(0.75) : BWTheme.cardStroke,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("录音场景：\(label)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .help(isSelected ? "当前录音场景：\(label)" : "将录音场景设为\(label)")
    }

    // MARK: - 异常项目提示（非阻塞）

    @ViewBuilder
    private var abnormalNotice: some View {
        let leftover = ProjectHomeSupport.leftoverProjects(
            in: projects,
            liveProjectIDs: environment.liveRecordingProjectIDs
        )
        if !leftover.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                Text("有 \(leftover.count) 个项目上次未正常结束。")
                    .font(.callout)
                Spacer()
                // 提示必须带得动手的入口，不能只说「打开后可以」
                Button("查看第一个") {
                    if let first = leftover.first {
                        router.showProjectWorkspace(first.id, autoStart: false)
                    }
                }
                .buttonStyle(.link)
                Button("全部标记结束") {
                    markAllLeftoverResolved(leftover)
                }
                .buttonStyle(.link)
                .disabled(isResolvingLeftover)
            }
            .padding(12)
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// 把残留状态推进到 ready，口径与异常恢复弹窗一致（复用同一函数，不另立映射）
    private func markAllLeftoverResolved(_ leftover: [Project]) {
        isResolvingLeftover = true
        defer { isResolvingLeftover = false }
        for project in leftover {
            do {
                try MeetingRecovery.markResolvedAfterAbnormalExit(project)
                try environment.persist(project)
            } catch {
                loadError = error.localizedDescription
                break
            }
        }
        reload()
    }

    // MARK: - 最近项目

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("业务项目与录音")
                    .font(.headline)
                Spacer()
                if isSelectingForMerge {
                    Text("已选 \(selectedMergeProjectIDs.count) 段")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("取消") { cancelMergeSelection() }
                        .controlSize(.small)
                    Button("生成合并分析") { createCombinedAnalysis() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selectedMergeProjectIDs.count < 2)
                } else {
                    Button {
                        operationError = nil
                        isSelectingForMerge = true
                    } label: {
                        Label("跨录音合并", systemImage: "square.stack.3d.up")
                    }
                    .controlSize(.small)
                    .disabled(projects.filter(ProjectHomeSupport.isEligibleForMerge).count < 2)
                }
            }
            if projects.isEmpty && loadError == nil {
                Text("还没有录音。点击「开始录音」创建第一段记录。")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 24)
            }
            ForEach(ProjectHomeSupport.groupedForDisplay(projects)) { group in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: group.businessCategory == nil ? "tray" : "folder.fill")
                            .foregroundStyle(group.businessCategory == nil ? .secondary : BWTheme.accent)
                        Text(group.title)
                            .font(.callout)
                            .fontWeight(.semibold)
                        Text("\(group.projects.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 5)

                    ForEach(group.projects) { project in
                        ProjectHomeRow(
                            project: project,
                            display: ProjectHomeSupport.displayStatus(
                                for: project,
                                liveProjectIDs: environment.liveRecordingProjectIDs
                            ),
                            isMergeSelectionMode: isSelectingForMerge,
                            isSelectedForMerge: selectedMergeProjectIDs.contains(project.id),
                            isEligibleForMerge: ProjectHomeSupport.isEligibleForMerge(project),
                            onOpen: {
                                if isSelectingForMerge {
                                    toggleMergeSelection(project)
                                } else {
                                    router.showProjectWorkspace(project.id, autoStart: false)
                                }
                            },
                            onRename: {
                                renameTarget = project
                                renameDraft = project.title
                            },
                            onGroup: {
                                groupingTarget = project
                            },
                            onRemoveFromGroup: project.businessCategory == nil ? nil : {
                                removeFromBusinessGrouping(project)
                            },
                            onRevealInFinder: {
                                revealInFinder(project)
                            },
                            onDelete: {
                                requestDelete(project)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 行为

    /// 开始录音：立即创建临时项目并直达工作台开录（两次交互内）
    private func startRecordingProject() {
        guard !environment.isPersistentStorageUnavailable else {
            loadError = ProjectWriteError.storageUnavailable.localizedDescription
            return
        }
        let now = Date()
        let speakers: [Speaker]
        let voiceProfileWarning: String?
        do {
            speakers = try environment.automaticSpeakersWithPeople()
            voiceProfileWarning = nil
        } catch {
            speakers = []
            voiceProfileWarning = "永久声纹库无法读取，本次已不带声纹继续录音；可在「说话人」面板中修复。"
        }
        do {
            let project = ProjectHomeSupport.makeRecordingProject(
                at: now,
                scenario: selectedRecordingScenario,
                speakers: speakers
            )
            try environment.persist(project)
            for speaker in project.speakers {
                guard let personID = speaker.personId else { continue }
                do {
                    _ = try environment.personLibraryStore.linkSpeaker(
                        personID: personID, projectID: project.id, speakerID: speaker.id,
                        speakerDisplayName: speaker.displayName
                    )
                } catch {
                    environment.setPendingWarning("录音已创建，人物关联账本暂未更新，可在人物库重新关联。", for: project.id)
                }
            }
            if let voiceProfileWarning {
                environment.setPendingWarning(voiceProfileWarning, for: project.id)
            }
            router.showProjectWorkspace(project.id, autoStart: true)
        } catch {
            loadError = "项目创建失败（\(String(describing: type(of: error)))）"
        }
    }

    private func reload() {
        do {
            projects = try environment.allProjects()
            loadError = nil
        } catch {
            projects = []
            loadError = Self.loadErrorMessage(for: error)
        }
    }

    // MARK: - 重命名、在 Finder 中显示与删除

    /// 只写 title 字段：走 .title 所有权，避免覆盖工作台或流水线正在改的其他字段。
    private func commitRename() {
        guard let project = renameTarget else { return }
        renameTarget = nil
        guard let title = ProjectHomeSupport.normalizedTitle(renameDraft),
              title != project.title else { return }
        project.title = title
        project.lastActivityAt = Date()
        do {
            try environment.persist(project, fields: .title)
        } catch {
            loadError = "重命名保存失败（\(String(describing: type(of: error)))）"
        }
        reload()
    }

    private func commitBusinessGrouping(
        _ project: Project,
        category rawCategory: String?
    ) {
        groupingTarget = nil
        let category = ProjectHomeSupport.canonicalBusinessCategory(
            rawCategory,
            projects: projects
        )
        guard category != project.businessCategory else { return }
        project.businessCategory = category
        project.lastActivityAt = Date()
        do {
            try environment.persist(project, fields: .businessGrouping)
            operationError = nil
        } catch {
            operationError = "业务项目归组保存失败（\(String(describing: type(of: error)))）"
        }
        reload()
    }

    private func removeFromBusinessGrouping(_ project: Project) {
        project.businessCategory = nil
        project.lastActivityAt = Date()
        do {
            try environment.persist(project, fields: .businessGrouping)
            operationError = nil
        } catch {
            operationError = "移出业务项目失败（\(String(describing: type(of: error)))）"
        }
        reload()
    }

    private func toggleMergeSelection(_ project: Project) {
        guard ProjectHomeSupport.isEligibleForMerge(project) else { return }
        if selectedMergeProjectIDs.contains(project.id) {
            selectedMergeProjectIDs.remove(project.id)
        } else {
            selectedMergeProjectIDs.insert(project.id)
        }
    }

    private func cancelMergeSelection() {
        isSelectingForMerge = false
        selectedMergeProjectIDs.removeAll()
        operationError = nil
    }

    private func createCombinedAnalysis() {
        do {
            let selected = projects.filter { selectedMergeProjectIDs.contains($0.id) }
            let combined = try ProjectHomeSupport.makeCombinedAnalysisProject(from: selected)
            try environment.persist(combined)
            cancelMergeSelection()
            reload()
            if environment.isAnalysisConfigured {
                environment.finalReportCoordinator.start(projectID: combined.id)
            }
            router.showProjectFinalReport(combined.id)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func revealInFinder(_ project: Project) {
        guard let target = ProjectHomeSupport.finderRevealTarget(
            projectDirectory: environment.fileStore.meetingDirectory(for: project.id),
            baseDirectory: environment.fileStore.baseDirectory
        ) else {
            loadError = ProjectHomeSupport.missingStorageDirectoryMessage
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// 守卫放在弹确认之前：不可删的项目就别先问「确定吗」再拒绝，
    /// 那等于让用户按下「永久删除」之后才知道白按了。
    private func requestDelete(_ project: Project) {
        if let block = ProjectHomeSupport.deletionBlock(
            for: project,
            liveProjectIDs: environment.liveRecordingProjectIDs,
            importProcessingProjectID: environment.importProcessing.activeProjectID
        ) {
            operationError = block.message
            return
        }
        operationError = nil
        deleteTarget = project
    }

    /// 确认后再查一次守卫：弹窗展示期间用户可能在别处开了录音或触发了导入。
    private func commitDelete() {
        guard let project = deleteTarget else { return }
        deleteTarget = nil
        if let block = ProjectHomeSupport.deletionBlock(
            for: project,
            liveProjectIDs: environment.liveRecordingProjectIDs,
            importProcessingProjectID: environment.importProcessing.activeProjectID
        ) {
            operationError = block.message
            return
        }
        do {
            try environment.deleteProject(project)
            operationError = nil
        } catch {
            operationError = "删除失败（\(String(describing: type(of: error)))）"
        }
        reload()
    }

    static func loadErrorMessage(for error: Error) -> String {
        guard case let ProjectStoreError.dataCorrupted(backupFileName) = error else {
            return String(describing: type(of: error))
        }
        if let backupFileName {
            return "数据文件损坏，已备份为 \(backupFileName)，原始数据未丢失。"
        }
        return "数据文件损坏，自动备份未完成，已阻止写入。"
    }

    // MARK: - 导入音视频（阶段 C，03 §6.2）

    /// 文件选择导入：检查通过即创建项目并直达工作台，处理在后台流水线继续
    private func pickAndImportFile() {
        let panel = NSOpenPanel()
        panel.title = "导入音视频"
        panel.allowsMultipleSelection = false // 首版一次一个文件（03 §6.2）
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginImport(url: url)
    }

    /// 拖放导入：只取第一个文件（首版一次一个）。
    /// 落点收敛到导入卡片本身，高亮区域与真实可放区域一致；
    /// 类型不符时同步返回 false，光标直接显示「不接受」而不是先接受再弹错。
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !environment.importProcessing.isRunning else { return false }
        let candidate = providers.first { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                && ProjectHomeSupport.acceptsDrop(
                    registeredContentTypes: provider.registeredTypeIdentifiers.compactMap(UTType.init)
                )
        }
        guard let provider = candidate else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                // provider 只交付 file URL；外部文件的 security scope 由导入控制器
                // 覆盖检查与原件复制，后续阶段只读取项目目录内副本。
                guard ProjectHomeSupport.acceptsDroppedFile(at: url) else {
                    importErrorMessage = ProjectHomeSupport.unsupportedDropMessage
                    return
                }
                beginImport(url: url)
            }
        }
        return true
    }

    private func beginImport(url: URL) {
        guard !environment.isPersistentStorageUnavailable else {
            importErrorMessage = ProjectWriteError.storageUnavailable.localizedDescription
            return
        }
        Task {
            do {
                let projectID = try await environment.importProcessing.beginImport(url: url)
                reload()
                router.showProjectWorkspace(projectID, autoStart: false)
            } catch let error as AudioImportError {
                importErrorMessage = error.userMessage
            } catch let error as ImportBusyError {
                importErrorMessage = error.userMessage
            } catch {
                importErrorMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct BusinessProjectPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let projects: [Project]
    let onSelect: (String?) -> Void

    @State private var search = ""
    @State private var newName = ""
    @State private var isCreating = false

    private var options: [ProjectHomeSupport.BusinessCategoryOption] {
        ProjectHomeSupport.businessCategoryOptions(
            from: projects,
            search: search
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("归入业务项目")
                        .font(.headline)
                    Text(project.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("取消") { dismiss() }
            }
            .padding(16)
            Divider()

            List {
                Section("现有业务项目 · 最近使用优先") {
                    if options.isEmpty {
                        Text(search.isEmpty ? "还没有业务项目" : "没有匹配的业务项目")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(options) { option in
                            Button {
                                choose(option.name)
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(BWTheme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.name)
                                        Text("已有 \(option.projectCount) 条录音")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if ProjectHomeSupport.normalizedBusinessCategory(
                                        project.businessCategory
                                    ) == option.name {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(BWTheme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button {
                        isCreating.toggle()
                        if isCreating && newName.isEmpty { newName = search }
                    } label: {
                        Label("新建业务项目", systemImage: "folder.badge.plus")
                    }
                    if isCreating {
                        HStack {
                            TextField("输入新名称", text: $newName)
                            Button("创建并归入") {
                                choose(newName)
                            }
                            .disabled(
                                ProjectHomeSupport.normalizedBusinessCategory(
                                    newName
                                ) == nil
                            )
                        }
                    }
                    if project.businessCategory != nil {
                        Button("移出当前业务项目") {
                            choose(nil)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索已有业务项目")
        }
        .frame(width: 520, height: 440)
    }

    private func choose(_ category: String?) {
        onSelect(category)
        dismiss()
    }
}

/// 最近项目的一行。独立成 View 才能持有 hover 状态：
/// 整行可点却毫无反馈时用户不知道能点（界面 4）。
/// 右侧信息重新分层——时长为主，来源降级成小图标，时间最弱。
private struct ProjectHomeRow: View {
    let project: Project
    let display: ProjectHomeSupport.DisplayStatus
    let isMergeSelectionMode: Bool
    let isSelectedForMerge: Bool
    let isEligibleForMerge: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onGroup: () -> Void
    let onRemoveFromGroup: (() -> Void)?
    let onRevealInFinder: () -> Void
    let onDelete: () -> Void

    private var statusText: String {
        if case .normal = display { return project.processingStatusText }
        return display.text
    }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    if isMergeSelectionMode {
                        Image(systemName: isSelectedForMerge ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelectedForMerge ? BWTheme.accent : .secondary)
                            .opacity(isEligibleForMerge ? 1 : 0.35)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(project.title)
                                .font(.callout)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            BWBadge(text: statusText, color: Self.badgeColor(display))
                        }
                        Text(ProjectHomeSupport.summary(for: project))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(LiveMeetingView.formatDuration(ms: project.durationMs))
                            .font(.callout)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        HStack(spacing: 5) {
                            Image(systemName: Self.sourceIcon(project.sourceType))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help(ProjectHomeSupport.sourceLabel(for: project.sourceType))
                            Text(project.lastActivityAt,
                                 format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(isHovering ? BWTheme.accent : Color.secondary.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isMergeSelectionMode && !isEligibleForMerge)
            .accessibilityLabel("\(project.title)，\(statusText)，时长 \(LiveMeetingView.formatDuration(ms: project.durationMs))")
            .help("打开「\(project.title)」")

            if !isMergeSelectionMode {
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.red)
                .help("删除录音及这个项目的本地内容")
                .accessibilityLabel("删除「\(project.title)」")
            }
        }
        .bwCard(padding: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isHovering ? BWTheme.accent.opacity(0.5) : .clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu {
            Button("打开") { onOpen() }
            Button("重命名…") { onRename() }
            Button("归入业务项目…") { onGroup() }
            if let onRemoveFromGroup {
                Button("移出当前业务项目") { onRemoveFromGroup() }
            }
            Button("在 Finder 中显示") { onRevealInFinder() }
            Divider()
            Button("删除项目…", role: .destructive) { onDelete() }
        }
    }

    private static func sourceIcon(_ sourceType: ProjectSourceType) -> String {
        switch sourceType {
        case .liveRecording: return "mic"
        case .importedAudio: return "waveform"
        case .importedVideo: return "film"
        case .combinedRecordings: return "square.stack.3d.up"
        }
    }

    /// 红色只留给此刻真正活跃的录音；异常残留用灰色，避免误读成「正在进行」
    static func badgeColor(_ display: ProjectHomeSupport.DisplayStatus) -> Color {
        switch display {
        case .abnormalLeftover:
            return .secondary
        case .liveRecording(let status), .normal(let status):
            switch status {
            case .recording: return .red
            case .paused, .processing, .readyWithWarnings: return .orange
            case .ready: return .green
            case .creating: return .gray
            case .failed: return .red
            }
        }
    }
}
