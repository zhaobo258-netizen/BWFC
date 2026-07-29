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

    /// V1 会议与 V2 项目统一后的轻量条目
    let items: [AbnormalRecoveryItem]
    let onAction: (AbnormalRecoveryItem?, Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("发现未正常结束的项目", systemImage: "exclamationmark.triangle.fill")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)

            Text("上次退出时以下项目仍在录音或处理中。已写入的录音与文稿都已保留，不会被删除。")
                .foregroundStyle(.secondary)

            List(items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(detailText(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看") { onAction(item, .openMeeting) }
                    Button("标记为已结束") { onAction(item, .markCompleted) }
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

    /// 「中断时状态 · 已记录时长」；时长为 0 时不展示，避免给出误导数字
    private func detailText(for item: AbnormalRecoveryItem) -> String {
        let status = "中断时状态：\(item.statusText)"
        guard item.durationMs > 0 else { return status }
        return "\(status) · 已记录 \(Self.formatDuration(ms: item.durationMs))"
    }

    /// 纯格式化，不触碰视图状态，允许在任意上下文调用
    nonisolated static func formatDuration(ms: Int64) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
