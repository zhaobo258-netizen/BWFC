import SwiftUI

/// 轻 CRM 业务项目页（产品文档 12 号 §7）。
/// 回答“要达成什么、当前依据是什么、下一步由谁确认”；
/// 跟进闭环：候选（在工作台确认）→ 待跟进 → 进行中 → 已完成（记录实际结果）。
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
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                listPane
                    .frame(width: 280)
                Divider()
                Group {
                    if let selected {
                        BusinessProjectDetailPane(
                            businessProject: selected,
                            projects: projects,
                            onChanged: reload
                        )
                        .id(selected.id)
                    } else {
                        ContentUnavailableView(
                            "选择或新建业务项目",
                            systemImage: "briefcase",
                            description: Text("业务项目把人物、录音与已确认跟进连起来；先建一个真实业务闭环。")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(BWTheme.columnBackground.opacity(0.72))
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

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                router.showProjectHome()
            } label: {
                Label("返回", systemImage: "chevron.left")
            }
            Label("业务项目", systemImage: "briefcase")
                .font(.headline)
            Text("\(businessProjects.count) 个项目")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !BusinessProjectStore.groupingSuggestions(
                recordings: projects,
                existingBusinessProjects: businessProjects
            ).isEmpty {
                Button {
                    isShowingSuggestions = true
                } label: {
                    Label("从业务分类归组建议", systemImage: "square.grid.2x2")
                }
                .help("把已有录音的业务分类整理成业务项目（仅建议，不自动认定同一项目）")
            }
            Button {
                isCreating = true
            } label: {
                Label("新建业务项目", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var listPane: some View {
        List(selection: $selectedID) {
            ForEach(businessProjects) { businessProject in
                BusinessProjectRow(businessProject: businessProject)
                    .tag(businessProject.id as UUID?)
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(6)
                    .background(.regularMaterial)
                    .padding(6)
            }
        }
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

private struct BusinessProjectRow: View {
    let businessProject: BusinessProject

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(businessProject.name)
                    .fontWeight(.medium)
                if businessProject.status == .archived {
                    Text("已归档")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text("\(businessProject.linkedProjectIDs.count) 场录音")
                let open = businessProject.openFollowUps.count
                let overdue = businessProject.overdueFollowUps.count
                if open > 0 {
                    Text("\(open) 项跟进中")
                        .foregroundStyle(overdue > 0 ? .orange : BWTheme.accent)
                }
                if overdue > 0 {
                    Text("\(overdue) 项逾期")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(businessProject.lastActivityAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
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

/// 业务项目详情：目标、参与人物、关联录音、跟进闭环。
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
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                followUpSection
                recordingsSection
                participantsSection
                backgroundSection
                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(businessProject.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Toggle("归档", isOn: Binding(
                    get: { businessProject.status == .archived },
                    set: { newValue in setArchived(newValue) }
                ))
                .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("目标说明")
                        .font(.subheadline)
                        .fontWeight(.semibold)
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
                .font(.callout)
                .frame(minHeight: 54)
                .scrollContentBackground(.hidden)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("跟进事项", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("待跟进 \(businessProject.followUps.filter { $0.handlingStatus == .pending }.count) · 进行中 \(businessProject.followUps.filter { $0.handlingStatus == .inProgress }.count) · 已完成 \(businessProject.followUps.filter { $0.handlingStatus == .completed }.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if businessProject.followUps.isEmpty {
                Text("暂无跟进。录音结束后的跟进候选可在工作台确认到这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(businessProject.followUps.sorted {
                ($0.completedAt ?? .distantFuture) < ($1.completedAt ?? .distantFuture)
            }) { followUp in
                followUpRow(followUp)
            }
        }
    }

    private func followUpRow(_ followUp: FollowUp) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        followUp.handlingStatus == .completed
                            ? Color.green
                            : followUp.handlingStatus == .inProgress
                                ? BWTheme.accent
                                : Color.secondary.opacity(0.4)
                    )
                    .frame(width: 7, height: 7)
                Text(followUp.title)
                    .font(.callout)
                    .strikethrough(followUp.handlingStatus == .completed)
                Spacer()
                if followUp.confirmationStatus == .candidate {
                    Text("候选")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Text("责任人：\(ownerName(followUp))")
                Text("期限：\(followUp.dueDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "未定")")
                if followUp.handlingStatus != .completed,
                   let due = followUp.dueDate, due < Date() {
                    Text("已逾期")
                        .foregroundStyle(.orange)
                }
                Text(followUp.handlingStatus.displayName)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if followUp.handlingStatus == .completed {
                if let note = followUp.resultNote {
                    Text("结果：\(note)")
                        .font(.caption)
                }
                Text("完成于 \(followUp.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let source = followUp.source {
                let recording = projects.first { $0.id == source.recordingID }
                let sourceIsCurrent = recording.map {
                    BusinessMemoryCandidateBuilder.sourceIsCurrent(
                        project: $0, segmentID: source.segmentID, version: source.sourceVersion
                    )
                } ?? false
                Text(sourceIsCurrent ? "来源：原话证据" : "来源需复核：录音、原话或人物归属已变化")
                    .font(.caption2)
                    .foregroundStyle(sourceIsCurrent ? Color.secondary : .orange)
                Text(source.snippet)
                    .font(.caption)
                    .textSelection(.enabled)
                if let recording {
                    Button("打开来源录音：\(recording.title)") {
                        router.showProjectWorkspace(
                            recording.id, autoStart: false, evidenceSegmentID: source.segmentID
                        )
                    }
                    .controlSize(.mini)
                }
            } else {
                Text("来源：未记录可核验的原话证据")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if followUp.handlingStatus != .completed {
                HStack(spacing: 8) {
                    if followUp.handlingStatus == .pending {
                        Button("开始跟进") { setHandling(followUp, .inProgress) }
                            .controlSize(.mini)
                    } else {
                        Button("恢复待跟进") { setHandling(followUp, .pending) }
                            .controlSize(.mini)
                    }
                    Button("完成（记录结果）") {
                        actionError = nil
                        completingFollowUpID = followUp.id
                    }
                    .controlSize(.mini)
                    Spacer()
                }
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func ownerName(_ followUp: FollowUp) -> String {
        if let personID = followUp.ownerPersonID,
           let person = persons.first(where: { $0.id == personID }) {
            return person.displayName
        }
        return followUp.ownerDisplayText ?? "未明确"
    }

    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("关联录音", systemImage: "waveform")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    isSelectingRecordings = true
                } label: {
                    Label("关联录音", systemImage: "link")
                }
                .controlSize(.mini)
            }
            if linkedRecordings.isEmpty {
                Text("尚未关联录音；关联后问答与总结会带上本项目的记忆与背景。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(linkedRecordings) { project in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title)
                            .font(.callout)
                        Text("\(project.lastActivityAt.formatted(date: .abbreviated, time: .omitted)) · \(project.speakers.count) 位说话人")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开") {
                        router.showProjectWorkspace(project.id, autoStart: false)
                    }
                    .controlSize(.mini)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("参与人物", systemImage: "person.2")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    isSelectingParticipants = true
                } label: {
                    Label("选择人物", systemImage: "person.badge.plus")
                }
                .controlSize(.mini)
            }
            if businessProject.participantPersonIDs.isEmpty {
                Text("尚未选择参与人物。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowParticipantChips(
                    names: businessProject.participantPersonIDs.compactMap { id in
                        persons.first { $0.id == id }?.displayName
                    }
                )
            }
        }
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("有效背景")
                    .font(.subheadline)
                    .fontWeight(.semibold)
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
            .font(.callout)
            .frame(minHeight: 54)
            .scrollContentBackground(.hidden)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Text("项目背景供 AI 作为已确认上下文使用，不冒充任何一场录音的原话。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
                    Text(name)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(BWTheme.accent.opacity(0.12), in: Capsule())
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
