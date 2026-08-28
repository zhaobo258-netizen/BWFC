import Foundation

enum ProjectExportContent: String, CaseIterable, Identifiable, Sendable {
    case recording
    case transcript
    case liveSummary
    case motives
    case finalReport
    case knowledgeGarden
    case aiCollaboration
    case projectNote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: return "原始录音"
        case .transcript: return "完整转写"
        case .liveSummary: return "实时总结"
        case .motives: return "动机与目的"
        case .finalReport: return "完整总结"
        case .knowledgeGarden: return "开花与知识延展"
        case .aiCollaboration: return "AI 共创记录"
        case .projectNote: return "项目笔记"
        }
    }

    var fileName: String {
        switch self {
        case .recording: return "原始录音"
        case .transcript: return "完整转写.md"
        case .liveSummary: return "实时总结.md"
        case .motives: return "动机与目的.md"
        case .finalReport: return "完整总结.md"
        case .knowledgeGarden: return "开花与知识延展.md"
        case .aiCollaboration: return "AI共创记录.md"
        case .projectNote: return "项目笔记.md"
        }
    }
}

enum ProjectExportError: LocalizedError {
    case emptySelection
    case noAvailableContent

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "请至少选择一项导出内容"
        case .noAvailableContent: return "所选内容当前没有可导出的数据"
        }
    }
}

struct ProjectExportService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func availableContents(project: Project, recordingURL: URL?) -> Set<ProjectExportContent> {
        var result: Set<ProjectExportContent> = []
        if let recordingURL, fileManager.fileExists(atPath: recordingURL.path) {
            result.insert(.recording)
        }
        if project.segments.contains(where: { $0.state == .final || $0.state == .edited }) {
            result.insert(.transcript)
        }
        if let snapshot = latestAnalysis(project),
           snapshot.headline?.isEmpty == false
            || snapshot.items.contains(where: { $0.category.belongsToSummaryTab }) {
            result.insert(.liveSummary)
        }
        if latestAnalysis(project)?.items.contains(where: { !$0.category.belongsToSummaryTab }) == true {
            result.insert(.motives)
        }
        if !project.finalReportSnapshots.isEmpty {
            result.insert(.finalReport)
        }
        if !project.knowledgeSeeds.isEmpty {
            result.insert(.knowledgeGarden)
        }
        if !project.aiChatMessages.isEmpty {
            result.insert(.aiCollaboration)
        }
        if !project.note.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.insert(.projectNote)
        }
        return result
    }

    func export(
        project: Project,
        recordingURL: URL?,
        contents: Set<ProjectExportContent>,
        to parentDirectory: URL,
        now: Date = Date()
    ) throws -> URL {
        guard !contents.isEmpty else { throw ProjectExportError.emptySelection }
        let available = availableContents(project: project, recordingURL: recordingURL)
        let selected = contents.intersection(available)
        guard !selected.isEmpty else { throw ProjectExportError.noAvailableContent }

        let folderName = "\(sanitized(project.title))-导出-\(Self.timestamp(now))"
        let destination = uniqueDestination(parentDirectory.appendingPathComponent(folderName, isDirectory: true))
        let temporary = parentDirectory.appendingPathComponent(".bwfx-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)

        do {
            for content in ProjectExportContent.allCases where selected.contains(content) {
                if content == .recording, let recordingURL {
                    let ext = recordingURL.pathExtension.isEmpty ? "caf" : recordingURL.pathExtension
                    try fileManager.copyItem(
                        at: recordingURL,
                        to: temporary.appendingPathComponent("\(content.fileName).\(ext)")
                    )
                } else if let markdown = markdown(for: content, project: project) {
                    try Data(markdown.utf8).write(
                        to: temporary.appendingPathComponent(content.fileName),
                        options: .atomic
                    )
                }
            }
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func markdown(for content: ProjectExportContent, project: Project) -> String? {
        switch content {
        case .recording:
            return nil
        case .transcript:
            return transcriptMarkdown(project)
        case .liveSummary:
            return analysisMarkdown(project, summaryTab: true)
        case .motives:
            return analysisMarkdown(project, summaryTab: false)
        case .finalReport:
            return finalReportMarkdown(project)
        case .knowledgeGarden:
            return knowledgeMarkdown(project)
        case .aiCollaboration:
            return collaborationMarkdown(project)
        case .projectNote:
            return "# 项目笔记：\(project.title)\n\n\(project.note.markdown)\n"
        }
    }

    private func transcriptMarkdown(_ project: Project) -> String {
        let speakers = Dictionary(uniqueKeysWithValues: project.speakers.map { ($0.id, $0.displayName) })
        let rows = project.segments
            .filter { $0.state == .final || $0.state == .edited }
            .sorted { $0.startMs == $1.startMs ? $0.id.uuidString < $1.id.uuidString : $0.startMs < $1.startMs }
            .map { segment in
                let speaker = segment.participantId.flatMap { speakers[$0] } ?? segment.remoteSpeakerLabel ?? "待识别"
                return "[\(Self.duration(segment.startMs))] **\(speaker)**：\(segment.text)"
            }
        return document(title: "完整转写", project: project, body: rows.joined(separator: "\n\n"))
    }

    private func analysisMarkdown(_ project: Project, summaryTab: Bool) -> String {
        guard let snapshot = latestAnalysis(project) else {
            return document(title: summaryTab ? "实时总结" : "动机与目的", project: project, body: "暂无内容")
        }
        var sections: [String] = []
        if summaryTab, let headline = snapshot.headline, !headline.isEmpty {
            sections.append("## 总览\n\n\(headline)")
        }
        let items = snapshot.items.filter { $0.category.belongsToSummaryTab == summaryTab }
        for category in AnalysisItemCategory.allCases {
            let matching = items.filter { $0.category == category }
            guard !matching.isEmpty else { continue }
            sections.append(
                "## \(category.displayName)\n\n"
                    + matching.map { item in
                        let speaker = speakerName(item.subjectSpeakerId, project: project)
                        let attribution = speaker.map { " · \($0)" } ?? ""
                        return "- \(item.text)（\(item.epistemicStatus.displayName) · 置信度\(item.confidence.displayName)\(attribution)）"
                            + evidenceMarkdown(item.evidenceSegmentIds, project: project)
                    }
                    .joined(separator: "\n")
            )
        }
        return document(
            title: summaryTab ? "实时总结" : "动机与目的",
            project: project,
            body: sections.isEmpty ? "暂无内容" : sections.joined(separator: "\n\n")
        )
    }

    private func finalReportMarkdown(_ project: Project) -> String {
        guard let report = project.finalReportSnapshots.max(by: { $0.version < $1.version }) else {
            return document(title: "完整总结", project: project, body: "暂无内容")
        }
        var sections = ["## \(report.headline)\n\n\(report.overview)"]
        if let collaboration = report.collaborationSummary, !collaboration.isEmpty {
            sections.append("## 我的思考与 AI 共创\n\n\(collaboration)")
        }
        for category in FinalReportItemCategory.allCases {
            let items = report.items.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            sections.append(
                "## \(category.displayName)\n\n"
                    + items.map { item in
                        var details = [item.epistemicStatus.displayName, "置信度\(item.confidence.displayName)"]
                        if let subject = speakerName(item.subjectSpeakerId, project: project) {
                            details.append("相关人：\(subject)")
                        }
                        if let owner = speakerName(item.ownerSpeakerId, project: project) {
                            details.append("负责人：\(owner)")
                        }
                        if let deadline = item.deadlineText, !deadline.isEmpty {
                            details.append("时间：\(deadline)")
                        }
                        return "- \(item.text)（\(details.joined(separator: " · "))）"
                            + evidenceMarkdown(item.evidenceSegmentIds, project: project)
                    }
                    .joined(separator: "\n")
            )
        }
        return document(title: "完整总结（第 \(report.version) 版）", project: project, body: sections.joined(separator: "\n\n"))
    }

    private func knowledgeMarkdown(_ project: Project) -> String {
        let sections = project.knowledgeSeeds.map { seed in
            var lines = ["## \(seed.seedText)", "", seed.whyItMatters]
            for branch in seed.branches {
                lines.append(contentsOf: ["", "### \(branch.type.displayName)：\(branch.title)", "", branch.body])
            }
            if let synthesis = seed.sourceSynthesis {
                lines.append(contentsOf: ["", "### 来源综合", "", synthesis.summary])
            }
            return lines.joined(separator: "\n")
        }
        return document(title: "开花与知识延展", project: project, body: sections.joined(separator: "\n\n"))
    }

    private func collaborationMarkdown(_ project: Project) -> String {
        let rows = project.aiChatMessages.map { message in
            let role = message.role == .user ? "我" : "AI"
            return "## \(role) · \(message.createdAt.formatted(date: .abbreviated, time: .shortened))\n\n\(message.text)"
        }
        return document(title: "AI 共创记录", project: project, body: rows.joined(separator: "\n\n"))
    }

    private func document(title: String, project: Project, body: String) -> String {
        "# \(title)：\(project.title)\n\n导出时间：\(Date().formatted(date: .long, time: .shortened))\n\n\(body)\n"
    }

    private func latestAnalysis(_ project: Project) -> ConversationAnalysisSnapshot? {
        project.analysisSnapshots.max(by: { $0.version < $1.version })
    }

    private func speakerName(_ id: UUID?, project: Project) -> String? {
        guard let id else { return nil }
        return project.speakers.first(where: { $0.id == id })?.displayName
    }

    private func evidenceMarkdown(_ ids: [UUID], project: Project) -> String {
        let segmentByID = Dictionary(uniqueKeysWithValues: project.segments.map { ($0.id, $0) })
        let lines = ids.compactMap { id -> String? in
            guard let segment = segmentByID[id] else { return nil }
            let speaker = speakerName(segment.participantId, project: project)
                ?? segment.remoteSpeakerLabel
                ?? "待识别"
            return "  - 证据 [\(Self.duration(segment.startMs)) \(speaker)]：\(segment.text)"
        }
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }

    private func uniqueDestination(_ proposed: URL) -> URL {
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        return proposed.deletingLastPathComponent().appendingPathComponent(
            "\(proposed.lastPathComponent)-\(UUID().uuidString.prefix(6))",
            isDirectory: true
        )
    }

    private func sanitized(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let parts = value.components(separatedBy: forbidden).filter { !$0.isEmpty }
        let result = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "未命名项目" : String(result.prefix(80))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func duration(_ milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
