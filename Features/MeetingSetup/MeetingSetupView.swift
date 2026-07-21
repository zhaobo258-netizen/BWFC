import SwiftUI

/// 新建会议（阶段 0 占位）：仅提供最小表单与草稿创建；
/// 完整表单（背景、目标、底线、参会人、声音样本、麦克风测试、上传告知确认）
/// 将在阶段 1 实现（实施计划 5.2）。
struct MeetingSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var title: String = ""
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("新建谈判")
                .font(.largeTitle)
                .fontWeight(.bold)

            Form {
                Section {
                    TextField("会议名称（例如：与某某公司的年度采购谈判）", text: $title)
                } header: {
                    Text("基本信息")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)

            Text("完整会前准备表单（谈判背景、我方目标与底线、对方背景、专业词汇、\n参会人与声音样本、麦克风测试、录音与云端处理告知确认）将在阶段 1 实现。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button("取消") {
                    router.showMeetingList()
                }
                Button("创建草稿") {
                    createDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(32)
        .navigationTitle("新建谈判")
    }

    /// 创建草稿会议（初始状态 draft，走状态机起点）并持久化
    private func createDraft() {
        let meeting = Meeting(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            var meetings = try environment.meetingStore.loadMeetings()
            meetings.append(meeting)
            try environment.meetingStore.saveMeetings(meetings)
            router.showMeetingList()
        } catch {
            // 只展示错误类型，不含正文
            saveError = "保存失败：\(error.localizedDescription)"
            AppLog.persistence.error("\(LogSanitizer.formatEvent("meeting_save_failed", error: String(describing: type(of: error))))")
        }
    }
}
