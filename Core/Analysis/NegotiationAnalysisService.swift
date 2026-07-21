import Foundation

/// 分析接口错误（分类驱动调度行为，实施计划 11.2）
enum AnalysisAPIError: Error, Equatable {
    /// 401：API Key 无效 → 云端分析暂停，修复后可重试
    case unauthorized
    /// 429：限流 → 失败退避
    case rateLimited
    /// 5xx：服务失败 → 失败退避
    case serverError(statusCode: Int)
    /// 其他 4xx
    case clientError(statusCode: Int)
    /// 网络层失败（超时、断网）
    case network
    /// 响应或结构化输出无法解析 → 丢弃该快照并保留上一版（实施计划 11.2）
    case invalidResponse
    /// 未配置 API Key
    case missingAPIKey
}

extension AnalysisAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "API Key 无效（401），请在设置中更新后重试"
        case .rateLimited: return "云端限流（429），稍后自动重试"
        case .serverError(let code): return "云端服务失败（\(code)），稍后自动重试"
        case .clientError(let code): return "请求被拒绝（\(code)）"
        case .network: return "网络连接失败，稍后自动重试"
        case .invalidResponse: return "分析结果不合规，已丢弃并保留上一版"
        case .missingAPIKey: return "未配置 API Key"
        }
    }
}

/// 谈判分析服务协议（实施计划 10.2 / 16）。
/// 协议隔离云端实现，为后续阶段（以及未来可能的回应策略扩展）保留替换点。
protocol NegotiationAnalysisServicing: Sendable {
    /// 执行一次增量分析
    /// - Parameters:
    ///   - instructions: 系统指令（AnalysisSystemPrompt.text）
    ///   - inputJSON: 增量输入（AnalysisInputAssembler 组装，含不可信包裹）
    /// - Returns: 通过严格 schema 的输出 DTO（尚未做证据校验）
    func analyze(instructions: String, inputJSON: String) async throws -> AnalysisOutputDTO
    /// 连接测试（设置页使用）：只返回可用/不可用，错误按统一分类抛出（脱敏）
    func testConnection() async throws -> Bool
}

/// 基于 URLSession 的 OpenAI Responses API 实现（阶段 4）。
/// - store: false；严格 JSON Schema 的 Structured Outputs，不解析自由文本；
/// - 模型 ID 来自 CloudModelConfig 集中配置；
/// - API Key 只从 Keychain 读取，不落盘、不进日志。
struct OpenAIAnalysisService: NegotiationAnalysisServicing {
    private let session: URLSession
    private let apiKeyStore: CloudAPIKeyStore
    private let baseURL: URL
    private let modelID: String

    init(
        session: URLSession = .shared,
        apiKeyStore: CloudAPIKeyStore = CloudAPIKeyStore.store(for: .diarization),
        baseURL: URL = CloudModelConfig.apiBaseURL,
        modelID: String = CloudModelConfig.analysisModelID
    ) {
        self.session = session
        self.apiKeyStore = apiKeyStore
        self.baseURL = baseURL
        self.modelID = modelID
    }

    func analyze(instructions: String, inputJSON: String) async throws -> AnalysisOutputDTO {
        guard let apiKey = try apiKeyStore.readKey(), !apiKey.isEmpty else {
            throw AnalysisAPIError.missingAPIKey
        }

        let requestBody: [String: Any] = [
            "model": modelID,
            "store": false, // 实施计划 12.1：不等于商业合同意义上的零留存
            "instructions": instructions,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": inputJSON]
                    ]
                ]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": AnalysisSchema.schemaName,
                    "strict": true,
                    "schema": AnalysisSchema.jsonSchema
                ]
            ]
        ]

        var request = URLRequest(url: baseURL.appending(path: "/responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 120

        let (data, response) = try await perform(request)
        return try parse(data: data, response: response)
    }

    // MARK: - 内部

    /// 连接测试（OpenAI 兼容形态：GET /models）
    func testConnection() async throws -> Bool {
        guard let apiKey = try apiKeyStore.readKey(), !apiKey.isEmpty else {
            throw AnalysisAPIError.missingAPIKey
        }
        var request = URLRequest(url: baseURL.appending(path: "/models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw AnalysisAPIError.invalidResponse
        }
        return (200..<300).contains(http.statusCode)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw AnalysisAPIError.network
        }
    }

    private func parse(data: Data, response: URLResponse) throws -> AnalysisOutputDTO {
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

        // Responses API：取第一个 output_text 文本作为结构化输出
        guard let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data) else {
            throw AnalysisAPIError.invalidResponse
        }
        for item in envelope.output ?? [] {
            for content in item.content ?? [] where content.type == "output_text" {
                if let text = content.text,
                   let textData = text.data(using: .utf8),
                   let dto = try? JSONDecoder().decode(AnalysisOutputDTO.self, from: textData) {
                    return dto
                }
            }
        }
        throw AnalysisAPIError.invalidResponse
    }

    private struct ResponseEnvelope: Decodable {
        let output: [OutputItem]?

        struct OutputItem: Decodable {
            let content: [ContentItem]?
        }

        struct ContentItem: Decodable {
            let type: String?
            let text: String?
        }
    }
}

/// 占位实现：未配置网络层时的兜底（报「未实现」）
struct UnimplementedNegotiationAnalysisService: NegotiationAnalysisServicing {
    func analyze(instructions: String, inputJSON: String) async throws -> AnalysisOutputDTO {
        throw ServiceNotReadyError.notImplemented("谈判分析")
    }
    func testConnection() async throws -> Bool {
        throw ServiceNotReadyError.notImplemented("连接测试")
    }
}
