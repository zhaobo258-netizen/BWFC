import SwiftUI

struct HistoricalPeopleLibraryPage: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    router.showProjectHome()
                } label: {
                    Label("返回项目", systemImage: "chevron.left")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("人物库与我的背景")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("声纹 · 关联录音 · 人工背景 · 表达与沟通画像")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.bar)
            Divider()
            HistoricalPeopleLibraryView()
        }
        .background(BWTheme.paper)
    }
}

struct HistoricalPeopleLibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    var allowsProjectNavigation = true
    var managementEnabled = true

    @State private var summaries: [HistoricalPersonSummary] = []
    @State private var invalidLibrary = false
    @State private var notice: String?
    @State private var editingProfile: SpeakerVoiceProfile?
    @State private var pendingDelete: SpeakerVoiceProfile?
    @State private var analyzingProfileID: UUID?
    @State private var samplePlayer = AudioPlaybackController()

    var body: some View {
        Form {
            statusSection
            peopleSection
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .sheet(item: $editingProfile) { profile in
            HistoricalPersonEditSheet(profile: profile) { name, role, background in
                saveProfile(
                    profile,
                    displayName: name,
                    role: role,
                    backgroundContext: background
                )
            }
        }
        .confirmationDialog(
            "删除这个历史人物？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除人物档案与声纹", role: .destructive) {
                if let profile = pendingDelete {
                    deleteProfile(profile)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除本机永久声纹、人工背景和表达画像；历史录音和文稿保留。")
        }
    }

    private var statusSection: some View {
        Section("人物库") {
            HStack(spacing: 22) {
                LabeledContent("人物档案", value: "\(summaries.count) 人")
                LabeledContent(
                    "已启用历史声纹",
                    value: "\(summaries.filter { $0.profile.isAutoEnabled }.count) / \(SpeakerVoiceProfileStore.maximumAutoEnabledProfiles)"
                )
            }
            providerCapability
            if !managementEnabled {
                Label("录音进行中可查看和试听；结束录音后才能修改或删除人物档案。", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
            }
            Text("这里是全局人物主档；录音里的“本场人物”只引用它，不是另一套人物。将一人设为“我”后，经你确认的背景与有原话证据的表达画像会继续用于下次 AI 对话。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if invalidLibrary {
                Label("有声纹样本缺失或损坏，已停止其自动识别。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var providerCapability: some View {
        let provider = environment.diarizationProviderConfigurationStore.load().selectedProvider
        switch provider {
        case .openAICompatible:
            Label(
                "已启用已知声纹请求；官方 OpenAI 每场最多 4 人，自定义兼容地址仍需用真实录音验证。",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .volcengine:
            Label(
                "当前火山引擎只返回匿名说话人，不会把历史声纹自动识别成具体人物。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        case .disabled:
            Label(
                "云端分人已关闭，历史声纹不会自动匹配。",
                systemImage: "pause.circle"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var peopleSection: some View {
        Section("声纹、背景与表达画像") {
            if summaries.isEmpty {
                ContentUnavailableView(
                    "还没有历史人物",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("完成一次说话人标注后，人物、声纹和背景会显示在这里。")
                )
            } else {
                ForEach(summaries) { summary in
                    personRow(summary)
                }
            }
        }
    }

    private func personRow(_ summary: HistoricalPersonSummary) -> some View {
        let profile = summary.profile
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                BWSpeakerDot(
                    name: profile.displayName,
                    color: colorForToken(profile.colorToken),
                    size: 32
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.headline)
                    Text(profile.role ?? "未填写角色")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if profile.isCurrentUser == true {
                        Label("这是我 · AI 连续上下文", systemImage: "person.crop.circle.fill.badge.checkmark")
                            .font(.caption2)
                            .foregroundStyle(BWTheme.accent)
                    }
                    Text("关联 \(summary.projects.count) 场录音 · \(summary.attributedSegmentCount) 条归属发言 · \(summary.userConfirmedSegmentCount) 条人工确认 · 声纹 \(durationText(profile.sampleDurationMs))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "启用历史声纹",
                    isOn: Binding(
                        get: { profile.isAutoEnabled },
                        set: { setAutoEnabled($0, profile: profile) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!managementEnabled)
            }

            if let background = profile.backgroundContext, !background.isEmpty {
                LabeledContent("人工背景", value: background)
                    .font(.caption)
            } else {
                Text("人工背景：尚未填写")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let communication = profile.communicationProfile {
                VStack(alignment: .leading, spacing: 4) {
                    Text("表达与沟通画像")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(communication.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(communication.observations.count) 项可观察特征 · 更新于 \(communication.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("表达与沟通画像：尚未生成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("试听声纹") { playSample(profile) }
                Button("编辑人物档案") { editingProfile = profile }
                    .disabled(!managementEnabled)
                Button(profile.isCurrentUser == true ? "这是我" : "设为我") {
                    setCurrentUser(profile)
                }
                .disabled(!managementEnabled)
                Button(
                    analyzingProfileID == profile.id
                        ? "正在分析…"
                        : "用全部历史发言更新画像"
                ) {
                    updateCommunicationProfile(profile)
                }
                .disabled(
                    analyzingProfileID != nil
                        || !managementEnabled
                        || summary.userConfirmedSegmentCount < 2
                        || !environment.isAnalysisConfigured
                )
                if !summary.projects.isEmpty, allowsProjectNavigation {
                    Menu("关联录音 \(summary.projects.count)") {
                        ForEach(summary.projects) { project in
                            Button("\(project.title) · \(project.attributedSegmentCount) 条发言") {
                                router.closeSettings()
                                router.showProjectWorkspace(project.projectID, autoStart: false)
                            }
                        }
                    }
                } else if !summary.projects.isEmpty {
                    Text("关联录音 \(summary.projects.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("删除人物", role: .destructive) {
                    pendingDelete = profile
                }
                .disabled(!managementEnabled)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }

    private func reload() {
        do {
            let profiles: [SpeakerVoiceProfile]
            do {
                profiles = try environment.speakerVoiceProfileStore.load()
                invalidLibrary = false
            } catch {
                profiles = try environment.speakerVoiceProfileStore.loadForManagement()
                invalidLibrary = true
            }
            summaries = HistoricalPersonLibrary.summaries(
                profiles: profiles,
                projects: try environment.projectStore.loadProjects()
            )
        } catch {
            summaries = []
            notice = "历史人物库读取失败：\(error.localizedDescription)"
        }
    }

    private func setAutoEnabled(_ enabled: Bool, profile: SpeakerVoiceProfile) {
        do {
            try environment.speakerVoiceProfileStore.setAutoEnabled(enabled, profileID: profile.id)
            notice = enabled ? "已设为下次自动识别。" : "已停止下次自动识别，人物档案仍保留。"
            reload()
        } catch SpeakerVoiceProfileStoreError.autoRecognitionLimitReached {
            notice = "每场最多自动识别 4 人，请先关闭一位。"
        } catch {
            notice = "自动识别状态未保存：\(error.localizedDescription)"
        }
    }

    private func setCurrentUser(_ profile: SpeakerVoiceProfile) {
        do {
            try environment.speakerVoiceProfileStore.setCurrentUser(
                profileID: profile.id
            )
            let updatedProfiles = try environment.speakerVoiceProfileStore
                .loadForManagement()
            let projects = try environment.projectStore.loadProjects()
            for updated in updatedProfiles {
                _ = HistoricalPersonLibrary.applyProfile(
                    updated,
                    to: projects
                )
            }
            try environment.projectStore.saveProjects(projects)
            notice = "已设为“我”；人工背景与可核验表达画像会用于后续 AI 对话。"
            reload()
        } catch {
            notice = "“我”的设置未完整保存：\(error.localizedDescription)"
        }
    }

    private func playSample(_ profile: SpeakerVoiceProfile) {
        do {
            let url = try environment.fileStore.absoluteURL(
                forRelativePath: profile.sampleRelativePath
            )
            try samplePlayer.load(url: url)
            samplePlayer.togglePlay()
        } catch {
            notice = "声纹样本无法试听，请在录音项目中重新标注或录制。"
        }
    }

    private func saveProfile(
        _ original: SpeakerVoiceProfile,
        displayName: String,
        role: String?,
        backgroundContext: String?
    ) -> String? {
        var projects: [Project]?
        var speakerSnapshots: [ProjectSpeakerSnapshot] = []
        var profileWriteAttempted = false
        do {
            profileWriteAttempted = true
            try environment.speakerVoiceProfileStore.updateMetadata(
                profileID: original.id,
                displayName: displayName,
                role: role,
                colorToken: original.colorToken
            )
            try environment.speakerVoiceProfileStore.updateContext(
                profileID: original.id,
                backgroundContext: backgroundContext,
                communicationProfile: original.communicationProfile
            )
            guard let updated = try environment.speakerVoiceProfileStore.loadForManagement()
                .first(where: { $0.id == original.id }) else {
                throw SpeakerVoiceProfileStoreError.profileNotFound
            }
            let loadedProjects = try environment.projectStore.loadProjects()
            projects = loadedProjects
            speakerSnapshots = captureSpeakerSnapshots(
                profileID: original.id,
                projects: loadedProjects
            )
            if !speakerSnapshots.isEmpty {
                _ = HistoricalPersonLibrary.applyProfile(updated, to: loadedProjects)
                try environment.projectStore.saveProjects(loadedProjects)
            }
            notice = "人物档案已更新，并同步到关联录音。"
            reload()
            return nil
        } catch {
            var rollbackFailures: [String] = []
            if profileWriteAttempted, let failure = restoreProfile(original) {
                rollbackFailures.append(failure)
            }
            if let projects,
               let failure = restoreProjectSpeakers(speakerSnapshots, in: projects) {
                rollbackFailures.append(failure)
            }
            return transactionFailureMessage(
                prefix: "人物档案未保存",
                error: error,
                rollbackFailures: rollbackFailures
            )
        }
    }

    private func updateCommunicationProfile(_ profile: SpeakerVoiceProfile) {
        let projects: [Project]
        do {
            projects = try environment.projectStore.loadProjects()
        } catch {
            notice = "无法读取历史会议：\(error.localizedDescription)"
            return
        }
        let evidence = HistoricalPersonLibrary.communicationEvidence(
            profileID: profile.id,
            projects: projects
        )
        guard evidence.count >= 2 else {
            notice = "至少需要 2 条已确认属于此人的发言。"
            return
        }
        analyzingProfileID = profile.id
        notice = nil
        Task {
            defer { analyzingProfileID = nil }
            var persistedOriginal: SpeakerVoiceProfile?
            var speakerSnapshots: [ProjectSpeakerSnapshot] = []
            var profileWriteAttempted = false
            do {
                let generated = try await SpeakerCommunicationProfileAgent(
                    generationService: environment.aiProviderRegistry
                ).analyze(
                    profileID: profile.id,
                    backgroundContext: profile.backgroundContext,
                    previousProfile: profile.communicationProfile,
                    evidence: evidence
                )
                guard let current = try environment.speakerVoiceProfileStore
                    .loadForManagement()
                    .first(where: { $0.id == profile.id }) else {
                    throw SpeakerVoiceProfileStoreError.profileNotFound
                }
                persistedOriginal = current
                profileWriteAttempted = true
                try environment.speakerVoiceProfileStore.updateContext(
                    profileID: profile.id,
                    backgroundContext: current.backgroundContext,
                    communicationProfile: generated
                )
                guard let updated = try environment.speakerVoiceProfileStore
                    .loadForManagement()
                    .first(where: { $0.id == profile.id }) else {
                    throw SpeakerVoiceProfileStoreError.profileNotFound
                }
                speakerSnapshots = captureSpeakerSnapshots(
                    profileID: profile.id,
                    projects: projects
                )
                _ = HistoricalPersonLibrary.applyProfile(updated, to: projects)
                try environment.projectStore.saveProjects(projects)
                notice = "已基于 \(evidence.count) 条历史发言更新表达与沟通画像。"
                reload()
            } catch {
                var rollbackFailures: [String] = []
                if profileWriteAttempted,
                   let persistedOriginal,
                   let failure = restoreProfileContext(persistedOriginal) {
                    rollbackFailures.append(failure)
                }
                if let failure = restoreProjectSpeakers(speakerSnapshots, in: projects) {
                    rollbackFailures.append(failure)
                }
                let baseMessage = (error as? AnalysisAPIError) == .invalidResponse
                    ? "模型没有返回可由原话核验的画像。"
                    : "表达画像更新失败：\(error.localizedDescription)"
                notice = rollbackFailures.isEmpty
                    ? baseMessage
                    : "\(baseMessage) 自动恢复未完成（\(rollbackFailures.joined(separator: "；"))），请重新打开人物库确认。"
            }
        }
    }

    private func deleteProfile(_ profile: SpeakerVoiceProfile) {
        let projects: [Project]
        do {
            projects = try environment.projectStore.loadProjects()
        } catch {
            notice = "人物档案未删除：\(error.localizedDescription)"
            return
        }
        let speakerSnapshots = captureSpeakerSnapshots(
            profileID: profile.id,
            projects: projects
        )
        _ = HistoricalPersonLibrary.unlinkProfile(profile, from: projects)
        do {
            try environment.projectStore.saveProjects(projects)
        } catch {
            let rollbackFailure = restoreProjectSpeakers(speakerSnapshots, in: projects)
            notice = transactionFailureMessage(
                prefix: "人物档案未删除",
                error: error,
                rollbackFailures: [rollbackFailure].compactMap { $0 }
            )
            return
        }
        do {
            try environment.speakerVoiceProfileStore.delete(profileID: profile.id)
            pendingDelete = nil
            notice = "已删除 \(profile.displayName) 的人物档案和永久声纹；历史录音与文稿保留。"
            reload()
        } catch {
            let rollbackFailure = restoreProjectSpeakers(speakerSnapshots, in: projects)
            notice = transactionFailureMessage(
                prefix: "人物档案未删除",
                error: error,
                rollbackFailures: [rollbackFailure].compactMap { $0 }
            )
        }
    }

    private struct ProjectSpeakerSnapshot {
        var projectID: UUID
        var speakerID: UUID
        var displayName: String
        var role: String?
        var colorToken: String
        var voiceSamplePath: String?
        var voiceSampleDurationMs: Int64?
        var voiceProfileID: UUID?
        var backgroundContext: String?
        var communicationProfile: SpeakerCommunicationProfile?
    }

    private func captureSpeakerSnapshots(
        profileID: UUID,
        projects: [Project]
    ) -> [ProjectSpeakerSnapshot] {
        projects.flatMap { project in
            project.speakers.compactMap { speaker in
                guard speaker.voiceProfileId == profileID else { return nil }
                return ProjectSpeakerSnapshot(
                    projectID: project.id,
                    speakerID: speaker.id,
                    displayName: speaker.displayName,
                    role: speaker.role,
                    colorToken: speaker.colorToken,
                    voiceSamplePath: speaker.voiceSamplePath,
                    voiceSampleDurationMs: speaker.voiceSampleDurationMs,
                    voiceProfileID: speaker.voiceProfileId,
                    backgroundContext: speaker.backgroundContext,
                    communicationProfile: speaker.communicationProfile
                )
            }
        }
    }

    private func restoreProjectSpeakers(
        _ snapshots: [ProjectSpeakerSnapshot],
        in projects: [Project]
    ) -> String? {
        guard !snapshots.isEmpty else { return nil }
        for snapshot in snapshots {
            guard let speaker = projects
                .first(where: { $0.id == snapshot.projectID })?
                .speakers.first(where: { $0.id == snapshot.speakerID }) else {
                continue
            }
            speaker.displayName = snapshot.displayName
            speaker.role = snapshot.role
            speaker.colorToken = snapshot.colorToken
            speaker.voiceSamplePath = snapshot.voiceSamplePath
            speaker.voiceSampleDurationMs = snapshot.voiceSampleDurationMs
            speaker.voiceProfileId = snapshot.voiceProfileID
            speaker.backgroundContext = snapshot.backgroundContext
            speaker.communicationProfile = snapshot.communicationProfile
        }
        do {
            try environment.projectStore.saveProjects(projects)
            return nil
        } catch {
            return "关联录音恢复失败：\(error.localizedDescription)"
        }
    }

    private func restoreProfile(_ original: SpeakerVoiceProfile) -> String? {
        var failures: [String] = []
        do {
            try environment.speakerVoiceProfileStore.updateMetadata(
                profileID: original.id,
                displayName: original.displayName,
                role: original.role,
                colorToken: original.colorToken,
                now: original.updatedAt
            )
        } catch {
            failures.append("基本资料恢复失败：\(error.localizedDescription)")
        }
        if let failure = restoreProfileContext(original) {
            failures.append(failure)
        }
        return failures.isEmpty ? nil : failures.joined(separator: "；")
    }

    private func restoreProfileContext(_ original: SpeakerVoiceProfile) -> String? {
        do {
            try environment.speakerVoiceProfileStore.updateContext(
                profileID: original.id,
                backgroundContext: original.backgroundContext,
                communicationProfile: original.communicationProfile,
                now: original.updatedAt
            )
            return nil
        } catch {
            return "背景与表达画像恢复失败：\(error.localizedDescription)"
        }
    }

    private func transactionFailureMessage(
        prefix: String,
        error: Error,
        rollbackFailures: [String]
    ) -> String {
        let base = "\(prefix)：\(error.localizedDescription)"
        guard !rollbackFailures.isEmpty else {
            return "\(base)；已恢复原数据。"
        }
        return "\(base)；自动恢复未完成（\(rollbackFailures.joined(separator: "；"))），请重新打开人物库确认。"
    }

    private func durationText(_ milliseconds: Int64) -> String {
        String(format: "%.1f 秒", Double(milliseconds) / 1_000)
    }
}

private struct HistoricalPersonEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profile: SpeakerVoiceProfile
    let onSave: (String, String?, String?) -> String?

    @State private var displayName = ""
    @State private var role = ""
    @State private var backgroundContext = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑历史人物")
                .font(.headline)
            TextField("姓名（只存本机）", text: $displayName)
                .textFieldStyle(.roundedBorder)
            TextField("角色 / 职位", text: $role)
                .textFieldStyle(.roundedBorder)
            Text("人工背景")
                .font(.subheadline)
            TextEditor(text: $backgroundContext)
                .frame(minHeight: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
            Text("可填写职责、与你的关系、关注重点和历史约定；后续分析会连续使用。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560, height: 430)
        .onAppear {
            displayName = profile.displayName
            role = profile.role ?? ""
            backgroundContext = profile.backgroundContext ?? ""
        }
    }

    private func save() {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "姓名不能为空。"
            return
        }
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBackground = backgroundContext
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = onSave(
            name,
            normalizedRole.isEmpty ? nil : normalizedRole,
            normalizedBackground.isEmpty ? nil : normalizedBackground
        ) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}
