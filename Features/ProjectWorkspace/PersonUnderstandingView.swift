import SwiftUI

/// 「人物」页（A 版 M2）：按说话人投影真实分析条目，绝不臆测归属与动机。
///
/// UI 规范：正文 14–16pt、辅助/来源 ≥12pt、证据按钮命中区 ≥32pt；
/// 多条证据纵向排列并带真实时间/序号，不横向无界挤压卡片。
struct PersonUnderstandingView: View {
    let projection: AnalysisPresentationMapper.Projection
    /// 片段时间标签（由工作台按当前/历史时间轴提供；nil 表示无法取得）
    var evidenceTimeLabel: (UUID) -> String? = { _ in nil }
    var onEvidenceTap: (UUID) -> Void = { _ in }
    var onRequestSpeakerAssignment: (AnalysisPresentationMapper.Entry) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if projection.people.isEmpty && projection.unassignedEntries.isEmpty {
                    ContentUnavailableView(
                        "尚未形成人物理解",
                        systemImage: "person.2",
                        description: Text("有可归属原话后，这里会按人物整理发言、诉求、动机推测与待确认判断。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(projection.people) { person in
                    personCard(person)
                }
                if !projection.unassignedEntries.isEmpty {
                    unassignedCard
                }
                Text("人物理解只来自真实原话；AI 推断均带标签并可逐条查证证据。")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func personCard(_ person: AnalysisPresentationMapper.Person) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(person.identity.displayName)
                    .font(.system(size: BWTheme.fontSizeBody, weight: .semibold))
                if let role = person.identity.role, !role.isEmpty {
                    Text(role)
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(person.identity.statusText)
                    .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                    .foregroundStyle(person.identity.isUserConfirmed ? Color.green : Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (person.identity.isUserConfirmed ? Color.green : Color.orange)
                            .opacity(0.12),
                        in: Capsule()
                    )
                    .accessibilityLabel("身份状态：" + person.identity.statusText)
            }

            if !person.spokenSummaryEntries.isEmpty {
                section("明确说了什么", items: person.spokenSummaryEntries)
            }
            if !person.explicitNeedsAndCommitments.isEmpty {
                section("明确诉求 / 承诺", items: person.explicitNeedsAndCommitments)
            }
            motiveSection(person)
            if !person.otherExplanations.isEmpty {
                section("其他解释 / 待确认", items: person.otherExplanations)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bwCard(padding: 10)
    }

    private func motiveSection(_ person: AnalysisPresentationMapper.Person) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.accent)
                Text("可能动机（推测）")
                    .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if person.possibleMotives.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(person.motiveEvidenceInsufficient
                         ? "证据不足：目前只有行动/承诺，尚无足够原话推断动机。"
                         : "暂无可推断的动机内容。")
                }
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(person.possibleMotives) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private func section(_ title: String,
                         items: [AnalysisPresentationMapper.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(BWTheme.accent.opacity(0.55))
                    .frame(width: 2.5, height: 12)
                Text(title)
                    .font(.system(size: BWTheme.fontSizeLabel, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { entry in
                entryRow(entry)
            }
        }
    }

    private func entryRow(_ entry: AnalysisPresentationMapper.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .font(.system(size: BWTheme.fontSizeBody))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                BWBadge(text: entry.epistemicStatus == .explicit ? "明确表达" : "AI 推断",
                        color: entry.epistemicStatus == .explicit ? .green : .orange)
                Text(entry.displayCategory)
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.secondary)
                Text(confidenceLabel(entry.confidence))
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            evidenceRows(entry.evidenceSegmentIDs)
        }
        .padding(.vertical, 4)
    }

    /// 多证据逐条展示：纵向 + 序号 + 真实时间，命中区 ≥32pt。
    private func evidenceRows(_ segmentIDs: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(segmentIDs.enumerated()), id: \.element) { index, id in
                Button {
                    onEvidenceTap(id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.quote")
                            .font(.system(size: BWTheme.fontSizeDetail))
                        Text(timePrefix(index: index, id: id))
                            .font(.system(size: BWTheme.fontSizeDetail))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(BWTheme.accent)
                    .padding(.horizontal, 8)
                    .frame(minHeight: BWTheme.minimumHitHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开这条证据原话")
                .accessibilityLabel("打开第 \(index + 1) 条证据原话")
            }
        }
    }

    private func timePrefix(index: Int, id: UUID) -> String {
        if let label = evidenceTimeLabel(id) {
            return "证据 \(index + 1) · \(label)"
        }
        return "证据 \(index + 1)"
    }

    private var unassignedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(BWTheme.accent)
                Text("归属待确认")
                    .font(.system(size: BWTheme.fontSizeBody, weight: .semibold))
                Spacer()
                Text("\(projection.unassignedEntries.count) 条")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(.secondary)
            }
            Text("这些内容没有可靠说话人主体，不会归给任一人物；请逐条核对归属。")
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(projection.unassignedEntries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.text)
                        .font(.system(size: BWTheme.fontSizeBody))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        BWBadge(text: entry.epistemicStatus == .explicit ? "明确表达" : "AI 推断",
                                color: entry.epistemicStatus == .explicit ? .green : .orange)
                        Text(entry.displayCategory)
                            .font(.system(size: BWTheme.fontSizeDetail))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("标注说话人") {
                            onRequestSpeakerAssignment(entry)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .frame(minHeight: BWTheme.minimumHitHeight)
                        .help("确认这条内容归谁")
                        .accessibilityLabel("标注这条内容的说话人")
                    }
                    evidenceRows(entry.evidenceSegmentIDs)
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bwCard(padding: 10)
    }

    private func confidenceLabel(_ confidence: Confidence) -> String {
        switch confidence {
        case .low: return "低置信"
        case .medium: return "中置信"
        case .high: return "高置信"
        }
    }
}
