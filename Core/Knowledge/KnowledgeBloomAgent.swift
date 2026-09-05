import Foundation

enum KnowledgeBloomExpansionOutcome: Sendable {
    case success(KnowledgeExpansionResult)
    case failure(KnowledgeBloomFailure)
}

enum KnowledgeBloomFailure: Error, Sendable {
    case api(AnalysisAPIError)
    case unavailable
}

enum KnowledgeBloomProgress: Sendable {
    case expansion(KnowledgeBloomExpansionOutcome)
    case sources([KnowledgeProviderSearchOutcome])
}

struct KnowledgeBloomAgentOutput: Sendable {
    var expansion: KnowledgeBloomExpansionOutcome
    var initialOutcomes: [KnowledgeProviderSearchOutcome]
    var refinedOutcomes: [KnowledgeProviderSearchOutcome]
    var sourceSynthesis: KnowledgeSourceSynthesis?
    var sourceSynthesisFailure: KnowledgeBloomFailure?
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
        userContext: [String],
        noteMarkdown: String?,
        providers: [any KnowledgeProvider],
        onProgress: @Sendable (KnowledgeBloomProgress) async -> Void = { _ in }
    ) async -> KnowledgeBloomAgentOutput {
        async let expansionAttempt = expansion(
            seedText: seedText,
            whyItMatters: whyItMatters,
            evidence: evidence,
            scenario: scenario,
            userContext: userContext,
            noteMarkdown: noteMarkdown
        )
        async let initialSearch: [KnowledgeProviderSearchOutcome] = {
            let outcomes = await KnowledgeProviderSearch.search(
                providers: providers.filter { $0.kind == .obsidian }, query: seedText
            )
            if !Task.isCancelled { await onProgress(.sources(outcomes)) }
            return outcomes
        }()

        let expansion = await expansionAttempt
        if !Task.isCancelled { await onProgress(.expansion(expansion)) }
        let initialOutcomes = await initialSearch
        var refinedOutcomes: [KnowledgeProviderSearchOutcome] = []
        if case .success(let result) = expansion {
            let sourceTexts = evidence.map(\.text) + userContext
                + [noteMarkdown].compactMap { $0 }
            var seen = Set<String>()
            let queries = result.searchQueries.compactMap {
                KnowledgeSearchQueryPolicy.keywords($0, excluding: sourceTexts)
            }.filter { seen.insert(Self.normalized($0)).inserted }.prefix(2)
            for query in queries {
                guard !Task.isCancelled else { break }
                let outcomes = await KnowledgeProviderSearch.search(
                    providers: providers, query: query, limit: 4
                )
                refinedOutcomes += outcomes
                if !Task.isCancelled { await onProgress(.sources(outcomes)) }
            }
        }
        let sources = Self.sourceInputs(
            from: initialOutcomes + refinedOutcomes
        )
        let synthesisResult = await sourceSynthesis(
            seedText: seedText,
            whyItMatters: whyItMatters,
            sources: sources
        )
        return KnowledgeBloomAgentOutput(
            expansion: expansion,
            initialOutcomes: initialOutcomes,
            refinedOutcomes: refinedOutcomes,
            sourceSynthesis: synthesisResult.value,
            sourceSynthesisFailure: synthesisResult.failure
        )
    }

    private func expansion(
        seedText: String,
        whyItMatters: String,
        evidence: [KnowledgeEvidenceInput],
        scenario: ProjectScenario?,
        userContext: [String],
        noteMarkdown: String?
    ) async -> KnowledgeBloomExpansionOutcome {
        do {
            return .success(try await expansionService.expand(
                seedText: seedText,
                whyItMatters: whyItMatters,
                evidence: evidence,
                scenario: scenario,
                userContext: userContext,
                noteMarkdown: noteMarkdown
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

    private func sourceSynthesis(
        seedText: String,
        whyItMatters: String,
        sources: [KnowledgeSourceInput]
    ) async -> (value: KnowledgeSourceSynthesis?, failure: KnowledgeBloomFailure?) {
        guard !sources.isEmpty, !Task.isCancelled else { return (nil, nil) }
        do {
            return (
                try await expansionService.synthesizeSources(
                    seedText: seedText,
                    whyItMatters: whyItMatters,
                    sources: sources
                ),
                nil
            )
        } catch let error as AnalysisAPIError {
            return (nil, .api(error))
        } catch {
            return (nil, .unavailable)
        }
    }

    private static func sourceInputs(
        from outcomes: [KnowledgeProviderSearchOutcome]
    ) -> [KnowledgeSourceInput] {
        var seen = Set<String>()
        return outcomes
            .flatMap(\.connections)
            .compactMap { connection -> KnowledgeSourceInput? in
                let id = "\(connection.stableProviderID)|\(connection.sourceId)"
                guard seen.insert(id).inserted else { return nil }
                return KnowledgeSourceInput(
                    id: id,
                    providerName: connection.providerName,
                    title: String(connection.title.prefix(300)),
                    excerpt: String(connection.excerpt.prefix(1_200))
                )
            }
            .prefix(8)
            .map { $0 }
    }
}
