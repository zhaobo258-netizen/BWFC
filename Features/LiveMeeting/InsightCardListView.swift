import SwiftUI

/// 右侧「谈判分析」（实施计划 6.4）：
/// 固定六类卡片；每张卡含一句判断、涉及参会人、「明确表达 / AI 推测」标签、
/// 低/中/高置信度、证据与最近更新时间。
/// 明确表达与 AI 推测在视觉上清晰区分；不出现任何回应建议。
struct InsightCardListView: View {
    let snapshot: AnalysisSnapshot?
    let participants: [Participant]
    let segments: [TranscriptSegment]
    /// 点击证据定位到底部片段
    var onEvidenceTap: ((UUID) -> Void)?
    var onSpeakerTap: ((Insight) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if (snapshot?.insights.isEmpty ?? true) {
                    Text("尚无足够信息")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
                ForEach(InsightCategory.allCases, id: \.self) { category in
                    let insights = (snapshot?.insights ?? []).filter { $0.category == category }
                    if !insights.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.displayName)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            ForEach(insights) { insight in
                                InsightCardView(
                                    insight: insight,
                                    participant: participants.first(where: { $0.id == insight.subjectParticipantId }),
                                    segments: segments,
                                    onEvidenceTap: onEvidenceTap,
                                    onSpeakerTap: onSpeakerTap
                                )
                            }
                        }
                    }
                }
                if let updated = snapshot?.createdAt {
                    Text("最近更新：\(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
    }
}

/// 单张分析卡片
struct InsightCardView: View {
    let insight: Insight
    let participant: Participant?
    let segments: [TranscriptSegment]
    var onEvidenceTap: ((UUID) -> Void)?
    var onSpeakerTap: ((Insight) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧色条：明确表达（蓝）与 AI 推测（橙）视觉清晰区分
            RoundedRectangle(cornerRadius: 2)
                .fill(insight.epistemicStatus == .explicit ? Color.blue : Color.orange)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                // 一句简洁判断
                Text(insight.statement)
                    .font(.callout)

                HStack(spacing: 6) {
                    // 涉及参会人
                    if let onSpeakerTap {
                        Button {
                            onSpeakerTap(insight)
                        } label: {
                            Label(
                                participant?.displayName ?? "标注说话人",
                                systemImage: participant == nil
                                    ? "person.crop.circle.badge.questionmark"
                                    : "person.crop.circle"
                            )
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                participant.map { colorForToken($0.colorToken).opacity(0.15) }
                                    ?? BWTheme.accent.opacity(0.12),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .help("确认这条 AI 内容归谁")
                    } else if let participant {
                        Text(participant.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(colorForToken(participant.colorToken).opacity(0.15), in: Capsule())
                    }

                    // 判断类型标签
                    Text(insight.epistemicStatus.displayName)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            insight.epistemicStatus == .explicit
                                ? Color.blue.opacity(0.15)
                                : Color.orange.opacity(0.18),
                            in: Capsule()
                        )
                        .foregroundStyle(
                            insight.epistemicStatus == .explicit ? Color.blue : Color.orange
                        )

                    // 置信度（低/中/高，不显示伪精确百分比）
                    Text("置信度 \(insight.confidence.displayName)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)

                    Spacer()

                    // 最近更新时间
                    Text(insight.lastUpdatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // 证据
                HStack(spacing: 4) {
                    Text("证据")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(insight.evidenceSegmentIds, id: \.self) { id in
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            insight.epistemicStatus == .inference
                ? Color.orange.opacity(0.05)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    insight.epistemicStatus == .inference
                        ? Color.orange.opacity(0.35)
                        : Color.gray.opacity(0.2),
                    style: insight.epistemicStatus == .inference
                        ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                        : StrokeStyle(lineWidth: 1)
                )
        )
    }

    private func evidenceLabel(for id: UUID) -> String {
        guard let segment = segments.first(where: { $0.id == id }) else { return "证据" }
        return TranscriptRowView.formatMs(segment.startMs)
    }
}
