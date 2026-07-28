import Foundation

/// 已知说话人参考（实施计划 10.1）：本地代号 + 声音样本文件。
/// 真实姓名绝不作为云端参数（实施计划 7.5）。
struct KnownSpeakerReference: Equatable, Sendable {
    /// 本地代号（p_01…p_04）
    var alias: String
    /// 声音样本文件（2–10 秒）
    var sampleURL: URL
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
    /// 当前 App 身份无法静默读取旧 Keychain 凭证
    case credentialAccessRequired
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
        }
    }
}

/// 云端说话人识别服务协议（实施计划 7.3 / 10.1）。
/// 协议隔离网络实现，集成测试用 URLProtocol Mock 替换 URLSession，
/// 编排测试用 Mock 服务替换整个协议。
protocol DiarizationServicing: Sendable {
    /// 上传一个音频分片并返回带说话人代号的确认片段（时间相对分片起点）
    func transcribeChunk(at chunkURL: URL,
                         knownSpeakers: [KnownSpeakerReference]) async throws -> DiarizationChunkResult
    /// 云端连接测试（设置页使用）：只返回可用/不可用与脱敏错误
    func testConnection() async throws -> Bool
}

/// 基于 URLSession 的 OpenAI Audio Transcriptions 实现（阶段 3）。
/// - model/language/response_format 来自 CloudModelConfig（模型 ID 集中配置）；
/// - API Key 只从 Keychain 读取，不落盘、不进日志；
/// - 只读取总时长、片段起止、文字与 speaker 标签。
struct OpenAIDiarizationService: DiarizationServicing {
    private let session: URLSession
    private let apiKeyStore: CloudAPIKeyStore
    private let baseURL: URL
    private let modelID: String

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
        let apiKey: String?
        do {
            apiKey = try apiKeyStore.readKey()
        } catch KeychainError.interactionNotAllowed {
            throw DiarizationAPIError.credentialAccessRequired
        }
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
        // 已知说话人：只传本地代号（≤4），样本转数据 URL
        let speakers = Array(knownSpeakers.prefix(4))
        builder.addArrayField(name: "known_speaker_names[]",
                              values: speakers.map(\.alias))
        for speaker in speakers {
            let sampleData = try Data(contentsOf: speaker.sampleURL)
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
        let apiKey: String?
        do {
            apiKey = try apiKeyStore.readKey()
        } catch KeychainError.interactionNotAllowed {
            throw DiarizationAPIError.credentialAccessRequired
        }
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
        let segments = (dto.segments ?? []).map { segment in
            DiarizationChunkResult.Segment(
                startMs: Int64((segment.start ?? 0) * 1000),
                endMs: Int64((segment.end ?? 0) * 1000),
                text: segment.text ?? "",
                speakerLabel: segment.speaker
            )
        }
        return DiarizationChunkResult(
            durationMs: Int64((dto.duration ?? 0) * 1000),
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

/// 占位实现：未配置网络层时的兜底（报「未实现」）
struct UnimplementedDiarizationService: DiarizationServicing {
    func transcribeChunk(at chunkURL: URL,
                         knownSpeakers: [KnownSpeakerReference]) async throws -> DiarizationChunkResult {
        throw ServiceNotReadyError.notImplemented("云端说话人识别")
    }
    func testConnection() async throws -> Bool {
        throw ServiceNotReadyError.notImplemented("连接测试")
    }
}
