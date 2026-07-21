import SwiftUI

/// 会前准备表单（阶段 1，实施计划 5.2）：
/// 基本信息、专业词汇、参会人、麦克风选择与 5 秒测试、录音与云端处理告知确认。
struct MeetingSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    /// 正在编辑的会议 ID（nil = 新建）
    let meetingID: UUID?

    @State private var form = MeetingSetupFormModel()
    @State private var levelTest = MicLevelTestController()
    @State private var sampleRecorder: VoiceSampleController?
    @State private var samplePlayer = AudioPlaybackController()
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var newGlossaryTerm = ""
    @State private var editingParticipant: Participant?
    @State private var showParticipantEditor = false
    @State private var saveError: String?
    /// 编辑模式下载入的既有会议
    @State private var editingMeeting: Meeting?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                basicInfoSection
                glossarySection
                participantsSection
                microphoneSection
                consentSection
                actionSection
            }
            .padding(32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(meetingID == nil ? "新建谈判" : "编辑会议")
        .onAppear {
            inputDevices = environment.audioCapture.inputDevices()
            sampleRecorder = VoiceSampleController(
                capture: environment.audioCapture,
                fileStore: environment.fileStore
            )
            loadExistingMeeting()
        }
        .onDisappear {
            levelTest.cancel()
            sampleRecorder?.cancelRecording()
        }
        .sheet(isPresented: $showParticipantEditor) {
            ParticipantEditorView(
                participant: editingParticipant,
                onSave: { participant in
                    if editingParticipant == nil {
                        _ = form.addParticipant(
                            displayName: participant.displayName,
                            side: participant.side,
                            role: participant.role,
                            colorToken: participant.colorToken
                        )
                    } else {
                        form.updateParticipant(participant)
                    }
                },
                onCancel: { showParticipantEditor = false }
            )
        }
    }

    // MARK: - 基本信息

    private var basicInfoSection: some View {
        GroupBox("基本信息") {
            VStack(alignment: .leading, spacing: 12) {
                labeledField("会议名称") {
                    TextField("例如：与某某公司的年度采购谈判", text: $form.title)
                }
                labeledField("谈判背景") {
                    TextEditor(text: $form.background).frame(height: 60)
                }
                labeledField("我方目标") {
                    TextEditor(text: $form.ourGoal).frame(height: 48)
                }
                labeledField("我方底线（只参与分析，不会展示给对方）") {
                    TextEditor(text: $form.ourBottomLine).frame(height: 48)
                }
                labeledField("对方背景") {
                    TextEditor(text: $form.counterpartContext).frame(height: 48)
                }
            }
            .padding(8)
        }
    }

    // MARK: - 专业词汇

    private var glossarySection: some View {
        GroupBox("专业词汇与专有名词") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("输入词条后添加（如：返点、账期、SKU）", text: $newGlossaryTerm)
                        .onSubmit { addTerm() }
                    Button("添加") { addTerm() }
                        .disabled(newGlossaryTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if form.glossary.isEmpty {
                    Text("尚无词条。录入行业术语和专有名词有助于提高转写与分析的准确性。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(form.glossary, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                form.removeGlossaryTerm(term)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - 参会人

    private var participantsSection: some View {
        GroupBox("参会人（最多 \(MeetingSetupFormModel.maxParticipants) 名）") {
            VStack(alignment: .leading, spacing: 8) {
                if form.participants.isEmpty {
                    Text("尚无参会人。添加后可在会中按人显示转写与分析。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(form.participants) { participant in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(colorForToken(participant.colorToken))
                                    .frame(width: 10, height: 10)
                                Text(participant.displayName).font(.headline)
                                Text(participant.side.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                if !participant.role.isEmpty {
                                    Text(participant.role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("编辑") {
                                    editingParticipant = participant
                                    showParticipantEditor = true
                                }
                                Button {
                                    form.removeParticipant(id: participant.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                            }
                            // 声音样本（实施计划 7.5：2–10 秒单人清晰样本）
                            voiceSampleRow(for: participant)
                        }
                        .padding(.vertical, 2)
                    }
                }
                HStack {
                    Button("添加参会人") {
                        editingParticipant = nil
                        showParticipantEditor = true
                    }
                    .disabled(form.participantLimitReached)
                    if form.participantLimitReached {
                        Text("首版最多支持 \(MeetingSetupFormModel.maxParticipants) 名实名识别参会人（云端接口上限）。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - 麦克风

    private var microphoneSection: some View {
        GroupBox("麦克风") {
            VStack(alignment: .leading, spacing: 8) {
                if inputDevices.isEmpty {
                    Text("未检测到可用麦克风，请连接后重新打开本页。")
                        .foregroundStyle(.orange)
                } else {
                    Picker("输入设备", selection: $form.selectedInputDeviceID) {
                        Text("系统默认").tag(String?.none)
                        ForEach(inputDevices, id: \.id) { device in
                            Text(device.name).tag(String?.some(device.id))
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 12) {
                        Button(levelTest.isTesting ? "测试中… \(levelTest.remainingSeconds)s" : "测试 5 秒") {
                            levelTest.start(using: environment.audioCapture, deviceID: form.selectedInputDeviceID)
                        }
                        .disabled(levelTest.isTesting)

                        if levelTest.isTesting {
                            ProgressView(value: Double(levelTest.liveLevel))
                                .frame(maxWidth: 220)
                        } else if let result = levelTest.result {
                            Image(systemName: result.verdict == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.verdict == .good ? .green : .orange)
                            Text(result.verdict.displayName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - 告知确认

    private var consentSection: some View {
        GroupBox("录音与云端处理告知") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $form.consentGiven) {
                    Text("所有参会人已知晓并同意录音；会议音频会分段发送至云端进行说话人识别，这些分片合起来基本覆盖整场谈话。")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)
                Text("完整录音文件只保存在本机；API Key 仅保存在 Keychain。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - 操作区

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !form.validationIssues.isEmpty {
                ForEach(form.validationIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                Button("取消") {
                    router.showMeetingList()
                }
                Button("保存草稿") {
                    saveDraft()
                }
                .disabled(!form.canSaveDraft)
                Button("保存并进入会中") {
                    saveAndProceed()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!form.canProceedToLive)
            }
        }
    }

    // MARK: - 行为

    /// 声音样本行：录制 / 停止、试听、状态与校验结果
    @ViewBuilder
    private func voiceSampleRow(for participant: Participant) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            if sampleRecorder?.isRecording(participantID: participant.id) == true {
                ProgressView(value: Double(sampleRecorder?.liveLevel ?? 0))
                    .frame(maxWidth: 120)
                Button("停止") {
                    stopSampleRecording(for: participant)
                }
                .buttonStyle(.borderedProminent)
            } else {
                // 样本状态
                if let durationMs = participant.voiceReferenceDurationMs {
                    Text("已录入 \(String(format: "%.1f", Double(durationMs) / 1000))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未录入声音样本")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let verdict = sampleRecorder?.verdicts[participant.id] {
                    Text(verdict.displayName)
                        .font(.caption)
                        .foregroundStyle(verdict.isOK ? .green : .orange)
                }
                Button(participant.voiceReferenceDurationMs == nil ? "录制样本" : "重录") {
                    startSampleRecording(for: participant)
                }
                .disabled(sampleRecorder?.phase != .idle && sampleRecorder?.phase != nil)
                if participant.voiceReferencePath != nil {
                    Button("试听") {
                        playSample(for: participant)
                    }
                }
            }
        }
        .padding(.leading, 18)
    }

    private func startSampleRecording(for participant: Participant) {
        do {
            try sampleRecorder?.startRecording(
                meetingID: form.meetingID,
                participantID: participant.id,
                deviceID: form.selectedInputDeviceID
            )
        } catch {
            saveError = "样本录制失败：\(error.localizedDescription)"
        }
    }

    private func stopSampleRecording(for participant: Participant) {
        guard let result = sampleRecorder?.stopRecording() else { return }
        participant.voiceReferencePath = result.relativePath
        participant.voiceReferenceDurationMs = result.durationMs
        form.updateParticipant(participant)
    }

    private func playSample(for participant: Participant) {
        guard let relativePath = participant.voiceReferencePath,
              let url = try? environment.fileStore.absoluteURL(forRelativePath: relativePath) else {
            return
        }
        do {
            try samplePlayer.load(url: url)
            samplePlayer.togglePlay()
        } catch {
            saveError = "样本试听失败：\(error.localizedDescription)"
        }
    }

    private func addTerm() {
        if form.addGlossaryTerm(newGlossaryTerm) {
            newGlossaryTerm = ""
        }
    }

    private func loadExistingMeeting() {
        guard let meetingID, editingMeeting == nil else { return }
        if let meeting = try? environment.allMeetings().first(where: { $0.id == meetingID }) {
            editingMeeting = meeting
            form.load(from: meeting)
        }
    }

    /// 保存草稿（draft 状态不变）
    private func saveDraft() {
        do {
            let meeting = editingMeeting ?? form.makeMeeting()
            form.apply(to: meeting)
            try environment.persist(meeting)
            router.showMeetingList()
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }

    /// 保存并进入会中：draft → ready，跳转会中界面（录音在会中界面手动开始）
    private func saveAndProceed() {
        do {
            let meeting = editingMeeting ?? form.makeMeeting()
            form.apply(to: meeting)
            if meeting.status == .draft {
                try meeting.transition(to: .ready)
            }
            try environment.persist(meeting)
            router.showLiveMeeting(meeting.id)
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

/// 颜色令牌 → SwiftUI 颜色（参会人标注）
func colorForToken(_ token: String) -> Color {
    switch token {
    case "blue": return .blue
    case "orange": return .orange
    case "green": return .green
    case "purple": return .purple
    case "red": return .red
    default: return .gray
    }
}
