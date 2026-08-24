import SwiftUI

/// 说话人指认弹层（09 号计划需求 2）：
/// 从总结条目或转写行进入，选已有说话人或输入姓名新建。
/// 总结卡片归属与转写说话人修改分开，避免把多段证据误当成同一个人的声音。
struct SpeakerAssignSheet: View {
    @Environment(\.dismiss) private var dismiss

    let speakers: [Speaker]
    /// 这句话的原文（给用户对照「这是谁说的」）
    let anchorText: String
    let isAnalysisItem: Bool
    let canAlsoAssignTranscript: Bool
    let onPickExisting: (Speaker, Bool) -> Bool
    let onCreate: (String, String?, Bool) -> Bool

    @State private var newName: String = ""
    @State private var newRole: String = ""
    @State private var alsoAssignTranscript = false

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("这是谁说的？")
                .font(.headline)
            if !anchorText.isEmpty {
                Text("“\(anchorText)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(isAnalysisItem
                 ? "这里确认的是这条 AI 内容归谁，不会把多段证据静默当成同一个人的声音。"
                 : "这里会修改这句原话的说话人；永久识别需到「说话人」面板试听并确认一段 2–10 秒的单人样本。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if isAnalysisItem, canAlsoAssignTranscript {
                Toggle("同时把唯一一条证据原话标给此人", isOn: $alsoAssignTranscript)
                    .font(.caption)
            }

            if !speakers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(speakers) { speaker in
                        Button {
                            if onPickExisting(speaker, alsoAssignTranscript) {
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                BWSpeakerDot(name: speaker.displayName,
                                             color: colorForToken(speaker.colorToken), size: 22)
                                Text(speaker.displayName)
                                    .font(.callout)
                                if let role = speaker.role, !role.isEmpty {
                                    Text(role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if speaker.voiceSamplePath != nil {
                                    Image(systemName: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                        .help("已有声纹样本")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .bwCard(padding: 9)
                    }
                }
            }

            Divider()

            VStack(spacing: 8) {
                TextField("新说话人姓名（只存本机）", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createIfValid)
                TextField("角色 / 职位（可选，供总结区分立场）", text: $newRole)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createIfValid)
            }
            HStack {
                Spacer()
                Button("新建并指认") { createIfValid() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func createIfValid() {
        guard !trimmedName.isEmpty else { return }
        let role = newRole.trimmingCharacters(in: .whitespacesAndNewlines)
        if onCreate(trimmedName, role.isEmpty ? nil : role, alsoAssignTranscript) {
            dismiss()
        }
    }
}
