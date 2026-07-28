import Foundation

struct ExternalMCPConfiguration: Identifiable, Codable, Sendable, Equatable {
    static let credentialAccountPrefix = "knowledge-mcp."

    var id: UUID
    var displayName: String
    var endpoint: String
    var toolName: String
    var isEnabled: Bool
    var credentialAccount: String
    var verifiedReadOnlyToolName: String?

    init(
        id: UUID = UUID(),
        displayName: String = "得到大脑",
        endpoint: String = "",
        toolName: String = "",
        isEnabled: Bool = true,
        credentialAccount: String? = nil,
        verifiedReadOnlyToolName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.toolName = toolName
        self.isEnabled = isEnabled
        self.credentialAccount = credentialAccount
            ?? Self.credentialAccountPrefix + id.uuidString
        self.verifiedReadOnlyToolName = verifiedReadOnlyToolName
    }

    var validatedURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        if scheme == "http" {
            let host = url.host?.lowercased()
            guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
                return nil
            }
        }
        return url
    }

    var normalizedDisplayName: String {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "外部 MCP" : value
    }

    var isReadOnlyToolVerified: Bool {
        let selected = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !selected.isEmpty && verifiedReadOnlyToolName == selected
    }
}

struct ExternalMCPConfigurationStore: @unchecked Sendable {
    static let legacyDefaultsKey = "bwfx.knowledge.externalMCP"
    static let defaultsKey = "bwfx.knowledge.externalMCP.v2"
    static let legacyTokenAccount = "knowledge-mcp"
    static let tokenAccount = legacyTokenAccount

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [ExternalMCPConfiguration] {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let configurations = try? JSONDecoder().decode(
               [ExternalMCPConfiguration].self,
               from: data
           ) {
            return configurations
        }
        guard let data = defaults.data(forKey: Self.legacyDefaultsKey),
              let legacy = try? JSONDecoder().decode(
                  LegacyExternalMCPConfiguration.self,
                  from: data
              ) else {
            return []
        }
        let migrated = ExternalMCPConfiguration(
            displayName: legacy.displayName,
            endpoint: legacy.endpoint,
            toolName: legacy.toolName,
            isEnabled: true,
            credentialAccount: Self.legacyTokenAccount,
            verifiedReadOnlyToolName: legacy.toolName
        )
        if let encoded = try? JSONEncoder().encode([migrated]) {
            defaults.set(encoded, forKey: Self.defaultsKey)
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        }
        return [migrated]
    }

    func load() -> ExternalMCPConfiguration? {
        loadAll().first
    }

    func save(_ configuration: ExternalMCPConfiguration) throws {
        var configurations = loadAll()
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        try saveAll(configurations)
    }

    func saveAll(_ configurations: [ExternalMCPConfiguration]) throws {
        guard Set(configurations.map(\.id)).count == configurations.count,
              configurations.allSatisfy({ $0.validatedURL != nil }) else {
            throw KnowledgeProviderError.invalidConfiguration
        }
        defaults.set(
            try JSONEncoder().encode(configurations),
            forKey: Self.defaultsKey
        )
    }

    func remove(id: UUID) {
        let remaining = loadAll().filter { $0.id != id }
        if remaining.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let encoded = try? JSONEncoder().encode(remaining) {
            defaults.set(encoded, forKey: Self.defaultsKey)
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    private struct LegacyExternalMCPConfiguration: Codable {
        var displayName: String
        var endpoint: String
        var toolName: String
    }
}

/// 拒绝一切 HTTP 重定向：MCP 端点必须直接应答。
/// 跟随重定向可能把 Bearer Token 带到内网或第三方主机（SSRF / 凭证外带），
/// 被拒绝的 3xx 会以原始状态码走 serverRejected 错误路径，如实降级。
private final class MCPNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor ExternalMCPKnowledgeProvider: KnowledgeProvider {
    nonisolated let kind: KnowledgeProviderKind = .externalMCP
    nonisolated let providerID: String
    nonisolated let displayName: String

    private let configuration: ExternalMCPConfiguration
    private let tokenSnapshot: String?
    private let tokenReadFailed: Bool
    private let session: URLSession
    private var cachedDiscovery: Discovery?

    init(
        configuration: ExternalMCPConfiguration,
        tokenStore: CloudAPIKeyStore,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.providerID = "mcp:\(configuration.id.uuidString)"
        self.displayName = configuration.normalizedDisplayName
        do {
            self.tokenSnapshot = try tokenStore.readKey()
            self.tokenReadFailed = false
        } catch {
            self.tokenSnapshot = nil
            self.tokenReadFailed = true
        }
        self.session = session ?? URLSession(
            configuration: .ephemeral,
            delegate: MCPNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func healthCheck() async -> KnowledgeProviderHealth {
        do {
            let discovery = try await discover(force: true)
            return KnowledgeProviderHealth(
                isAvailable: true,
                message: "已连接 · \(discovery.tool.name)"
            )
        } catch {
            return KnowledgeProviderHealth(
                isAvailable: false,
                message: error.localizedDescription
            )
        }
    }

    func discoverReadOnlyToolNames() async throws -> [String] {
        let listed = try await listTools()
        return listed.tools.filter(\.looksLikeSearch).map(\.name)
    }

    func search(_ query: String, limit: Int = 5) async throws -> [KnowledgeConnection] {
        let trimmed = String(
            query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)
        )
        guard !trimmed.isEmpty else { return [] }
        let discovery = try await discover(force: false)
        var arguments: [String: Any] = [
            discovery.tool.queryArgument: trimmed
        ]
        if let limitArgument = discovery.tool.limitArgument {
            arguments[limitArgument] = max(1, min(limit, 10))
        }
        let response = try await post(
            method: "tools/call",
            params: [
                "name": discovery.tool.name,
                "arguments": arguments
            ],
            id: 3,
            sessionID: discovery.sessionID
        )
        guard let object = response.object,
              let result = object["result"] as? [String: Any],
              (result["isError"] as? Bool) != true else {
            throw KnowledgeProviderError.invalidResponse
        }
        return Self.connections(
            from: result,
            providerID: providerID,
            providerName: displayName,
            endpoint: configuration.endpoint,
            limit: limit
        )
    }

    private func discover(force: Bool) async throws -> Discovery {
        if !force, let cachedDiscovery {
            return cachedDiscovery
        }
        guard configuration.validatedURL != nil else {
            throw KnowledgeProviderError.invalidConfiguration
        }
        let listed = try await listTools()
        let parsed = listed.tools.filter(\.looksLikeSearch)
        let configuredName = configuration.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected: Tool?
        if configuredName.isEmpty {
            guard parsed.count <= 1 else {
                throw KnowledgeProviderError.multipleSearchTools(parsed.map(\.name))
            }
            selected = parsed.first
        } else {
            selected = parsed.first { $0.name == configuredName }
        }
        guard let selected else {
            throw KnowledgeProviderError.noSearchTool
        }
        let discovery = Discovery(
            sessionID: listed.sessionID,
            tool: selected,
            discoveredAt: Date()
        )
        cachedDiscovery = discovery
        return discovery
    }

    private func listTools() async throws -> ToolListing {
        let initialized = try await post(
            method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": [
                    "name": "BangWoFenXi",
                    "version": "1.0"
                ]
            ],
            id: 1,
            sessionID: nil
        )
        guard initialized.object?["result"] != nil else {
            throw KnowledgeProviderError.invalidResponse
        }
        _ = try await post(
            method: "notifications/initialized",
            params: [:],
            id: nil,
            sessionID: initialized.sessionID
        )
        let listed = try await post(
            method: "tools/list",
            params: [:],
            id: 2,
            sessionID: initialized.sessionID
        )
        guard let tools = listed.object?["result"] as? [String: Any],
              let rawTools = tools["tools"] as? [[String: Any]] else {
            throw KnowledgeProviderError.invalidResponse
        }
        return ToolListing(
            sessionID: initialized.sessionID,
            tools: rawTools.compactMap(Self.parseTool)
        )
    }

    private func post(
        method: String,
        params: [String: Any],
        id: Int?,
        sessionID: String?
    ) async throws -> MCPResponse {
        guard let endpoint = configuration.validatedURL else {
            throw KnowledgeProviderError.invalidConfiguration
        }
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        if let id {
            message["id"] = id
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        guard !tokenReadFailed else {
            throw KnowledgeProviderError.unavailable
        }
        if let token = tokenSnapshot, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= 2_000_000 else {
                throw KnowledgeProviderError.responseTooLarge
            }
            guard let http = response as? HTTPURLResponse else {
                throw KnowledgeProviderError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw KnowledgeProviderError.serverRejected(http.statusCode)
            }
            return MCPResponse(
                object: try Self.decodeJSONRPC(data),
                sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID
            )
        } catch let error as KnowledgeProviderError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AnalysisAPIError.timeout
        } catch {
            throw KnowledgeProviderError.unavailable
        }
    }

    private static func decodeJSONRPC(_ data: Data) throws -> [String: Any]? {
        if data.isEmpty { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw KnowledgeProviderError.invalidResponse
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard raw.hasPrefix("data:") else { continue }
            let payload = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let payloadData = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }
            return object
        }
        throw KnowledgeProviderError.invalidResponse
    }

    private static func parseTool(_ raw: [String: Any]) -> Tool? {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let description = raw["description"] as? String ?? ""
        let schema = raw["inputSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any] ?? [:]
        let queryNames = ["query", "q", "search", "keyword", "keywords", "text"]
        let limitNames = ["limit", "top_k", "max_results"]
        guard let queryArgument = queryNames.first(where: { name in
            guard let property = properties[name] as? [String: Any] else {
                return false
            }
            return (property["type"] as? String)?.lowercased() == "string"
        }) else {
            return Tool(
                name: name,
                queryArgument: "query",
                limitArgument: nil,
                looksLikeSearch: false
            )
        }
        let limitArgument = limitNames.first(where: { properties[$0] != nil })
        let searchText = (name + " " + description).lowercased()
        let hasReadIntent = [
            "search", "query", "find", "retrieve", "read", "lookup", "fetch",
            "检索", "搜索", "查询", "读取", "查找", "获取"
        ].contains { searchText.contains($0) }
        let hasWriteIntent = [
            "create", "update", "delete", "write", "send", "execute", "upload",
            "创建", "更新", "删除", "写入", "发送", "执行", "上传"
        ].contains { searchText.contains($0) }
        return Tool(
            name: name,
            queryArgument: queryArgument,
            limitArgument: limitArgument,
            looksLikeSearch: hasReadIntent && !hasWriteIntent
        )
    }

    static func connections(
        from result: [String: Any],
        providerID: String = KnowledgeProviderKind.externalMCP.rawValue,
        providerName: String,
        endpoint: String,
        limit: Int
    ) -> [KnowledgeConnection] {
        var candidates: [[String: Any]] = []
        if let structured = result["structuredContent"] as? [String: Any] {
            candidates.append(contentsOf: dictionaries(from: structured))
        }
        if let content = result["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "text" {
                guard let text = block["text"] as? String else { continue }
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    candidates.append(contentsOf: dictionaries(from: json))
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    candidates.append([
                        "title": "\(providerName) 返回",
                        "excerpt": String(text.prefix(600)),
                        "source_location": ""
                    ])
                }
            }
        }

        var seen = Set<String>()
        return candidates.compactMap { item -> KnowledgeConnection? in
            let title = firstString(in: item, keys: ["title", "name", "subject"]) ?? providerName
            let excerpt = firstString(
                in: item,
                keys: ["excerpt", "summary", "text", "content", "description"]
            ) ?? ""
            let location = firstString(
                in: item,
                keys: ["url", "uri", "source_location", "location", "path"]
            ) ?? ""
            let sourceId = firstString(in: item, keys: ["id", "source_id", "note_id"])
                ?? "\(title)|\(location)"
            guard !excerpt.isEmpty || title != providerName,
                  seen.insert(sourceId).inserted else {
                return nil
            }
            let relevance = firstNumber(in: item, keys: ["relevance", "score", "similarity"])
            return KnowledgeConnection(
                provider: .externalMCP,
                providerId: providerID,
                providerName: providerName,
                sourceId: sourceId,
                title: title,
                excerpt: String(excerpt.prefix(600)),
                sourceLocation: location,
                relevance: relevance,
                retrievedAt: Date()
            )
        }
        .prefix(max(1, limit))
        .map { $0 }
    }

    private static func dictionaries(from value: Any) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        if let dictionary = value as? [String: Any] {
            for key in ["results", "items", "data", "notes", "documents"] {
                if let array = dictionary[key] as? [[String: Any]] {
                    return array
                }
            }
            return [dictionary]
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func firstString(in item: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = item[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstNumber(in item: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = item[key] as? Double { return value }
            if let value = item[key] as? Int { return Double(value) }
            if let value = item[key] as? String, let number = Double(value) { return number }
        }
        return nil
    }

    private struct MCPResponse {
        var object: [String: Any]?
        var sessionID: String?
    }

    private struct Discovery: Sendable {
        var sessionID: String?
        var tool: Tool
        var discoveredAt: Date
    }

    private struct ToolListing: Sendable {
        var sessionID: String?
        var tools: [Tool]
    }

    private struct Tool: Sendable {
        var name: String
        var queryArgument: String
        var limitArgument: String?
        var looksLikeSearch: Bool
    }
}
