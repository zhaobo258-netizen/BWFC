import Foundation

struct KnowledgeProviderSearchOutcome: Sendable {
    var kind: KnowledgeProviderKind
    var providerID: String
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
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }
        return await withTaskGroup(of: KnowledgeProviderSearchOutcome.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let connections = try await provider.search(
                            normalizedQuery,
                            limit: limit
                        ).map { connection in
                            var connection = connection
                            connection.providerId = provider.providerID
                            return connection
                        }
                        return KnowledgeProviderSearchOutcome(
                            kind: provider.kind,
                            providerID: provider.providerID,
                            displayName: provider.displayName,
                            connections: connections,
                            errorMessage: nil
                        )
                    } catch {
                        return KnowledgeProviderSearchOutcome(
                            kind: provider.kind,
                            providerID: provider.providerID,
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
    private let automaticallyBloomNewSeeds: Bool
    private weak var project: Project?

    private(set) var seeds: [KnowledgeSeed] = []
    private(set) var selectedSeedID: UUID?
    private(set) var state: State = .idle
    private(set) var providerMessages: [String: String] = [:]
    private(set) var providerDisplayNames: [String: String] = [:]
    private(set) var expansionMessage: String?
    private(set) var sourceSynthesisMessage: String?
    var onUpdated: (() -> Void)?
    var noteContextProvider: () -> String? = { nil }
    private var automaticBloomTask: Task<Void, Never>?
    private var pendingAutomaticBloomIDs: [UUID] = []
    private var automaticallyAttemptedSeedIDs = Set<UUID>()

    init(
        expansionService: any KnowledgeExpansionServicing,
        providerFactory: @escaping () -> [any KnowledgeProvider],
        automaticallyBloomNewSeeds: Bool = false
    ) {
        self.expansionService = expansionService
        self.providerFactory = providerFactory
        self.automaticallyBloomNewSeeds = automaticallyBloomNewSeeds
    }

    var selectedSeed: KnowledgeSeed? {
        guard let selectedSeedID else { return seeds.first }
        return seeds.first { $0.id == selectedSeedID }
    }

    func attach(to project: Project) {
        automaticBloomTask?.cancel()
        automaticBloomTask = nil
        pendingAutomaticBloomIDs = []
        automaticallyAttemptedSeedIDs = Set(project.knowledgeSeeds.compactMap {
            Self.needsBloom($0) ? nil : $0.id
        })
        self.project = project
        state = .idle
        refreshCandidates(scheduleAutomatic: false)
    }

    /// 种子数量上限（超限时只裁剪可丢弃的候选，绝不丢用户已收藏/已开花/选中的种子）
    static let maxSeeds = 12

    func refreshCandidates(scheduleAutomatic: Bool = true) {
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
                    && seed.sourceSynthesis == nil
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
        let previousIDSet = Set(previousIDs)
        if scheduleAutomatic { scheduleAutomaticBloom(
            preferredIDs: merged.compactMap {
                previousIDSet.contains($0.id) ? nil : $0.id
            }
        ) }
    }

    func selectSeed(_ id: UUID) {
        guard seeds.contains(where: { $0.id == id }) else { return }
        guard id != selectedSeedID else { return }
        selectedSeedID = id
        // 状态消息属于上一个种子的开花过程，切换后清空，避免张冠李戴
        providerMessages = [:]
        providerDisplayNames = [:]
        expansionMessage = nil
        sourceSynthesisMessage = nil
    }

    func bloomIfNeeded() async {
        guard let seed = selectedSeed,
              Self.needsBloom(seed) else {
            return
        }
        await bloomSelected()
    }

    func bloomSelected() async {
        guard let selectedSeedID else {
            return
        }
        await bloom(seedID: selectedSeedID)
    }

    private func bloom(seedID: UUID) async {
        guard state != .expanding,
              let project,
              let seed = seeds.first(where: { $0.id == seedID }) else {
            return
        }
        state = .expanding
        if seedID == selectedSeedID {
            providerMessages = [:]
            providerDisplayNames = [:]
            expansionMessage = nil
            sourceSynthesisMessage = nil
        }

        let providers = providerFactory()
        let output = await KnowledgeBloomAgent(
            expansionService: expansionService
        ).bloom(
            seedText: seed.seedText,
            whyItMatters: seed.whyItMatters,
            evidence: Self.evidence(for: seed, in: project),
            scenario: project.scenario,
            userContext: ProjectAIUserContext.statements(
                from: project.aiChatMessages
            ),
            noteMarkdown: project.noteAIContextEnabled
                ? noteContextProvider()
                : nil,
            providers: providers
        )
        guard self.project === project, !Task.isCancelled else { return }
        apply(
            outcomes: output.initialOutcomes,
            to: seedID,
            replacing: true
        )

        switch output.expansion {
        case .success(let result):
            updateSeed(id: seedID) { stored in
                stored.branches = result.branches
                stored.searchQueries = result.searchQueries
                stored.updatedAt = Date()
            }
            if self.selectedSeedID == seedID {
                expansionMessage = result.branches.isEmpty ? "AI 暂未生成有效联想" : nil
            }
        case .failure(let failure):
            if self.selectedSeedID == seedID {
                expansionMessage = Self.expansionFailureMessage(failure)
            }
        }

        if !output.refinedOutcomes.isEmpty {
            apply(
                outcomes: output.refinedOutcomes,
                to: seedID,
                replacing: false
            )
        }
        if let synthesis = output.sourceSynthesis {
            updateSeed(id: seedID) {
                $0.sourceSynthesis = synthesis
                $0.updatedAt = Date()
            }
        } else if output.sourceSynthesisFailure != nil,
                  selectedSeedID == seedID {
            sourceSynthesisMessage = "已找到来源，但 AI 速览暂时生成失败；原始资料仍可查看"
        }
        state = .finished
    }

    private func scheduleAutomaticBloom(preferredIDs: [UUID]) {
        guard automaticallyBloomNewSeeds else { return }
        let orderedIDs = preferredIDs
        guard let candidateID = orderedIDs.first(where: { id in
            !automaticallyAttemptedSeedIDs.contains(id)
                && seeds.first(where: { $0.id == id }).map(Self.needsBloom) == true
        }) else {
            return
        }
        automaticallyAttemptedSeedIDs.insert(candidateID)
        if !pendingAutomaticBloomIDs.contains(candidateID) {
            pendingAutomaticBloomIDs.append(candidateID)
        }
        guard automaticBloomTask == nil else { return }
        automaticBloomTask = Task { [weak self] in
            await self?.drainAutomaticBloomQueue()
        }
    }

    private func drainAutomaticBloomQueue() async {
        while !Task.isCancelled, !pendingAutomaticBloomIDs.isEmpty {
            let seedID = pendingAutomaticBloomIDs.removeFirst()
            await bloom(seedID: seedID)
        }
        automaticBloomTask = nil
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
            if replacing {
                seed.sourceSynthesis = nil
            }
            var seen = Set(merged.map { "\($0.stableProviderID)|\($0.sourceId)" })
            for connection in incoming {
                let key = "\(connection.stableProviderID)|\(connection.sourceId)"
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
            providerDisplayNames[outcome.providerID] = outcome.displayName
            if let errorMessage = outcome.errorMessage {
                providerMessages[outcome.providerID] = "\(outcome.displayName)：\(errorMessage)"
            } else if mergedConnections.contains(where: {
                $0.stableProviderID == outcome.providerID
            }) {
                providerMessages[outcome.providerID] = nil
            } else {
                providerMessages[outcome.providerID] = "\(outcome.displayName)：没有找到相关内容"
            }
        }
    }

    func providerIDs(for seed: KnowledgeSeed) -> [String] {
        let ids = Set(seed.connections.map(\.stableProviderID))
            .union(providerMessages.keys)
        return ids.sorted { lhs, rhs in
            let leftRank = Self.providerRank(lhs)
            let rightRank = Self.providerRank(rhs)
            if leftRank != rightRank { return leftRank < rightRank }
            return (providerDisplayNames[lhs] ?? lhs)
                .localizedStandardCompare(providerDisplayNames[rhs] ?? rhs) == .orderedAscending
        }
    }

    func providerDisplayName(for id: String, in seed: KnowledgeSeed) -> String {
        providerDisplayNames[id]
            ?? seed.connections.first(where: { $0.stableProviderID == id })?.providerName
            ?? id
    }

    private static func providerRank(_ id: String) -> Int {
        if id == "obsidian" { return 0 }
        if id.hasPrefix("internet") { return 1 }
        return 2
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
        let existingSegmentIDs = Set(project.segments.map(\.id))
        var candidates: [KnowledgeSeed] = []
        var seen = Set<String>()
        if let snapshot {
            for category in preferred {
                for item in snapshot.items where item.category == category {
                    let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = normalized(text)
                    guard !item.evidenceSegmentIds.isEmpty,
                          item.evidenceSegmentIds.allSatisfy(existingSegmentIDs.contains),
                          text.count >= 4,
                          seen.insert(key).inserted else {
                        continue
                    }
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

    private static func needsBloom(_ seed: KnowledgeSeed) -> Bool {
        if seed.branches.isEmpty && seed.connections.isEmpty {
            return true
        }
        return !seed.connections.isEmpty && seed.sourceSynthesis == nil
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func expansionFailureMessage(
        _ failure: KnowledgeBloomFailure
    ) -> String {
        if case .api(let apiError) = failure {
            switch apiError {
            case .missingAPIKey: return "AI 联想未启用；连接分析模型后可生成概念与跨领域连接"
            case .credentialAccessRequired:
                return "App 更新后需要重新连接 AI；知识来源检索仍可使用"
            case .unauthorized: return "AI 凭证已失效；知识来源检索仍可使用"
            case .timeout: return "AI 联想超时；知识来源检索仍可使用"
            default: return "AI 联想暂不可用；知识来源检索仍可使用"
            }
        }
        return "AI 联想暂不可用；知识来源检索仍可使用"
    }
}
