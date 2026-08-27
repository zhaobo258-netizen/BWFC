import Foundation

protocol VolcengineWebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

protocol VolcengineWebSocketTransport: Sendable {
    func connect(request: URLRequest) async throws -> any VolcengineWebSocketConnection
}

struct URLSessionVolcengineWebSocketTransport: VolcengineWebSocketTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(request: URLRequest) async throws -> any VolcengineWebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionVolcengineWebSocketConnection(task: task)
    }
}

private actor URLSessionVolcengineWebSocketConnection: VolcengineWebSocketConnection {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string: throw DiarizationAPIError.invalidResponse
        @unknown default: throw DiarizationAPIError.invalidResponse
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

struct VolcengineDiarizationService: DiarizationServicing {
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")!
    static let keychainAccount = "diarization-volcengine"

    private let apiKeyStore: CloudAPIKeyStore
    private let resourceID: String
    private let transport: any VolcengineWebSocketTransport
    private let endpointURL: URL
    private let timeout: Duration

    init(
        apiKeyStore: CloudAPIKeyStore,
        resourceID: String,
        transport: any VolcengineWebSocketTransport = URLSessionVolcengineWebSocketTransport(),
        endpointURL: URL = endpoint,
        timeout: Duration = .seconds(60)
    ) {
        self.apiKeyStore = apiKeyStore
        self.resourceID = resourceID
        self.transport = transport
        self.endpointURL = endpointURL
        self.timeout = timeout
    }

    func transcribeChunk(
        at chunkURL: URL,
        knownSpeakers: [KnownSpeakerReference]
    ) async throws -> DiarizationChunkResult {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: chunkURL)
        } catch {
            throw DiarizationAPIError.network
        }
        guard !audioData.isEmpty else { throw DiarizationAPIError.invalidResponse }
        return try await transcribe(audioData: audioData, format: "wav")
    }

    func testConnection() async throws -> Bool {
        _ = try await transcribe(audioData: Self.silentPCM(), format: "raw")
        return true
    }

    private func transcribe(audioData: Data, format: String) async throws -> DiarizationChunkResult {
        let apiKey: String?
        do {
            apiKey = try apiKeyStore.readKey()
        } catch KeychainError.interactionNotAllowed {
            throw DiarizationAPIError.credentialAccessRequired
        } catch {
            throw DiarizationAPIError.missingAPIKey
        }
        guard let apiKey, !apiKey.isEmpty else { throw DiarizationAPIError.missingAPIKey }

        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = timeout.timeInterval
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")

        let connection: any VolcengineWebSocketConnection
        do {
            connection = try await transport.connect(request: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        defer { Task { await connection.close() } }

        do {
            let requestPayload = try JSONEncoder().encode(RequestDTO(format: format))
            try await connection.send(VolcengineProtocolCodec.encodeJSONRequest(requestPayload))
            let packetSize = 200 * 1024
            var offset = 0
            var sequence: Int32 = 2
            while offset < audioData.count {
                let end = min(offset + packetSize, audioData.count)
                let isFinal = end == audioData.count
                try await connection.send(VolcengineProtocolCodec.encodeAudio(
                    audioData.subdata(in: offset..<end),
                    sequence: sequence,
                    isFinal: isFinal
                ))
                offset = end
                sequence += 1
            }
            return try await receiveFinalResult(from: connection)
        } catch let error as DiarizationAPIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    private func receiveFinalResult(
        from connection: any VolcengineWebSocketConnection
    ) async throws -> DiarizationChunkResult {
        try await withThrowingTaskGroup(of: DiarizationChunkResult.self) { group in
            group.addTask {
                var latest: DiarizationChunkResult?
                for _ in 0..<200 {
                    let data = try await connection.receive()
                    let frame: VolcengineFrame
                    do {
                        frame = try VolcengineProtocolCodec.decode(data)
                    } catch {
                        throw DiarizationAPIError.invalidResponse
                    }
                    switch frame.messageType {
                    case .fullServerResponse:
                        latest = try Self.parseResponse(frame.payload)
                        if frame.isFinal, let latest { return latest }
                    case .serverAcknowledgement:
                        continue
                    case .serverError:
                        throw Self.mapServerError(frame.errorCode)
                    default:
                        throw DiarizationAPIError.invalidResponse
                    }
                }
                throw DiarizationAPIError.invalidResponse
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                await connection.close()
                throw DiarizationAPIError.network
            }
            guard let result = try await group.next() else {
                throw DiarizationAPIError.invalidResponse
            }
            group.cancelAll()
            return result
        }
    }

    static func parseResponse(_ data: Data) throws -> DiarizationChunkResult {
        let dto: ResponseDTO
        do {
            dto = try JSONDecoder().decode(ResponseDTO.self, from: data)
        } catch {
            throw DiarizationAPIError.invalidResponse
        }
        guard let result = dto.result, let utterances = result.utterances else {
            throw DiarizationAPIError.invalidResponse
        }
        var segments: [DiarizationChunkResult.Segment] = []
        var seen = Set<String>()
        for utterance in utterances where utterance.definite != false {
            let text = utterance.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let start = utterance.startTime,
                  let end = utterance.endTime,
                  start >= 0,
                  end > start,
                  !text.isEmpty else {
                throw DiarizationAPIError.invalidResponse
            }
            let speaker = utterance.additions?.speakerID?.value
                ?? utterance.additions?.speaker?.value
                ?? utterance.speaker?.value
            let key = "\(start)|\(end)|\(speaker ?? "")|\(text)"
            guard seen.insert(key).inserted else { continue }
            segments.append(.init(
                startMs: start,
                endMs: end,
                text: text,
                speakerLabel: speaker
            ))
        }
        let duration = result.duration
            ?? result.additions?.duration?.int64Value
            ?? dto.audioInfo?.duration
            ?? segments.map(\.endMs).max()
            ?? 0
        guard duration >= 0 else { throw DiarizationAPIError.invalidResponse }
        return DiarizationChunkResult(durationMs: duration, segments: segments)
    }

    private static func mapServerError(_ code: Int32?) -> DiarizationAPIError {
        guard let code else { return .invalidResponse }
        switch code {
        case 401: return .unauthorized
        case 429: return .rateLimited
        case 45000081: return .network
        case 500...599, 55_000_000...55_999_999: return .serverError(statusCode: Int(code))
        default: return .clientError(statusCode: Int(code))
        }
    }

    private static func mapTransportError(_ error: Error) -> DiarizationAPIError {
        if let error = error as? DiarizationAPIError { return error }
        if let urlError = error as? URLError,
           urlError.code == .userAuthenticationRequired {
            return .unauthorized
        }
        return .network
    }

    private static func silentPCM() -> Data {
        Data(repeating: 0, count: 3_200)
    }

    private struct RequestDTO: Encodable {
        let user = User(uid: UUID().uuidString)
        let audio: Audio
        let request = RecognitionRequest()

        init(format: String) {
            audio = Audio(format: format)
        }

        struct User: Encodable { let uid: String }
        struct Audio: Encodable {
            let format: String
            let codec = "raw"
            let rate: Int?
            let bits: Int?
            let channel: Int?

            init(format: String) {
                self.format = format
                let isRaw = format == "raw"
                rate = isRaw ? 16_000 : nil
                bits = isRaw ? 16 : nil
                channel = isRaw ? 1 : nil
            }
        }
        struct RecognitionRequest: Encodable {
            let modelName = "bigmodel"
            let enableITN = true
            let enablePunc = true
            let showUtterances = true
            let enableSpeakerInfo = true
            let resultType = "full"

            enum CodingKeys: String, CodingKey {
                case modelName = "model_name"
                case enableITN = "enable_itn"
                case enablePunc = "enable_punc"
                case showUtterances = "show_utterances"
                case enableSpeakerInfo = "enable_speaker_info"
                case resultType = "result_type"
            }
        }
    }

    private struct ResponseDTO: Decodable {
        let result: ResultDTO?
        let audioInfo: AudioInfoDTO?

        enum CodingKeys: String, CodingKey {
            case result
            case audioInfo = "audio_info"
        }

        struct AudioInfoDTO: Decodable {
            let duration: Int64?
        }

        struct ResultDTO: Decodable {
            let duration: Int64?
            let utterances: [UtteranceDTO]?
            let additions: ResultAdditionsDTO?
        }

        struct ResultAdditionsDTO: Decodable {
            let duration: FlexibleString?
        }

        struct UtteranceDTO: Decodable {
            let startTime: Int64?
            let endTime: Int64?
            let text: String?
            let definite: Bool?
            let additions: AdditionsDTO?
            let speaker: FlexibleString?

            enum CodingKeys: String, CodingKey {
                case startTime = "start_time"
                case endTime = "end_time"
                case text, definite, additions, speaker
            }
        }

        struct AdditionsDTO: Decodable {
            let speaker: FlexibleString?
            let speakerID: FlexibleString?

            enum CodingKeys: String, CodingKey {
                case speaker
                case speakerID = "speaker_id"
            }
        }

        struct FlexibleString: Decodable {
            let value: String

            var int64Value: Int64? { Int64(value) }

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) {
                    value = string
                } else if let integer = try? container.decode(Int.self) {
                    value = String(integer)
                } else {
                    throw DecodingError.typeMismatch(
                        String.self,
                        .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer")
                    )
                }
            }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
