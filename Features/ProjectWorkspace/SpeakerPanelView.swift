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
                voiceReferencePath: speaker.voiceSamplePath ?? speaker.legacyVoiceReferencePath,
                voiceReferenceDurationMs: speaker.voiceSampleDurationMs ?? speaker.legacyVoiceReferenceDurationMs
            )
        }
    }
}

/// 工作台「说话人」面板（声纹识别入口）：
/// 录入说话人（本地姓名 + 角色 + 颜色）并录制 2–10 秒声纹样本；
/// 样本仅存本机，云端识别时随分片上传做已知说话人匹配（只发代号 p_01…）。
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("说话人与声纹")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("为每位说话人录一段 2–10 秒的声音样本，云端识别会把发言自动匹配到对应的人。样本只保存在本机；云端只见代号（\(project.speakers.map(\.cloudAlias).joined(separator: "、")))，不见姓名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

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
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 460)
        .onDisappear {
            sampleRecorder?.cancelRecording()
            if samplePlayer.isPlaying { samplePlayer.togglePlay() }
        }
        .sheet(item: $editingSpeaker) { speaker in
            SpeakerEditSheet(speaker: speaker) {
                changed()
                refreshTick += 1
            }
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
                if speaker.voiceSamplePath != nil {
                    Button {
                        playSample(speaker)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                    .help("试听样本")
                }
                Button(speaker.voiceSamplePath == nil ? "录样本" : "重录") {
                    startSample(for: speaker)
                }
                .disabled(microphoneBusy || sampleRecorder?.phase != .idle && sampleRecorder != nil)
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
        } else if let duration = speaker.voiceSampleDurationMs {
            Label("声纹样本 \(String(format: "%.1f", Double(duration) / 1000)) 秒", systemImage: "waveform")
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
        try? ensureRecorder().startRecording(
            meetingID: meeting.id,
            participantID: speaker.id,
            deviceID: meeting.preferredInputDeviceID
        )
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
        guard let path = speaker.voiceSamplePath,
              let url = try? environment.fileStore.absoluteURL(forRelativePath: path) else { return }
        try? samplePlayer.load(url: url)
        samplePlayer.togglePlay()
    }

    private func changed() {
        SpeakerPanelLogic.syncRuntimeParticipants(speakers: project.speakers, meeting: meeting)
        onSpeakersChanged()
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
