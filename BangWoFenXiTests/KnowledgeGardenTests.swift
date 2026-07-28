import Foundation
import Testing
@testable import BangWoFenXi

private struct MockKnowledgeExpansionService: KnowledgeExpansionServicing {
    var result: KnowledgeExpansionResult

    func expand(
        seedText: String,
        whyItMatters: String,
        evidence: [KnowledgeEvidenceInput],
        scenario: ProjectScenario?
    ) async throws -> KnowledgeExpansionResult {
        result
    }
}

private struct MockKnowledgeProvider: KnowledgeProvider {
    var kind: KnowledgeProviderKind
    var displayName: String
    var shouldFail = false

    func healthCheck() async -> KnowledgeProviderHealth {
        KnowledgeProviderHealth(isAvailable: !shouldFail, message: shouldFail ? "不可用" : "正常")
    }

    func search(_ query: String, limit: Int) async throws -> [KnowledgeConnection] {
        if shouldFail {
            throw KnowledgeProviderError.unavailable
        }
        return [
            KnowledgeConnection(
                provider: kind,
                providerName: displayName,
                sourceId: "\(kind.rawValue)-source",
                title: "\(displayName)资料",
                excerpt: "与\(query)相关的真实来源摘要",
                sourceLocation: kind == .obsidian
                    ? "/tmp/source.md"
                    : "https://example.com/source",
                relevance: 0.9
            )
        ]
    }
}

final class KnowledgeInternetMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

final class KnowledgeMCPMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

@Suite("知识开花", .serialized)
struct KnowledgeGardenTests {
    @Test("Project 新旧 JSON 均兼容知识种子")
    func projectPersistenceCompatibility() throws {
        let segmentID = UUID()
        let seed = KnowledgeSeed(
            seedText: "渠道库存与对账口径",
            whyItMatters: "来自客户讨论",
            evidenceSegmentIds: [segmentID],
            branches: [
                KnowledgeBranch(
                    type: .conceptExplanation,
                    title: "库存口径",
                    body: "库存必须明确业务时点与单据状态。"
                )
            ]
        )
        let project = Project(
            title: "知识项目",
            sourceType: .importedAudio,
            knowledgeSeeds: [seed]
        )
        let data = try JSONEncoder().encode(project)
        let restored = try JSONDecoder().decode(Project.self, from: data)
        #expect(restored.knowledgeSeeds == [seed])

        var legacyObject = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "knowledgeSeeds")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(Project.self, from: legacyData)
        #expect(legacy.knowledgeSeeds.isEmpty)
    }

    @Test("知识字段独立合并，不覆盖笔记与分析")
    func knowledgeFieldOwnership() {
        let id = UUID()
        let stored = Project(
            id: id,
            title: "存储副本",
            sourceType: .importedAudio,
            note: NoteDocument(markdown: "用户笔记")
        )
        let incoming = Project(
            id: id,
            title: "旧标题",
            sourceType: .importedAudio,
            knowledgeSeeds: [
                KnowledgeSeed(
                    seedText: "一条知识种子",
                    whyItMatters: "测试",
                    evidenceSegmentIds: [UUID()]
                )
            ],
            note: NoteDocument(markdown: "旧笔记")
        )
        var projects = [stored]
        ProjectPersistence.upsert(incoming, into: &projects, fields: .knowledgeGarden)
        #expect(projects[0].note.markdown == "用户笔记")
        #expect(projects[0].knowledgeSeeds.count == 1)
    }

    @Test("模型结果只保留合法分支并去重检索词")
    func expansionResultValidation() {
        let dto = KnowledgeExpansionOutputDTO(
            branches: [
                .init(type: "concept_explanation", title: " 概念 ", body: " 正文 "),
                .init(type: "made_up", title: "非法", body: "丢弃"),
                .init(type: "continue_question", title: "", body: "空标题")
            ],
            searchQueries: ["渠道库存", "渠道库存", "  对账口径  "]
        )
        let result = KimiKnowledgeExpansionService.buildResult(from: dto)
        #expect(result.branches.count == 1)
        #expect(result.branches.first?.type == .conceptExplanation)
        #expect(result.branches.first?.title == "概念")
        #expect(result.searchQueries == ["渠道库存", "对账口径"])
    }

    @Test("控制器从真实证据生成种子，并聚合多来源且允许部分失败")
    @MainActor
    func controllerAggregatesProviders() async throws {
        let segmentID = UUID()
        let segment = TranscriptSegment(
            id: segmentID,
            startMs: 0,
            endMs: 1_000,
            text: "客户认为库存与对账口径经常冲突。",
            source: .local,
            state: .final
        )
        let snapshot = ConversationAnalysisSnapshot(
            version: 1,
            analyzedThroughMs: 1_000,
            items: [
                AnalysisItem(
                    category: .knowledgeSeed,
                    text: "渠道库存与对账口径",
                    epistemicStatus: .explicit,
                    confidence: .high,
                    evidenceSegmentIds: [segmentID]
                )
            ]
        )
        let project = Project(
            title: "开花测试",
            sourceType: .importedAudio,
            segments: [segment],
            analysisSnapshots: [snapshot]
        )
        let controller = KnowledgeGardenController(
            expansionService: MockKnowledgeExpansionService(
                result: KnowledgeExpansionResult(
                    branches: [
                        KnowledgeBranch(
                            type: .crossDomainConnection,
                            title: "口径治理",
                            body: "这与主数据治理的定义权问题相连。"
                        )
                    ],
                    searchQueries: ["库存对账 口径治理"]
                )
            ),
            providerFactory: {
                [
                    MockKnowledgeProvider(kind: .obsidian, displayName: "Obsidian"),
                    MockKnowledgeProvider(kind: .internet, displayName: "互联网"),
                    MockKnowledgeProvider(
                        kind: .externalMCP,
                        displayName: "得到大脑",
                        shouldFail: true
                    )
                ]
            }
        )

        controller.attach(to: project)
        let seed = try #require(controller.selectedSeed)
        #expect(seed.evidenceSegmentIds == [segmentID])
        await controller.bloomSelected()

        let bloomed = try #require(controller.selectedSeed)
        #expect(bloomed.branches.count == 1)
        #expect(bloomed.connections.count == 2)
        #expect(Set(bloomed.connections.map(\.provider)) == [.obsidian, .internet])
        #expect(controller.providerMessages[.externalMCP]?.contains("不可用") == true)
        #expect(controller.state == .finished)
    }

    @Test("Obsidian 只检索真实 Markdown，并忽略应用数据目录")
    func obsidianProviderSearch() async throws {
        let vault = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-knowledge-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: vault) }
        let knowledge = vault.appending(path: "3_知识库", directoryHint: .isDirectory)
        let appData = vault.appending(path: "帮我分析", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        try Data("# 渠道库存管理\n库存口径要区分可销库存和账面库存。".utf8)
            .write(to: knowledge.appending(path: "库存.md"))
        try Data("# 不应命中\n渠道库存".utf8)
            .write(to: appData.appending(path: "内部.md"))

        let provider = ObsidianKnowledgeProvider(vaultURL: vault)
        let results = try await provider.search("渠道库存", limit: 5)
        #expect(results.count == 1)
        #expect(results.first?.title == "渠道库存管理")
        #expect(results.first?.sourceId == "3_知识库/库存.md")
    }

    @Test("互联网 Provider 保留维基百科真实 URL 与摘要")
    func internetProviderParsesSource() async throws {
        KnowledgeInternetMockURLProtocol.storage.reset()
        KnowledgeInternetMockURLProtocol.storage.requestHandler = { request in
            #expect(request.url?.query?.contains("generator=search") == true)
            let data = Data("""
            {
              "query": {
                "pages": [
                  {
                    "pageid": 42,
                    "title": "库存管理",
                    "extract": "库存管理是对库存数量与状态的管理。",
                    "fullurl": "https://zh.wikipedia.org/wiki/库存管理"
                  }
                ]
              }
            }
            """.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let provider = InternetKnowledgeProvider(
            session: KnowledgeInternetMockURLProtocol.makeSession()
        )
        let results = try await provider.search("库存管理", limit: 3)
        #expect(results.count == 1)
        #expect(results.first?.provider == .internet)
        #expect(results.first?.sourceLocation.contains("wikipedia.org") == true)
    }

    @Test("外部 MCP 完成握手、工具发现和真实结果映射")
    func externalMCPFlow() async throws {
        KnowledgeMCPMockURLProtocol.storage.reset()
        KnowledgeMCPMockURLProtocol.storage.requestHandler = { request in
            let body = try #require(mockRequestBodyData(of: request))
            let object = try #require(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let method = try #require(object["method"] as? String)
            let responseObject: [String: Any]?
            switch method {
            case "initialize":
                responseObject = [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "result": [
                        "protocolVersion": "2025-03-26",
                        "capabilities": [:],
                        "serverInfo": ["name": "dedao", "version": "1"]
                    ]
                ]
            case "notifications/initialized":
                responseObject = nil
            case "tools/list":
                responseObject = [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "result": [
                        "tools": [
                            [
                                "name": "search_notes",
                                "description": "搜索知识和笔记",
                                "inputSchema": [
                                    "type": "object",
                                    "properties": [
                                        "query": ["type": "string"],
                                        "limit": ["type": "integer"]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            case "tools/call":
                responseObject = [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "result": [
                        "content": [
                            [
                                "type": "text",
                                "text": """
                                {"results":[{"id":"note-1","title":"库存课","summary":"库存口径案例","url":"https://example.com/note-1","score":0.88}]}
                                """
                            ]
                        ]
                    ]
                ]
            default:
                Issue.record("未预期的 MCP 方法：\(method)")
                responseObject = nil
            }
            let data = try responseObject.map {
                try JSONSerialization.data(withJSONObject: $0)
            } ?? Data()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Mcp-Session-Id": "session-1"]
                )!,
                data
            )
        }

        let service = "com.zhaobo.BangWoFenXi.tests.mcp.\(UUID().uuidString)"
        let tokenStore = CloudAPIKeyStore(
            service: service,
            account: ExternalMCPConfigurationStore.tokenAccount
        )
        defer { try? tokenStore.deleteKey() }
        let provider = ExternalMCPKnowledgeProvider(
            configuration: ExternalMCPConfiguration(
                displayName: "得到大脑",
                endpoint: "https://example.com/mcp"
            ),
            tokenStore: tokenStore,
            session: KnowledgeMCPMockURLProtocol.makeSession()
        )
        let results = try await provider.search("库存口径", limit: 5)
        #expect(results.count == 1)
        #expect(results.first?.providerName == "得到大脑")
        #expect(results.first?.sourceId == "note-1")
        #expect(results.first?.sourceLocation == "https://example.com/note-1")
        #expect(KnowledgeMCPMockURLProtocol.storage.capturedRequests.count == 4)
    }

    @Test("种子超限裁剪只丢可弃候选，保留已收藏与已开花的种子")
    @MainActor
    func seedTrimmingProtectsUserInvestedSeeds() {
        let collected = KnowledgeSeed(
            seedText: "已收藏的种子",
            whyItMatters: "用户收藏",
            evidenceSegmentIds: [UUID()],
            isAddedToProject: true
        )
        let bloomed = KnowledgeSeed(
            seedText: "已开花的种子",
            whyItMatters: "有开花成果",
            evidenceSegmentIds: [UUID()],
            branches: [KnowledgeBranch(
                type: .conceptExplanation,
                title: "概念",
                body: "内容"
            )]
        )
        let disposable = (0..<12).map { index in
            KnowledgeSeed(
                seedText: "可弃候选\(index)：一条足够长的普通候选文本",
                whyItMatters: "候选",
                evidenceSegmentIds: [UUID()]
            )
        }
        let project = Project(
            title: "裁剪测试",
            sourceType: .importedAudio,
            knowledgeSeeds: [collected, bloomed] + disposable
        )
        let controller = KnowledgeGardenController(
            expansionService: MockKnowledgeExpansionService(
                result: KnowledgeExpansionResult(branches: [], searchQueries: [])
            ),
            providerFactory: { [] }
        )

        controller.attach(to: project)

        #expect(controller.seeds.count == KnowledgeGardenController.maxSeeds)
        #expect(controller.seeds.contains { $0.id == collected.id }, "已收藏种子不得被裁剪")
        #expect(controller.seeds.contains { $0.id == bloomed.id }, "已开花种子不得被裁剪")
        // 被丢弃的必须是最旧的可弃候选
        #expect(!controller.seeds.contains { $0.id == disposable[0].id })
        #expect(!controller.seeds.contains { $0.id == disposable[1].id })
    }

    @Test("refined 检索空结果不得掩盖初次检索的成功来源")
    @MainActor
    func refinedEmptyResultKeepsInitialSuccess() async throws {
        /// 初次查询返回结果、refined 查询返回空的 provider
        struct QueryAwareProvider: KnowledgeProvider {
            let kind: KnowledgeProviderKind = .internet
            let displayName = "互联网"
            let initialQuery: String

            func healthCheck() async -> KnowledgeProviderHealth {
                KnowledgeProviderHealth(isAvailable: true, message: "正常")
            }

            func search(_ query: String, limit: Int) async throws -> [KnowledgeConnection] {
                guard query == initialQuery else { return [] }
                return [KnowledgeConnection(
                    provider: .internet,
                    sourceId: "initial-hit",
                    title: "初次命中",
                    excerpt: "初次检索的真实结果",
                    sourceLocation: "https://example.com/hit"
                )]
            }
        }

        let segmentID = UUID()
        let seedText = "一段足够长的讨论原话内容，用于生成种子。"
        let project = Project(
            title: "refined 测试",
            sourceType: .importedAudio,
            segments: [TranscriptSegment(
                id: segmentID,
                startMs: 0,
                endMs: 1_000,
                text: seedText,
                source: .local,
                state: .final
            )]
        )
        let refinedController = KnowledgeGardenController(
            expansionService: MockKnowledgeExpansionService(
                result: KnowledgeExpansionResult(
                    branches: [],
                    searchQueries: ["完全不同的refined检索词"]
                )
            ),
            providerFactory: { [QueryAwareProvider(initialQuery: seedText)] }
        )
        refinedController.attach(to: project)
        let seed = try #require(refinedController.selectedSeed)
        #expect(seed.seedText == seedText)
        await refinedController.bloomSelected()

        let bloomed = try #require(refinedController.selectedSeed)
        #expect(bloomed.connections.count == 1, "初次检索结果必须保留")
        #expect(
            refinedController.providerMessages[.internet] == nil,
            "已有真实结果时不得显示「没有找到相关内容」"
        )
    }

    @Test("Obsidian provider 在同一 AppEnvironment 内复用同一实例（索引缓存生效）")
    @MainActor
    func obsidianProviderReusedAcrossBlooms() throws {
        let vault = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: vault.appending(path: ".obsidian", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: vault) }
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: FileManager.default.temporaryDirectory),
            obsidianVaultURL: vault,
            keychainServiceName: "com.zhaobo.BangWoFenXi.tests.knowledge.\(UUID().uuidString)"
        )

        let first = environment.makeKnowledgeProviders()
            .compactMap { $0 as? ObsidianKnowledgeProvider }.first
        let second = environment.makeKnowledgeProviders()
            .compactMap { $0 as? ObsidianKnowledgeProvider }.first

        #expect(first != nil)
        #expect(first === second, "重复开花必须复用同一索引实例，避免反复全量扫描")
    }

    @Test("Obsidian 跳过 symlink 指向 Vault 之外的文件")
    func obsidianProviderSkipsOutOfVaultSymlink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appending(path: "vault", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: vault.appending(path: ".obsidian", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appending(path: "秘密.md")
        try Data("# 渠道库存机密\n渠道库存".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: vault.appending(path: "链接.md"),
            withDestinationURL: secret
        )
        try Data("# 渠道库存正常\n渠道库存".utf8)
            .write(to: vault.appending(path: "正常.md"))

        let provider = ObsidianKnowledgeProvider(vaultURL: vault)
        let results = try await provider.search("渠道库存", limit: 5)
        #expect(results.count == 1)
        #expect(results.first?.title == "渠道库存正常")
    }

    @Test("MCP 地址只允许 HTTPS 或本机 HTTP")
    func externalMCPURLValidation() {
        #expect(ExternalMCPConfiguration(
            endpoint: "https://example.com/mcp"
        ).validatedURL != nil)
        #expect(ExternalMCPConfiguration(
            endpoint: "http://127.0.0.1:3000/mcp"
        ).validatedURL != nil)
        #expect(ExternalMCPConfiguration(
            endpoint: "http://example.com/mcp"
        ).validatedURL == nil)
        #expect(ExternalMCPConfiguration(
            endpoint: "file:///tmp/mcp"
        ).validatedURL == nil)
    }
}
