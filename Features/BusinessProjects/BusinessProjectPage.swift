import SwiftUI

/// 轻 CRM 业务项目页（界面设计定稿 v1.0）：左列表 + 右详情（目标、参与人物、
/// 跟进三列看板、关联录音、有效背景）。
/// 跟进闭环：候选（在工作台确认）→ 待跟进 → 进行中 → 已完成（必填实际结果）；
/// 责任人与期限没有原话支持时标「待核对」，不由系统臆造。
struct BusinessProjectPage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var businessProjects: [BusinessProject] = []
    @State private var projects: [Project] = []
    @State private var selectedID: UUID?
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var isShowingSuggestions = false

    private var selected: BusinessProject? {
        businessProjects.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 280)
            Rectangle().fill(BWTheme.border).frame(width: 1)
            Group {
                if let selected {
                    BusinessProjectDetailPane(
                        businessProject: selected,
                        projects: projects,
                        onChanged: reload
                    )
                    .id(selected.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "briefcase")
                            .font(.system(size: 28))
                            .foregroundStyle(BWTheme.ink3)
                        Text("选择或新建业务项目")
                            .font(.system(size: BWTheme.fontSizeBody, weight: .medium))
                            .foregroundStyle(BWTheme.ink2)
                        Text("业务项目把人物、录音与已确认跟进连起来；先建一个真实业务闭环。")
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink3)
                            .multilineTextAlignment(.center)
                        Button("＋ 新建业务项目") { isCreating = true }
                            .buttonStyle(.borderedProminent)
                            .tint(BWTheme.accentButton)
                            .controlSize(.small)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BWTheme.canvas)
        .sheet(isPresented: $isCreating) {
            BusinessProjectCreateSheet(
                suggestions: BusinessProjectStore.groupingSuggestions(
                    recordings: projects,
                    existingBusinessProjects: businessProjects
                ).map(\.name)
            ) { name, goal in
                createBusinessProject(name: name, goal: goal)
            }
            .environment(environment)
            .frame(minWidth: 440)
        }
        .sheet(isPresented: $isShowingSuggestions) {
            BusinessProjectSuggestionsSheet(
                suggestions: BusinessProjectStore.groupingSuggestions(
                    recordings: projects,
                    existingBusinessProjects: businessProjects
                )
            ) { suggestion in
                createFromSuggestion(suggestion)
            }
            .environment(environment)
            .frame(minWidth: 480, minHeight: 360)
        }
        .task { reload() }
    }

    // MARK: - 左列：项目列表

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("业务项目")
                    .font(.system(size: BWTheme.fontSizeSectionTitle, weight: .semibold))
                    .foregroundStyle(BWTheme.ink)
                Spacer()
                Button {
                    isCreating = true
                } label: {
                    Text("＋ 新建")
                        .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: BWTheme.minimumHitHeight)
                        .background(BWTheme.accentButton, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(businessProjects) { businessProject in
                        BusinessProjectRow(
                            businessProject: businessProject,
                            isSelected: businessProject.id == selectedID
                        ) {
                            selectedID = businessProject.id
                        }
                    }
                    if businessProjects.isEmpty {
                        Text("还没有业务项目。点右上角「新建」，或从下方归组建议开始。")
                            .font(.system(size: BWTheme.fontSizeDetail))
                            .foregroundStyle(BWTheme.ink3)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 10)
            }

            if !BusinessProjectStore.groupingSuggestions(
                recordings: projects,
                existingBusinessProjects: businessProjects
            ).isEmpty {
                Button {
                    isShowingSuggestions = true
                } label: {
                    Text("从业务分类归组建议…")
                        .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                        .foregroundStyle(BWTheme.evidence)
                        .underline()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("把已有录音的业务分类整理成业务项目（仅建议，不自动认定同一项目）")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.danger)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(BWTheme.panel)
            }
        }
        .background(BWTheme.canvas)
    }

    private func reload() {
        do {
            let loadedBusinessProjects = try environment.businessProjectStore.load()
            let loadedProjects = try environment.allProjects()
            businessProjects = loadedBusinessProjects
            projects = loadedProjects
            errorMessage = nil
        } catch {
            errorMessage = "读取失败：\(error.localizedDescription)"
            return
        }
        if selectedID == nil || !businessProjects.contains(where: { $0.id == selectedID }) {
            selectedID = businessProjects.first?.id
        }
    }

    private func createBusinessProject(name: String, goal: String?) -> String? {
        do {
            let created = try environment.businessProjectStore.create(
                name: name,
                goalStatement: goal
            )
            reload()
            selectedID = created.id
            return nil
        } catch {
            return "创建失败：\(error.localizedDescription)"
        }
    }

    private func createFromSuggestion(_ suggestion: BusinessProjectStore.GroupingSuggestion) -> String? {
        do {
            let created = try environment.businessProjectStore.create(
                name: suggestion.name,
                linkedProjectIDs: suggestion.projectIDs
            )
            reload()
            selectedID = created.id
            return nil
        } catch {
            return "创建失败：\(error.localizedDescription)"
        }
    }
}

/// 项目行：名称 + 录音数/人数/跟进/逾期；归档态弱化
private struct BusinessProjectRow: View {
    let businessProject: BusinessProject
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(businessProject.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            businessProject.status == .archived ? BWTheme.ink3 : BWTheme.ink
                        )
                        .lineLimit(1)
                    if businessProject.status == .archived {
                        Text("已归档")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(BWTheme.ink3)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(BWTheme.sunken, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                HStack(spacing: 8) {
                    Text("\(businessProject.linkedProjectIDs.count) 场录音")
                    Text("\(businessProject.participantPersonIDs.count) 人")
                    let overdue = businessProject.overdueFollowUps.count
                    if overdue > 0 {
                        Text("\(overdue) 项逾期")
                            .fontWeight(.semibold)
                            .foregroundStyle(BWTheme.danger)
                    } else if !businessProject.openFollowUps.isEmpty {
                        Text("\(businessProject.openFollowUps.count) 项跟进")
                            .foregroundStyle(BWTheme.accent)
                    }
                }
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(BWTheme.ink3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? BWTheme.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

private struct BusinessProjectCreateSheet: View {
    let suggestions: [String]
    let onCreate: (String, String?) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var goal = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("新建业务项目", systemImage: "briefcase.badge.plus")
                .font(.headline)
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion }
                                .controlSize(.mini)
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            TextField("目标说明：要达成什么（可空）", text: $goal, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            Text("创建后可在详情页关联人物与录音；同名项目不自动合并。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") {
                    saveError = onCreate(name, goal)
                    if saveError == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

private struct BusinessProjectSuggestionsSheet: View {
    let suggestions: [BusinessProjectStore.GroupingSuggestion]
    let onAccept: (BusinessProjectStore.GroupingSuggestion) -> String?
    @State private var saveError: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("从业务分类归组建议", systemImage: "square.grid.2x2")
                .font(.headline)
            Text("以下建议来自录音上的业务分类字符串（同名仅建议，不自动认定是同一项目）。接受后创建业务项目并关联这些录音。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.name)
                                    .font(.callout)
                                Text("\(suggestion.projectIDs.count) 场未关联录音")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("创建并关联") {
                                saveError = onAccept(suggestion)
                                if saveError == nil { dismiss() }
                            }
                            .controlSize(.mini)
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
            }
        }
        .padding(16)
    }
}

/// 业务项目详情：目标、参与人物、跟进看板、关联录音、有效背景。
struct BusinessProjectDetailPane: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    let businessProject: BusinessProject
    let projects: [Project]
    let onChanged: () -> Void

    @State private var editedGoal: String?
    @State private var editedBackground: String?
    @State private var isSelectingRecordings = false
    @State private var isSelectingParticipants = false
    @State private var completingFollowUpID: UUID?
    @State private var resultNote = ""
    @State private var actionError: String?
    @State private var persons: [Person] = []

    private var linkedRecordings: [Project] {
        let ids = Set(businessProject.linkedProjectIDs)
        return projects
            .filter { ids.contains($0.id) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.danger)
                }
                participantsSection
                followUpBoard
                recordingsSection
                backgroundSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(BWTheme.canvas)
        .sheet(isPresented: $isSelectingRecordings) {
            RecordingLinkPickerSheet(
                businessProject: businessProject,
                projects: projects
            ) { projectIDs in
                setLinkedRecordings(projectIDs)
            }
            .environment(environment)
            .frame(minWidth: 480, minHeight: 440)
        }
        .sheet(isPresented: $isSelectingParticipants) {
            ParticipantPickerSheet(
                businessProject: businessProject,
                persons: persons
            ) { personIDs in
                setParticipants(personIDs)
            }
            .environment(environment)
            .frame(minWidth: 440, minHeight: 400)
        }
        .sheet(isPresented: Binding(
            get: { completingFollowUpID != nil },
            set: { if !$0 { completingFollowUpID = nil; resultNote = "" } }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Label("记录实际结果", systemImage: "checkmark.seal")
                    .font(.headline)
                Text("点击完成不等于客户已接受；请写下实际结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $resultNote)
                    .font(.callout)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("取消") {
                        completingFollowUpID = nil
                        resultNote = ""
                    }
                    Button("确认完成") {
                        if let id = completingFollowUpID,
                           completeFollowUp(id: id, note: resultNote) {
                            completingFollowUpID = nil
                            resultNote = ""
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(resultNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(minWidth: 420, minHeight: 260)
        }
        .task {
            do {
                persons = try environment.personLibraryStore.load()
            } catch {
                actionError = "人物库读取失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 头部（名称 / 目标 / 归档）

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(businessProject.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(BWTheme.ink)
                if businessProject.status == .archived {
                    Text("已归档")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(BWTheme.ink3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(BWTheme.sunken, in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer()
                Button(businessProject.status == .archived ? "恢复项目" : "归档") {
                    setArchived(businessProject.status != .archived)
                }
                .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                .foregroundStyle(BWTheme.ink2)
                .padding(.horizontal, 12)
                .frame(height: BWTheme.minimumHitHeight)
                .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(BWTheme.border, lineWidth: 1)
                )
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("目标说明")
                        .font(.system(size: BWTheme.fontSizeDetail, weight: .bold))
                        .foregroundStyle(BWTheme.ink2)
                    Spacer()
                    if let edited = editedGoal,
                       edited != (businessProject.goalStatement ?? "") {
                        Button("保存目标") {
                            if updateFields({ $0.goalStatement = edited }) {
                                editedGoal = nil
                            }
                        }
                        .controlSize(.mini)
                    }
                }
                TextEditor(
                    text: Binding(
                        get: { editedGoal ?? businessProject.goalStatement ?? "" },
                        set: { editedGoal = $0 }
                    )
                )
                .font(.system(size: BWTheme.fontSizeBody))
                .foregroundStyle(BWTheme.ink)
                .frame(minHeight: 54)
                .scrollContentBackground(.hidden)
                .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(BWTheme.border, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - 参与人物

    private var participantsSection: some View {
        sectionShell(
            title: "参与人物",
            note: nil,
            moreTitle: "编辑",
            more: { isSelectingParticipants = true }
        ) {
            if businessProject.participantPersonIDs.isEmpty {
                Text("尚未选择参与人物。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
            } else {
                FlowParticipantChips(
                    names: businessProject.participantPersonIDs.compactMap { id in
                        persons.first { $0.id == id }?.displayName
                    }
                )
            }
        }
    }

    // MARK: - 跟进看板（三列：待跟进 → 进行中 → 已完成）

    private var followUpBoard: some View {
        sectionShell(
            title: "跟进看板",
            note: "完成必须填写实际结果；责任人与期限来自原话，缺了就是待核对",
            moreTitle: nil,
            more: nil
        ) {
            if businessProject.followUps.isEmpty {
                Text("暂无跟进。录音结束后的跟进候选在工作台确认后进入这里。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    followUpColumn(
                        title: "待跟进",
                        status: .pending,
                        items: businessProject.followUps.filter { $0.handlingStatus == .pending }
                    )
                    followUpColumn(
                        title: "进行中",
                        status: .inProgress,
                        items: businessProject.followUps.filter { $0.handlingStatus == .inProgress }
                    )
                    followUpColumn(
                        title: "已完成",
                        status: .completed,
                        items: businessProject.followUps
                            .filter { $0.handlingStatus == .completed }
                            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                    )
                }
            }
        }
    }

    private func followUpColumn(
        title: String,
        status: FollowUpHandlingStatus,
        items: [FollowUp]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status == .completed ? BWTheme.ok
                          : status == .inProgress ? BWTheme.accent
                          : BWTheme.ink3.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                    .foregroundStyle(BWTheme.ink2)
                Text("\(items.count)")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(items) { followUp in
                    followUpCard(followUp)
                }
                if items.isEmpty {
                    Text("—")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(BWTheme.sunken.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func followUpCard(_ followUp: FollowUp) -> some View {
        let overdue = followUp.handlingStatus != .completed
            && (followUp.dueDate ?? .distantFuture) < Date()
        return VStack(alignment: .leading, spacing: 6) {
            Text(followUp.title)
                .font(.system(size: BWTheme.fontSizeLabel, weight: .medium))
                .foregroundStyle(BWTheme.ink)
                .strikethrough(followUp.handlingStatus == .completed)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                // 责任人/期限缺原话支持时标「待核对」，不臆造
                if let owner = ownerDisplayText(followUp) {
                    Text(owner)
                        .foregroundStyle(BWTheme.ink2)
                } else {
                    Text("责任人待核对")
                        .fontWeight(.semibold)
                        .foregroundStyle(BWTheme.warn)
                }
                if let due = followUp.dueDate {
                    Text(overdue
                         ? "\(due.formatted(date: .abbreviated, time: .omitted)) 到期 · 已逾期"
                         : due.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(overdue ? BWTheme.danger : BWTheme.ink2)
                        .fontWeight(overdue ? .semibold : .regular)
                } else {
                    Text("期限未定")
                        .foregroundStyle(BWTheme.ink3)
                }
            }
            .font(.system(size: BWTheme.fontSizeDetail))

            if followUp.handlingStatus == .completed {
                if let note = followUp.resultNote, !note.isEmpty {
                    Text("实际结果：\(note)")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("完成于 \(followUp.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-")")
                    .font(.system(size: 11))
                    .foregroundStyle(BWTheme.ink3)
            }

            if let source = followUp.source {
                let recording = projects.first { $0.id == source.recordingID }
                let sourceIsCurrent = recording.map {
                    BusinessMemoryCandidateBuilder.sourceIsCurrent(
                        project: $0, segmentID: source.segmentID, version: source.sourceVersion
                    )
                } ?? false
                if let recording {
                    Button {
                        router.showProjectWorkspace(
                            recording.id, autoStart: false, evidenceSegmentID: source.segmentID
                        )
                    } label: {
                        Text("来源 \(recording.title)")
                            .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                            .foregroundStyle(BWTheme.evidence)
                            .underline()
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(source.snippet)
                }
                if !sourceIsCurrent {
                    Text("来源需复核：录音、原话或人物归属已变化")
                        .font(.system(size: 11))
                        .foregroundStyle(BWTheme.warn)
                }
            } else {
                Text("来源：未记录可核验的原话证据")
                    .font(.system(size: 11))
                    .foregroundStyle(BWTheme.warn)
            }

            if followUp.handlingStatus != .completed {
                HStack(spacing: 8) {
                    if followUp.handlingStatus == .pending {
                        cardButton("开始跟进", primary: false) {
                            setHandling(followUp, .inProgress)
                        }
                    } else {
                        cardButton("恢复待跟进", primary: false) {
                            setHandling(followUp, .pending)
                        }
                    }
                    cardButton("填写结果并完成", primary: true) {
                        actionError = nil
                        completingFollowUpID = followUp.id
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(overdue ? BWTheme.danger : BWTheme.border, lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(overdue ? BWTheme.dangerBg.opacity(0.35) : .clear)
        )
        .opacity(followUp.handlingStatus == .completed ? 0.75 : 1)
    }

    private func cardButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: BWTheme.fontSizeDetail, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color.white : BWTheme.ink2)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                primary ? BWTheme.accentButton : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(primary ? .clear : BWTheme.border, lineWidth: 1)
            )
            .buttonStyle(.plain)
    }

    /// 责任人显示：关联人物被删除后回退到原文表述；两者皆无返回 nil（界面标待核对）
    private func ownerDisplayText(_ followUp: FollowUp) -> String? {
        if let personID = followUp.ownerPersonID,
           let person = persons.first(where: { $0.id == personID }) {
            return person.displayName
        }
        if let text = followUp.ownerDisplayText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }

    // MARK: - 关联录音

    private var recordingsSection: some View {
        sectionShell(
            title: "关联录音",
            note: nil,
            moreTitle: "关联",
            more: { isSelectingRecordings = true }
        ) {
            if linkedRecordings.isEmpty {
                Text("尚未关联录音；关联后问答与总结会带上本项目的记忆与背景。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
            }
            ForEach(linkedRecordings) { project in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title)
                            .font(.system(size: BWTheme.fontSizeBody, weight: .medium))
                            .foregroundStyle(BWTheme.ink)
                            .lineLimit(1)
                        Text("\(project.lastActivityAt.formatted(date: .abbreviated, time: .omitted)) · \(project.speakers.count) 位说话人")
                            .font(.system(size: BWTheme.fontSizeDetail))
                            .foregroundStyle(BWTheme.ink3)
                    }
                    Spacer(minLength: 8)
                    Button("打开") {
                        router.showProjectWorkspace(project.id, autoStart: false)
                    }
                    .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                    .foregroundStyle(BWTheme.evidence)
                    .underline()
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - 有效背景

    private var backgroundSection: some View {
        sectionShell(title: "有效背景", note: nil, moreTitle: nil, more: nil) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Spacer()
                    if let edited = editedBackground,
                       edited != (businessProject.backgroundContext ?? "") {
                        Button("保存背景") {
                            if updateFields({ $0.backgroundContext = edited }) {
                                editedBackground = nil
                            }
                        }
                        .controlSize(.mini)
                    }
                }
                TextEditor(
                    text: Binding(
                        get: { editedBackground ?? businessProject.backgroundContext ?? "" },
                        set: { editedBackground = $0 }
                    )
                )
                .font(.system(size: BWTheme.fontSizeBody))
                .foregroundStyle(BWTheme.ink)
                .frame(minHeight: 54)
                .scrollContentBackground(.hidden)
                .background(BWTheme.sunken.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Text("项目背景供 AI 作为已确认上下文使用，不冒充任何一场录音的原话。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
            }
        }
    }

    // MARK: - 区块容器

    private func sectionShell<Content: View>(
        title: String,
        note: String?,
        moreTitle: String?,
        more: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: BWTheme.fontSizeSectionTitle, weight: .semibold))
                    .foregroundStyle(BWTheme.ink)
                if let note {
                    Text(note)
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.ink3)
                }
                Spacer()
                if let moreTitle, let more {
                    Button(moreTitle, action: more)
                        .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                        .foregroundStyle(BWTheme.evidence)
                        .underline()
                        .buttonStyle(.plain)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(BWTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 操作

    @discardableResult
    private func updateFields(_ mutate: (inout BusinessProject) -> Void) -> Bool {
        do {
            guard var updated = try environment.businessProjectStore.load()
                .first(where: { $0.id == businessProject.id }) else {
                actionError = "业务项目已不存在，请刷新后重试。"
                return false
            }
            mutate(&updated)
            _ = try environment.businessProjectStore.update(updated)
            actionError = nil
            onChanged()
            return true
        } catch {
            actionError = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func setLinkedRecordings(_ projectIDs: [UUID]) -> String? {
        do {
            _ = try environment.businessProjectStore.setLinkedProjects(
                businessProjectID: businessProject.id,
                projectIDs: projectIDs
            )
            actionError = nil
            onChanged()
            return nil
        } catch {
            return "关联失败：\(error.localizedDescription)"
        }
    }

    private func setParticipants(_ personIDs: [UUID]) -> String? {
        do {
            _ = try environment.businessProjectStore.setParticipants(
                businessProjectID: businessProject.id,
                personIDs: personIDs
            )
            actionError = nil
            onChanged()
            return nil
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
    }

    private func setArchived(_ archived: Bool) {
        updateFields { project in
            project.status = archived ? .archived : .active
        }
    }

    private func setHandling(_ followUp: FollowUp, _ status: FollowUpHandlingStatus) {
        do {
            guard var updated = try environment.businessProjectStore.load()
                .first(where: { $0.id == businessProject.id }),
                let index = updated.followUps.firstIndex(where: { $0.id == followUp.id }) else {
                actionError = "跟进事项已不存在，请刷新后重试。"
                return
            }
            updated.followUps[index].handlingStatus = status
            updated.followUps[index].updatedAt = Date()
            _ = try environment.businessProjectStore.replaceFollowUps(
                businessProjectID: businessProject.id,
                followUps: updated.followUps
            )
            actionError = nil
            onChanged()
        } catch {
            actionError = "状态更新失败：\(error.localizedDescription)"
        }
    }

    private func completeFollowUp(id: UUID, note: String) -> Bool {
        do {
            guard var updated = try environment.businessProjectStore.load()
                .first(where: { $0.id == businessProject.id }),
                let index = updated.followUps.firstIndex(where: { $0.id == id }) else {
                actionError = "跟进事项已不存在，请刷新后重试。"
                return false
            }
            updated.followUps[index].handlingStatus = .completed
            updated.followUps[index].resultNote = note
            updated.followUps[index].completedAt = Date()
            updated.followUps[index].updatedAt = Date()
            _ = try environment.businessProjectStore.replaceFollowUps(
                businessProjectID: businessProject.id,
                followUps: updated.followUps
            )
            actionError = nil
            onChanged()
            return true
        } catch {
            actionError = "完成记录失败：\(error.localizedDescription)"
            return false
        }
    }
}

private struct FlowParticipantChips: View {
    let names: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                    HStack(spacing: 6) {
                        BWSpeakerDot(name: name, color: BWTheme.accent, size: 22)
                        Text(name)
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(BWTheme.accentSoft, in: Capsule())
                }
            }
        }
    }
}

private struct RecordingLinkPickerSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let businessProject: BusinessProject
    let projects: [Project]
    let onDone: ([UUID]) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("关联录音", systemImage: "link")
                .font(.headline)
            Text("业务项目只引用录音，不复制录音；删除录音会自动解除关联。")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(
                    projects
                        .filter { $0.sourceType != .combinedRecordings }
                        .sorted { $0.lastActivityAt > $1.lastActivityAt }
                ) { project in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.title).lineLimit(1)
                            Text(
                                project.lastActivityAt
                                    .formatted(date: .abbreviated, time: .omitted)
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let category = project.businessCategory {
                            Text(category)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(project.id)
                }
            }
            .listStyle(.plain)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存关联") {
                    saveError = onDone(Array(selection))
                    if saveError == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            selection = Set(businessProject.linkedProjectIDs)
        }
    }
}

private struct ParticipantPickerSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let businessProject: BusinessProject
    let persons: [Person]
    let onDone: ([UUID]) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("选择参与人物", systemImage: "person.2")
                .font(.headline)
            if persons.isEmpty {
                Text("人物库为空；先在人物库创建人物。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List(selection: $selection) {
                ForEach(persons) { person in
                    HStack {
                        Text(person.displayName)
                        if let role = person.role, !role.isEmpty {
                            Text(role)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Set(person.speakerLinks.map(\.projectID)).count) 场录音")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(person.id)
                }
            }
            .listStyle(.plain)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    saveError = onDone(Array(selection))
                    if saveError == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            selection = Set(businessProject.participantPersonIDs)
        }
    }
}
