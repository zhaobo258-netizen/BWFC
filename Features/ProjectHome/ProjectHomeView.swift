import SwiftUI
import UniformTypeIdentifiers

/// 首页（界面设计定稿 v1.0，2026-10-08）：问候 + 全库搜索 + 开始录音/导入音视频双卡 +
/// 分类筛选分组列表 + 右侧「业务项目 / 人物库 / 需要处理」栏。
/// 行为口径不变：开始录音零预填、首次知情确认一次、导入直达工作台后台流水线。
/// 搜索为真实本地检索（标题 + 最终/人工修订文稿），不伪造能力。
struct ProjectHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var projects: [Project] = []
    @State private var persons: [Person] = []
    @State private var businessProjects: [BusinessProject] = []
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
    /// 全库搜索词（标题 + 最终/人工修订文稿；本地真实检索）
    @State private var searchText = ""
    /// 分类筛选：nil = 全部；"" 哨兵不可用，用枚举更清晰
    @State private var categoryFilter: CategoryFilter = .all
    /// 首次录音知情确认只做一次（03 §6.1）
    @AppStorage("bwfx.recordingConsentConfirmed") private var consentConfirmed = false

    private enum CategoryFilter: Equatable {
        case all
        case ungrouped
        case named(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                greetRow
                actionArea
                noticeLine
                scenarioSection
                if let loadError {
                    errorLine("项目读取失败：\(loadError)")
                }
                if let operationError {
                    errorLine(operationError)
                }
                abnormalNotice
                contentGrid
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 48)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .background(BWTheme.canvas)
        .onAppear {
            selectedRecordingScenario = nil
            isScenarioExpanded = false
            reload()
            consumeStartRecordingRequestIfNeeded()
        }
        .onChange(of: router.startRecordingRequestToken) { _, _ in
            consumeStartRecordingRequestIfNeeded()
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

    // MARK: - 问候与搜索

    private var greetRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greetingTitle)
                    .font(.system(size: BWTheme.fontSizePageTitle, weight: .bold))
                    .foregroundStyle(BWTheme.ink)
                Text(todayLine)
                    .font(.system(size: BWTheme.fontSizeLabel))
                    .foregroundStyle(BWTheme.ink2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(BWTheme.ink3)
                TextField("搜索录音标题、逐字稿…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: BWTheme.fontSizeLabel))
                    .foregroundStyle(BWTheme.ink)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(BWTheme.ink3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 320)
            .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(BWTheme.border, lineWidth: 1)
            )
        }
    }

    private var greetingTitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let daypart: String
        switch hour {
        case 5..<11: daypart = "早上好"
        case 11..<14: daypart = "中午好"
        case 14..<18: daypart = "下午好"
        default: daypart = "晚上好"
        }
        if let me = persons.first(where: { $0.isCurrentUser }) {
            return "\(daypart)，\(me.displayName)"
        }
        return daypart
    }

    private var todayLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        let total = projects.count
        if total > 0 {
            return "\(formatter.string(from: Date())) · 共 \(total) 场录音"
        }
        return formatter.string(from: Date())
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
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("开始录音")
                            .font(.system(size: 20, weight: .bold))
                        Text("零预填，点开就录 · 场景自动判断")
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 34, weight: .light))
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
                .background(BWTheme.accentButton, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: BWTheme.accentButton.opacity(0.28), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .layoutPriority(1.2)

            Button {
                pickAndImportFile()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: environment.importProcessing.isRunning
                          ? "arrow.triangle.2.circlepath" : "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(BWTheme.ink)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(environment.importProcessing.isRunning ? "导入处理中…" : "导入音视频")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(BWTheme.ink)
                        Text("拖文件到这里 · 自动提取音轨并转写")
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
                .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            isDropTargeted ? BWTheme.accent : BWTheme.ink3,
                            style: StrokeStyle(
                                lineWidth: isDropTargeted ? 2 : 1.5,
                                dash: isDropTargeted ? [] : [6, 4]
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .disabled(environment.importProcessing.isRunning)
            .onDrop(of: ProjectHomeSupport.importContentTypes + [.fileURL],
                    isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
        }
    }

    private var noticeLine: some View {
        Text("首次录音会提示参与者知情确认；录音、转写、AI 分析是独立状态，失败都能单独重试。")
            .font(.system(size: BWTheme.fontSizeDetail))
            .foregroundStyle(BWTheme.ink3)
            .padding(.top, -12)
    }

    // MARK: - 录音场景

    /// 可选项不该占满一屏：默认折叠成一行，纵向空间留给项目列表（界面 3）
    private var scenarioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isScenarioExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("录音场景")
                        .font(.system(size: BWTheme.fontSizeLabel))
                        .foregroundStyle(BWTheme.ink2)
                    Text(selectedRecordingScenario?.displayName ?? "自动判断")
                        .font(.system(size: BWTheme.fontSizeLabel))
                        .fontWeight(.medium)
                        .foregroundStyle(selectedRecordingScenario == nil ? BWTheme.ink : BWTheme.accent)
                    Image(systemName: "chevron.down")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.ink3)
                        .rotationEffect(.degrees(isScenarioExpanded ? 180 : 0))
                    Spacer()
                    Text("仅用于现场录音")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("录音场景：\(selectedRecordingScenario?.displayName ?? "自动判断")")
            .help(isScenarioExpanded ? "收起录音场景选项" : "展开选择录音场景")

            if isScenarioExpanded {
                HStack(spacing: 8) {
                    scenarioButton(nil)
                    ForEach(ProjectHomeSupport.recordingScenarioOrder, id: \.self) { scenario in
                        scenarioButton(scenario)
                    }
                }

                Text("默认由 AI 根据内容判断，也可以提前指定；进入工作台后仍可随时修改。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink2)
            }
        }
        .padding(14)
        .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(BWTheme.border, lineWidth: 1)
        )
    }

    private func scenarioButton(_ scenario: ProjectScenario?) -> some View {
        let isSelected = selectedRecordingScenario == scenario
        let label = scenario?.displayName ?? "自动判断"
        return Button {
            selectedRecordingScenario = scenario
        } label: {
            Text(label)
                .font(.system(size: BWTheme.fontSizeDetail))
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.white : BWTheme.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    isSelected ? BWTheme.ink : Color.clear,
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? BWTheme.ink : BWTheme.border, lineWidth: 1)
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
                    .font(.system(size: BWTheme.fontSizeLabel))
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
            .foregroundStyle(BWTheme.warn)
            .padding(12)
            .background(BWTheme.warnBg, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func errorLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: BWTheme.fontSizeLabel))
            .foregroundStyle(BWTheme.danger)
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

    // MARK: - 列表 + 右侧栏

    /// 筛选与搜索后的展示项目
    private var visibleProjects: [Project] {
        projects.filter { project in
            switch categoryFilter {
            case .all: break
            case .ungrouped:
                guard ProjectHomeSupport.normalizedBusinessCategory(project.businessCategory) == nil else {
                    return false
                }
            case .named(let name):
                guard ProjectHomeSupport.normalizedBusinessCategory(project.businessCategory) == name else {
                    return false
                }
            }
            return ProjectHomeSupport.matchesSearch(project, query: searchText)
        }
    }

    private var contentGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 22) {
                projectListColumn
                    .frame(maxWidth: .infinity)
                sideColumn
                    .frame(width: 300)
            }
            VStack(alignment: .leading, spacing: 22) {
                projectListColumn
                sideColumn
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var projectListColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            listHead
            if visibleProjects.isEmpty {
                if projects.isEmpty && loadError == nil {
                    VStack(spacing: 8) {
                        Text("还没有录音")
                            .font(.system(size: BWTheme.fontSizeBody, weight: .medium))
                            .foregroundStyle(BWTheme.ink2)
                        Text("点击上方「开始录音」创建第一段记录；或把音视频文件拖到导入卡片。")
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    Text("没有匹配的录音。清空搜索或换个分类试试。")
                        .font(.system(size: BWTheme.fontSizeLabel))
                        .foregroundStyle(BWTheme.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            ForEach(ProjectHomeSupport.groupedForDisplay(visibleProjects)) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(group.title) · \(group.projects.count) 场")
                        .font(.system(size: BWTheme.fontSizeDetail, weight: .bold))
                        .foregroundStyle(BWTheme.ink3)
                        .padding(.horizontal, 4)
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

    private var listHead: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip("全部", isOn: categoryFilter == .all) { categoryFilter = .all }
                    ForEach(ProjectHomeSupport.businessCategoryOptions(from: projects)) { option in
                        filterChip(option.name, isOn: categoryFilter == .named(option.name)) {
                            categoryFilter = .named(option.name)
                        }
                    }
                    let hasUngrouped = projects.contains {
                        ProjectHomeSupport.normalizedBusinessCategory($0.businessCategory) == nil
                    }
                    if hasUngrouped {
                        filterChip("未分组", isOn: categoryFilter == .ungrouped) {
                            categoryFilter = .ungrouped
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            if isSelectingForMerge {
                Text("已选 \(selectedMergeProjectIDs.count) 段")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink2)
                Button("取消") { cancelMergeSelection() }
                    .controlSize(.small)
                Button("生成合并分析") { createCombinedAnalysis() }
                    .buttonStyle(.borderedProminent)
                    .tint(BWTheme.accentButton)
                    .controlSize(.small)
                    .disabled(selectedMergeProjectIDs.count < 2)
            } else {
                Button {
                    operationError = nil
                    isSelectingForMerge = true
                } label: {
                    Label("跨录音合并", systemImage: "square.stack.3d.up")
                        .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(projects.filter(ProjectHomeSupport.isEligibleForMerge).count < 2)
                .help("选择至少两段同分类录音，创建合并分析")
            }
        }
    }

    private func filterChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: BWTheme.fontSizeDetail))
            .foregroundStyle(isOn ? Color.white : BWTheme.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isOn ? BWTheme.ink : BWTheme.panel, in: Capsule())
            .overlay(
                Capsule().strokeBorder(isOn ? BWTheme.ink : BWTheme.border, lineWidth: 1)
            )
            .buttonStyle(.plain)
    }

    // MARK: - 右侧栏（业务项目 / 人物库 / 需要处理）

    private var sideColumn: some View {
        VStack(spacing: 12) {
            businessCard
            peopleCard
            todoCard
        }
    }

    private func sideCard<Content: View>(
        title: String,
        destination: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BWTheme.ink)
                Spacer()
                Button("全部", action: destination)
                    .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                    .foregroundStyle(BWTheme.evidence)
                    .underline()
                    .buttonStyle(.plain)
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(BWTheme.border, lineWidth: 1)
        )
    }

    private var businessCard: some View {
        sideCard(title: "业务项目", destination: { router.showBusinessProjects() }) {
            let active = businessProjects
                .filter { $0.status == .active }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            if active.isEmpty {
                sideEmptyRow("还没有业务项目。把多次录音连成一件事来跟进。")
            }
            ForEach(active.prefix(2)) { bp in
                Button { router.showBusinessProjects() } label: {
                    HStack(spacing: 10) {
                        Text(bp.name)
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if !bp.overdueFollowUps.isEmpty {
                            Text("\(bp.overdueFollowUps.count) 项逾期")
                                .font(.system(size: BWTheme.fontSizeDetail, weight: .semibold))
                                .foregroundStyle(BWTheme.danger)
                        } else if !bp.openFollowUps.isEmpty {
                            Text("\(bp.openFollowUps.count) 项跟进")
                                .font(.system(size: BWTheme.fontSizeDetail))
                                .foregroundStyle(BWTheme.ink3)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(BWTheme.border)
            }
        }
    }

    private var peopleCard: some View {
        sideCard(title: "人物库", destination: { router.showPeopleLibrary() }) {
            let sorted = persons.sorted {
                ($0.speakerLinks.map(\.linkedAt).max() ?? .distantPast)
                    > ($1.speakerLinks.map(\.linkedAt).max() ?? .distantPast)
            }
            if sorted.isEmpty {
                sideEmptyRow("还没有人物。人物不需要声纹，录音指认或手工创建都可以。")
            }
            ForEach(sorted.prefix(3)) { person in
                Button { router.showPeopleLibrary() } label: {
                    HStack(spacing: 10) {
                        BWSpeakerDot(
                            name: person.displayName,
                            color: person.isCurrentUser ? BWTheme.evidence : BWTheme.accent,
                            size: 28
                        )
                        Text(person.displayName + (person.isCurrentUser ? "（我）" : ""))
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(person.linkedVoiceProfileID != nil ? "声纹已登记" : "\(Set(person.speakerLinks.map(\.projectID)).count) 场录音")
                            .font(.system(size: BWTheme.fontSizeDetail))
                            .foregroundStyle(BWTheme.ink3)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(BWTheme.border)
            }
        }
    }

    private var todoCard: some View {
        sideCard(title: "需要处理", destination: {}) {
            let failedProjects = projects.filter {
                $0.hasFailedProcessingJobs || $0.status == .failed
            }
            let pendingSpeakers = projects.reduce(0) {
                $0 + $1.speakers.filter { !$0.isUserConfirmed }.count
            }
            let overdue = businessProjects
                .filter { $0.status == .active }
                .reduce(0) { $0 + $1.overdueFollowUps.count }

            if failedProjects.isEmpty && pendingSpeakers == 0 && overdue == 0 {
                sideEmptyRow("没有待处理事项。失败的分片、待确认的人物和逾期跟进会出现在这里。")
            }
            if !failedProjects.isEmpty {
                todoRow(
                    text: "\(failedProjects.count) 个项目有失败任务待重试",
                    actionTitle: "去重试"
                ) {
                    if let first = failedProjects.first {
                        router.showProjectWorkspace(first.id, autoStart: false)
                    }
                }
            }
            if pendingSpeakers > 0 {
                todoRow(text: "\(pendingSpeakers) 位说话人待确认", actionTitle: "去确认") {
                    router.showPeopleLibrary()
                }
            }
            if overdue > 0 {
                todoRow(text: "\(overdue) 项跟进已逾期", actionTitle: "去跟进") {
                    router.showBusinessProjects()
                }
            }
        }
    }

    private func todoRow(text: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: BWTheme.fontSizeLabel))
                .foregroundStyle(BWTheme.ink)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button(actionTitle, action: action)
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(BWTheme.ink2)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7).strokeBorder(BWTheme.border, lineWidth: 1)
                )
                .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private func sideEmptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: BWTheme.fontSizeDetail))
            .foregroundStyle(BWTheme.ink3)
            .padding(.vertical, 6)
    }

    // MARK: - 行为

    /// 边栏「开始录音」CTA 的一次性请求：回到首页后由这里消费，
    /// 复用本页知情确认 + 建项目链路（不另起第二条开录路径）。
    private func consumeStartRecordingRequestIfNeeded() {
        guard router.consumeStartRecordingRequest() else { return }
        if consentConfirmed {
            startRecordingProject()
        } else {
            showConsent = true
        }
    }

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
        persons = (try? environment.personLibraryStore.load()) ?? []
        businessProjects = (try? environment.businessProjectStore.load()) ?? []
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

/// 首页项目行（定稿版）：场景色图标块 + 标题/状态徽章 + 元信息 + 处理流水线 +
/// hover 行内操作（重命名/归入分类/删除）。整行可点有反馈（界面 4）。
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

    @State private var isHovering = false

    private var statusText: String {
        if case .normal = display { return project.processingStatusText }
        return display.text
    }

    var body: some View {
        HStack(spacing: 14) {
            if isMergeSelectionMode {
                Image(systemName: isSelectedForMerge ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelectedForMerge ? BWTheme.accent : BWTheme.ink3)
                    .opacity(isEligibleForMerge ? 1 : 0.35)
            }
            sceneIcon
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(project.title)
                                .font(.system(size: BWTheme.fontSizeBody, weight: .semibold))
                                .foregroundStyle(BWTheme.ink)
                                .lineLimit(1)
                            statusBadge
                        }
                        Text(metaLine)
                            .font(.system(size: BWTheme.fontSizeDetail))
                            .foregroundStyle(BWTheme.ink3)
                            .lineLimit(1)
                        pipelineRow
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isMergeSelectionMode && !isEligibleForMerge)
            .accessibilityLabel("\(project.title)，\(statusText)")

            if !isMergeSelectionMode {
                HStack(spacing: 4) {
                    hoverOp(icon: "pencil", label: "重命名", action: onRename)
                    hoverOp(icon: "folder", label: "归入分类", action: onGroup)
                    hoverOp(icon: "trash", label: "删除", tint: BWTheme.danger, action: onDelete)
                }
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isHovering ? BWTheme.accentLine : BWTheme.border,
                    lineWidth: 1
                )
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

    /// 场景色图标块（场景识别色两态一致，不随主题反转）
    private var sceneIcon: some View {
        let color = Self.sceneColor(for: project.scenario)
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.10))
            Image(systemName: Self.sceneIconName(for: project))
                .font(.system(size: 16))
                .foregroundStyle(color)
        }
        .frame(width: 40, height: 40)
    }

    private var metaLine: String {
        [
            project.lastActivityAt.formatted(date: .abbreviated, time: .shortened),
            "时长 \(LiveMeetingView.formatDuration(ms: project.durationMs))",
            project.scenario?.displayName ?? ProjectHomeSupport.sourceLabel(for: project.sourceType)
        ].joined(separator: " · ")
    }

    @ViewBuilder
    private var statusBadge: some View {
        let style = Self.badgeStyle(display, project: project)
        Text(statusText)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.background, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var pipelineRow: some View {
        let steps = ProjectHomeSupport.pipelineSteps(for: project)
        if !steps.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 3) {
                        Text(step.state.mark)
                        Text(step.title)
                    }
                    .font(.system(size: 11, weight: step.state == .running ? .semibold : .regular))
                    .foregroundStyle(Self.pipelineColor(step.state))
                    if index < steps.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(BWTheme.border)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func hoverOp(
        icon: String,
        label: String,
        tint: Color = BWTheme.ink2,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel("\(label)「\(project.title)」")
    }

    // MARK: - 样式映射

    private struct BadgeStyle {
        let foreground: Color
        let background: Color
    }

    private static func badgeStyle(
        _ display: ProjectHomeSupport.DisplayStatus,
        project: Project
    ) -> BadgeStyle {
        switch display {
        case .abnormalLeftover:
            return BadgeStyle(foreground: BWTheme.warn, background: BWTheme.warnBg)
        case .liveRecording(let status):
            switch status {
            case .recording:
                return BadgeStyle(foreground: .white, background: BWTheme.liveRed)
            case .paused:
                return BadgeStyle(foreground: BWTheme.warn, background: BWTheme.warnBg)
            default:
                return BadgeStyle(foreground: BWTheme.evidence, background: BWTheme.runBg)
            }
        case .normal(let status):
            switch status {
            case .ready:
                return BadgeStyle(foreground: BWTheme.ok, background: BWTheme.okBg)
            case .readyWithWarnings, .paused:
                return BadgeStyle(foreground: BWTheme.warn, background: BWTheme.warnBg)
            case .failed:
                return BadgeStyle(foreground: BWTheme.danger, background: BWTheme.dangerBg)
            case .processing, .creating:
                return project.hasFailedProcessingJobs
                    ? BadgeStyle(foreground: BWTheme.danger, background: BWTheme.dangerBg)
                    : BadgeStyle(foreground: BWTheme.evidence, background: BWTheme.runBg)
            case .recording:
                return BadgeStyle(foreground: .white, background: BWTheme.liveRed)
            }
        }
    }

    static func pipelineColor(_ state: ProjectHomeSupport.PipelineStep.State) -> Color {
        switch state {
        case .done: return BWTheme.ok
        case .running: return BWTheme.evidence
        case .todo: return BWTheme.ink3
        case .failed: return BWTheme.danger
        }
    }

    static func sceneColor(for scenario: ProjectScenario?) -> Color {
        switch scenario {
        case .clientVisit: return Color(hexStatic: 0xA94B22)
        case .internalMeeting: return Color(hexStatic: 0x375F85)
        case .classLearning: return Color(hexStatic: 0x2E7D52)
        case .journalistInterview: return Color(hexStatic: 0x6B5B95)
        case .freeform, nil: return Color(hexStatic: 0x62665E)
        }
    }

    static func sceneIconName(for project: Project) -> String {
        switch project.sourceType {
        case .liveRecording: return "waveform"
        case .importedAudio: return "waveform"
        case .importedVideo: return "film"
        case .combinedRecordings: return "square.stack.3d.up"
        }
    }
}

private extension Color {
    /// 场景识别色等固定色（不随深浅模式反转）
    init(hexStatic: UInt32) {
        self.init(nsColor: NSColor(hex: hexStatic))
    }
}
