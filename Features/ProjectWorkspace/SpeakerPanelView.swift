import SwiftUI

/// 说话人面板纯逻辑（可单测）：代号分配与运行时参会人同步。
enum SpeakerPanelLogic {
    /// 分配下一个云端代号（p_01…；云端只见代号，不见真实姓名）
    static func nextCloudAlias(existing: [Speaker]) -> String {
        let used = Set(existing.map(\.cloudAlias))
        for index in 1...20 {
            let alias = String(format: "p_%02d", index)
            if !used.contains(alias) { return alias }
        }
        return String(format: "p_%02d", existing.count + 1)
    }

    /// 未被占用的下一个颜色令牌
    static func nextColorToken(existing: [Speaker]) -> String {
        let tokens = ["blue", "orange", "green", "purple", "red", "gray"]
        let used = Set(existing.map(\.colorToken))
        return tokens.first { !used.contains($0) } ?? tokens[existing.count % tokens.count]
    }

    static func voiceReferencePath(for speaker: Speaker) -> String? {
        speaker.voiceSamplePath ?? speaker.legacyVoiceReferencePath
    }

    static func voiceReferenceDurationMs(for speaker: Speaker) -> Int64? {
        speaker.voiceSampleDurationMs ?? speaker.legacyVoiceReferenceDurationMs
    }

    static func activeVoiceReferenceCount(in speakers: [Speaker]) -> Int {
        speakers.filter { voiceReferencePath(for: $0) != nil }.count
    }

    static func canActivateVoiceReference(for speakerID: UUID, in speakers: [Speaker]) -> Bool {
        guard let speaker = speakers.first(where: { $0.id == speakerID }) else { return false }
        return voiceReferencePath(for: speaker) != nil
            || activeVoiceReferenceCount(in: speakers) < KnownSpeakerReference.maximumCount
    }

    /// 把 V2 说话人同步进运行时参会人列表（id 对齐；样本路径 V2 优先）。
    /// 已有片段的 participantId 不动，后续分片按新列表解析。
    static func syncRuntimeParticipants(speakers: [Speaker], meeting: Meeting) {
        meeting.participants = speakers.map { speaker in
            Participant(
                id: speaker.id,
                cloudAlias: speaker.cloudAlias,
                displayName: speaker.displayName,
                side: speaker.legacySide.flatMap { ParticipantSide(rawValue: $0) } ?? .neutral,
                role: speaker.role ?? "",
                colorToken: speaker.colorToken,
                voiceReferencePath: voiceReferencePath(for: speaker),
                voiceReferenceDurationMs: voiceReferenceDurationMs(for: speaker),
                iflytekFeatureID: speaker.iflytekFeatureID
            )
        }
    }
}

/// 工作台「说话人」面板（声纹识别入口）：
/// 录入说话人（本地姓名 + 角色 + 颜色）并录制 2–10 秒声纹样本；
/// 样本由本机管理：OpenAI 请求时随分片发送，讯飞只在注册/更新声纹时发送。
/// 录音进行中麦克风被占用，样本录制入口置灰（如实说明原因）。
struct SpeakerPanelView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let meeting: Meeting
    /// 麦克风是否被会议录音占用
    let microphoneBusy: Bool
    /// 变更后的持久化 + 运行时刷新（工作台注入）
    let onSpeakersChanged: () -> Void

    @State private var sampleRecorder: VoiceSampleController?
    @State private var samplePlayer = AudioPlaybackController()
    @State private var editingSpeaker: Speaker?
    @State private var refreshTick = 0
    @State private var voiceProfiles: [SpeakerVoiceProfile] = []
    @State private var pendingPermanentSpeaker: Speaker?
    @State private var pendingDeleteProfile: SpeakerVoiceProfile?
    @State private var editingProfile: SpeakerVoiceProfile?
    @State private var contextProfile: SpeakerVoiceProfile?
    @State private var profileLibraryHasValidationFailure = false
    @State private var profileNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("本场人物与声纹")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("上面是本场人物；下面的人物库是跨录音的全局档案，可直接加入本场，不再重复建人。声纹样本由本机管理，只在声纹匹配需要时发送；云端只见代号，不见姓名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("在文稿中指认一次后，App 会从该人已确认的单人发言提取样本并记住；手工录制或更换样本时，请试听确认只有此人。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let profileNotice {
                        Label(profileNotice, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if microphoneBusy {
                        Label("录音进行中，麦克风被占用；暂停或结束录音后可录制声纹样本。", systemImage: "mic.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    let _ = refreshTick
                    ForEach(project.speakers) { speaker in
                        speakerRow(speaker)
                    }

                    Button {
                        addSpeaker()
                    } label: {
                        Label("添加说话人", systemImage: "person.badge.plus")
                    }
                    .padding(.top, 4)

                    if !voiceProfiles.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("人物库（跨录音复用）")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("当前服务每场最多自动匹配 4 个永久声纹。关闭自动使用不会删除样本。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(voiceProfiles) { profile in
                            profileRow(profile)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 460)
        .onDisappear {
            sampleRecorder?.cancelRecording()
            if samplePlayer.isPlaying { samplePlayer.togglePlay() }
        }
        .onAppear(perform: reloadProfiles)
        .sheet(item: $editingSpeaker) { speaker in
            SpeakerEditSheet(speaker: speaker) {
                changed()
                refreshTick += 1
            }
        }
        .sheet(item: $editingProfile) { profile in
            VoiceProfileEditSheet(profile: profile) { name, role, colorToken in
                updateProfileMetadata(
                    profile,
                    displayName: name,
                    role: role,
                    colorToken: colorToken
                )
            }
        }
        .sheet(item: $contextProfile) { profile in
            SpeakerCommunicationProfileSheet(
                profile: profile,
                speaker: project.speakers.first { $0.voiceProfileId == profile.id },
                project: project,
                onSave: { background, communicationProfile in
                    updateProfileContext(
                        profile,
                        backgroundContext: background,
                        communicationProfile: communicationProfile
                    )
                }
            )
            .environment(environment)
        }
        .confirmationDialog(
            "保存为永久声纹？",
            isPresented: Binding(
                get: { pendingPermanentSpeaker != nil },
                set: { if !$0 { pendingPermanentSpeaker = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("我已试听，确认只有此人") {
                if let speaker = pendingPermanentSpeaker {
                    enrollPermanentProfile(for: speaker)
                }
                pendingPermanentSpeaker = nil
            }
            Button("取消", role: .cancel) { pendingPermanentSpeaker = nil }
        } message: {
            Text("确认后样本会复制到本机永久声纹库，并在后续新录音中自动用于匹配。混有他人声音的样本会污染之后的识别。")
        }
        .confirmationDialog(
            "删除永久声纹？",
            isPresented: Binding(
                get: { pendingDeleteProfile != nil },
                set: { if !$0 { pendingDeleteProfile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除样本与资料", role: .destructive) {
                if let profile = pendingDeleteProfile {
                    deleteProfile(profile)
                }
                pendingDeleteProfile = nil
            }
            Button("取消", role: .cancel) { pendingDeleteProfile = nil }
        } message: {
            Text("会从本机永久删除该人的声音样本和资料；已有会议文稿不会被删除。")
        }
    }

    // MARK: - 行

    @ViewBuilder
    private func speakerRow(_ speaker: Speaker) -> some View {
        let recording = sampleRecorder?.isRecording(participantID: speaker.id) == true
        HStack(spacing: 10) {
            BWSpeakerDot(name: speaker.displayName,
                         color: colorForToken(speaker.colorToken), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(speaker.displayName)
                        .font(.callout)
                        .fontWeight(.medium)
                    if let role = speaker.role, !role.isEmpty {
                        Text(role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(speaker.cloudAlias)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                }
                sampleStatus(speaker, recording: recording)
            }
            Spacer()

            if recording {
                // 录制中：电平 + 停止
                ProgressView(value: min(1, max(0, sampleRecorder?.liveLevel ?? 0)))
                    .frame(width: 60)
                Button("停止") { stopSample(for: speaker) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            } else {
                if SpeakerPanelLogic.voiceReferencePath(for: speaker) != nil {
                    Button {
                        playSample(speaker)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                    .help("试听样本")
                }
                Button(SpeakerPanelLogic.voiceReferencePath(for: speaker) == nil ? "录样本" : "重录") {
                    startSample(for: speaker)
                }
                .disabled(microphoneBusy || sampleRecorder?.phase != .idle && sampleRecorder != nil)
                if SpeakerPanelLogic.voiceReferencePath(for: speaker) != nil {
                    Button(permanentActionTitle(for: speaker)) {
                        pendingPermanentSpeaker = speaker
                    }
                    .disabled(!isSafeDuration(SpeakerPanelLogic.voiceReferenceDurationMs(for: speaker)))
                }
                Button {
                    editingSpeaker = speaker
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("编辑姓名与角色")
            }
        }
        .bwCard(padding: 12)
    }

    @ViewBuilder
    private func sampleStatus(_ speaker: Speaker, recording: Bool) -> some View {
        if recording {
            Text("录制中…请让这位说话人单独说一句话（2–10 秒）")
                .font(.caption2)
                .foregroundStyle(.red)
        } else if let verdict = sampleRecorder?.verdicts[speaker.id], verdict != .ok {
            Text(verdict.displayName)
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if let duration = SpeakerPanelLogic.voiceReferenceDurationMs(for: speaker) {
            Label(sampleStatusText(for: speaker, duration: duration), systemImage: "waveform")
                .font(.caption2)
                .foregroundStyle(.green)
        } else {
            Text("未录声纹样本 · 该说话人的发言将显示为「待识别」")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 行为

    private func ensureRecorder() -> VoiceSampleController {
        if let sampleRecorder { return sampleRecorder }
        let controller = VoiceSampleController(
            capture: environment.audioCapture,
            fileStore: environment.fileStore
        )
        sampleRecorder = controller
        return controller
    }

    private func addSpeaker() {
        let speaker = Speaker(
            cloudAlias: SpeakerPanelLogic.nextCloudAlias(existing: project.speakers),
            displayName: "说话人 \(project.speakers.count + 1)",
            colorToken: SpeakerPanelLogic.nextColorToken(existing: project.speakers),
            isUserConfirmed: true
        )
        project.speakers.append(speaker)
        changed()
        editingSpeaker = speaker
    }

    private func startSample(for speaker: Speaker) {
        guard !microphoneBusy else { return }
        guard SpeakerPanelLogic.canActivateVoiceReference(
            for: speaker.id,
            in: project.speakers
        ) else {
            profileNotice = "本场已启用 4 个声纹，请先在下方将一人「本场停用」再录制。"
            return
        }
        do {
            try ensureRecorder().startRecording(
                meetingID: meeting.id,
                participantID: speaker.id,
                deviceID: meeting.preferredInputDeviceID
            )
        } catch {
            profileNotice = "声纹录制未开始（\(String(describing: type(of: error)))）"
        }
        refreshTick += 1
    }

    private func stopSample(for speaker: Speaker) {
        guard let result = sampleRecorder?.stopRecording() else { return }
        if result.verdict == .ok {
            speaker.voiceSamplePath = result.relativePath
            speaker.voiceSampleDurationMs = result.durationMs
            changed()
        }
        refreshTick += 1
    }

    private func playSample(_ speaker: Speaker) {
        guard let path = SpeakerPanelLogic.voiceReferencePath(for: speaker) else {
            profileNotice = "当前没有可试听的声纹样本。"
            return
        }
        do {
            let url = try environment.fileStore.absoluteURL(forRelativePath: path)
            try samplePlayer.load(url: url)
            samplePlayer.togglePlay()
        } catch {
            profileNotice = "声纹样本无法试听，请重新录制或更新永久声纹。"
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: SpeakerVoiceProfile) -> some View {
        let linkedSpeaker = project.speakers.first { $0.voiceProfileId == profile.id }
        let activeThisMeeting = linkedSpeaker.flatMap {
            SpeakerPanelLogic.voiceReferencePath(for: $0)
        } != nil
        HStack(spacing: 8) {
            BWSpeakerDot(name: profile.displayName,
                         color: colorForToken(profile.colorToken), size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(.callout)
                Text(profile.role ?? "未填写角色")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if profile.isCurrentUser == true {
                    Label("这是我 · AI 连续上下文", systemImage: "person.crop.circle.fill.badge.checkmark")
                        .font(.caption2)
                        .foregroundStyle(BWTheme.accent)
                }
                if profileLibraryHasValidationFailure {
                    Text("样本需试听确认；失效时请更新或删除")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                playProfile(profile)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .help("试听永久声纹")
            Button {
                editingProfile = profile
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("修正永久姓名与角色")
            Button("沟通画像") {
                contextProfile = profile
            }
            .buttonStyle(.bordered)
            Button(profile.isCurrentUser == true ? "这是我" : "设为我") {
                setCurrentUser(profile)
            }
            .buttonStyle(.bordered)
            Button(profile.isAutoEnabled ? "自动使用中" : "设为自动") {
                setAutoEnabled(!profile.isAutoEnabled, profile: profile)
            }
            .buttonStyle(.bordered)
            if activeThisMeeting {
                Button("本场停用") { deactivateProfileForCurrentMeeting(profile) }
                    .buttonStyle(.bordered)
            } else {
                Button("加入本场") { addProfileToCurrentMeeting(profile) }
                    .buttonStyle(.bordered)
            }
            Button(role: .destructive) {
                pendingDeleteProfile = profile
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("删除永久声纹")
        }
        .bwCard(padding: 9)
    }

    private func reloadProfiles() {
        do {
            voiceProfiles = try environment.speakerVoiceProfileStore.load()
                .sorted { $0.updatedAt > $1.updatedAt }
            profileLibraryHasValidationFailure = false
        } catch {
            do {
                voiceProfiles = try environment.speakerVoiceProfileStore.loadForManagement()
                    .sorted { $0.updatedAt > $1.updatedAt }
                profileLibraryHasValidationFailure = true
                profileNotice = "永久声纹库中有样本丢失或损坏，已停止自动带入；请试听后更新或删除。"
            } catch {
                voiceProfiles = []
                profileLibraryHasValidationFailure = true
                profileNotice = "永久声纹库读取失败（\(String(describing: type(of: error)))）"
            }
        }
    }

    private func enrollPermanentProfile(for speaker: Speaker) {
        guard let relativePath = SpeakerPanelLogic.voiceReferencePath(for: speaker),
              let durationMs = SpeakerPanelLogic.voiceReferenceDurationMs(for: speaker),
              let sourceURL = try? environment.fileStore.absoluteURL(forRelativePath: relativePath) else {
            profileNotice = "没有可保存的声纹样本。"
            return
        }
        do {
            let profile = try environment.speakerVoiceProfileStore.enroll(
                profileID: speaker.voiceProfileId,
                displayName: speaker.displayName,
                role: speaker.role,
                colorToken: speaker.colorToken,
                sourceSampleURL: sourceURL,
                durationMs: durationMs
            )
            speaker.voiceProfileId = profile.id
            speaker.voiceSamplePath = profile.sampleRelativePath
            speaker.voiceSampleDurationMs = profile.sampleDurationMs
            speaker.backgroundContext = profile.backgroundContext
            speaker.communicationProfile = profile.communicationProfile
            speaker.isCurrentUser = profile.isCurrentUser
            speaker.iflytekFeatureID = profile.iflytekFeatureID
            profileNotice = profile.isAutoEnabled
                ? "已保存为永久声纹，后续新录音会自动带入。"
                : "已保存；自动名额已满，可先关闭一个现有声纹再启用。"
            changed()
            reloadProfiles()
        } catch {
            profileNotice = "永久声纹保存失败（\(profileErrorText(error))）"
        }
    }

    private func setAutoEnabled(_ enabled: Bool, profile: SpeakerVoiceProfile) {
        do {
            try environment.speakerVoiceProfileStore.setAutoEnabled(enabled, profileID: profile.id)
            profileNotice = enabled ? "后续新录音会自动带入此人。" : "已停止自动带入，永久样本仍保留。"
            reloadProfiles()
        } catch {
            profileNotice = profileErrorText(error)
        }
    }

    private func setCurrentUser(_ profile: SpeakerVoiceProfile) {
        do {
            try environment.speakerVoiceProfileStore.setCurrentUser(
                profileID: profile.id
            )
            for speaker in project.speakers {
                speaker.isCurrentUser = speaker.voiceProfileId == profile.id
            }
            changed()
            reloadProfiles()
            profileNotice = "已设为“我”；人工背景与可核验表达画像会用于后续 AI 对话。"
        } catch {
            profileNotice = "“我”的设置未保存（\(profileErrorText(error))）"
        }
    }

    private func addProfileToCurrentMeeting(_ profile: SpeakerVoiceProfile) {
        if let linked = project.speakers.first(where: { $0.voiceProfileId == profile.id }) {
            activateProfile(profile, for: linked)
            return
        }
        let knownCount = SpeakerPanelLogic.activeVoiceReferenceCount(in: project.speakers)
        guard knownCount < SpeakerVoiceProfileStore.maximumAutoEnabledProfiles else {
            profileNotice = "本场已有 4 个声纹样本；当前服务无法再加入第 5 个。"
            return
        }
        let speaker = Speaker(
            cloudAlias: SpeakerPanelLogic.nextCloudAlias(existing: project.speakers),
            displayName: profile.displayName,
            role: profile.role,
            colorToken: profile.colorToken,
            isUserConfirmed: true,
            voiceSamplePath: profile.sampleRelativePath,
            voiceSampleDurationMs: profile.sampleDurationMs,
            voiceProfileId: profile.id,
            iflytekFeatureID: profile.iflytekFeatureID,
            backgroundContext: profile.backgroundContext,
            communicationProfile: profile.communicationProfile,
            isCurrentUser: profile.isCurrentUser
        )
        project.speakers.append(speaker)
        changed()
        profileNotice = "已将 \(profile.displayName) 加入本场识别。"
    }

    private func permanentActionTitle(for speaker: Speaker) -> String {
        guard let profileID = speaker.voiceProfileId,
              let profile = voiceProfiles.first(where: { $0.id == profileID }),
              profile.sampleRelativePath == speaker.voiceSamplePath else {
            return speaker.voiceProfileId == nil ? "永久保存" : "更新永久声纹"
        }
        return "已永久保存"
    }

    private func sampleStatusText(for speaker: Speaker, duration: Int64) -> String {
        let durationText = String(format: "%.1f", Double(duration) / 1000)
        if let profileID = speaker.voiceProfileId,
           let profile = voiceProfiles.first(where: { $0.id == profileID }),
           profile.sampleRelativePath == speaker.voiceSamplePath {
            return "永久声纹 \(durationText) 秒"
        }
        return "本场样本 \(durationText) 秒 · 尚未永久保存"
    }

    private func isSafeDuration(_ durationMs: Int64?) -> Bool {
        guard let durationMs else { return false }
        return (2_000...10_000).contains(durationMs)
    }

    private func profileErrorText(_ error: Error) -> String {
        switch error as? SpeakerVoiceProfileStoreError {
        case .autoRecognitionLimitReached:
            return "自动声纹已达 4 人上限，请先关闭一个现有声纹"
        case .invalidSample:
            return "样本必须存在且为 2–10 秒"
        case .profileNotFound:
            return "永久声纹已不存在，请刷新后重试"
        case nil:
            return String(describing: type(of: error))
        }
    }

    private func changed() {
        SpeakerPanelLogic.syncRuntimeParticipants(speakers: project.speakers, meeting: meeting)
        onSpeakersChanged()
    }

    private func updateProfileMetadata(
        _ profile: SpeakerVoiceProfile,
        displayName: String,
        role: String?,
        colorToken: String
    ) -> String? {
        do {
            try environment.speakerVoiceProfileStore.updateMetadata(
                profileID: profile.id,
                displayName: displayName,
                role: role,
                colorToken: colorToken
            )
            if let linked = project.speakers.first(where: { $0.voiceProfileId == profile.id }) {
                linked.displayName = displayName
                linked.role = role
                linked.colorToken = colorToken
                changed()
            }
            reloadProfiles()
            profileNotice = "永久资料已更新。"
            return nil
        } catch {
            return "永久资料未保存（\(profileErrorText(error))）"
        }
    }

    private func updateProfileContext(
        _ profile: SpeakerVoiceProfile,
        backgroundContext: String?,
        communicationProfile: SpeakerCommunicationProfile?
    ) -> String? {
        do {
            try environment.speakerVoiceProfileStore.updateContext(
                profileID: profile.id,
                backgroundContext: backgroundContext,
                communicationProfile: communicationProfile
            )
            if let linked = project.speakers.first(where: { $0.voiceProfileId == profile.id }) {
                let trimmed = backgroundContext?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                linked.backgroundContext = trimmed.isEmpty ? nil : trimmed
                linked.communicationProfile = communicationProfile
                changed()
            }
            reloadProfiles()
            profileNotice = communicationProfile == nil
                ? "人物背景已保存，将用于后续分析。"
                : "表达与沟通画像已更新，将随此人物用于后续会议。"
            return nil
        } catch {
            return "人物档案未保存（\(profileErrorText(error))）"
        }
    }

    private func playProfile(_ profile: SpeakerVoiceProfile) {
        do {
            let url = try environment.fileStore.absoluteURL(
                forRelativePath: profile.sampleRelativePath
            )
            try samplePlayer.load(url: url)
            samplePlayer.togglePlay()
        } catch {
            profileNotice = "\(profile.displayName) 的永久样本无法试听，请重新录制更新或删除。"
        }
    }

    private func deleteProfile(_ profile: SpeakerVoiceProfile) {
        do {
            try environment.speakerVoiceProfileStore.delete(profileID: profile.id)
            if let linked = project.speakers.first(where: { $0.voiceProfileId == profile.id }) {
                linked.voiceProfileId = nil
                if linked.voiceSamplePath == profile.sampleRelativePath {
                    linked.voiceSamplePath = nil
                    linked.voiceSampleDurationMs = nil
                }
                linked.backgroundContext = nil
                linked.communicationProfile = nil
                linked.isCurrentUser = nil
                linked.iflytekFeatureID = nil
                changed()
            }
            reloadProfiles()
            profileNotice = "已删除 \(profile.displayName) 的永久声纹与资料。"
        } catch {
            profileNotice = "永久声纹未删除（\(profileErrorText(error))）"
        }
    }

    private func activateProfile(_ profile: SpeakerVoiceProfile, for speaker: Speaker) {
        guard SpeakerPanelLogic.activeVoiceReferenceCount(in: project.speakers)
                < SpeakerVoiceProfileStore.maximumAutoEnabledProfiles else {
            profileNotice = "本场已有 4 个声纹样本；请先停用一人再替换。"
            return
        }
        speaker.voiceSamplePath = profile.sampleRelativePath
        speaker.voiceSampleDurationMs = profile.sampleDurationMs
        speaker.backgroundContext = profile.backgroundContext
        speaker.communicationProfile = profile.communicationProfile
        speaker.isCurrentUser = profile.isCurrentUser
        speaker.iflytekFeatureID = profile.iflytekFeatureID
        changed()
        profileNotice = "已将 \(profile.displayName) 加入本场识别。"
    }

    private func deactivateProfileForCurrentMeeting(_ profile: SpeakerVoiceProfile) {
        guard let speaker = project.speakers.first(where: { $0.voiceProfileId == profile.id }) else {
            return
        }
        speaker.voiceSamplePath = nil
        speaker.voiceSampleDurationMs = nil
        changed()
        profileNotice = "已在本场停用 \(profile.displayName)；永久样本未删除。"
    }
}

private struct SpeakerCommunicationProfileSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let profile: SpeakerVoiceProfile
    let speaker: Speaker?
    let project: Project
    let onSave: (String?, SpeakerCommunicationProfile?) -> String?

    @State private var backgroundContext = ""
    @State private var communicationProfile: SpeakerCommunicationProfile?
    @State private var isAnalyzing = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(profile.displayName) · 表达与沟通画像")
                        .font(.headline)
                    Text("基于已人工确认归属的原话，形成跨会议连续人物档案。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }

            GroupBox("人工背景") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $backgroundContext)
                        .frame(minHeight: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                    Text("填写职责、关系、关注重点或历史约定。背景会随人物保存，并发送给当前分析模型作为用户补充信息，不作为录音证据。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("保存背景") { saveBackground() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("表达方式") {
                VStack(alignment: .leading, spacing: 10) {
                    if let communicationProfile {
                        Text(communicationProfile.summary)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(communicationProfile.observations) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.caption).fontWeight(.semibold)
                                Text(item.observation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("证据 \(item.evidenceSegmentIds.count) 条")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        Text("尚未生成。至少需要两条已确认属于此人的发言。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Label("只分析可观察的沟通模式，不做心理诊断。", systemImage: "checkmark.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(isAnalyzing ? "分析中…" : "用本场发言更新画像") {
                            analyzeCurrentProject()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isAnalyzing || speaker == nil)
                    }
                }
                .padding(.top, 4)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(
                        message.contains("失败") || message.contains("不足")
                            ? Color.orange
                            : Color.secondary
                    )
            }
        }
        .padding(20)
        .frame(width: 620, height: 610)
        .onAppear {
            backgroundContext = profile.backgroundContext ?? ""
            communicationProfile = profile.communicationProfile
        }
    }

    private func saveBackground() {
        let normalized = backgroundContext
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.isEmpty ? nil : normalized
        if let error = onSave(value, communicationProfile) {
            message = error
        } else {
            speaker?.backgroundContext = value
            message = "人物背景已保存。"
        }
    }

    private func analyzeCurrentProject() {
        guard let speaker else {
            message = "请先把这个人物加入本场并完成发言标注。"
            return
        }
        let normalized = backgroundContext
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.isEmpty ? nil : normalized
        speaker.backgroundContext = value
        speaker.communicationProfile = communicationProfile
        if let error = onSave(value, communicationProfile) {
            message = error
            return
        }
        isAnalyzing = true
        message = nil
        Task {
            defer { isAnalyzing = false }
            do {
                let generated = try await SpeakerCommunicationProfileAgent(
                    generationService: environment.aiProviderRegistry
                ).analyze(
                    speaker: speaker,
                    projectId: project.id,
                    segments: project.segments
                )
                if let error = onSave(value, generated) {
                    message = error
                    return
                }
                speaker.communicationProfile = generated
                communicationProfile = generated
                message = "画像已更新，并写入此人物的跨会议档案。"
            } catch {
                message = (error as? AnalysisAPIError) == .invalidResponse
                    ? "可用发言不足，或模型没有返回可核验证据。"
                    : "画像分析失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct VoiceProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profile: SpeakerVoiceProfile
    let onSave: (String, String?, String) -> String?

    @State private var name = ""
    @State private var role = ""
    @State private var colorToken = "blue"
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修正永久资料")
                .font(.headline)
            Text("这里的修改会用于以后的新会议。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("姓名（只存本机）", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("角色 / 职位（可选）", text: $role)
                .textFieldStyle(.roundedBorder)
            Picker("颜色", selection: $colorToken) {
                ForEach(MeetingSetupFormModel.colorTokens, id: \.token) { item in
                    Text(item.displayName).tag(item.token)
                }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty else {
                        saveError = "姓名不能为空。"
                        return
                    }
                    let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let error = onSave(
                        trimmedName,
                        trimmedRole.isEmpty ? nil : trimmedRole,
                        colorToken
                    ) {
                        saveError = error
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = profile.displayName
            role = profile.role ?? ""
            colorToken = profile.colorToken
        }
    }
}

/// 说话人编辑弹层（姓名 / 角色 / 颜色；真实姓名只存本地）
private struct SpeakerEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let speaker: Speaker
    let onSave: () -> Void

    @State private var name: String = ""
    @State private var role: String = ""
    @State private var colorToken: String = "blue"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑说话人")
                .font(.headline)
            TextField("姓名（只存本机）", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("角色 / 职位（可选，会作为分析上下文）", text: $role)
                .textFieldStyle(.roundedBorder)
            Picker("颜色", selection: $colorToken) {
                ForEach(MeetingSetupFormModel.colorTokens, id: \.token) { item in
                    HStack {
                        Circle().fill(colorForToken(item.token)).frame(width: 8, height: 8)
                        Text(item.displayName)
                    }
                    .tag(item.token)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { speaker.displayName = trimmed }
                    speaker.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
                    speaker.colorToken = colorToken
                    speaker.isUserConfirmed = true
                    onSave()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = speaker.displayName
            role = speaker.role ?? ""
            colorToken = speaker.colorToken
        }
    }
}
