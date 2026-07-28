import Foundation

/// 分析接口错误（分类驱动调度行为，实施计划 11.2）
enum AnalysisAPIError: Error, Equatable, Sendable {
    /// 401：凭证无效或所选模型未授权 → 云端分析暂停，修复后可重试
    case unauthorized
    /// 429：限流 → 失败退避
    case rateLimited
    /// 5xx：服务失败 → 失败退避
    case serverError(statusCode: Int)
    /// 其他 4xx
    case clientError(statusCode: Int)
    /// 请求超时（thinking 模型长上下文响应慢；与断网区分）
    case timeout
    /// 网络层失败（断网、连接失败等非超时类）
    case network
    /// stop_reason = max_tokens：输出被长度截断（thinking 预算挤占 text）
    case truncated
    /// 响应或结构化输出无法解析 → 丢弃该快照并保留上一版（实施计划 11.2）
    case invalidResponse
    /// 未配置 API Key
    case missingAPIKey
    /// 当前 App 身份无法静默读取旧 Keychain 凭证
    case credentialAccessRequired
}

extension AnalysisAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "凭证无效或所选模型未开通（401），请在设置中检查后重试"
        case .rateLimited: return "云端限流（429），稍后自动重试"
        case .serverError(let code): return "云端服务失败（\(code)），稍后自动重试"
        case .clientError(let code): return "请求被拒绝（\(code)）"
        case .timeout: return "请求超时（模型响应过慢），将自动重试"
        case .network: return "网络连接失败，稍后自动重试"
        case .truncated: return "分析输出被长度限制截断，已丢弃并保留上一版"
        case .invalidResponse: return "分析结果不合规，已丢弃并保留上一版"
        case .missingAPIKey: return "未配置 API Key"
        case .credentialAccessRequired:
            return "当前 App 无法读取旧凭证，请前往设置重新登录或保存 API Key"
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
        let apiKey: String?
        do {
            apiKey = try apiKeyStore.readKey()
        } catch KeychainError.interactionNotAllowed {
            throw AnalysisAPIError.credentialAccessRequired
        }
        guard let apiKey, !apiKey.isEmpty else {
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
        let apiKey: String?
        do {
            apiKey = try apiKeyStore.readKey()
        } catch KeychainError.interactionNotAllowed {
            throw AnalysisAPIError.credentialAccessRequired
        }
        guard let apiKey, !apiKey.isEmpty else {
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
