import SwiftUI

/// 异常退出恢复提示（实施计划 11.1）：
/// 列出未正常结束的会议，明确告知已写入的录音会保留，由用户决定处理方式。
struct AbnormalRecoveryView: View {
    enum Action {
        /// 标记为已结束（状态修正为 completed）
        case markCompleted
        /// 标记已结束并打开会后页面
        case openMeeting
        /// 稍后处理（下次启动再次提示）
        case later
    }

    let meetings: [Meeting]
    let onAction: (Meeting?, Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("发现未正常结束的会议", systemImage: "exclamationmark.triangle.fill")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)

            Text("上次退出时以下会议仍在录音或收尾。已写入的录音文件已保留，不会被删除。")
                .foregroundStyle(.secondary)

            List(meetings) { meeting in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(.headline)
                        Text("中断时状态：\(meeting.status.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看") { onAction(meeting, .openMeeting) }
                    Button("标记为已结束") { onAction(meeting, .markCompleted) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120)

            HStack {
                Spacer()
                Button("稍后处理") { onAction(nil, .later) }
            }
        }
        .padding(24)
        .frame(width: 560, height: 380)
    }
}
