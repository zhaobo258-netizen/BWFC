import CryptoKit
import Foundation

enum FinalReportItemCategory: String, Codable, Sendable, CaseIterable {
    case topic
    case chapter
    case fact
    case decision
    case actionItem
    case motiveConcern
    case riskDisagreement
    case openQuestion
    case keyQuote

    var displayName: String {
        switch self {
        case .topic: return "核心议题"
        case .chapter: return "章节概要"
        case .fact: return "关键事实"
        case .decision: return "决定与结论"
        case .actionItem: return "行动项"
        case .motiveConcern: return "动机与顾虑"
        case .riskDisagreement: return "分歧与风险"
        case .openQuestion: return "未决问题"
        case .keyQuote: return "关键原话"
        }
    }
}

struct FinalReportItem: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var category: FinalReportItemCategory
    var text: String
    var subjectSpeakerId: UUID?
    var ownerSpeakerId: UUID?
    var deadlineText: String?
    var epistemicStatus: EpistemicStatus
    var confidence: Confidence
    var evidenceSegmentIds: [UUID]

    init(
        id: UUID = UUID(),
        category: FinalReportItemCategory,
        text: String,
        subjectSpeakerId: UUID? = nil,
        ownerSpeakerId: UUID? = nil,
        deadlineText: String? = nil,
        epistemicStatus: EpistemicStatus,
        confidence: Confidence,
        evidenceSegmentIds: [UUID]
    ) {
        self.id = id
        self.category = category
        self.text = text
        self.subjectSpeakerId = subjectSpeakerId
        self.ownerSpeakerId = ownerSpeakerId
        self.deadlineText = deadlineText
        self.epistemicStatus = epistemicStatus
        self.confidence = confidence
        self.evidenceSegmentIds = evidenceSegmentIds
    }
}

struct FinalReportSnapshot: Identifiable, Codable, Sendable {
    let id: UUID
    let version: Int
    let generatedAt: Date
    let providerID: String
    let providerName: String
    let modelID: String
    let promptVersion: String
    let inputFingerprint: String
    let headline: String
    let overview: String
    let collaborationSummary: String?
    let items: [FinalReportItem]
    var markdownHash: String?

    init(
        id: UUID = UUID(),
        version: Int,
        generatedAt: Date = Date(),
        providerID: String,
        providerName: String,
        modelID: String,
        promptVersion: String,
        inputFingerprint: String,
        headline: String,
        overview: String,
        collaborationSummary: String? = nil,
        items: [FinalReportItem],
        markdownHash: String? = nil
    ) {
        self.id = id
        self.version = version
        self.generatedAt = generatedAt
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.promptVersion = promptVersion
        self.inputFingerprint = inputFingerprint
        self.headline = headline
        self.overview = overview
        self.collaborationSummary = collaborationSummary
        self.items = items
        self.markdownHash = markdownHash
    }
}

enum FinalReportSnapshotRetention {
    static let maximumCount = 3

    static func keepingMostRecent(
        _ snapshots: [FinalReportSnapshot]
    ) -> [FinalReportSnapshot] {
        Array(
            snapshots.sorted {
                if $0.version != $1.version {
                    return $0.version < $1.version
                }
                return $0.generatedAt < $1.generatedAt
            }
            .suffix(maximumCount)
        )
    }
}

enum FinalReportFingerprint {
    static func make(for project: Project, relatedProjects: [Project] = []) -> String {
        let local = localFingerprint(for: project)
        guard !project.relatedProjectIDs.isEmpty else { return local }
        let byID = Dictionary(relatedProjects.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let dependencies = project.relatedProjectIDs.map { id -> String in
            guard let related = byID[id] else { return id.uuidString + "|unavailable" }
            let report = related.finalReportSnapshots.max { $0.version < $1.version }
            let analysis = related.analysisSnapshots.max { $0.version < $1.version }
            return [
                id.uuidString, related.title, related.businessCategory ?? "",
                localFingerprint(for: related),
                report.map { "\($0.version)|\($0.inputFingerprint)|\($0.headline)|\($0.overview)" }
                    ?? analysis.map { snapshot in
                        "analysis:\(snapshot.version)|\(snapshot.headline ?? "")|"
                            + snapshot.items.map(\.text).joined(separator: "\u{1F}")
                    } ?? "no_summary"
            ].joined(separator: "\u{1F}")
        }
        let relatedHash = SHA256.hash(data: Data(dependencies.joined(separator: "\u{1E}").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return local + "." + relatedHash
    }

    private static func localFingerprint(for project: Project) -> String {
        var lines: [String] = [
            project.scenario.map(ConversationAnalysisTaxonomy.wireName(for:)) ?? "auto",
            project.scenarioWasUserSelected ? "user" : "automatic",
            project.businessCategory ?? "",
            project.projectBackgroundContext ?? "",
            project.relatedProjectIDs.map(\.uuidString).joined(separator: ",")
        ]
        lines.append(contentsOf: project.speakers
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                [
                    $0.id.uuidString,
                    $0.cloudAlias,
                    $0.displayName,
                    $0.role ?? "",
                    $0.backgroundContext ?? "",
                    $0.communicationProfile?.summary ?? "",
                    $0.isCurrentUser == true ? "current_user" : "other_person"
                ].joined(separator: "\u{1F}")
            })
        lines.append(contentsOf: project.segments
            .filter { $0.state == .final || $0.state == .edited }
            .sorted {
                $0.startMs == $1.startMs
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.startMs < $1.startMs
            }
            .map {
                [
                    $0.id.uuidString,
                    String($0.startMs),
                    String($0.endMs),
                    $0.participantId?.uuidString ?? "",
                    $0.state.rawValue,
                    $0.text
                ].joined(separator: "\u{1F}")
            })
        lines.append(
            project.noteAIContextEnabled
                ? "legacy_note_enabled"
                : "legacy_note_disabled"
        )
        if project.noteAIContextEnabled {
            lines.append("legacy_note\u{1F}\(project.note.markdown)")
        }
        lines.append(contentsOf: project.aiChatMessages.map { message in
            [
                message.id.uuidString,
                message.role.rawValue,
                message.text,
                message.attachments.map(\.fileName).joined(separator: "\u{1D}")
            ].joined(separator: "\u{1F}")
        })
        return SHA256.hash(data: Data(lines.joined(separator: "\u{1E}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isStale(
        _ report: FinalReportSnapshot,
        for project: Project,
        relatedProjects: [Project]? = nil
    ) -> Bool {
        if let relatedProjects {
            return report.inputFingerprint != make(for: project, relatedProjects: relatedProjects)
        }
        return report.inputFingerprint.split(separator: ".").first.map(String.init)
            != localFingerprint(for: project)
    }
}
