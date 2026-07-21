import Foundation

/// Markdown 纪要导出（实施计划阶段 5）：
/// 会议信息、结构总结、分析（含证据时间戳和说话人）、完整按人转写；
/// 可独立阅读。纯文本生成，不触碰文件面板，便于单测。
enum MeetingMarkdownExporter {
    /// 生成完整 Markdown 纪要
    static func makeMarkdown(meeting: Meeting) -> String {
        var lines: [String] = []
        let snapshot = meeting.latestSnapshot

        // ── 标题与元信息 ──
        lines.append("# 会议纪要：\(meeting.title)")
        lines.append("")
        lines.append("- 状态：\(meeting.status.displayName)")
        if let startedAt = meeting.startedAt {
            lines.append("- 开始：\(formatDateTime(startedAt))")
        }
        if let endedAt = meeting.endedAt {
            lines.append("- 结束：\(formatDateTime(endedAt))")
        }
        if !meeting.pauseIntervals.isEmpty {
            lines.append("- 录音中有 \(meeting.pauseIntervals.count) 段暂停区间（暂停期间无音频）")
        }
        lines.append("")

        // ── 会议信息 ──
        lines.append("## 会议信息")
        lines.append("")
        infoRow(&lines, "谈判背景", meeting.background)
        infoRow(&lines, "我方目标", meeting.ourGoal)
        infoRow(&lines, "我方底线", meeting.ourBottomLine)
        infoRow(&lines, "对方背景", meeting.counterpartContext)
        if !meeting.glossary.isEmpty {
            lines.append("- 专业词汇：\(meeting.glossary.joined(separator: "、"))")
        }
        if !meeting.participants.isEmpty {
            let names = meeting.participants.map {
                "\($0.displayName)（\($0.side.displayName)\($0.role.isEmpty ? "" : " · \($0.role)")）"
            }
            lines.append("- 参会人：\(names.joined(separator: "、"))")
        }
        lines.append("")

        // ── 结构总结 ──
        lines.append("## 结构总结")
        lines.append("")
        lines.append("### 当前议题")
        lines.append("")
        if let topic = snapshot?.currentTopicTitle, !topic.isEmpty {
            lines.append(topic)
        } else {
            lines.append("尚无足够信息")
        }
        lines.append("")

        lines.append("### 议题列表")
        lines.append("")
        appendTopics(&lines, snapshot?.topics ?? [], meeting: meeting)

        appendEntries(&lines, title: "我方明确立场", entries: snapshot?.ourPositions ?? [], meeting: meeting)
        appendEntries(&lines, title: "对方明确立场", entries: snapshot?.counterpartPositions ?? [], meeting: meeting)
        appendEntries(&lines, title: "已确认事项", entries: snapshot?.confirmedItems ?? [], meeting: meeting)
        appendEntries(&lines, title: "未决事项", entries: snapshot?.openItems ?? [], meeting: meeting)
        appendEntries(&lines, title: "关键数字、日期和承诺", entries: snapshot?.keyFacts ?? [], meeting: meeting)

        // ── 谈判分析 ──
        lines.append("## 谈判分析")
        lines.append("")
        lines.append("> 分析包含「明确表达」与「AI 推测」两类：明确表达由原话直接支持；AI 推测不等于事实，仅供辅助判断。")
        lines.append("")
        let insights = snapshot?.insights ?? []
        if insights.isEmpty {
            lines.append("尚无足够信息")
            lines.append("")
        }
        for category in InsightCategory.allCases {
            let categoryInsights = insights.filter { $0.category == category }
            guard !categoryInsights.isEmpty else { continue }
            lines.append("### \(category.displayName)")
            lines.append("")
            for insight in categoryInsights {
                let participantName = insight.subjectParticipantId
                    .flatMap { id in meeting.participants.first(where: { $0.id == id })?.displayName }
                    ?? "未指明"
                lines.append(
                    "- \(insight.statement) —— \(participantName) · \(insight.epistemicStatus.displayName) · 置信度\(insight.confidence.displayName) · 更新于 \(insight.lastUpdatedAt.formatted(date: .omitted, time: .shortened))"
                )
                for evidenceId in insight.evidenceSegmentIds {
                    if let evidence = evidenceLine(for: evidenceId, in: meeting) {
                        lines.append("  - 证据：\(evidence)")
                    }
                }
            }
            lines.append("")
        }

        // ── 完整按人转写 ──
        lines.append("## 完整转写")
        lines.append("")
        let segments = meeting.segments
            .filter { $0.state == .final || $0.state == .edited }
            .sorted { $0.startMs < $1.startMs }
        if segments.isEmpty {
            lines.append("（无转写内容）")
        }
        for segment in segments {
            lines.append(transcriptLine(for: segment, in: meeting))
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - 内部

    private static func infoRow(_ lines: inout [String], _ label: String, _ value: String) {
        lines.append("- \(label)：\(value.isEmpty ? "（未填写）" : value)")
    }

    private static func appendTopics(_ lines: inout [String], _ topics: [TopicState], meeting: Meeting) {
        if topics.isEmpty {
            lines.append("尚无足够信息")
            lines.append("")
            return
        }
        for topic in topics.sorted(by: { $0.order < $1.order }) {
            let evidence = topic.evidenceSegmentIds
                .compactMap { evidenceLabel(for: $0, in: meeting) }
                .joined(separator: "、")
            lines.append("- [\(topic.status.displayName)] \(topic.title)\(evidence.isEmpty ? "" : "（证据 \(evidence)）")")
        }
        lines.append("")
    }

    private static func appendEntries(
        _ lines: inout [String],
        title: String,
        entries: [StructureEntry],
        meeting: Meeting
    ) {
        lines.append("### \(title)")
        lines.append("")
        if entries.isEmpty {
            lines.append("尚无足够信息")
        }
        for entry in entries {
            let evidence = entry.evidenceSegmentIds
                .compactMap { evidenceLabel(for: $0, in: meeting) }
                .joined(separator: "、")
            lines.append("- \(entry.text)\(evidence.isEmpty ? "" : "（证据 \(evidence)）")")
        }
        lines.append("")
    }

    /// 证据标签：mm:ss + 说话人
    private static func evidenceLabel(for segmentId: UUID, in meeting: Meeting) -> String? {
        guard let segment = meeting.segments.first(where: { $0.id == segmentId }) else {
            return nil
        }
        return "[\(formatMs(segment.startMs)) \(speakerName(for: segment, in: meeting))]"
    }

    /// 证据行：mm:ss 说话人「原文」
    private static func evidenceLine(for segmentId: UUID, in meeting: Meeting) -> String? {
        guard let segment = meeting.segments.first(where: { $0.id == segmentId }) else {
            return nil
        }
        return "[\(formatMs(segment.startMs)) \(speakerName(for: segment, in: meeting))]「\(segment.text)」"
    }

    private static func transcriptLine(for segment: TranscriptSegment, in meeting: Meeting) -> String {
        let speaker = speakerName(for: segment, in: meeting)
        let side = sideName(for: segment, in: meeting)
        let stateLabel: String
        switch segment.state {
        case .final:
            stateLabel = segment.source == .cloud ? "云端已确认" : "已确认"
        case .edited:
            stateLabel = "人工已修订"
        case .provisional:
            stateLabel = "识别中"
        case .failed:
            stateLabel = "待重试"
        }
        let star = segment.isStarred ? " ★" : ""
        return "- [\(formatMs(segment.startMs))] **\(speaker)\(side)**：\(segment.text)（\(stateLabel)）\(star)"
    }

    private static func speakerName(for segment: TranscriptSegment, in meeting: Meeting) -> String {
        if let id = segment.participantId,
           let participant = meeting.participants.first(where: { $0.id == id }) {
            return participant.displayName
        }
        return "待识别"
    }

    private static func sideName(for segment: TranscriptSegment, in meeting: Meeting) -> String {
        guard let id = segment.participantId,
              let participant = meeting.participants.first(where: { $0.id == id }) else {
            return ""
        }
        return "（\(participant.side.displayName)）"
    }

    private static func formatMs(_ ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func formatDateTime(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }
}
