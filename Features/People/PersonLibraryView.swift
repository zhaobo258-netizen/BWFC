import SwiftUI

/// 独立人物库（产品文档 12 号 §5）。
/// 人物优先：无声纹也能建人；声纹与表达画像放次级管理区。
/// 旧「历史人物库（声纹档案）」保留为声音样本管理入口。
struct PersonLibraryPage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var persons: [Person] = []
    @State private var projects: [Project] = []
    @State private var selectedPersonID: UUID?
    @State private var errorMessage: String?
    @State private var isCreatingPerson = false
    @State private var isShowingVoiceManagement = false
    @State private var isSelectingMergeTarget = false

    private var selectedPerson: Person? {
        persons.first { $0.id == selectedPersonID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                personList
                    .frame(width: 260)
                Divider()
                Group {
                    if let selectedPerson {
                        PersonDetailPane(
                            person: selectedPerson,
                            projects: projects,
                            onChanged: reload
                        )
                        .id(selectedPerson.id)
                    } else {
                        ContentUnavailableView(
                            "选择或新建人物",
                            systemImage: "person.crop.circle",
                            description: Text("人物不需要声纹样本；从录音指认或手工关联后跨录音连续。")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(BWTheme.columnBackground.opacity(0.72))
        .sheet(isPresented: $isCreatingPerson) {
            PersonCreateSheet { name, role, background in
                createPerson(name: name, role: role, background: background)
            }
            .environment(environment)
        }
        .sheet(isPresented: $isShowingVoiceManagement, onDismiss: reload) {
            HistoricalPeopleLibraryPage()
                .environment(environment)
                .environment(router)
                .frame(minWidth: 860, minHeight: 560)
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
            Label("人物库", systemImage: "person.2")
                .font(.headline)
            Text("\(persons.count) 位人物")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if environment.personLibraryStore.canUndo {
                Button {
                    do {
                        try environment.undoPersonChange()
                        reload()
                    } catch {
                        errorMessage = "撤销失败：\(error.localizedDescription)"
                    }
                } label: {
                    Label("撤销上次人物操作", systemImage: "arrow.uturn.backward")
                }
                .help("撤销最近一次指认、合并、修改或删除")
            }
            Button {
                isShowingVoiceManagement = true
            } label: {
                Label("声音档案管理", systemImage: "waveform")
            }
            .help("声纹样本、自动带入与讯飞注册（可选能力）")
            Button {
                isCreatingPerson = true
            } label: {
                Label("新建人物", systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var personList: some View {
        List(selection: Binding(
            get: { selectedPersonID.map(OptionalSelection.person) },
            set: { selection in
                selectedPersonID = selection?.personID
            }
        )) {
            ForEach(persons) { person in
                PersonRow(person: person, projectCount: uniqueProjectCount(person))
                    .tag(OptionalSelection.person(person.id))
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

    private struct OptionalSelection: Hashable {
        let personID: UUID
        static func person(_ id: UUID) -> OptionalSelection {
            OptionalSelection(personID: id)
        }
    }

    private func uniqueProjectCount(_ person: Person) -> Int {
        Set(person.speakerLinks.map(\.projectID)).count
    }

    private func reload() {
        do {
            persons = try environment.personLibraryStore.load()
            projects = try environment.allProjects()
            if selectedPersonID == nil || !persons.contains(where: { $0.id == selectedPersonID }) {
                selectedPersonID = persons.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = "人物库读取失败：\(error.localizedDescription)"
        }
    }

    private func createPerson(name: String, role: String?, background: String?) -> String? {
        do {
            let person = try environment.personLibraryStore.createPerson(
                displayName: name,
                role: role,
                backgroundContext: background
            )
            reload()
            selectedPersonID = person.id
            return nil
        } catch {
            errorMessage = "新建人物失败：\(error.localizedDescription)"
            return errorMessage
        }
    }
}

private struct PersonRow: View {
    let person: Person
    let projectCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if person.isCurrentUser {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(BWTheme.accent)
                }
                Text(person.displayName)
                    .fontWeight(.medium)
                if person.linkedVoiceProfileID == nil {
                    Text("无声纹")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }
            HStack(spacing: 8) {
                Text("\(projectCount) 场录音")
                let active = person.activeMemories.count
                let review = person.memoryEntries.filter { $0.status == .needsReview }.count
                if active > 0 { Text("\(active) 条有效记忆") }
                if review > 0 {
                    Text("\(review) 条待复核")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 新建人物（无需声纹）
private struct PersonCreateSheet: View {
    @Environment(AppEnvironment.self) private var environment
    var initialPerson: Person? = nil
    let onCreate: (String, String?, String?) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var background = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(initialPerson == nil ? "新建人物" : "编辑人物资料", systemImage: "person.badge.plus")
                .font(.headline)
            TextField("姓名（只是显示名，可随时修改）", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("职务或角色（可空）", text: $role)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("人工背景（可空；老板确认的长期背景，不是录音原话）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $background)
                    .font(.callout)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("不需要声音样本；之后可从任意录音把说话人关联到这位人物。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(initialPerson == nil ? "创建" : "保存") {
                    saveError = onCreate(name, role, background)
                    if saveError == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            name = initialPerson?.displayName ?? ""
            role = initialPerson?.role ?? ""
            background = initialPerson?.backgroundContext ?? ""
        }
    }
}

/// 人物详情（12 号 §5.4：姓名与人工背景在上，交往、确认事项、待确认依次展示，
/// 表达观察与声音样本在次级区域）。
struct PersonDetailPane: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    let person: Person
    let projects: [Project]
    let onChanged: () -> Void

    @State private var editedBackground: String?
    @State private var isSelectingSpeaker = false
    @State private var isSelectingMergeTarget = false
    @State private var actionError: String?
    @State private var isAddingMemory = false
    @State private var isEditingIdentity = false
    @State private var newMemoryText = ""
    @State private var supersededMemoryID: UUID?

    private var projectTitles: [UUID: String] {
        Dictionary(projects.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                identitySection
                memorySection
                engagementSection
                voiceSection
                dangerSection
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isEditingIdentity) {
            PersonCreateSheet(initialPerson: person) { name, role, background in
                do {
                    try environment.updateLibraryPersonMetadata(
                        personID: person.id, displayName: name, role: role, backgroundContext: background
                    )
                    editedBackground = nil
                    onChanged()
                    return nil
                } catch {
                    return "人物资料未保存：\(error.localizedDescription)"
                }
            }
            .environment(environment)
        }
        .sheet(isPresented: $isSelectingSpeaker) {
            SpeakerLinkPickerSheet(
                personsLibraryExcludedPersonID: person.id,
                projects: projects,
                existingLinks: person.speakerLinks
            ) { projectID, speakerID, speakerName in
                linkSpeaker(projectID: projectID, speakerID: speakerID, name: speakerName)
            }
            .environment(environment)
            .frame(minWidth: 520, minHeight: 440)
        }
        .sheet(isPresented: $isSelectingMergeTarget) {
            PersonMergeSheet(
                keepingPerson: person,
                allPersons: ((try? environment.personLibraryStore.load()) ?? [])
                    .filter { $0.id != person.id }
            ) { absorbingID, keepBackgroundFromAbsorbing, keepVoiceFromAbsorbing in
                mergePersons(
                    absorbingID: absorbingID,
                    keepBackground: keepBackgroundFromAbsorbing,
                    keepVoice: keepVoiceFromAbsorbing
                )
            }
            .environment(environment)
            .frame(minWidth: 520, minHeight: 380)
        }
        .alert("添加人工记忆", isPresented: $isAddingMemory) {
            TextField("填写已确认的背景或偏好", text: $newMemoryText)
            Button("取消", role: .cancel) { supersededMemoryID = nil }
            Button("保存") { addManualMemory() }
                .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("保存后作为人工背景使用，不作为录音原话。")
        }
    }

    // MARK: - 身份与人工背景

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(person.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                if person.isCurrentUser {
                    Label("这是我", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(BWTheme.accent)
                }
                Spacer()
                Button("编辑资料") { isEditingIdentity = true }
                Toggle("这是我", isOn: Binding(
                    get: { person.isCurrentUser },
                    set: { newValue in setCurrentUser(newValue) }
                ))
                .toggleStyle(.checkbox)
                .disabled(person.isCurrentUser)
            }
            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("人工背景")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    if let edited = editedBackground, edited != (person.backgroundContext ?? "") {
                        Button("保存背景") { saveBackground(edited) }
                            .controlSize(.mini)
                    }
                }
                TextEditor(
                    text: Binding(
                        get: { editedBackground ?? person.backgroundContext ?? "" },
                        set: { editedBackground = $0 }
                    )
                )
                .font(.callout)
                .frame(minHeight: 64)
                .scrollContentBackground(.hidden)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Text("人工背景是老板确认的长期信息，不冒充任何一场录音的原话。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 记忆

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("业务记忆", systemImage: "brain.head.profile")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("有效 \(person.activeMemories.count) · 待复核 \(person.memoryEntries.filter { $0.status == .needsReview }.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if person.memoryEntries.isEmpty {
                Text("暂无记忆。录音结束后确认候选，或在此手工添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(person.memoryEntries.sorted { $0.createdAt > $1.createdAt }) { entry in
                memoryRow(entry)
            }
            Button {
                newMemoryText = ""
                supersededMemoryID = nil
                isAddingMemory = true
            } label: {
                Label("手工添加记忆", systemImage: "plus")
            }
            .controlSize(.mini)
        }
    }

    private func memoryRow(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.kind.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        entry.status == .needsReview
                            ? Color.orange.opacity(0.16)
                            : BWTheme.accent.opacity(0.14),
                        in: Capsule()
                    )
                Text(entry.status.displayName)
                    .font(.caption2)
                    .foregroundStyle(
                        entry.status == .active ? BWTheme.accent : .secondary
                    )
                Spacer()
                if entry.status == .active {
                    Button("忘记这条") { forgetMemory(entry) }
                        .controlSize(.mini)
                } else if entry.status == .needsReview {
                    Button("重新确认有效") { reactivateMemory(entry) }
                        .controlSize(.mini)
                    Button("另存为人工背景") {
                        newMemoryText = entry.content
                        supersededMemoryID = entry.id
                        isAddingMemory = true
                    }
                    .controlSize(.mini)
                } else if entry.status == .rejected {
                    Button("恢复使用") { reactivateMemory(entry) }
                        .controlSize(.mini)
                }
            }
            Text(entry.content).font(.callout)
            Text("作用域：\(entry.scope.displayText)")
                .font(.caption2).foregroundStyle(.secondary)
            if let reason = entry.reviewReason, entry.status == .needsReview {
                Text("需复核原因：\(reason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let source = entry.source {
                Text("来源：\(projectTitles[source.recordingID] ?? "已删除录音") · 更新 \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if projectTitles[source.recordingID] != nil {
                    Button("查看来源原话") {
                        router.showProjectWorkspace(source.recordingID, autoStart: false, evidenceSegmentID: source.segmentID)
                    }
                    .controlSize(.mini)
                }
            } else {
                Text(entry.isManuallyAuthored ? "来源：人工添加" : "来源：无（待确认）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 交往

    private var engagementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("最近交往", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    isSelectingSpeaker = true
                } label: {
                    Label("关联录音说话人", systemImage: "link")
                }
                .controlSize(.mini)
                .help("把某场录音里的说话人槽位手工关联到这位人物（跨录音认人的手工方式）")
            }
            if person.speakerLinks.isEmpty {
                Text("尚无关联录音。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(person.speakerLinks.sorted { $0.linkedAt > $1.linkedAt }) { link in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(projectTitles[link.projectID] ?? "未知录音")
                            .font(.callout)
                        Text("说话人：\(link.speakerDisplayName) · 关联于 \(link.linkedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开录音") {
                        router.showProjectWorkspace(link.projectID, autoStart: false)
                    }
                    .controlSize(.mini)
                    Button("解除关联") {
                        unlinkSpeaker(link)
                    }
                    .controlSize(.mini)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - 声音样本（次级区域）

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("声音样本（可选）", systemImage: "waveform")
                .font(.subheadline)
                .fontWeight(.semibold)
            if let profileID = person.linkedVoiceProfileID {
                let profile = ((try? environment.speakerVoiceProfileStore.loadForManagement()) ?? [])
                    .first { $0.id == profileID }
                if let profile {
                    HStack(spacing: 8) {
                        Text("已挂接声纹：\(profile.sampleDurationMs / 1000) 秒样本")
                            .font(.caption)
                        if profile.isAutoEnabled {
                            Text("自动带入新录音")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(BWTheme.accent.opacity(0.12), in: Capsule())
                        }
                        if let featureID = profile.iflytekFeatureID {
                            Text("讯飞已注册")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.14), in: Capsule())
                                .help("讯飞 feature ID：\(featureID)")
                        }
                        Spacer()
                    }
                } else {
                    Text("声纹档案记录缺失（样本可能已损坏）；人物不受影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("这位人物没有声音样本；不影响建人、关联录音与业务记忆。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("试听、录制、讯飞注册等声音管理在「声音档案管理」中完成。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 合并与删除

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("合并与删除", systemImage: "square.stack.3d.up")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    isSelectingMergeTarget = true
                } label: {
                    Label("合并另一位人物", systemImage: "arrow.triangle.merge")
                }
                .controlSize(.mini)
                .disabled(((try? environment.personLibraryStore.load()) ?? []).count < 2)
                Button("删除人物", role: .destructive) {
                    deletePerson()
                }
                .controlSize(.mini)
            }
            Text("同名不自动合并；合并前会展示关联录音、背景冲突与样本来源。删除人物仅解除关联，声音样本在声音档案管理中另行处理。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 操作

    private func setCurrentUser(_ value: Bool) {
        do {
            try environment.setCurrentPerson(personID: value ? person.id : nil)
            onChanged()
        } catch { actionError = "设置失败：\(error.localizedDescription)" }
    }

    private func saveBackground(_ text: String) {
        do {
            try environment.updateLibraryPersonMetadata(
                personID: person.id, displayName: person.displayName,
                role: person.role, backgroundContext: text
            )
            editedBackground = nil
            onChanged()
        } catch { actionError = "背景保存失败：\(error.localizedDescription)" }
    }

    private func linkSpeaker(projectID: UUID, speakerID: UUID, name: String) {
        do {
            try environment.linkPerson(personID: person.id, projectID: projectID, speakerID: speakerID)
            onChanged()
        } catch { actionError = "关联失败：\(error.localizedDescription)" }
    }

    private func unlinkSpeaker(_ link: PersonSpeakerLink) {
        do {
            try environment.linkPerson(personID: nil, projectID: link.projectID, speakerID: link.speakerID)
            onChanged()
        } catch { actionError = "解除失败：\(error.localizedDescription)" }
    }

    private func addManualMemory() {
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            guard !environment.isPersistentStorageUnavailable else { throw ProjectWriteError.storageUnavailable }
            guard var current = try environment.personLibraryStore.person(id: person.id) else {
                throw PersonLibraryStoreError.personNotFound
            }
            let entry = MemoryEntry(
                content: text, kind: .manualBackground,
                scope: MemoryScope(personID: person.id, businessProjectID: nil, displayText: "人物（\(person.displayName)）"),
                isManuallyAuthored: true, status: .active, confirmedAt: Date(), effectiveFrom: Date(),
                supersedesEntryID: supersededMemoryID
            )
            if let oldID = supersededMemoryID,
               let index = current.memoryEntries.firstIndex(where: { $0.id == oldID }) {
                current.memoryEntries[index].status = .superseded
            }
            current.memoryEntries.append(entry)
            _ = try environment.personLibraryStore.replaceMemoryEntries(personID: person.id, entries: current.memoryEntries)
            supersededMemoryID = nil
            onChanged()
        } catch { actionError = "记忆添加失败：\(error.localizedDescription)" }
    }

    private func forgetMemory(_ entry: MemoryEntry) {
        do {
            guard !environment.isPersistentStorageUnavailable else { throw ProjectWriteError.storageUnavailable }
            guard var current = try environment.personLibraryStore.person(id: person.id),
                  let index = current.memoryEntries.firstIndex(where: { $0.id == entry.id }) else {
                throw PersonLibraryStoreError.personNotFound
            }
            current.memoryEntries[index].status = .rejected
            current.memoryEntries[index].updatedAt = Date()
            _ = try environment.personLibraryStore.replaceMemoryEntries(personID: person.id, entries: current.memoryEntries)
            onChanged()
        } catch { actionError = "记忆更新失败：\(error.localizedDescription)" }
    }

    private func reactivateMemory(_ entry: MemoryEntry) {
        do {
            guard !environment.isPersistentStorageUnavailable else { throw ProjectWriteError.storageUnavailable }
            guard var current = try environment.personLibraryStore.person(id: person.id),
                  let index = current.memoryEntries.firstIndex(where: { $0.id == entry.id }) else {
                throw PersonLibraryStoreError.personNotFound
            }
            if let source = current.memoryEntries[index].source {
                guard let project = try environment.allProjects().first(where: { $0.id == source.recordingID }),
                      BusinessMemoryCandidateBuilder.sourceIsCurrent(
                        project: project, segmentID: source.segmentID,
                        version: source.sourceVersion, personID: person.id
                      ) else {
                    actionError = "来源已变化或不可用；请先查看原话，或另存为人工背景。"
                    return
                }
            }
            current.memoryEntries[index].status = .active
            current.memoryEntries[index].reviewReason = nil
            current.memoryEntries[index].confirmedAt = Date()
            current.memoryEntries[index].updatedAt = Date()
            _ = try environment.personLibraryStore.replaceMemoryEntries(personID: person.id, entries: current.memoryEntries)
            onChanged()
        } catch { actionError = "记忆更新失败：\(error.localizedDescription)" }
    }

    private func mergePersons(absorbingID: UUID, keepBackground: Bool, keepVoice: Bool) {
        do {
            try environment.mergePeople(
                keepingID: person.id, absorbingID: absorbingID,
                keepBackground: keepBackground, keepVoice: keepVoice
            )
            onChanged()
        } catch { actionError = "合并失败：\(error.localizedDescription)" }
    }

    private func deletePerson() {
        do {
            try environment.deleteLibraryPerson(personID: person.id)
            onChanged()
        } catch { actionError = "删除失败：\(error.localizedDescription)" }
    }

}

/// 从录音说话人手工关联人物（阶段 B 验收：两场录音可手工关联同一个人）
struct SpeakerLinkPickerSheet: View {
    let personsLibraryExcludedPersonID: UUID?
    let projects: [Project]
    let existingLinks: [PersonSpeakerLink]
    let onLink: (UUID, UUID, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProjectID: UUID?
    @State private var selectedSpeakerID: UUID?

    private var candidateProjects: [Project] {
        projects.filter { project in
            project.sourceType != .combinedRecordings && !project.speakers.isEmpty
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var selectedProject: Project? {
        candidateProjects.first { $0.id == selectedProjectID }
    }

    private var isAlreadyLinked: Bool {
        guard let selectedProjectID, let selectedSpeakerID else { return false }
        return existingLinks.contains {
            $0.projectID == selectedProjectID && $0.speakerID == selectedSpeakerID
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("关联录音说话人", systemImage: "link")
                .font(.headline)
            Text("选择一场录音和其中一个说话人槽位，把它关联到当前人物。误关联可在人物库撤销。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("录音").font(.caption).foregroundStyle(.secondary)
                    List(selection: $selectedProjectID) {
                        ForEach(candidateProjects) { project in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.title).lineLimit(1)
                                Text(project.lastActivityAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(project.id as UUID?)
                        }
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 260)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("本场说话人").font(.caption).foregroundStyle(.secondary)
                    if let project = selectedProject {
                        List(selection: $selectedSpeakerID) {
                            ForEach(project.speakers) { speaker in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(speaker.displayName)
                                        if speaker.personId != nil {
                                            Text("已关联")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if let role = speaker.role, !role.isEmpty {
                                        Text(role)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(speaker.id as UUID?)
                            }
                        }
                        .listStyle(.plain)
                        .frame(maxHeight: 260)
                    } else {
                        ContentUnavailableView(
                            "先选择录音",
                            systemImage: "waveform"
                        )
                        .frame(maxHeight: 260)
                    }
                }
            }
            HStack {
                if isAlreadyLinked {
                    Text("该说话人已在当前人物名下（或已关联其他人物，将自动改指当前人物）。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("关联") {
                    if let projectID = selectedProjectID,
                       let speakerID = selectedSpeakerID,
                       let speaker = selectedProject?.speakers
                        .first(where: { $0.id == speakerID }) {
                        onLink(projectID, speakerID, speaker.displayName)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedProjectID == nil || selectedSpeakerID == nil)
            }
        }
        .padding(16)
        .onAppear {
            selectedProjectID = candidateProjects.first?.id
        }
    }
}

/// 合并人物（先展示预览：关联录音、背景冲突、样本来源）
struct PersonMergeSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let keepingPerson: Person
    let allPersons: [Person]
    let onMerge: (UUID, Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var absorbingID: UUID?
    @State private var keepBackgroundFromAbsorbing = false
    @State private var keepVoiceFromAbsorbing = false
    @State private var preview: PersonLibraryStore.MergePlan?

    private var absorbingPerson: Person? {
        allPersons.first { $0.id == absorbingID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("合并人物", systemImage: "arrow.triangle.merge")
                .font(.headline)
            Picker("并入的人物（将被删除）", selection: $absorbingID) {
                Text("请选择…").tag(UUID?.none)
                ForEach(allPersons) { person in
                    Text("\(person.displayName)（\(person.speakerLinks.count) 条关联）")
                        .tag(person.id as UUID?)
                }
            }
            if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    mergeRow("合并后关联录音", "\(preview.combinedRecordingCount) 场")
                    mergeRow("合并后记忆", "\(preview.combinedMemoryCount) 条")
                    mergeRow(
                        "人工背景",
                        preview.backgroundConflict
                            ? "两侧都有背景，需选择保留哪一侧"
                            : "保留非空一侧"
                    )
                    mergeRow(
                        "声音样本",
                        preview.voiceProfileConflict
                            ? "两侧都有声纹，需选择保留哪一侧"
                            : "保留已有样本"
                    )
                }
                .padding(10)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                if preview.backgroundConflict {
                    Picker("保留人工背景", selection: $keepBackgroundFromAbsorbing) {
                        Text("保留「\(preview.keepingPerson.displayName)」的背景").tag(false)
                        Text("保留「\(preview.absorbingPerson.displayName)」的背景").tag(true)
                    }
                }
                if preview.voiceProfileConflict {
                    Picker("保留声音样本", selection: $keepVoiceFromAbsorbing) {
                        Text("保留「\(preview.keepingPerson.displayName)」的样本").tag(false)
                        Text("保留「\(preview.absorbingPerson.displayName)」的样本").tag(true)
                    }
                }
            }
            Text("合并后可在人物库「撤销上次人物操作」恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("合并") {
                    if let absorbingID {
                        onMerge(absorbingID, keepBackgroundFromAbsorbing, keepVoiceFromAbsorbing)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(absorbingID == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 520)
        .onChange(of: absorbingID) { _, newValue in
            guard let newValue else {
                preview = nil
                return
            }
            preview = try? environment.personLibraryStore.mergePreview(
                keepingID: keepingPerson.id,
                absorbingID: newValue
            )
        }
    }

    private func mergeRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }
}
