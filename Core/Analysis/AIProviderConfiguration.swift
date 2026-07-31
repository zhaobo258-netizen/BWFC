import Foundation

enum AIProviderKind: String, Codable, Sendable, CaseIterable {
    case kimi
    case openAICompatible

    var displayName: String {
        switch self {
        case .kimi: return "Kimi"
        case .openAICompatible: return "OpenAI 兼容"
        }
    }
}

enum KimiModelPreference: String, Codable, Sendable, CaseIterable {
    case k3Recommended = "k3-256k"
    case k3LongContext = "k3"
    case k2Compatibility = "kimi-for-coding"

    var modelID: String { rawValue }

    var displayName: String {
        switch self {
        case .k3Recommended:
            return "Kimi K3 · 256K（推荐）"
        case .k3LongContext:
            return "Kimi K3 · 1M"
        case .k2Compatibility:
            return "Kimi K2.7 Code（兼容）"
        }
    }
}

struct AIProviderConfiguration: Codable, Sendable, Equatable {
    var selectedProvider: AIProviderKind
    var kimiModel: KimiModelPreference
    var openAIBaseURL: String
    var openAIModelID: String

    init(
        selectedProvider: AIProviderKind = .kimi,
        kimiModel: KimiModelPreference = .k3Recommended,
        openAIBaseURL: String = "https://api.openai.com/v1",
        openAIModelID: String = ""
    ) {
        self.selectedProvider = selectedProvider
        self.kimiModel = kimiModel
        self.openAIBaseURL = openAIBaseURL
        self.openAIModelID = openAIModelID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedProvider = try container.decodeIfPresent(
            AIProviderKind.self,
            forKey: .selectedProvider
        ) ?? .kimi
        kimiModel = try container.decodeIfPresent(
            KimiModelPreference.self,
            forKey: .kimiModel
        ) ?? .k3Recommended
        openAIBaseURL = try container.decodeIfPresent(
            String.self,
            forKey: .openAIBaseURL
        ) ?? "https://api.openai.com/v1"
        openAIModelID = try container.decodeIfPresent(
            String.self,
            forKey: .openAIModelID
        ) ?? ""
    }

    var validatedOpenAIBaseURL: URL? {
        Self.validatedBaseURL(openAIBaseURL)
    }

    var normalizedOpenAIModelID: String {
        openAIModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isOpenAIConfigurationValid: Bool {
        validatedOpenAIBaseURL != nil && !normalizedOpenAIModelID.isEmpty
    }

    static func validatedBaseURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        if scheme == "http" {
            guard ["localhost", "127.0.0.1", "::1"].contains(host) else {
                return nil
            }
        }
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }
}

struct AIProviderConfigurationStore: @unchecked Sendable {
    static let defaultsKey = "bwfx.ai.provider.configuration"
    static let openAIKeychainAccount = "analysis-openai-compatible"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AIProviderConfiguration {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let configuration = try? JSONDecoder().decode(
                AIProviderConfiguration.self,
                from: data
              ) else {
            return AIProviderConfiguration()
        }
        return configuration
    }

    func save(_ configuration: AIProviderConfiguration) throws {
        if configuration.selectedProvider == .openAICompatible,
           !configuration.isOpenAIConfigurationValid {
            throw AIProviderConfigurationError.invalidOpenAIConfiguration
        }
        defaults.set(
            try JSONEncoder().encode(configuration),
            forKey: Self.defaultsKey
        )
    }

    func selectKimiAndClearCustomConfiguration() throws {
        try save(AIProviderConfiguration(selectedProvider: .kimi))
    }
}

enum AIProviderConfigurationError: Error, Equatable, LocalizedError {
    case invalidOpenAIConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidOpenAIConfiguration:
            return "请填写有效的 HTTPS（或本机 localhost）地址和模型 ID。"
        }
    }
}

struct AIProviderDescriptor: Sendable, Equatable {
    var id: String
    var displayName: String
    var modelID: String
}

struct AITextGenerationRequest: Sendable, Equatable {
    var system: String
    var input: String
    /// nil 表示由当前 Provider 选择安全默认值，避免 K3 的 thinking 预算
    /// 被套用到输出上限更小的 OpenAI-compatible 模型。
    var maxTokens: Int?

    init(
        system: String,
        input: String,
        maxTokens: Int? = nil
    ) {
        self.system = system
        self.input = input
        self.maxTokens = maxTokens
    }
}

struct AITextGenerationResponse: Sendable, Equatable {
    var text: String
    var provider: AIProviderDescriptor
}

protocol AITextGenerationServing: Sendable {
    func generate(_ request: AITextGenerationRequest) async throws -> AITextGenerationResponse
    func testActiveConnection() async throws -> AIProviderDescriptor
}

struct KimiTextGenerationService: AITextGenerationServing {
    private let transport: KimiAnalysisService

    init(transport: KimiAnalysisService) {
        self.transport = transport
    }

    func generate(_ request: AITextGenerationRequest) async throws -> AITextGenerationResponse {
        let text = try await transport.rawAnalysisText(
            system: request.system,
            inputJSON: request.input,
            maxTokens: request.maxTokens
        )
        return AITextGenerationResponse(
            text: text,
            provider: AIProviderDescriptor(
                id: AIProviderKind.kimi.rawValue,
                displayName: AIProviderKind.kimi.displayName,
                modelID: CloudModelConfig.analysisModelID
            )
        )
    }

    func testActiveConnection() async throws -> AIProviderDescriptor {
        _ = try await transport.testConnection()
        return AIProviderDescriptor(
            id: AIProviderKind.kimi.rawValue,
            displayName: AIProviderKind.kimi.displayName,
            modelID: CloudModelConfig.analysisModelID
        )
    }
}

actor AIProviderRegistry: AITextGenerationServing {
    private let configurationStore: AIProviderConfigurationStore
    private let openAIKeyStore: CloudAPIKeyStore
    private let kimiTransport: KimiAnalysisService
    private let makeSession: @Sendable () -> URLSession

    init(
        configurationStore: AIProviderConfigurationStore,
        openAIKeyStore: CloudAPIKeyStore,
        kimiTransport: KimiAnalysisService,
        makeSession: @escaping @Sendable () -> URLSession = {
            URLSession(
                configuration: .ephemeral,
                delegate: AIProviderNoRedirectDelegate(),
                delegateQueue: nil
            )
        }
    ) {
        self.configurationStore = configurationStore
        self.openAIKeyStore = openAIKeyStore
        self.kimiTransport = kimiTransport
        self.makeSession = makeSession
    }

    func generate(_ request: AITextGenerationRequest) async throws -> AITextGenerationResponse {
        let configuration = configurationStore.load()
        switch configuration.selectedProvider {
        case .kimi:
            let text = try await kimiTransport.rawAnalysisText(
                system: request.system,
                inputJSON: request.input,
                modelID: configuration.kimiModel.modelID,
                maxTokens: request.maxTokens
            )
            return AITextGenerationResponse(
                text: text,
                provider: AIProviderDescriptor(
                    id: AIProviderKind.kimi.rawValue,
                    displayName: AIProviderKind.kimi.displayName,
                    modelID: configuration.kimiModel.modelID
                )
            )
        case .openAICompatible:
            return try await openAIService(configuration: configuration)
                .generate(request)
        }
    }

    func testActiveConnection() async throws -> AIProviderDescriptor {
        let configuration = configurationStore.load()
        switch configuration.selectedProvider {
        case .kimi:
            _ = try await kimiTransport.testConnection(
                modelID: configuration.kimiModel.modelID
            )
            return AIProviderDescriptor(
                id: AIProviderKind.kimi.rawValue,
                displayName: AIProviderKind.kimi.displayName,
                modelID: configuration.kimiModel.modelID
            )
        case .openAICompatible:
            return try await openAIService(configuration: configuration)
                .testConnection()
        }
    }

    private func openAIService(
        configuration: AIProviderConfiguration
    ) throws -> OpenAICompatibleTextGenerationService {
        guard let baseURL = configuration.validatedOpenAIBaseURL,
              !configuration.normalizedOpenAIModelID.isEmpty else {
            throw AIProviderConfigurationError.invalidOpenAIConfiguration
        }
        let apiKey: String?
        do {
            apiKey = try openAIKeyStore.readKey()
        } catch KeychainError.interactionNotAllowed {
            throw AnalysisAPIError.credentialAccessRequired
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw AnalysisAPIError.missingAPIKey
        }
        return OpenAICompatibleTextGenerationService(
            session: makeSession(),
            apiKey: apiKey,
            baseURL: baseURL,
            modelID: configuration.normalizedOpenAIModelID
        )
    }
}

private final class AIProviderNoRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
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

struct OpenAICompatibleTextGenerationService: Sendable {
    private let session: URLSession
    private let apiKey: String
    private let baseURL: URL
    private let modelID: String

    init(
        session: URLSession,
        apiKey: String,
        baseURL: URL,
        modelID: String
    ) {
        self.session = session
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelID = modelID
    }

    func generate(
        _ request: AITextGenerationRequest
    ) async throws -> AITextGenerationResponse {
        let text = try await perform(
            system: request.system,
            input: request.input,
            maxTokens: request.maxTokens ?? 16_384
        )
        return AITextGenerationResponse(
            text: text,
            provider: AIProviderDescriptor(
                id: AIProviderKind.openAICompatible.rawValue,
                displayName: AIProviderKind.openAICompatible.displayName,
                modelID: modelID
            )
        )
    }

    func testConnection() async throws -> AIProviderDescriptor {
        _ = try await perform(
            system: "只回复 pong。",
            input: "ping",
            maxTokens: 8
        )
        return AIProviderDescriptor(
            id: AIProviderKind.openAICompatible.rawValue,
            displayName: AIProviderKind.openAICompatible.displayName,
            modelID: modelID
        )
    }

    private func perform(
        system: String,
        input: String,
        maxTokens: Int
    ) async throws -> String {
        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": max(1, maxTokens),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": input]
            ]
        ]
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = CloudModelConfig.analysisRequestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= 2_000_000 else {
                throw AnalysisAPIError.invalidResponse
            }
            guard let http = response as? HTTPURLResponse else {
                throw AnalysisAPIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                switch http.statusCode {
                case 401, 403: throw AnalysisAPIError.unauthorized
                case 429: throw AnalysisAPIError.rateLimited
                case 500...599:
                    throw AnalysisAPIError.serverError(statusCode: http.statusCode)
                default:
                    throw AnalysisAPIError.clientError(statusCode: http.statusCode)
                }
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = Self.messageText(message["content"]),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AnalysisAPIError.invalidResponse
            }
            return text
        } catch let error as AnalysisAPIError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AnalysisAPIError.timeout
        } catch {
            throw AnalysisAPIError.network
        }
    }

    private var endpointURL: URL {
        if baseURL.path.hasSuffix("/chat/completions") {
            return baseURL
        }
        return baseURL.appending(path: "chat/completions")
    }

    private static func messageText(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let blocks = value as? [[String: Any]] else {
            return nil
        }
        let text = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        .joined()
        return text.isEmpty ? nil : text
    }
}
