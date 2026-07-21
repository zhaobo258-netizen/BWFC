import SwiftUI

/// 左侧「结构总结」（实施计划 6.3）：
/// 固定 7 段顺序：当前议题 / 议题列表（当前高亮）/ 我方明确立场 / 对方明确立场 /
/// 已确认事项 / 未决事项 / 关键数字日期承诺。
/// 空内容显示「尚无足够信息」，不用想象内容填满；所有条目必须带证据。
struct StructureSummaryView: View {
    let snapshot: AnalysisSnapshot?
    let participants: [Participant]
    let segments: [TranscriptSegment]
    /// 点击证据定位到底部片段
    var onEvidenceTap: ((UUID) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                currentTopicSection
                topicsSection
                entrySection(title: "我方明确立场", entries: snapshot?.ourPositions ?? [])
                entrySection(title: "对方明确立场", entries: snapshot?.counterpartPositions ?? [])
                entrySection(title: "已确认事项", entries: snapshot?.confirmedItems ?? [])
                entrySection(title: "未决事项", entries: snapshot?.openItems ?? [])
                entrySection(title: "关键数字、日期和承诺", entries: snapshot?.keyFacts ?? [])
            }
            .padding(16)
        }
    }

    // MARK: - 当前议题

    private var currentTopicSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("当前议题")
            if let title = snapshot?.currentTopicTitle, !title.isEmpty {
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                emptyHint
            }
        }
    }

    // MARK: - 议题列表

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("议题列表")
            let topics = (snapshot?.topics ?? []).sorted { $0.order < $1.order }
            if topics.isEmpty {
                emptyHint
            } else {
                ForEach(topics) { topic in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(topicStatusColor(topic.status))
                            .frame(width: 8, height: 8)
                        Text(topic.title)
                            .font(.callout)
                            .fontWeight(isCurrentTopic(topic) ? .semibold : .regular)
                        Spacer()
                        Text(topic.status.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        evidenceChips(topic.evidenceSegmentIds)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        isCurrentTopic(topic) ? Color.blue.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
            }
        }
    }

    // MARK: - 结构项段落（立场 / 确认 / 未决 / 关键数字）

    private func entrySection(title: String, entries: [StructureEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(title)
            if entries.isEmpty {
                emptyHint
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text)
                            .font(.callout)
                        evidenceChips(entry.evidenceSegmentIds)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - 共用

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    /// 空内容：显示「尚无足够信息」，不用想象内容填满（实施计划 6.3）
    private var emptyHint: some View {
        Text("尚无足够信息")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
    }

    /// 证据胶囊：点击定位到底部对应片段
    private func evidenceChips(_ segmentIds: [UUID]) -> some View {
        HStack(spacing: 4) {
            ForEach(segmentIds, id: \.self) { id in
                Button {
                    onEvidenceTap?(id)
                } label: {
                    Label(evidenceLabel(for: id), systemImage: "quote.bubble")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 证据标签：片段开始时间（mm:ss）
    private func evidenceLabel(for id: UUID) -> String {
        guard let segment = segments.first(where: { $0.id == id }) else { return "证据" }
        return TranscriptRowView.formatMs(segment.startMs)
    }

    private func isCurrentTopic(_ topic: TopicState) -> Bool {
        guard let current = snapshot?.currentTopicTitle else { return false }
        return topic.title == current
    }

    private func topicStatusColor(_ status: TopicStatus) -> Color {
        switch status {
        case .discussing: return .blue
        case .confirmed: return .green
        case .open: return .orange
        }
    }
}
