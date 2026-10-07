import SwiftUI

/// 批量指认范围预览（说话人左键指认计划 20261007 §三.4 / §四）：
/// 显示目标人物、选中数、可修改数、受保护数与逐条语句摘要；
/// 所有被排除条目可查看原因，不只给总数。提交前工作台会重新校验范围。
struct BatchAssignPreviewSheet: View {
    let context: ProjectWorkspaceView.BatchAssignPreviewContext
    /// 一次提交；返回 false 表示范围已过期或保存失败（弹层保留）
    let onCommit: () -> Bool
    let onClose: () -> Void

    @State private var rangeChangedNotice: String?

    private var applicableCount: Int {
        context.preview.applicableSegmentIds.count
    }
    private var protectedCount: Int {
        context.preview.exclusions.filter { $0.reason == .confirmedToOther }.count
    }
    private var otherExcludedCount: Int {
        context.preview.exclusions.count - protectedCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认指认范围")
                .font(.headline)

            HStack(spacing: 8) {
                BWSpeakerDot(name: context.speaker.displayName,
                             color: colorForToken(context.speaker.colorToken), size: 22)
                Text(context.speaker.displayName)
                    .font(.callout)
                    .fontWeight(.semibold)
                if let role = context.speaker.role, !role.isEmpty {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 14) {
                Label("已选 \(context.segmentIds.count)", systemImage: "checklist")
                Label("将修改 \(applicableCount)", systemImage: "arrow.right.circle")
                    .foregroundStyle(BWTheme.accent)
                if protectedCount > 0 {
                    Label("保留原归属 \(protectedCount)", systemImage: "lock")
                        .foregroundStyle(.orange)
                }
                if otherExcludedCount > 0 {
                    Label("其他排除 \(otherExcludedCount)", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption)

            if protectedCount > 0 {
                Text("已人工确认给其他人的 \(protectedCount) 条保留原归属；需要改判请在原话页用单条入口处理。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(context.segmentSummaries) { summary in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: summary.isApplicable
                                ? "checkmark.circle" : "minus.circle")
                                .font(.caption)
                                .foregroundStyle(summary.isApplicable
                                    ? BWTheme.accent : .secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if !summary.timeText.isEmpty {
                                        Text(summary.timeText)
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(.tertiary)
                                    }
                                    if let title = summary.sourceTitle {
                                        Text(title)
                                            .font(.caption2)
                                            .foregroundStyle(BWTheme.accent.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                }
                                Text(summary.text)
                                    .font(.caption)
                                    .foregroundStyle(summary.isApplicable ? .primary : .secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let exclusion = summary.exclusionText {
                                    Text("不修改：\(exclusion)")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 260)

            if let rangeChangedNotice {
                Text(rangeChangedNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(applicableCount == 0 ? "没有可修改的语句" : commitTitle) {
                    if onCommit() {
                        // 提交成功后由工作台关闭弹层与反馈
                    } else {
                        rangeChangedNotice = "范围已变化或保存未成功；请关闭后重新预览再提交。"
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(applicableCount == 0)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private var commitTitle: String {
        let protectedSuffix = protectedCount > 0
            ? "，另 \(protectedCount) 条保留原归属" : ""
        return "将 \(applicableCount) 条指认为 \(context.speaker.displayName)\(protectedSuffix)"
    }
}
