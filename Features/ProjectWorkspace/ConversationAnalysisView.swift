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
                    Text(headline)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }

                let groups = groupedItems
                if groups.isEmpty {
                    Text(snapshot == nil ? "尚无足够信息" : "本页签暂无内容")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 20)
                }
                ForEach(groups, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.category.displayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
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
                Text(item.epistemicStatus == .explicit ? "明确表达" : "AI 推断")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        item.epistemicStatus == .explicit
                            ? Color.green.opacity(0.15) : Color.orange.opacity(0.18),
                        in: Capsule()
                    )
                Text(confidenceLabel(item.confidence))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let speakerName = speakerName(for: item.subjectSpeakerId) {
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
                    .foregroundStyle(.blue)
                    .help("查看原话")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func confidenceLabel(_ confidence: Confidence) -> String {
        switch confidence {
        case .low: return "低置信"
        case .medium: return "中置信"
        case .high: return "高置信"
        }
    }

    private func speakerName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }?.displayName
    }
}
