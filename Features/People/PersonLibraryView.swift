import SwiftUI

/// 独立人物库（界面设计定稿 v1.0）：左列表（搜索/新建/人物行）+ 右详情
/// （身份与操作、声音档案、背景与画像、关联录音、待确认事项、合并与删除）。
/// 人物优先：无声纹也能建人；声纹与表达画像放次级区域；候选身份不得伪装成人工确认。
struct PersonLibraryPage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var persons: [Person] = []
    @State private var projects: [Project] = []
    @State private var selectedPersonID: UUID?
    @State private var errorMessage: String?
    @State private var isCreatingPerson = false
    @State private var isShowingVoiceManagement = false
    @State private var search = ""

    private var selectedPerson: Person? {
        persons.first { $0.id == selectedPersonID }
    }

    private var visiblePersons: [Person] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return persons }
        return persons.filter {
            $0.displayName.localizedStandardContains(query)
                || ($0.role?.localizedStandardContains(query) ?? false)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 280)
            Rectangle().fill(BWTheme.border).frame(width: 1)
            Group {
                if let selectedPerson {
                    PersonDetailPane(
                        person: selectedPerson,
                        projects: projects,
                        onChanged: reload,
                        onOpenVoiceManagement: { isShowingVoiceManagement = true }
                    )
                    .id(selectedPerson.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(BWTheme.ink3)
                        Text("选择或新建人物")
                            .font(.system(size: BWTheme.fontSizeBody, weight: .medium))
                            .foregroundStyle(BWTheme.ink2)
                        Text("人物不需要声纹样本；从录音指认或手工关联后跨录音连续。")
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink3)
                            .multilineTextAlignment(.center)
                        Button("＋ 新建人物") { isCreatingPerson = true }
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

    // MARK: - 左列：列表

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("人物库")
                    .font(.system(size: BWTheme.fontSizeSectionTitle, weight: .semibold))
                    .foregroundStyle(BWTheme.ink)
                Spacer()
                Button {
                    isCreatingPerson = true
                } label: {
                    Text("＋ 新建人物")
                        .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: BWTheme.minimumHitHeight)
                        .background(BWTheme.accentButton, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("新建人物：不需要声纹，名字也不是主键")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(BWTheme.ink3)
                TextField("搜索人物…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: BWTheme.fontSizeLabel))
                    .foregroundStyle(BWTheme.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9).strokeBorder(BWTheme.border, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visiblePersons) { person in
                        PersonRow(
                            person: person,
                            projectCount: uniqueProjectCount(person),
                            isSelected: person.id == selectedPersonID
                        ) {
                            selectedPersonID = person.id
                        }
                    }
                    if visiblePersons.isEmpty {
                        Text(search.isEmpty
                             ? "还没有人物。点右上角「新建人物」开始。"
                             : "没有匹配的人物。")
                            .font(.system(size: BWTheme.fontSizeDetail))
                            .foregroundStyle(BWTheme.ink3)
                            .padding(.vertical, 28)
                    }
                }
                .padding(.horizontal, 10)
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

/// 人物行：头像点 + 姓名（我）+ 角色 + 声纹/无声纹标签 + 录音场数
private struct PersonRow: View {
    let person: Person
    let projectCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                BWSpeakerDot(
                    name: person.displayName,
                    color: person.isCurrentUser ? BWTheme.evidence : BWTheme.accent,
                    size: 32
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(person.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(BWTheme.ink)
                            .lineLimit(1)
                        if person.isCurrentUser {
                            Text("我")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(BWTheme.evidence, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(person.role ?? "\(projectCount) 场录音")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(person.linkedVoiceProfileID != nil ? "声纹" : "无声纹")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(person.linkedVoiceProfileID != nil ? BWTheme.ok : BWTheme.ink3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        person.linkedVoiceProfileID != nil
                            ? BWTheme.okBg : BWTheme.sunken,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                isSelected ? BWTheme.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("人物 \(person.displayName)")
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

/// 人物详情（定稿版）：
/// 身份头（含设为我/编辑/合并/撤销/删除）→ 声音档案 → 背景与画像 → 关联录音 → 待确认事项。
/// 业务记忆管理保留在「背景与画像」区内；合并与删除移入身份头操作。
struct PersonDetailPane: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    let person: Person
    let projects: [Project]
    let onChanged: () -> Void
    /// 打开声音档案管理（由列表页持有的 sheet 入口）
    var onOpenVoiceManagement: () -> Void = {}

    @State private var editedBackground: String?
    @State private var isSelectingSpeaker = false
    @State private var isSelectingMergeTarget = false
    @State private var actionError: String?
    @State private var isAddingMemory = false
    @State private var isEditingIdentity = false
    @State private var isConfirmingDelete = false
    @State private var newMemoryText = ""
    @State private var supersededMemoryID: UUID?

    private var projectTitles: [UUID: String] {
        Dictionary(projects.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// 待确认身份候选：录音中已关联到本人物、但归属尚未人工确认的说话人槽位
    private var pendingIdentityLinks: [(project: Project, speaker: Speaker)] {
        projects.flatMap { project in
            project.speakers
                .filter { $0.personId == person.id && !$0.isUserConfirmed }
                .map { (project: project, speaker: $0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identityHeader
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.danger)
                }
                voiceSection
                backgroundSection
                recordingsSection
                pendingSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(BWTheme.canvas)
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
        .confirmationDialog(
            "删除「\(person.displayName)」？",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除人物", role: .destructive) { deletePerson() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅解除人物与录音的关联；已确认的原话归属记录不受影响，声音样本在声音档案管理中另行处理。可在人物库页用「撤销」恢复最近一次操作。")
        }
    }

    // MARK: - 身份头

    private var identityHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            BWSpeakerDot(
                name: person.displayName,
                color: person.isCurrentUser ? BWTheme.evidence : BWTheme.accent,
                size: 44
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(person.displayName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(BWTheme.ink)
                    if person.isCurrentUser {
                        Text("我")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(BWTheme.evidence, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Text([
                    person.role,
                    "关联 \(Set(person.speakerLinks.map(\.projectID)).count) 场录音"
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: BWTheme.fontSizeLabel))
                    .foregroundStyle(BWTheme.ink2)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    if !person.isCurrentUser {
                        headerButton("设为我") { setCurrentUser(true) }
                    }
                    headerButton("编辑资料") { isEditingIdentity = true }
                    headerButton("合并…") { isSelectingMergeTarget = true }
                        .disabled(((try? environment.personLibraryStore.load()) ?? []).count < 2)
                }
                HStack(spacing: 8) {
                    if environment.personLibraryStore.canUndo {
                        headerButton("撤销上次人物操作") {
                            do {
                                try environment.undoPersonChange()
                                onChanged()
                            } catch {
                                actionError = "撤销失败：\(error.localizedDescription)"
                            }
                        }
                    }
                    headerButton("删除", tint: BWTheme.danger) { isConfirmingDelete = true }
                }
            }
        }
    }

    private func headerButton(
        _ title: String,
        tint: Color = BWTheme.ink2,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: BWTheme.minimumHitHeight)
            .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(BWTheme.border, lineWidth: 1)
            )
            .buttonStyle(.plain)
    }

    // MARK: - 声音档案

    private var voiceSection: some View {
        sectionCard(
            title: "声音档案",
            moreTitle: "管理样本",
            more: { onOpenVoiceManagement() }
        ) {
            if let profileID = person.linkedVoiceProfileID {
                let profile = ((try? environment.speakerVoiceProfileStore.loadForManagement()) ?? [])
                    .first { $0.id == profileID }
                if let profile {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .foregroundStyle(BWTheme.evidence)
                        Text("样本 · \(profile.sampleDurationMs / 1_000) 秒")
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink)
                        Text("有效")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BWTheme.ok)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(BWTheme.okBg, in: RoundedRectangle(cornerRadius: 5))
                        if profile.isAutoEnabled {
                            Text("自动带入新录音")
                                .font(.system(size: 11))
                                .foregroundStyle(BWTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(BWTheme.accentSoft, in: RoundedRectangle(cornerRadius: 5))
                        }
                        if profile.iflytekFeatureID != nil {
                            Text("讯飞已注册")
                                .font(.system(size: 11))
                                .foregroundStyle(BWTheme.ok)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(BWTheme.okBg, in: RoundedRectangle(cornerRadius: 5))
                        }
                        Spacer()
                    }
                } else {
                    Text("声纹档案记录缺失（样本可能已损坏）；人物不受影响。")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.ink2)
                }
            } else {
                Text("这位人物没有声音样本；不影响建人、关联录音与业务记忆。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink2)
            }
            Text("声纹是可选附件，不是人物本身。自动认人结果均需人工确认，相似度低时保持匿名。")
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(BWTheme.ink3)
        }
    }

    // MARK: - 背景与画像（含业务记忆管理）

    private var backgroundSection: some View {
        sectionCard(
            title: "背景与画像",
            moreTitle: "编辑资料",
            more: { isEditingIdentity = true }
        ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("人工背景")
                        .font(.system(size: BWTheme.fontSizeDetail, weight: .bold))
                        .foregroundStyle(BWTheme.ink2)
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
                .font(.system(size: BWTheme.fontSizeBody))
                .frame(minHeight: 64)
                .scrollContentBackground(.hidden)
                .background(BWTheme.sunken.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Text("人工背景是老板确认的长期信息，不冒充任何一场录音的原话。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
            }

            memoryBlock
        }
    }

    private var memoryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("业务记忆")
                    .font(.system(size: BWTheme.fontSizeDetail, weight: .bold))
                    .foregroundStyle(BWTheme.ink2)
                Text("有效 \(person.activeMemories.count) · 待复核 \(person.memoryEntries.filter { $0.status == .needsReview }.count)")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
                Spacer()
                Button {
                    newMemoryText = ""
                    supersededMemoryID = nil
                    isAddingMemory = true
                } label: {
                    Label("手工添加", systemImage: "plus")
                        .font(.system(size: BWTheme.fontSizeDetail))
                }
                .controlSize(.mini)
            }
            if person.memoryEntries.isEmpty {
                Text("暂无记忆。录音结束后确认候选，或手工添加。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
            }
            ForEach(person.memoryEntries.sorted { $0.createdAt > $1.createdAt }) { entry in
                memoryRow(entry)
            }
        }
    }

    private func memoryRow(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.kind.displayName)
                    .font(.system(size: 11))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        entry.status == .needsReview
                            ? BWTheme.warnBg
                            : BWTheme.accentSoft,
                        in: Capsule()
                    )
                    .foregroundStyle(entry.status == .needsReview ? BWTheme.warn : BWTheme.accent)
                Text(entry.status.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        entry.status == .active ? BWTheme.accent : BWTheme.ink3
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
            Text(entry.content)
                .font(.system(size: BWTheme.fontSizeBody))
                .foregroundStyle(BWTheme.ink)
            Text("作用域：\(entry.scope.displayText)")
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(BWTheme.ink3)
            if let reason = entry.reviewReason, entry.status == .needsReview {
                Text("需复核原因：\(reason)")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.warn)
            }
            if let source = entry.source {
                HStack(spacing: 6) {
                    Text("来源：\(projectTitles[source.recordingID] ?? "已删除录音") · 更新 \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.ink3)
                    if projectTitles[source.recordingID] != nil {
                        Button("查看来源原话") {
                            router.showProjectWorkspace(source.recordingID, autoStart: false, evidenceSegmentID: source.segmentID)
                        }
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.evidence)
                        .underline()
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text(entry.isManuallyAuthored ? "来源：人工添加" : "来源：无（待确认）")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
            }
        }
        .padding(10)
        .background(BWTheme.sunken.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 关联录音

    private var recordingsSection: some View {
        sectionCard(
            title: "关联录音",
            moreTitle: "关联说话人",
            more: { isSelectingSpeaker = true }
        ) {
            if person.speakerLinks.isEmpty {
                Text("尚无关联录音。把某场录音里的说话人槽位关联到这位人物后，会出现在这里。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
            }
            ForEach(person.speakerLinks.sorted { $0.linkedAt > $1.linkedAt }) { link in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(projectTitles[link.projectID] ?? "未知录音")
                            .font(.system(size: BWTheme.fontSizeBody, weight: .medium))
                            .foregroundStyle(BWTheme.ink)
                            .lineLimit(1)
                        Text("说话人：\(link.speakerDisplayName) · 关联于 \(link.linkedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: BWTheme.fontSizeDetail))
                            .foregroundStyle(BWTheme.ink3)
                    }
                    Spacer(minLength: 8)
                    Button("打开") {
                        router.showProjectWorkspace(link.projectID, autoStart: false)
                    }
                    .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                    .foregroundStyle(BWTheme.evidence)
                    .underline()
                    .buttonStyle(.plain)
                    Button("解除") {
                        unlinkSpeaker(link)
                    }
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - 待确认事项

    @ViewBuilder
    private var pendingSection: some View {
        let reviewMemories = person.memoryEntries.filter { $0.status == .needsReview }
        if !pendingIdentityLinks.isEmpty || !reviewMemories.isEmpty {
            sectionCard(title: "待确认事项", moreTitle: nil, more: nil) {
                ForEach(pendingIdentityLinks, id: \.speaker.id) { item in
                    HStack(spacing: 8) {
                        Circle().fill(BWTheme.warn).frame(width: 7, height: 7)
                        Text("「\(item.project.title)」的「\(item.speaker.displayName)」已关联本人物，但归属尚未人工确认")
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("去确认") {
                            router.showProjectWorkspace(item.project.id, autoStart: false)
                        }
                        .font(.system(size: BWTheme.fontSizeDetail, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(BWTheme.accentButton, in: RoundedRectangle(cornerRadius: 7))
                        .buttonStyle(.plain)
                    }
                }
                ForEach(reviewMemories) { entry in
                    HStack(spacing: 8) {
                        Circle().fill(BWTheme.warn).frame(width: 7, height: 7)
                        Text("记忆待复核：\(entry.content)")
                            .font(.system(size: BWTheme.fontSizeLabel))
                            .foregroundStyle(BWTheme.ink)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button("重新确认有效") { reactivateMemory(entry) }
                            .controlSize(.mini)
                    }
                }
            }
        }
    }

    // MARK: - 区块容器

    private func sectionCard<Content: View>(
        title: String,
        moreTitle: String?,
        more: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: BWTheme.fontSizeSectionTitle, weight: .semibold))
                    .foregroundStyle(BWTheme.ink)
                Spacer()
                if let moreTitle, let more {
                    Button(moreTitle, action: more)
                        .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                        .foregroundStyle(BWTheme.evidence)
                        .underline()
                        .buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(BWTheme.border, lineWidth: 1)
        )
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
            Text("合并后可在人物库撤销最近一次人物操作恢复。")
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
