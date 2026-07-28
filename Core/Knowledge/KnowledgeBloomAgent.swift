import Foundation

enum KnowledgeBloomExpansionOutcome: Sendable {
    case success(KnowledgeExpansionResult)
    case failure(KnowledgeBloomFailure)
}

enum KnowledgeBloomFailure: Sendable {
    case api(AnalysisAPIError)
    case unavailable
}

struct KnowledgeBloomAgentOutput: Sendable {
    var expansion: KnowledgeBloomExpansionOutcome
    var initialOutcomes: [KnowledgeProviderSearchOutcome]
    var refinedOutcomes: [KnowledgeProviderSearchOutcome]
}

struct KnowledgeBloomAgent: Sendable {
    private let expansionService: any KnowledgeExpansionServicing

    init(expansionService: any KnowledgeExpansionServicing) {
        self.expansionService = expansionService
    }

    func bloom(
        seedText: String,
        whyItMatters: String,
        evidence: [KnowledgeEvidenceInput],
        scenario: ProjectScenario?,
        providers: [any KnowledgeProvider]
    ) async -> KnowledgeBloomAgentOutput {
        async let expansionAttempt = expansion(
            seedText: seedText,
            whyItMatters: whyItMatters,
            evidence: evidence,
            scenario: scenario
        )
        async let initialSearch = KnowledgeProviderSearch.search(
            providers: providers,
            query: seedText
        )

        let expansion = await expansionAttempt
        let initialOutcomes = await initialSearch
        var refinedOutcomes: [KnowledgeProviderSearchOutcome] = []
        if case .success(let result) = expansion,
           let refinedQuery = result.searchQueries.first(where: {
               Self.normalized($0) != Self.normalized(seedText)
           }) {
            refinedOutcomes = await KnowledgeProviderSearch.search(
                providers: providers,
                query: refinedQuery,
                limit: 4
            )
        }
        return KnowledgeBloomAgentOutput(
            expansion: expansion,
            initialOutcomes: initialOutcomes,
            refinedOutcomes: refinedOutcomes
        )
    }

    private func expansion(
        seedText: String,
        whyItMatters: String,
        evidence: [KnowledgeEvidenceInput],
        scenario: ProjectScenario?
    ) async -> KnowledgeBloomExpansionOutcome {
        do {
            return .success(try await expansionService.expand(
                seedText: seedText,
                whyItMatters: whyItMatters,
                evidence: evidence,
                scenario: scenario
            ))
        } catch let error as AnalysisAPIError {
            return .failure(.api(error))
        } catch {
            return .failure(.unavailable)
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }
}
