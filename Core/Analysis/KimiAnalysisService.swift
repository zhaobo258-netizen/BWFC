import Foundation

/// 基于 Kimi 网关（Anthropic 风格 messages 接口）的谈判分析实现。
///
/// 与 OpenAI Structured Outputs 的差异：
/// - 无 JSON Schema 强制能力：系统提示词约束「只输出 JSON」，
///   本地仍以 AnalysisSchema 严格解码 + 证据过滤兜底；
/// - 响应 content 数组可能含 thinking 块与 text 块：只拼接 text 块；
/// - 可能包裹 ```json 围栏：解析前剥离；
/// - 不发送 store 字段（该接口无此概念）。
struct KimiAnalysisService: NegotiationAnalysisServicing {
    private let session: URLSession
    private let apiKeyStore: CloudAPIKeyStore
    private let baseURL: URL
    private let modelID: String
    private let maxTokens: Int

    init(
        session: URLSession = .shared,
        apiKeyStore: CloudAPIKeyStore = CloudAPIKeyStore.store(for: .analysis),
        baseURL: URL = CloudModelConfig.analysisBaseURL,
        modelID: String = CloudModelConfig.analysisModelID,
        maxTokens: Int = CloudModelConfig.analysisMaxTokens
    ) {
        self.session = session
        self.apiKeyStore = apiKeyStore
        self.baseURL = baseURL
        self.modelID = modelID
        self.maxTokens = maxTokens
    }

    // MARK: - NegotiationAnalysisServicing

    func analyze(instructions: String, inputJSON: String) async throws -> AnalysisOutputDTO {
        guard let apiKey = try apiKeyStore.readKey(), !apiKey.isEmpty else {
            throw AnalysisAPIError.missingAPIKey
        }

        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": maxTokens,
            // 系统指令 = 8 条分析约束 + 纯文本 JSON 输出约束
            "system": instructions + "\n\n" + AnalysisSystemPrompt.jsonOutputSuffix,
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
        request.timeoutInterval = 120

        let (data, response) = try await perform(request)
        let text = try parse(data: data, response: response)
        return try decodeOutput(text)
    }

    /// 连接测试（实施计划 5.1：只返回可用/不可用与脱敏错误）。
    /// 发起一次最小 messages 请求；非 2xx 按统一分类抛出。
    func testConnection() async throws -> Bool {
        guard let apiKey = try apiKeyStore.readKey(), !apiKey.isEmpty else {
            throw AnalysisAPIError.missingAPIKey
        }
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

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw AnalysisAPIError.network
        }
    }

    /// 状态码分类 + 提取 text 块文本
    private func parse(data: Data, response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse else {
            throw AnalysisAPIError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw AnalysisAPIError.unauthorized
        case 429:
            throw AnalysisAPIError.rateLimited
        case 500...599:
            throw AnalysisAPIError.serverError(statusCode: http.statusCode)
        default:
            throw AnalysisAPIError.clientError(statusCode: http.statusCode)
        }

        guard let dto = try? JSONDecoder().decode(MessagesResponseDTO.self, from: data) else {
            throw AnalysisAPIError.invalidResponse
        }
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

    /// 剥离可能的 ```json 围栏并走统一严格解码（失败即 invalidResponse，保留上一版）
    private func decodeOutput(_ text: String) throws -> AnalysisOutputDTO {
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
        guard let data = trimmed.data(using: .utf8),
              let dto = try? JSONDecoder().decode(AnalysisOutputDTO.self, from: data) else {
            throw AnalysisAPIError.invalidResponse
        }
        return dto
    }

    /// Anthropic messages 响应（只读取 content 块的 type 与 text）
    private struct MessagesResponseDTO: Decodable {
        let content: [ContentBlock]?

        struct ContentBlock: Decodable {
            let type: String?
            let text: String?
        }
    }
}
