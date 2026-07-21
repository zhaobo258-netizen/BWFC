import SwiftUI

/// 参会人编辑器（新增 / 编辑）：姓名、阵营、角色、显示颜色。
struct ParticipantEditorView: View {
    /// 被编辑的参会人（nil = 新增）
    let participant: Participant?
    let onSave: (Participant) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var side: ParticipantSide
    @State private var role: String
    @State private var colorToken: String

    init(participant: Participant?, onSave: @escaping (Participant) -> Void, onCancel: @escaping () -> Void) {
        self.participant = participant
        self.onSave = onSave
        self.onCancel = onCancel
        _displayName = State(initialValue: participant?.displayName ?? "")
        _side = State(initialValue: participant?.side ?? .counterpart)
        _role = State(initialValue: participant?.role ?? "")
        _colorToken = State(initialValue: participant?.colorToken ?? "blue")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(participant == nil ? "添加参会人" : "编辑参会人")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("姓名或称呼（如：张总）", text: $displayName)
                Picker("阵营", selection: $side) {
                    ForEach(ParticipantSide.allCases, id: \.self) { side in
                        Text(side.displayName).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                TextField("职位或谈判角色（如：采购负责人）", text: $role)
                Picker("显示颜色", selection: $colorToken) {
                    ForEach(MeetingSetupFormModel.colorTokens, id: \.token) { item in
                        HStack {
                            Circle().fill(colorForToken(item.token)).frame(width: 8, height: 8)
                            Text(item.displayName)
                        }
                        .tag(item.token)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") {
                    // 新增时 cloudAlias 由表单模型分配；编辑时保留原代号
                    let result = Participant(
                        id: participant?.id ?? UUID(),
                        cloudAlias: participant?.cloudAlias ?? "",
                        displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        side: side,
                        role: role,
                        colorToken: colorToken
                    )
                    onSave(result)
                    onCancel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 380)
    }
}
