import Foundation

struct KnowledgeProviderSearchOutcome: Sendable {
    var kind: KnowledgeProviderKind
    var displayName: String
    var connections: [KnowledgeConnection]
    var errorMessage: String?
}

enum KnowledgeProviderSearch {
    static func search(
        providers: [any KnowledgeProvider],
        query: String,
        limit: Int = 5
    ) async -> [KnowledgeProviderSearchOutcome] {
        await withTaskGroup(of: KnowledgeProviderSearchOutcome.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return KnowledgeProviderSearchOutcome(
                            kind: provider.kind,
                            displayName: provider.displayName,
                            connections: try await provider.search(query, limit: limit),
                            errorMessage: nil
                        )
                    } catch {
                        return KnowledgeProviderSearchOutcome(
                            kind: provider.kind,
                            displayName: provider.displayName,
                            connections: [],
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }
            var outcomes: [KnowledgeProviderSearchOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }
}

@MainActor
@Observable
final class KnowledgeGardenController {
    enum State: Equatable {
        case idle
        case expanding
        case finished
    }

    private let expansionService: any KnowledgeExpansionServicing
    private let providerFactory: () -> [any KnowledgeProvider]
    private weak var project: Project?

    private(set) var seeds: [KnowledgeSeed] = []
    private(set) var selectedSeedID: UUID?
    private(set) var state: State = .idle
    private(set) var providerMessages: [KnowledgeProviderKind: String] = [:]
    private(set) var expansionMessage: String?
    var onUpdated: (() -> Void)?

    init(
        expansionService: any KnowledgeExpansionServicing,
        providerFactory: @escaping () -> [any KnowledgeProvider]
    ) {
        self.expansionService = expansionService
        self.providerFactory = providerFactory
    }

    var selectedSeed: KnowledgeSeed? {
        guard let selectedSeedID else { return seeds.first }
        return seeds.first { $0.id == selectedSeedID }
    }

    func attach(to project: Project) {
        self.project = project
        refreshCandidates()
    }

    /// 种子数量上限（超限时只裁剪可丢弃的候选，绝不丢用户已收藏/已开花/选中的种子）
    static let maxSeeds = 12

    func refreshCandidates() {
        guard let project else { return }
        let previousIDs = project.knowledgeSeeds.map(\.id)
        var merged = project.knowledgeSeeds
        let existingKeys = Set(merged.map(Self.identityKey))
        var seen = existingKeys
        for candidate in Self.makeCandidates(from: project) {
            let key = Self.identityKey(candidate)
            if seen.insert(key).inserted {
                merged.append(candidate)
            }
        }
        if merged.count > Self.maxSeeds {
            // 从最旧的开始，只丢「未收藏、无开花成果、非当前选中」的候选；
            // 全部受保护时宁可超限，也不丢用户成果（收藏与开花结果已持久化）。
            var overflow = merged.count - Self.maxSeeds
            let protectedID = selectedSeedID
            merged.removeAll { seed in
                guard overflow > 0 else { return false }
                let disposable = !seed.isAddedToProject
                    && seed.branches.isEmpty
                    && seed.connections.isEmpty
                    && seed.id != protectedID
                if disposable {
                    overflow -= 1
                    return true
                }
                return false
            }
        }
        project.knowledgeSeeds = merged
        seeds = merged
        if selectedSeedID.flatMap({ id in merged.first(where: { $0.id == id }) }) == nil {
            selectedSeedID = merged.first?.id
        }
        if merged.map(\.id) != previousIDs {
            onUpdated?()
        }
    }

    func selectSeed(_ id: UUID) {
        guard seeds.contains(where: { $0.id == id }) else { return }
        guard id != selectedSeedID else { return }
        selectedSeedID = id
        // 状态消息属于上一个种子的开花过程，切换后清空，避免张冠李戴
        providerMessages = [:]
        expansionMessage = nil
    }

    func bloomIfNeeded() async {
        guard let seed = selectedSeed,
              seed.branches.isEmpty && seed.connections.isEmpty else {
            return
        }
        await bloomSelected()
    }

    func bloomSelected() async {
        guard state != .expanding,
              let project,
              let selectedSeedID,
              let seed = seeds.first(where: { $0.id == selectedSeedID }) else {
            return
        }
        state = .expanding
        providerMessages = [:]
        expansionMessage = nil

        let evidence = Self.evidence(for: seed, in: project)
        let scenario = project.scenario
        let expansionService = self.expansionService
        async let expansionAttempt: Result<KnowledgeExpansionResult, Error> = {
            do {
                return .success(try await expansionService.expand(
                    seedText: seed.seedText,
                    whyItMatters: seed.whyItMatters,
                    evidence: evidence,
                    scenario: scenario
                ))
            } catch {
                return .failure(error)
            }
        }()

        let providers = providerFactory()
        let initialOutcomes = await KnowledgeProviderSearch.search(
            providers: providers,
            query: seed.seedText
        )
        apply(outcomes: initialOutcomes, to: selectedSeedID, replacing: true)

        let expansion = await expansionAttempt
        var refinedQuery: String?
        switch expansion {
        case .success(let result):
            updateSeed(id: selectedSeedID) { stored in
                stored.branches = result.branches
                stored.searchQueries = result.searchQueries
                stored.updatedAt = Date()
            }
            refinedQuery = result.searchQueries.first(where: {
                Self.normalized($0) != Self.normalized(seed.seedText)
            })
            if self.selectedSeedID == selectedSeedID {
                expansionMessage = result.branches.isEmpty ? "AI 暂未生成有效联想" : nil
            }
        case .failure(let error):
            if self.selectedSeedID == selectedSeedID {
                expansionMessage = Self.expansionFailureMessage(error)
            }
        }

        if let refinedQuery {
            let refinedOutcomes = await KnowledgeProviderSearch.search(
                providers: providers,
                query: refinedQuery,
                limit: 4
            )
            apply(outcomes: refinedOutcomes, to: selectedSeedID, replacing: false)
        }
        state = .finished
    }

    func setAddedToProject(_ added: Bool) {
        guard let selectedSeedID else { return }
        updateSeed(id: selectedSeedID) {
            $0.isAddedToProject = added
            $0.updatedAt = Date()
        }
    }

    private func apply(
        outcomes: [KnowledgeProviderSearchOutcome],
        to seedID: UUID,
        replacing: Bool
    ) {
        let incoming = outcomes.flatMap(\.connections)
        updateSeed(id: seedID) { seed in
            var merged = replacing ? [] : seed.connections
            var seen = Set(merged.map { "\($0.provider.rawValue)|\($0.sourceId)" })
            for connection in incoming {
                let key = "\(connection.provider.rawValue)|\(connection.sourceId)"
                if seen.insert(key).inserted {
                    merged.append(connection)
                }
            }
            seed.connections = merged.sorted {
                if $0.provider != $1.provider {
                    return $0.provider.rawValue < $1.provider.rawValue
                }
                return ($0.relevance ?? 0) > ($1.relevance ?? 0)
            }
            seed.updatedAt = Date()
        }
        // 状态消息只描述当前选中的种子；且「没有找到相关内容」必须以合并后的
        // 真实结果为准——refined 检索空手而归时不得掩盖初次检索的成功结果。
        guard seedID == selectedSeedID else { return }
        let mergedConnections = seeds.first(where: { $0.id == seedID })?.connections ?? []
        for outcome in outcomes {
            if let errorMessage = outcome.errorMessage {
                providerMessages[outcome.kind] = "\(outcome.displayName)：\(errorMessage)"
            } else if mergedConnections.contains(where: { $0.provider == outcome.kind }) {
                providerMessages[outcome.kind] = nil
            } else {
                providerMessages[outcome.kind] = "\(outcome.displayName)：没有找到相关内容"
            }
        }
    }

    private func updateSeed(id: UUID, change: (inout KnowledgeSeed) -> Void) {
        guard let project,
              let index = project.knowledgeSeeds.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&project.knowledgeSeeds[index])
        seeds = project.knowledgeSeeds
        onUpdated?()
    }

    private static func makeCandidates(from project: Project) -> [KnowledgeSeed] {
        let snapshot = project.analysisSnapshots.max(by: { $0.version < $1.version })
        let preferred: [AnalysisItemCategory] = [
            .knowledgeSeed, .concept, .topic, .fact, .possibleConcern,
            .openQuestion, .factCheck
        ]
        var candidates: [KnowledgeSeed] = []
        var seen = Set<String>()
        if let snapshot {
            for category in preferred {
                for item in snapshot.items where item.category == category {
                    let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = normalized(text)
                    guard text.count >= 4, seen.insert(key).inserted else { continue }
                    candidates.append(KnowledgeSeed(
                        seedText: text,
                        whyItMatters: "来自“\(category.displayName)”的讨论线索",
                        evidenceSegmentIds: item.evidenceSegmentIds
                    ))
                    if candidates.count == 3 { return candidates }
                }
            }
        }
        let fallbackSegments = project.segments
            .filter { ($0.state == .final || $0.state == .edited) && $0.text.count >= 12 }
            .sorted {
                if $0.isStarred != $1.isStarred { return $0.isStarred && !$1.isStarred }
                return $0.startMs > $1.startMs
            }
        for segment in fallbackSegments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(text)
            guard seen.insert(key).inserted else { continue }
            candidates.append(KnowledgeSeed(
                seedText: String(text.prefix(160)),
                whyItMatters: segment.isStarred ? "来自已标记原话" : "来自讨论原话",
                evidenceSegmentIds: [segment.id]
            ))
            if candidates.count == 3 { break }
        }
        return candidates
    }

    private static func evidence(
        for seed: KnowledgeSeed,
        in project: Project
    ) -> [KnowledgeEvidenceInput] {
        let byID = Dictionary(
            project.segments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return seed.evidenceSegmentIds.prefix(3).compactMap { id in
            guard let segment = byID[id] else { return nil }
            return KnowledgeEvidenceInput(
                segmentId: id,
                text: String(segment.text.prefix(1_000))
            )
        }
    }

    private static func identityKey(_ seed: KnowledgeSeed) -> String {
        normalized(seed.seedText) + "|" + seed.evidenceSegmentIds.map(\.uuidString).joined(separator: ",")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func expansionFailureMessage(_ error: Error) -> String {
        if let apiError = error as? AnalysisAPIError {
            switch apiError {
            case .missingAPIKey: return "AI 联想未启用；登录 Kimi 后可生成概念与跨领域连接"
            case .unauthorized: return "Kimi 登录已失效；知识来源检索仍可使用"
            case .timeout: return "AI 联想超时；知识来源检索仍可使用"
            default: return "AI 联想暂不可用；知识来源检索仍可使用"
            }
        }
        return "AI 联想暂不可用；知识来源检索仍可使用"
    }
}
