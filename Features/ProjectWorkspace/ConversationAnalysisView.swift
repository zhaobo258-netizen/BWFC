import SwiftUI

/// V2 通用分析视图（阶段 D，03 §6.3）：按类别分组渲染 AnalysisItem，
/// 明确表达 / AI 推断与置信度可一眼区分，证据点击回链左栏。
/// 场景只改变分组显示顺序，不改变布局。
struct ConversationAnalysisView: View {
    let snapshot: ConversationAnalysisSnapshot?
    /// 页签过滤：true = 总结页签类别；false = 动机与目的页签类别
    let summaryTab: Bool
    let speakers: [Speaker]
    var onEvidenceTap: ((UUID) -> Void)?
    /// 片段 id → 会议时间轴起始毫秒（09 号计划需求 1：条目时间标签；
    /// 悬空 id 返回 nil，chip 不显示）
    var segmentStartMs: ((UUID) -> Int64?)?
    /// 点击条目说话人（09 号计划需求 2：标注/修改说话人的入口；
    /// 传条目涉及的证据片段 id 列表与当前 subjectSpeakerId）
    var onSpeakerTap: ((AnalysisItem) -> Void)?

    /// 类别显示顺序（场景增强类别自然排在其归属页签内）
    private static let displayOrder: [AnalysisItemCategory] = [
        .summary, .topic, .fact, .decision, .actionItem, .openQuestion,
        .concept, .example, .confusingPoint, .reviewQuestion, .keyQuote,
        .explicitNeed, .possibleConcern, .possibleMotive, .expressionPurpose,
        .stanceChange, .contradictionEvasion, .factCheck, .followUpQuestion,
        .knowledgeSeed
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if summaryTab, let headline = snapshot?.headline {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.caption)
                            .foregroundStyle(BWTheme.accent)
                            .padding(.top, 2)
                        Text(headline)
                            .font(.callout)
                            .fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BWTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(BWTheme.accent.opacity(0.22), lineWidth: 1)
                    )
                }

                let groups = groupedItems
                if groups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: summaryTab ? "text.page" : "sparkles")
                            .font(.title2)
                            .foregroundStyle(BWTheme.accent.opacity(0.75))
                        Text(snapshot == nil ? "尚无足够信息" : "本页签暂无内容")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text(snapshot == nil
                             ? "对话继续后，AI 会在这里更新分析"
                             : "当前证据没有形成可靠条目")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
                ForEach(groups, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(BWTheme.accent.opacity(0.7))
                                .frame(width: 2.5, height: 10)
                            Text(group.category.displayName)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group.items) { item in
                            itemCard(item)
                        }
                    }
                }

                if let createdAt = snapshot?.createdAt {
                    Text("更新于 \(createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var groupedItems: [(category: AnalysisItemCategory, items: [AnalysisItem])] {
        let items = (snapshot?.items ?? []).filter { $0.category.belongsToSummaryTab == summaryTab }
        return Self.displayOrder.compactMap { category in
            let matched = items.filter { $0.category == category }
            return matched.isEmpty ? nil : (category, matched)
        }
    }

    private func itemCard(_ item: AnalysisItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                // 明确表达 / AI 推断：视觉必须可一眼区分（红线）
                BWBadge(text: item.epistemicStatus == .explicit ? "明确表达" : "AI 推断",
                        color: item.epistemicStatus == .explicit ? .green : .orange)
                // 时间标签：取最早证据片段的会议时间（与左栏转写同格式），点击回链原话
                if let anchor = earliestEvidence(of: item) {
                    Button {
                        onEvidenceTap?(anchor.segmentId)
                    } label: {
                        Text(TranscriptRowView.formatMs(anchor.startMs))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("定位到这句原话")
                }
                Text(confidenceLabel(item.confidence))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let onSpeakerTap {
                    // 说话人可点（有名字显示名字，未识别给标注入口）
                    Button {
                        onSpeakerTap(item)
                    } label: {
                        HStack(spacing: 3) {
                            if speakerName(for: item.subjectSpeakerId) == nil {
                                Image(systemName: "person.crop.circle.badge.questionmark")
                            }
                            Text(speakerName(for: item.subjectSpeakerId) ?? "标注说话人")
                        }
                        .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(speakerName(for: item.subjectSpeakerId) == nil
                                     ? AnyShapeStyle(BWTheme.accent)
                                     : AnyShapeStyle(.secondary))
                    .help("确认这条内容归谁；只有唯一证据时才可另选回写原话并学习声纹")
                } else if let speakerName = speakerName(for: item.subjectSpeakerId) {
                    Text(speakerName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // 证据回链
                ForEach(Array(item.evidenceSegmentIds.prefix(4)), id: \.self) { id in
                    Button {
                        onEvidenceTap?(id)
                    } label: {
                        Image(systemName: "text.quote")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BWTheme.accent)
                    .help("查看原话")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bwCard(padding: 11)
    }

    private func confidenceLabel(_ confidence: Confidence) -> String {
        switch confidence {
        case .low: return "低置信"
        case .medium: return "中置信"
        case .high: return "高置信"
        }
    }

    private func speakerName(for id: UUID?) -> String? {
        guard let id,
              let speaker = speakers.first(where: { $0.id == id }) else {
            return nil
        }
        guard let role = speaker.role?.trimmingCharacters(in: .whitespacesAndNewlines),
              !role.isEmpty else {
            return speaker.displayName
        }
        return "\(speaker.displayName) · \(role)"
    }

    /// 条目证据中会议时间最早的一条（时间标签锚点；证据悬空时为 nil）
    private func earliestEvidence(of item: AnalysisItem) -> (segmentId: UUID, startMs: Int64)? {
        guard let segmentStartMs else { return nil }
        return item.evidenceSegmentIds
            .compactMap { id in segmentStartMs(id).map { (id, $0) } }
            .min { $0.1 < $1.1 }
            .map { (segmentId: $0.0, startMs: $0.1) }
    }
}
