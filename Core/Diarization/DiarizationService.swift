import Foundation

enum DiarizationProvider: String, Codable, Sendable, CaseIterable {
    case disabled
    case openAICompatible
    case volcengine
    case iflytek

    var displayName: String {
        switch self {
        case .disabled: return "关闭"
        case .openAICompatible: return "OpenAI 兼容"
        case .volcengine: return "火山引擎"
        case .iflytek: return "讯飞"
        }
    }

}

struct DiarizationProviderConfiguration: Codable, Equatable, Sendable {
    var selectedProvider: DiarizationProvider
    var openAIBaseURL: String
    var openAIModelID: String
    var volcengineResourceID: String
    var iflytekAppID: String

    init(
        selectedProvider: DiarizationProvider = .openAICompatible,
        openAIBaseURL: String = CloudModelConfig.apiBaseURL.absoluteString,
        openAIModelID: String = CloudModelConfig.diarizationModelID,
        volcengineResourceID: String = VolcengineDiarizationService.resourceID,
        iflytekAppID: String = "d83cc043"
    ) {
        self.selectedProvider = selectedProvider
        self.openAIBaseURL = openAIBaseURL
        self.openAIModelID = openAIModelID
        self.volcengineResourceID = volcengineResourceID
        self.iflytekAppID = iflytekAppID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedProvider = try container.decodeIfPresent(
            DiarizationProvider.self,
            forKey: .selectedProvider
        ) ?? .openAICompatible
        openAIBaseURL = try container.decodeIfPresent(
            String.self,
            forKey: .openAIBaseURL
        ) ?? CloudModelConfig.apiBaseURL.absoluteString
        openAIModelID = try container.decodeIfPresent(
            String.self,
            forKey: .openAIModelID
        ) ?? CloudModelConfig.diarizationModelID
        let decodedVolcengineResourceID = try container.decodeIfPresent(
            String.self,
            forKey: .volcengineResourceID
        ) ?? VolcengineDiarizationService.resourceID
        switch decodedVolcengineResourceID {
        case "volc.seedasr.sauc.duration", "volc.bigasr.sauc.duration":
            volcengineResourceID = VolcengineDiarizationService.resourceID
        default:
            volcengineResourceID = decodedVolcengineResourceID
        }
        iflytekAppID = try container.decodeIfPresent(
            String.self,
            forKey: .iflytekAppID
        ) ?? "d83cc043"
    }

    var validatedOpenAIBaseURL: URL? {
        AIProviderConfiguration.validatedBaseURL(openAIBaseURL)
    }

    var normalizedOpenAIModelID: String {
        openAIModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedVolcengineResourceID: String {
        volcengineResourceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedIFlytekAppID: String {
        iflytekAppID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        switch selectedProvider {
        case .disabled:
            return true
        case .openAICompatible:
            return validatedOpenAIBaseURL != nil && !normalizedOpenAIModelID.isEmpty
        case .volcengine:
            return normalizedVolcengineResourceID == VolcengineDiarizationService.resourceID
        case .iflytek:
            return !normalizedIFlytekAppID.isEmpty
        }
    }

    var fingerprint: String {
        let value = [
            selectedProvider.rawValue,
            openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedOpenAIModelID,
            volcengineResourceID.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedIFlytekAppID
        ].joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct DiarizationProviderConfigurationStore: @unchecked Sendable {
    static let defaultsKey = "bwfx.diarization.provider.configuration"
    static let legacyProviderKey = "bwfx.diarization.provider"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DiarizationProviderConfiguration {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let configuration = try? JSONDecoder().decode(
               DiarizationProviderConfiguration.self,
               from: data
           ) {
            return configuration
        }
        let legacy = defaults.string(forKey: Self.legacyProviderKey)
        let provider: DiarizationProvider = legacy == "disabled" ? .disabled : .openAICompatible
        return DiarizationProviderConfiguration(selectedProvider: provider)
    }

    func save(_ configuration: DiarizationProviderConfiguration) throws {
        guard configuration.isValid else {
            throw DiarizationProviderConfigurationError.invalidConfiguration(
                provider: configuration.selectedProvider
            )
        }
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.legacyProviderKey)
    }
}

enum DiarizationProviderConfigurationError: Error, Equatable, LocalizedError {
    case invalidConfiguration(provider: DiarizationProvider)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let provider):
            return "\(provider.displayName) 配置不完整或无效。"
        }
    }
}

/// 已知说话人参考（实施计划 10.1）：本地代号 + 声音样本文件。
/// 真实姓名绝不作为云端参数（实施计划 7.5）。
struct KnownSpeakerReference: Equatable, Sendable {
    /// OpenAI diarization 单次请求支持的已知说话人上限。
    static let maximumCount = 4

    /// 本地代号（p_01…p_04）
    var alias: String
    /// 声音样本文件（2–10 秒）
    var sampleURL: URL
    /// 讯飞声纹分离的远端特征 ID；OpenAI 兼容服务会忽略此字段。
    var iflytekFeatureID: String? = nil
}

enum KnownSpeakerMatchingCapability: Equatable, Sendable {
    case unsupported
    case supported(maximumSpeakers: Int)
}

enum KnownSpeakerSampleIssue: Equatable, Sendable {
    case invalidPath
    case fileMissingOrUnreadable
    case invalidDuration(actualMs: Int64?)
    case providerMinimumDuration(actualMs: Int64, minimumMs: Int64)
}

/// 云端分片识别结果（时间均为相对分片起点的毫秒）
struct DiarizationChunkResult: Equatable, Sendable {
    /// 云端报告的总时长（毫秒）
    var durationMs: Int64
    /// 片段列表
    var segments: [Segment]

    struct Segment: Equatable, Sendable {
        var startMs: Int64
        var endMs: Int64
        var text: String
        /// 云端说话人标签（已知代号或云端原始标签）
        var speakerLabel: String?
    }
}

/// 云端识别错误（分类驱动重试策略，实施计划 11.2）
enum DiarizationAPIError: Error, Equatable {
    /// 401：API Key 无效 → 云端模块暂停，本地继续，修复后可重试
    case unauthorized
    /// 429：限流 → 退避重试
    case rateLimited
    /// 5xx：服务失败 → 退避重试
    case serverError(statusCode: Int)
    /// 其他 4xx：请求问题（不重试）
    case clientError(statusCode: Int)
    /// 网络层失败（超时、断网等）→ 退避重试
    case network
    /// 响应体无法解析（不重试）
    case invalidResponse
    /// 未配置 API Key
    case missingAPIKey
    /// 本机凭证存储暂时不可读取
    case credentialAccessRequired
    /// 已知说话人超过 provider 单次请求容量，不得静默截断。
    case tooManyKnownSpeakers(maximum: Int, actual: Int)
    /// 已配置声纹但样本无法安全上传，不得静默降级为未知说话人。
    case invalidKnownSpeakerSample(alias: String, issue: KnownSpeakerSampleIssue)
    /// 当前 provider 只支持匿名分人，不支持已知人物声纹匹配。
    case knownSpeakerMatchingUnsupported
    /// 已启用历史人物，但尚未注册讯飞声纹。
    case missingProviderVoiceprint(alias: String)
    /// Provider 返回了可读的业务错误。
    case providerError(code: String, message: String)
}

extension DiarizationAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "API Key 无效（401），请在设置中更新后重试"
        case .rateLimited: return "云端限流（429），将自动退避重试"
        case .serverError(let code): return "云端服务失败（\(code)），将自动退避重试"
        case .clientError(let code): return "请求被拒绝（\(code)）"
        case .network: return "网络连接失败，将自动退避重试"
        case .invalidResponse: return "云端响应无法解析"
        case .missingAPIKey: return "未配置 API Key"
        case .credentialAccessRequired:
            return "当前 App 无法读取旧凭证，请前往设置重新保存 API Key"
        case .tooManyKnownSpeakers(let maximum, let actual):
            return "已配置 \(actual) 个声纹样本，单次识别最多支持 \(maximum) 个"
        case .invalidKnownSpeakerSample(let alias, let issue):
            switch issue {
            case .invalidPath:
                return "说话人代号 \(alias) 的声纹样本路径无效"
            case .fileMissingOrUnreadable:
                return "说话人代号 \(alias) 的声纹样本文件缺失或不可读"
            case .invalidDuration(let actualMs):
                if let actualMs {
                    return "说话人代号 \(alias) 的声纹样本时长为 \(actualMs) 毫秒，必须在 2–10 秒之间"
                }
                return "说话人代号 \(alias) 的声纹样本缺少时长，必须在 2–10 秒之间"
            case .providerMinimumDuration(let actualMs, let minimumMs):
                return "说话人代号 \(alias) 的声纹样本时长为 \(actualMs) 毫秒，讯飞注册至少需要 \(minimumMs) 毫秒"
            }
        case .knownSpeakerMatchingUnsupported:
            return "当前分人服务只支持匿名说话人，不支持历史声纹身份匹配"
        case .missingProviderVoiceprint(let alias):
            return "说话人代号 \(alias) 尚未注册讯飞声纹"
        case .providerError(let code, let message):
            return "云端服务错误 \(code)：\(message)"
        }
    }
}

/// 云端说话人识别服务协议（实施计划 7.3 / 10.1）。
/// 协议隔离网络实现，集成测试用 URLProtocol Mock 替换 URLSession，
/// 编排测试用 Mock 服务替换整个协议。
protocol DiarizationServicing: Sendable {
    var knownSpeakerMatchingCapability: KnownSpeakerMatchingCapability { get }
    /// 上传一个音频分片并返回带说话人代号的确认片段（时间相对分片起点）
    func transcribeChunk(at chunkURL: URL,
                         knownSpeakers: [KnownSpeakerReference]) async throws -> DiarizationChunkResult
    /// 云端连接测试（设置页使用）：只返回可用/不可用与脱敏错误
    func testConnection() async throws -> Bool
}

extension DiarizationServicing {
    var knownSpeakerMatchingCapability: KnownSpeakerMatchingCapability { .unsupported }
}

/// 基于 URLSession 的 OpenAI Audio Transcriptions 实现（阶段 3）。
/// - model/language/response_format 来自 CloudModelConfig（模型 ID 集中配置）；
/// - API Key 从本机配置读取，不进日志；
/// - 只读取总时长、片段起止、文字与 speaker 标签。
struct OpenAIDiarizationService: DiarizationServicing {
    private let session: URLSession
    private let apiKeyStore: CloudAPIKeyStore
    private let baseURL: URL
    private let modelID: String

    var knownSpeakerMatchingCapability: KnownSpeakerMatchingCapability {
        .supported(maximumSpeakers: KnownSpeakerReference.maximumCount)
    }

    init(
        session: URLSession = .shared,
        apiKeyStore: CloudAPIKeyStore = CloudAPIKeyStore.store(for: .diarization),
        baseURL: URL = CloudModelConfig.apiBaseURL,
        modelID: String = CloudModelConfig.diarizationModelID
    ) {
        self.session = session
        self.apiKeyStore = apiKeyStore
        self.baseURL = baseURL
        self.modelID = modelID
    }

    func transcribeChunk(
        at chunkURL: URL,
        knownSpeakers: [KnownSpeakerReference]
    ) async throws -> DiarizationChunkResult {
        guard knownSpeakers.count <= KnownSpeakerReference.maximumCount else {
            throw DiarizationAPIError.tooManyKnownSpeakers(
                maximum: KnownSpeakerReference.maximumCount,
                actual: knownSpeakers.count
            )
        }

        let apiKey = try apiKeyStore.readKey()
        guard let apiKey, !apiKey.isEmpty else {
            throw DiarizationAPIError.missingAPIKey
        }

        // 组装 multipart 请求（实施计划 10.1 参数）
        var builder = MultipartFormBuilder()
        builder.addField(name: "model", value: modelID)
        builder.addField(name: "language", value: "zh")
        builder.addField(name: "response_format", value: "diarized_json")
        let chunkData = try Data(contentsOf: chunkURL)
        builder.addFile(name: "file",
                        fileName: "chunk.wav",
                        mimeType: "audio/wav",
                        fileData: chunkData)
        // 已知说话人：只传本地代号，样本转数据 URL。
        // 容量已在入口显式校验，这里不得 prefix 静默丢掉第 5 人。
        let speakers = knownSpeakers
        builder.addArrayField(name: "known_speaker_names[]",
                              values: speakers.map(\.alias))
        for speaker in speakers {
            let sampleData: Data
            do {
                sampleData = try Data(contentsOf: speaker.sampleURL)
            } catch {
                throw DiarizationAPIError.invalidKnownSpeakerSample(
                    alias: speaker.alias,
                    issue: .fileMissingOrUnreadable
                )
            }
            let dataURL = "data:audio/wav;base64,\(sampleData.base64EncodedString())"
            builder.addField(name: "known_speaker_references[]", value: dataURL)
        }

        var request = URLRequest(url: baseURL.appending(path: "/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue(builder.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = builder.finish()
        request.timeoutInterval = 60

        let (data, response) = try await perform(request)
        return try parse(data: data, response: response)
    }

    /// 连接测试：只返回可用/不可用（实施计划 5.1）
    func testConnection() async throws -> Bool {
        let apiKey = try apiKeyStore.readKey()
        guard let apiKey, !apiKey.isEmpty else {
            throw DiarizationAPIError.missingAPIKey
        }
        var request = URLRequest(url: baseURL.appending(path: "/models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw DiarizationAPIError.invalidResponse
        }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - 内部

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .userAuthenticationRequired {
            throw DiarizationAPIError.unauthorized
        } catch {
            throw DiarizationAPIError.network
        }
    }

    private func parse(data: Data, response: URLResponse) throws -> DiarizationChunkResult {
        guard let http = response as? HTTPURLResponse else {
            throw DiarizationAPIError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw DiarizationAPIError.unauthorized
        case 429:
            throw DiarizationAPIError.rateLimited
        case 500...599:
            throw DiarizationAPIError.serverError(statusCode: http.statusCode)
        default:
            throw DiarizationAPIError.clientError(statusCode: http.statusCode)
        }

        guard let dto = try? JSONDecoder().decode(ResponseDTO.self, from: data) else {
            throw DiarizationAPIError.invalidResponse
        }
        guard let rawSegments = dto.segments else {
            throw DiarizationAPIError.invalidResponse
        }
        var segments: [DiarizationChunkResult.Segment] = []
        for segment in rawSegments {
            guard let start = segment.start,
                  let end = segment.end,
                  let text = segment.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !speaker.isEmpty,
                  start.isFinite,
                  end.isFinite,
                  start >= 0,
                  end > start,
                  end <= Double(Int64.max) / 1_000 else {
                throw DiarizationAPIError.invalidResponse
            }
            segments.append(DiarizationChunkResult.Segment(
                startMs: Int64((start * 1_000).rounded()),
                endMs: Int64((end * 1_000).rounded()),
                text: text,
                speakerLabel: speaker
            ))
        }
        let duration = dto.duration
        if let duration {
            guard duration.isFinite,
                  duration >= 0,
                  duration <= Double(Int64.max) / 1_000 else {
                throw DiarizationAPIError.invalidResponse
            }
        }
        return DiarizationChunkResult(
            durationMs: Int64(((duration ?? rawSegments.compactMap(\.end).max() ?? 0) * 1_000).rounded()),
            segments: segments
        )
    }

    /// 响应 DTO：只读取总时长、片段起止、文字与 speaker 标签
    private struct ResponseDTO: Decodable {
        let duration: Double?
        let segments: [SegmentDTO]?

        struct SegmentDTO: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
            let speaker: String?
        }
    }
}

struct DisabledDiarizationService: DiarizationServicing {
    func transcribeChunk(
        at chunkURL: URL,
        knownSpeakers: [KnownSpeakerReference]
    ) async throws -> DiarizationChunkResult {
        throw DiarizationProviderConfigurationError.invalidConfiguration(provider: .disabled)
    }

    func testConnection() async throws -> Bool {
        throw DiarizationProviderConfigurationError.invalidConfiguration(provider: .disabled)
    }
}

enum DiarizationServiceFactory {
    static func make(
        configuration: DiarizationProviderConfiguration,
        keyStore: CloudAPIKeyStore = CloudAPIKeyStore.store(for: .diarization),
        volcengineKeyStore: CloudAPIKeyStore = CloudAPIKeyStore(
            service: CloudAPIKeyStore.defaultService,
            account: VolcengineDiarizationService.credentialAccount
        ),
        volcengineAccessTokenStore: CloudAPIKeyStore = CloudAPIKeyStore(
            service: CloudAPIKeyStore.defaultService,
            account: VolcengineDiarizationService.accessTokenCredentialAccount
        ),
        iflytekCredentialStore: CloudAPIKeyStore = CloudAPIKeyStore(
            service: CloudAPIKeyStore.defaultService,
            account: IFlytekCredentials.credentialAccount
        ),
        session: URLSession = .shared
    ) -> any DiarizationServicing {
        switch configuration.selectedProvider {
        case .disabled:
            return DisabledDiarizationService()
        case .openAICompatible:
            guard let baseURL = configuration.validatedOpenAIBaseURL,
                  !configuration.normalizedOpenAIModelID.isEmpty else {
                return DisabledDiarizationService()
            }
            return OpenAIDiarizationService(
                session: session,
                apiKeyStore: keyStore,
                baseURL: baseURL,
                modelID: configuration.normalizedOpenAIModelID
            )
        case .volcengine:
            guard configuration.isValid else {
                return DisabledDiarizationService()
            }
            return VolcengineDiarizationService(
                session: session,
                apiKeyStore: volcengineKeyStore,
                accessTokenStore: volcengineAccessTokenStore,
                resourceID: configuration.normalizedVolcengineResourceID
            )
        case .iflytek:
            guard configuration.isValid else {
                return DisabledDiarizationService()
            }
            return IFlytekDiarizationService(
                session: session,
                appID: configuration.normalizedIFlytekAppID,
                credentialStore: iflytekCredentialStore
            )
        }
    }
}
