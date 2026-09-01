import Foundation

struct ProxyAdaptiveURLSession: @unchecked Sendable {
    private let fixedSession: URLSession?
    private let sessionFactory: @Sendable () -> URLSession
    private static let systemSessionFactory: @Sendable () -> URLSession = {
        makeSystemSession()
    }

    init(
        fixedSession: URLSession? = nil,
        sessionFactory: (@Sendable () -> URLSession)? = nil
    ) {
        self.fixedSession = fixedSession
        self.sessionFactory = sessionFactory ?? Self.systemSessionFactory
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await perform(request)
        } catch let error as URLError
            where fixedSession == nil && Self.shouldRecreateSession(for: error.code) {
            AppLog.logWarning(
                AppLog.analysis,
                LogSanitizer.formatEvent(
                    "analysis_session_recreated_after_network_change",
                    error: String(error.code.rawValue)
                )
            )
            return try await perform(request)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let fixedSession {
            return try await fixedSession.data(for: request)
        }
        let session = sessionFactory()
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    private static func shouldRecreateSession(for code: URLError.Code) -> Bool {
        switch code {
        case .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func makeSystemSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// 基于 Kimi 网关（Anthropic 风格 messages 接口）的谈判分析实现。
///
/// 与 OpenAI Structured Outputs 的差异：
/// - 无 JSON Schema 强制能力：系统提示词约束「只输出 JSON」，
///   本地仍以 AnalysisSchema 严格解码 + 证据过滤兜底；
/// - 响应 content 数组可能含 thinking 块与 text 块：只拼接 text 块；
/// - 可能包裹 ```json 围栏：解析前剥离；
/// - 不发送 store 字段（该接口无此概念）。
struct KimiAnalysisService: NegotiationAnalysisServicing {
    private let networkSession: ProxyAdaptiveURLSession
    private let credentials: any KimiCredentialProviding
    private let baseURL: URL
    private let modelID: String
    private let maxTokens: Int

    init(
        session: URLSession? = nil,
        sessionFactory: (@Sendable () -> URLSession)? = nil,
        apiKeyStore: CloudAPIKeyStore = CloudAPIKeyStore.store(for: .analysis),
        credentials: (any KimiCredentialProviding)? = nil,
        baseURL: URL = CloudModelConfig.analysisBaseURL,
        modelID: String = CloudModelConfig.analysisModelID,
        maxTokens: Int = CloudModelConfig.analysisMaxTokens
    ) {
        self.networkSession = ProxyAdaptiveURLSession(
            fixedSession: session,
            sessionFactory: sessionFactory
        )
        // 凭证优先级：Kimi 账号登录（OAuth，自动刷新）> 静态分析 Key
        self.credentials = credentials ?? KimiCredentialProvider(staticKeyStore: apiKeyStore)
        self.baseURL = baseURL
        self.modelID = modelID
        self.maxTokens = maxTokens
    }

    // MARK: - NegotiationAnalysisServicing

    func analyze(instructions: String, inputJSON: String) async throws -> AnalysisOutputDTO {
        let text = try await rawAnalysisText(
            system: instructions + "\n\n" + AnalysisSystemPrompt.jsonOutputSuffix,
            inputJSON: inputJSON
        )
        return try decodeOutput(text)
    }

    /// 通用传输入口（V1 谈判分析与 V2 通用分析共用同一 HTTP/解析/日志路径）：
    /// 发送 system + user 消息，返回模型的 text 块拼接文本。
    func rawAnalysisText(
        system: String,
        inputJSON: String,
        modelID: String? = nil,
        maxTokens: Int? = nil
    ) async throws -> String {
        // 取当前可用凭证（OAuth 临期自动刷新；未配置抛 missingAPIKey，不发请求）
        let apiKey = try await credentials.validCredential()
        let activeModelID = modelID ?? self.modelID
        let activeMaxTokens = maxTokens ?? self.maxTokens

        let body: [String: Any] = [
            "model": activeModelID,
            "max_tokens": activeMaxTokens,
            "system": system,
            "messages": [
                ["role": "user", "content": inputJSON]
            ]
        ]

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(CloudModelConfig.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = CloudModelConfig.analysisRequestTimeout

        let startedAt = Date()
        do {
            let (data, response) = try await perform(request)
            return try parse(data: data, response: response,
                             durationMs: Self.ms(since: startedAt))
        } catch let error as AnalysisAPIError {
            throw error
        } catch {
            throw AnalysisAPIError.network
        }
    }

    /// 连接测试（实施计划 5.1：只返回可用/不可用与脱敏错误）。
    /// 发起一次最小 messages 请求；非 2xx 按统一分类抛出。
    func testConnection() async throws -> Bool {
        try await testConnection(modelID: modelID)
    }

    func testConnection(modelID: String) async throws -> Bool {
        let apiKey = try await credentials.validCredential()
        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": 8,
            "messages": [
                ["role": "user", "content": "ping"]
            ]
        ]
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(CloudModelConfig.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw AnalysisAPIError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: return true
        case 401: throw AnalysisAPIError.unauthorized
        case 429: throw AnalysisAPIError.rateLimited
        case 500...599: throw AnalysisAPIError.serverError(statusCode: http.statusCode)
        default: throw AnalysisAPIError.clientError(statusCode: http.statusCode)
        }
    }

    // MARK: - 内部

    private var endpointURL: URL {
        baseURL.appending(path: CloudModelConfig.analysisMessagesPath)
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await networkSession.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            // 超时与断网区分（实施计划：超时单独归类便于诊断）
            throw AnalysisAPIError.timeout
        } catch {
            throw AnalysisAPIError.network
        }
    }

    /// 状态码分类 + 提取 text 块文本（HTTP 层公开日志：状态码与耗时）
    private func parse(data: Data, response: URLResponse, durationMs: Int) throws -> String {
        guard let http = response as? HTTPURLResponse else {
            throw AnalysisAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "analysis_http_error", durationMs: durationMs, statusCode: http.statusCode
            ))
            switch http.statusCode {
            case 401: throw AnalysisAPIError.unauthorized
            case 429: throw AnalysisAPIError.rateLimited
            case 500...599: throw AnalysisAPIError.serverError(statusCode: http.statusCode)
            default: throw AnalysisAPIError.clientError(statusCode: http.statusCode)
            }
        }

        guard let dto = try? JSONDecoder().decode(MessagesResponseDTO.self, from: data) else {
            throw AnalysisAPIError.invalidResponse
        }
        // stop_reason = max_tokens：输出被截断，单独归类便于诊断
        if dto.stopReason == "max_tokens" {
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "analysis_truncated", durationMs: durationMs, statusCode: http.statusCode
            ))
            throw AnalysisAPIError.truncated
        }
        AppLog.logInfo(AppLog.analysis, LogSanitizer.formatEvent(
            "analysis_http_ok", durationMs: durationMs, statusCode: http.statusCode
        ))
        // 只拼接 type == "text" 的块（忽略 thinking 等块）
        let text = (dto.content ?? [])
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalysisAPIError.invalidResponse
        }
        return text
    }

    /// 剥离可能的 ```json 围栏（V1/V2 解码共用）
    static func strippedJSONText(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            // 去掉首行围栏（```json 或 ```）与结尾围栏
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if trimmed.hasSuffix("```") {
                trimmed = String(trimmed.dropLast(3))
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// 剥离围栏并走统一严格解码（失败即 invalidResponse，保留上一版）
    private func decodeOutput(_ text: String) throws -> AnalysisOutputDTO {
        let trimmed = Self.strippedJSONText(text)
        guard let data = trimmed.data(using: .utf8),
              let dto = try? JSONDecoder().decode(AnalysisOutputDTO.self, from: data) else {
            // 截断迹象公开记录：输出长度与结尾是否闭合（不记内容）
            let closed = trimmed.hasSuffix("}") || trimmed.hasSuffix("]")
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "analysis_output_invalid",
                error: "len=\(trimmed.count) closed=\(closed)"
            ))
            throw AnalysisAPIError.invalidResponse
        }
        return dto
    }

    /// Anthropic messages 响应（只读取 content 块的 type/text 与 stop_reason）
    private struct MessagesResponseDTO: Decodable {
        let content: [ContentBlock]?
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }

        struct ContentBlock: Decodable {
            let type: String?
            let text: String?
        }
    }
}
