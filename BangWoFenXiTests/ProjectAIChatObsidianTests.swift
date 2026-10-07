import Foundation
import Testing
@testable import BangWoFenXi

private actor ObsidianChatGenerationRecorder: AITextGenerationServing {
    private var requests: [AITextGenerationRequest] = []
    private let failFirst: Bool
    private let responseText: String

    init(
        failFirst: Bool = false,
        responseText: String = #"{"reply":"已结合合成历史资料回答。","source_ids":["obsidian_1"]}"#
    ) {
        self.failFirst = failFirst
        self.responseText = responseText
    }

    func generate(_ request: AITextGenerationRequest) async throws -> AITextGenerationResponse {
        requests.append(request)
        if failFirst && requests.count == 1 { throw AnalysisAPIError.timeout }
        return AITextGenerationResponse(text: responseText, provider: Self.descriptor)
    }

    func testActiveConnection() async throws -> AIProviderDescriptor { Self.descriptor }
    func capturedRequests() -> [AITextGenerationRequest] { requests }

    private static var descriptor: AIProviderDescriptor {
        AIProviderDescriptor(id: "synthetic", displayName: "合成测试模型", modelID: "offline-test")
    }
}

private actor ObsidianChatProviderRecorder: KnowledgeProvider {
    nonisolated let kind: KnowledgeProviderKind
    nonisolated let providerID = "synthetic-knowledge"
    nonisolated let displayName = "合成资料提供方"
    private let results: [KnowledgeConnection]
    private let failure: KnowledgeProviderError?
    private var queries: [String] = []

    init(
        kind: KnowledgeProviderKind = .obsidian,
        results: [KnowledgeConnection] = [],
        failure: KnowledgeProviderError? = nil
    ) {
        self.kind = kind
        self.results = results
        self.failure = failure
    }

    func healthCheck() async -> KnowledgeProviderHealth {
        KnowledgeProviderHealth(isAvailable: failure == nil, message: "合成状态")
    }

    func search(_ query: String, limit: Int) async throws -> [KnowledgeConnection] {
        queries.append(query)
        if let failure { throw failure }
        // 故意不替被测服务执行 limit，让测试验证外部结果仍有边界。
        return results
    }

    func capturedQueries() -> [String] { queries }
}

private enum ObsidianChatSyntheticError: Error {
    case persistenceFailed
}

private actor ObsidianChatSuspendedPreparation: ProjectAIChatServing {
    private var preparationCount = 0
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var replies: [ProjectAIChatRequest] = []

    func prepare(_ request: ProjectAIChatRequest) async throws -> ProjectAIChatRequest {
        preparationCount += 1
        let call = preparationCount
        // 模拟不能及时响应取消的本地读取：取消后仍可能返回旧结果。
        await withCheckedContinuation { waiting[call] = $0 }
        var prepared = request
        prepared.obsidianSources = [ProjectAIChatSource(
            id: "obsidian_1", providerName: "Obsidian", title: "合成操作 \(call)",
            excerpt: call == 1 ? "旧操作迟到的合成摘录" : "新操作正确的合成摘录",
            sourceLocation: "file:///tmp/synthetic-vault/operation-\(call).md",
            relativePath: "operation-\(call).md"
        )]
        prepared.obsidianSearchNotice = "合成检索结果"
        return prepared
    }

    func reply(to request: ProjectAIChatRequest) async throws -> ProjectAIChatResponse {
        replies.append(request)
        return ProjectAIChatResponse(
            reply: "合成模型回答",
            provider: AIProviderDescriptor(id: "synthetic", displayName: "合成模型", modelID: "offline"),
            sources: request.obsidianSources ?? []
        )
    }

    func isWaiting(_ call: Int) -> Bool { waiting[call] != nil }
    func release(_ call: Int) { waiting.removeValue(forKey: call)?.resume() }
    func capturedReplies() -> [ProjectAIChatRequest] { replies }
}

@Suite("项目对话 Obsidian 授权与来源冻结")
struct ProjectAIChatObsidianTests {
    private func request(
        _ text: String = "你是否能够看到 Obsidian 里面关于同福的所有的资料？",
        enabled: Bool = true
    ) -> ProjectAIChatRequest {
        ProjectAIChatRequest(
            scenario: "合成会议",
            speakers: [],
            transcript: [],
            analysisHeadline: nil,
            analysisItems: [],
            conversationHistory: [],
            currentRequest: text,
            noteMarkdown: nil,
            webSearchEnabled: false,
            obsidianSearchEnabled: enabled
        )
    }

    private func connection(
        _ index: Int,
        provider: KnowledgeProviderKind = .obsidian,
        path: String? = nil,
        excerpt: String = "合成同福历史资料：建议按门店补货。"
    ) -> KnowledgeConnection {
        KnowledgeConnection(
            provider: provider,
            sourceId: "项目/同福-\(index).md",
            title: "合成同福资料 \(index)",
            excerpt: excerpt,
            sourceLocation: path ?? "/tmp/synthetic-vault/项目/同福-\(index).md"
        )
    }

    private func temporaryVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianChatSynthetic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func payload(_ input: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
    }

    @Test("自然中文提问找回合成笔记，模型收到相对出处而没有本机绝对路径")
    func naturalQuestionIncludesRelevantHistoryWithoutAbsolutePath() async throws {
        let vault = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("同福项目.md")
        try "# 同福项目\n同福合成方案：先核实终端动销，再安排补货。".write(to: note, atomically: true, encoding: .utf8)
        try "# 天气观察\n本周晴天。".write(to: vault.appendingPathComponent("天气.md"), atomically: true, encoding: .utf8)
        let generation = ObsidianChatGenerationRecorder()
        let agent = ProjectAIChatAgent(
            generationService: generation,
            obsidianProvider: ObsidianKnowledgeProvider(vaultURL: vault)
        )

        let reply = try await agent.reply(to: request())

        let sent = try #require(await generation.capturedRequests().first)
        let document = try payload(sent.input)
        let block = try #require(document["untrusted_obsidian_sources"] as? [String: Any])
        let sources = try #require(block["sources"] as? [[String: Any]])
        #expect(sources.count == 1)
        #expect((sources.first?["excerpt"] as? String)?.contains("先核实终端动销") == true)
        #expect(sources.first?["sourceLocation"] as? String == "同福项目.md")
        #expect(!sent.input.contains(vault.path))
        #expect(!sent.input.contains("file:"))
        #expect(!sent.input.contains("本周晴天"))
        #expect((block["notice"] as? String)?.contains("不代表全库的全部资料") == true)
        let sourceURL = try #require(reply.sources.first?.localFileURL)
        #expect(sourceURL.lastPathComponent == note.lastPathComponent)
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let noteAttributes = try FileManager.default.attributesOfItem(atPath: note.path)
        let sourceFileNumber = try #require(sourceAttributes[.systemFileNumber] as? NSNumber)
        let noteFileNumber = try #require(noteAttributes[.systemFileNumber] as? NSNumber)
        let sourceSystemNumber = try #require(sourceAttributes[.systemNumber] as? NSNumber)
        let noteSystemNumber = try #require(noteAttributes[.systemNumber] as? NSNumber)
        #expect(sourceFileNumber == noteFileNumber)
        #expect(sourceSystemNumber == noteSystemNumber)
    }

    @Test("默认未授权不会读取知识库，残留来源也不会进入模型")
    func disabledSearchMakesNoReadsAndDropsStaleSources() async throws {
        let generation = ObsidianChatGenerationRecorder()
        let provider = ObsidianChatProviderRecorder(results: [connection(1)])
        let agent = ProjectAIChatAgent(generationService: generation, obsidianProvider: provider)
        let project = Project(title: "合成项目", sourceType: .liveRecording)
        var input = ProjectAIChatRequestBuilder.make(
            project: project, currentRequest: "回顾同福", noteMarkdown: nil, webSearchEnabled: false
        )
        #expect(!input.obsidianSearchEnabled)
        input.obsidianSources = [ProjectAIChatSource(
            id: "obsidian_1", providerName: "Obsidian", title: "残留来源",
            excerpt: "未授权的残留正文", sourceLocation: "file:///tmp/synthetic-vault/history.md"
        )]

        let reply = try await agent.reply(to: input)

        #expect(await provider.capturedQueries().isEmpty)
        let sent = try #require(await generation.capturedRequests().first)
        #expect(!sent.input.contains("未授权的残留正文"))
        let block = try #require(try payload(sent.input)["untrusted_obsidian_sources"] as? [String: Any])
        #expect(block["enabled"] as? Bool == false)
        #expect((block["sources"] as? [Any])?.isEmpty == true)
        #expect(reply.sources.isEmpty)
    }

    @Test("未连接、没有匹配和检索失败分别说明，空结果和失败重试不再读取")
    func unavailableEmptyAndFailedSearchesRemainTruthfulAndFrozen() async throws {
        let generation = ObsidianChatGenerationRecorder()
        let disconnected = ProjectAIChatAgent(generationService: generation)
        let missing = try await disconnected.prepare(request())
        #expect(missing.obsidianSources == [])
        #expect(missing.obsidianSearchNotice?.contains("尚未连接") == true)

        for failure in [nil, KnowledgeProviderError.permissionDenied] {
            let provider = ObsidianChatProviderRecorder(failure: failure)
            let agent = ProjectAIChatAgent(generationService: generation, obsidianProvider: provider)
            let first = try await agent.prepare(request())
            let second = try await agent.prepare(first)
            #expect(first.obsidianSources == [])
            #expect(second == first)
            #expect(await provider.capturedQueries().count == 1)
            #expect(first.obsidianSearchNotice?.contains(failure == nil ? "未找到匹配" : "检索失败") == true)
        }
        #expect(await generation.capturedRequests().isEmpty)
    }

    @Test("只接纳合法 Markdown 来源，去重限篇幅并拒绝模型伪造引用")
    func sourceFilteringBudgetAndCitationValidation() async throws {
        let invalid = [
            connection(40, provider: .internet),
            connection(41, path: "https://example.com/history.md"),
            connection(42, path: "/tmp/synthetic-vault/image.png"),
            connection(43, excerpt: " \n ")
        ]
        let oversized = String(repeating: "合成相关资料", count: 500)
        let valid = (1...9).map { connection($0, excerpt: oversized) }
        let provider = ObsidianChatProviderRecorder(results: invalid + [valid[0]] + valid)
        let generation = ObsidianChatGenerationRecorder(
            responseText: #"{"reply":"合成回答","source_ids":["obsidian_2","obsidian_2","obsidian_999","web_999"]}"#
        )
        let agent = ProjectAIChatAgent(generationService: generation, obsidianProvider: provider)

        let prepared = try await agent.prepare(request())
        let sources = try #require(prepared.obsidianSources)
        #expect(sources.count == 6)
        #expect(Set(sources.map(\.sourceLocation)).count == 6)
        #expect(sources.allSatisfy { $0.isObsidian && $0.excerpt.count <= 1_800 })
        #expect(sources.reduce(0) { $0 + $1.excerpt.count } <= 10_800)
        let reply = try await agent.reply(to: prepared)
        #expect(reply.sources.map(\.id) == ["obsidian_2"])
        #expect(await provider.capturedQueries().count == 1)
    }

    @Test("只问 Obsidian 即使联网开关开启也不做公开搜索或云端搜索规划")
    func localQuestionDoesNotDiscloseThemeToWebSearch() async throws {
        let generation = ObsidianChatGenerationRecorder()
        let web = ObsidianChatProviderRecorder(kind: .internet)
        let local = ObsidianChatProviderRecorder(results: [connection(1)])
        let agent = ProjectAIChatAgent(
            generationService: generation, webSearchProvider: web, obsidianProvider: local
        )
        var input = request()
        input.webSearchEnabled = true

        _ = try await agent.reply(to: input)

        #expect(await web.capturedQueries().isEmpty)
        #expect(await local.capturedQueries() == [input.currentRequest])
        #expect(await generation.capturedRequests().count == 1)
    }

    @Test("模型失败后重开项目重试复用落盘来源，修改 Vault 不改变当轮证据")
    @MainActor
    func retryAfterReopenFreezesHistoricalEvidence() async throws {
        let vault = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("同福.md")
        try "# 同福\n同福原始合成约定：先试销再补货。".write(to: note, atomically: true, encoding: .utf8)
        let generation = ObsidianChatGenerationRecorder(failFirst: true)
        let agent = ProjectAIChatAgent(
            generationService: generation, obsidianProvider: ObsidianKnowledgeProvider(vaultURL: vault)
        )
        var persisted: Data?
        let project = Project(title: "合成重试项目", sourceType: .liveRecording)
        let first = ProjectAIChatController(service: agent, persist: { persisted = try JSONEncoder().encode($0) })
        first.attach(to: project)
        first.isWebSearchEnabled = false
        first.isObsidianSearchEnabled = true
        first.draft = request().currentRequest
        await first.send()
        #expect(first.canRetryLastMessage)
        let frozenSources = try #require(project.aiChatMessages.last?.contextSnapshot?.obsidianSources)
        #expect(frozenSources.first?.excerpt.contains("先试销再补货") == true)

        try "# 同福\n同福后来改写：立即向全部门店铺货，替换了原有约定。".write(to: note, atomically: true, encoding: .utf8)
        let reopenedProject = try JSONDecoder().decode(Project.self, from: #require(persisted))
        let reopened = ProjectAIChatController(service: agent, persist: { _ in })
        reopened.attach(to: reopenedProject)
        #expect(!reopened.isObsidianSearchEnabled)
        await reopened.retryLastMessage()

        let calls = await generation.capturedRequests()
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.input.contains("先试销再补货") })
        #expect(calls.allSatisfy { !$0.input.contains("立即向全部门店铺货") })
        #expect(reopenedProject.aiChatMessages.last?.role == .assistant)
        #expect(reopenedProject.aiChatMessages.last?.contextSnapshot?.obsidianSources == frozenSources)
    }

    @Test("旧快照缺少 Obsidian 字段仍能解码，恢复时不会自动授权")
    func legacyContextDecodingDoesNotGrantPermission() throws {
        let project = Project(title: "合成旧项目", sourceType: .liveRecording)
        let input = ProjectAIChatRequestBuilder.make(
            project: project, currentRequest: "旧问题", noteMarkdown: nil, webSearchEnabled: false
        )
        let snapshots = ProjectAIChatRequestBuilder.snapshots(
            projectID: project.id, requestID: UUID(), scope: .wholeConversation,
            request: input, project: project, historyMessages: []
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshots.context)) as? [String: Any])
        for key in ["obsidianSearchEnabled", "obsidianSources", "obsidianSearchNotice"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(
            ProjectAIChatContextSnapshot.self, from: JSONSerialization.data(withJSONObject: object)
        )
        let restored = try #require(ProjectAIChatRequestBuilder.restoredRequest(
            currentRequest: "旧问题", evidence: snapshots.evidence, context: decoded
        ))
        #expect(decoded.obsidianSearchEnabled == nil)
        #expect(decoded.obsidianSources == nil)
        #expect(!restored.obsidianSearchEnabled)
        #expect(restored.obsidianSources == nil)
    }

    @Test("无快照旧消息重试不会借用当前开关读取或上传 Obsidian")
    @MainActor
    func legacyRetryDoesNotBorrowCurrentObsidianPermission() async throws {
        let generation = ObsidianChatGenerationRecorder()
        let provider = ObsidianChatProviderRecorder(results: [
            connection(1, excerpt: "仅属于新授权轮次的合成私有笔记正文")
        ])
        let agent = ProjectAIChatAgent(generationService: generation, obsidianProvider: provider)
        let project = Project(title: "合成遗留消息", sourceType: .liveRecording)
        project.aiChatMessages = [ProjectAIChatMessage(
            role: .user,
            text: "请查看 Obsidian 里关于同福的资料"
        )]
        let controller = ProjectAIChatController(service: agent, persist: { _ in })
        controller.attach(to: project)
        controller.isWebSearchEnabled = false
        controller.isObsidianSearchEnabled = true
        #expect(controller.canRetryLastMessage)

        await controller.retryLastMessage()

        #expect(await provider.capturedQueries().isEmpty)
        let calls = await generation.capturedRequests()
        #expect(calls.count == 1)
        let sent = try #require(calls.first)
        let block = try #require(try payload(sent.input)["untrusted_obsidian_sources"] as? [String: Any])
        #expect(block["enabled"] as? Bool == false)
        #expect((block["sources"] as? [Any])?.isEmpty == true)
        #expect(!sent.input.contains("仅属于新授权轮次的合成私有笔记正文"))
        #expect(project.aiChatMessages.last?.role == .assistant)
        #expect(project.aiChatMessages.last?.sources.isEmpty == true)
    }

    @Test("严格选段拒绝知识库授权，正常选段不会混入历史笔记或其他片段")
    func strictSelectionRejectsObsidianAndKeepsIsolation() async throws {
        let selected = TranscriptSegment(startMs: 0, endMs: 1_000, text: "选段合成原话。", source: .local, state: .final)
        let other = TranscriptSegment(startMs: 2_000, endMs: 3_000, text: "未选中的保密合成原话。", source: .local, state: .final)
        let project = Project(title: "合成选段项目", sourceType: .liveRecording, segments: [selected, other])
        let scope = ProjectAIChatQueryScope.selectedSegments(selectedSegmentIDs: [selected.id])
        #expect(throws: ProjectAIChatBuildError.strictObsidianSearchUnsupported) {
            try ProjectAIChatRequestBuilder.makeForScope(
                project: project, scope: scope, currentRequest: "解释", noteMarkdown: nil,
                webSearchEnabled: false, obsidianSearchEnabled: true
            )
        }
        let input = try ProjectAIChatRequestBuilder.makeForScope(
            project: project, scope: scope, currentRequest: "解释", noteMarkdown: "未授权的历史笔记正文",
            webSearchEnabled: false
        )
        let provider = ObsidianChatProviderRecorder(results: [connection(1)])
        let generation = ObsidianChatGenerationRecorder()
        let agent = ProjectAIChatAgent(generationService: generation, obsidianProvider: provider)
        _ = try await agent.reply(to: input)
        let sent = try #require(await generation.capturedRequests().first)
        #expect(sent.input.contains("选段合成原话"))
        #expect(!sent.input.contains("未选中的保密合成原话"))
        #expect(!sent.input.contains("未授权的历史笔记正文"))
        #expect(await provider.capturedQueries().isEmpty)
    }

    @Test("准备好的来源快照保存失败时不上云，原用户消息仍可重试")
    @MainActor
    func failedSourceSnapshotPersistencePreventsGeneration() async throws {
        let generation = ObsidianChatGenerationRecorder()
        let provider = ObsidianChatProviderRecorder(results: [connection(1)])
        let agent = ProjectAIChatAgent(generationService: generation, obsidianProvider: provider)
        let project = Project(title: "合成保存失败", sourceType: .liveRecording)
        var saves = 0
        let controller = ProjectAIChatController(service: agent, persist: { candidate in
            saves += 1
            if candidate.aiChatMessages.last?.contextSnapshot?.obsidianSources != nil {
                throw ObsidianChatSyntheticError.persistenceFailed
            }
        })
        controller.attach(to: project)
        controller.isWebSearchEnabled = false
        controller.isObsidianSearchEnabled = true
        controller.draft = request().currentRequest
        await controller.send()

        #expect(saves == 2)
        #expect(await provider.capturedQueries().count == 1)
        #expect(await generation.capturedRequests().isEmpty)
        #expect(project.aiChatMessages.map(\.role) == [.user])
        #expect(project.aiChatMessages.first?.contextSnapshot?.obsidianSources == nil)
        #expect(controller.canRetryLastMessage)
        #expect(controller.errorMessage?.contains("来源快照保存失败") == true)
    }

    @Test("切项目再重试同一轮时，忽略取消的旧检索晚到也不能覆盖新操作")
    @MainActor
    func latePreparationCannotHijackRetryOfSamePersistedTurn() async throws {
        let service = ObsidianChatSuspendedPreparation()
        let projectA = Project(title: "合成项目 A", sourceType: .liveRecording)
        let projectB = Project(title: "合成项目 B", sourceType: .liveRecording)
        let controller = ProjectAIChatController(service: service, persist: { _ in })
        controller.attach(to: projectA)
        controller.isWebSearchEnabled = false
        controller.isObsidianSearchEnabled = true
        controller.draft = "查看 Obsidian 中的合成主题"
        let oldSend = Task { await controller.send() }
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await service.isWaiting(1)), ContinuousClock.now < firstDeadline { await Task.yield() }
        #expect(await service.isWaiting(1))
        let persistedRequestID = try #require(projectA.aiChatMessages.first?.requestID)

        controller.attach(to: projectB)
        controller.attach(to: projectA)
        #expect(controller.canRetryLastMessage)
        let retry = Task { await controller.retryLastMessage() }
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await service.isWaiting(2)), ContinuousClock.now < secondDeadline { await Task.yield() }
        #expect(await service.isWaiting(2))
        #expect(projectA.aiChatMessages.first?.requestID == persistedRequestID)

        // 在新检索尚未完成时放行旧检索，逼出相同轮次 ID 的守卫碰撞。
        await service.release(1)
        await oldSend.value
        #expect(await service.capturedReplies().isEmpty)
        #expect(controller.isSending)
        #expect(projectA.aiChatMessages.map(\.role) == [.user])
        #expect(projectA.aiChatMessages.first?.contextSnapshot?.obsidianSources == nil)

        await service.release(2)
        await retry.value
        let calls = await service.capturedReplies()
        #expect(calls.count == 1)
        #expect(calls.first?.obsidianSources?.first?.excerpt == "新操作正确的合成摘录")
        #expect(projectA.aiChatMessages.map(\.role) == [.user, .assistant])
        #expect(projectA.aiChatMessages.last?.requestID == persistedRequestID)
        #expect(projectA.aiChatMessages.last?.contextSnapshot?.obsidianSources?.first?.excerpt == "新操作正确的合成摘录")
        #expect(projectB.aiChatMessages.isEmpty)
        #expect(!controller.isSending)
    }

    @Test("切项目和切严格范围均撤销工作台 Obsidian 开关")
    @MainActor
    func workspacePermissionResetsAtProjectAndScopeBoundary() {
        let agent = ProjectAIChatAgent(generationService: ObsidianChatGenerationRecorder())
        let controller = ProjectAIChatController(service: agent, persist: { _ in })
        controller.attach(to: Project(title: "合成甲", sourceType: .liveRecording))
        #expect(!controller.isObsidianSearchEnabled)
        controller.isObsidianSearchEnabled = true
        let project = Project(title: "合成乙", sourceType: .liveRecording)
        controller.attach(to: project)
        #expect(!controller.isObsidianSearchEnabled)
        controller.isObsidianSearchEnabled = true
        #expect(controller.setQueryScope(.selectedSegments(selectedSegmentIDs: [UUID()])))
        #expect(!controller.isObsidianSearchEnabled)
        #expect(!controller.isWebSearchEnabled)
    }
}
