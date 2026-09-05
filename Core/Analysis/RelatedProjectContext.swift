import Foundation

struct RelatedProjectAIContext: Sendable, Equatable, Encodable {
    var referenceID: String
    var title: String
    var businessCategory: String?
    var scenario: String?
    var backgroundContext: String?
    var latestSummary: String?
    var summaryStatus: String = "unavailable"
    var sourceRevision: String? = nil

    enum CodingKeys: String, CodingKey {
        case title, scenario
        case referenceID = "reference_id"
        case businessCategory = "business_category"
        case backgroundContext = "background_context"
        case latestSummary = "latest_summary"
        case summaryStatus = "summary_status"
        case sourceRevision = "source_revision"
    }
}

enum RelatedProjectContextBuilder {
    static let maximumRelatedProjectCount = 8
    static let maximumTitleCharacters = 200
    static let maximumCategoryCharacters = 100
    static let maximumBackgroundCharacters = 4_000
    static let maximumSummaryCharacters = 6_000

    static func make(
        for project: Project,
        from candidates: [Project]
    ) -> [RelatedProjectAIContext] {
        let byID = Dictionary(
            candidates
                .filter { $0.id != project.id }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<UUID>()
        return project.relatedProjectIDs
            .filter { seen.insert($0).inserted }
            .prefix(maximumRelatedProjectCount)
            .enumerated()
            .compactMap { index, id in
                guard let related = byID[id] else { return nil }
                return RelatedProjectAIContext(
                    referenceID: "related_\(index + 1)",
                    title: bounded(
                        related.title,
                        maximum: maximumTitleCharacters
                    ) ?? "未命名项目",
                    businessCategory: bounded(
                        related.businessCategory,
                        maximum: maximumCategoryCharacters
                    ),
                    scenario: related.scenario.map {
                        ConversationAnalysisTaxonomy.wireName(for: $0)
                    },
                    backgroundContext: bounded(
                        related.projectBackgroundContext,
                        maximum: maximumBackgroundCharacters
                    ),
                    latestSummary: latestSummary(for: related),
                    summaryStatus: summaryStatus(for: related),
                    sourceRevision: related.finalReportSnapshots.max { $0.version < $1.version }
                        .map { "report_v\($0.version):\($0.inputFingerprint)" }
                )
            }
    }

    static func normalizedCurrentBackground(_ value: String?) -> String? {
        bounded(value, maximum: maximumBackgroundCharacters)
    }

    private static func latestSummary(for project: Project) -> String? {
        if let report = project.finalReportSnapshots.max(by: {
            $0.version < $1.version
        }) {
            guard !FinalReportFingerprint.isStale(report, for: project) else { return nil }
            return bounded(
                [report.headline, report.overview]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n"),
                maximum: maximumSummaryCharacters
            )
        }
        guard let analysis = project.analysisSnapshots.max(by: {
            $0.version < $1.version
        }) else { return nil }
        let itemLines = analysis.items.prefix(12).map {
            "\(ConversationAnalysisTaxonomy.wireName(for: $0.category)): \($0.text)"
        }
        return bounded(
            ([analysis.headline].compactMap { $0 } + itemLines)
                .joined(separator: "\n"),
            maximum: maximumSummaryCharacters
        )
    }

    private static func summaryStatus(for project: Project) -> String {
        if let report = project.finalReportSnapshots.max(by: { $0.version < $1.version }) {
            return FinalReportFingerprint.isStale(report, for: project)
                ? "stale_summary_omitted" : "current_local_inputs"
        }
        return project.analysisSnapshots.isEmpty ? "unavailable" : "analysis_only_unverified"
    }

    private static func bounded(
        _ value: String?,
        maximum: Int
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximum))
    }
}
