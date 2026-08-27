import Foundation

struct VolcengineDiarizationService: DiarizationServicing {
    static let endpoint = URL(
        string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
    )!
    static let resourceID = "volc.bigasr.auc_turbo"
    static let keychainAccount = "diarization-volcengine"

    private let session: URLSession
    private let apiKeyStore: CloudAPIKeyStore
    private let configuredResourceID: String
    private let endpointURL: URL

    init(
        session: URLSession = .shared,
        apiKeyStore: CloudAPIKeyStore,
        resourceID: String = resourceID,
        endpointURL: URL = endpoint
    ) {
        self.session = session
        self.apiKeyStore = apiKeyStore
        self.configuredResourceID = resourceID
        self.endpointURL = endpointURL
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
        return try await recognize(wavData: audioData)
    }

    func testConnection() async throws -> Bool {
        _ = try await recognize(wavData: Self.silentWAV())
        return true
    }

    private func recognize(wavData: Data) async throws -> DiarizationChunkResult {
        let apiKey: String?
        do {
            apiKey = try apiKeyStore.readKey()
        } catch KeychainError.interactionNotAllowed {
            throw DiarizationAPIError.credentialAccessRequired
        } catch {
            throw DiarizationAPIError.missingAPIKey
        }
        guard let apiKey, !apiKey.isEmpty else { throw DiarizationAPIError.missingAPIKey }

        let requestBody = RequestDTO(
            user: .init(uid: UUID().uuidString),
            audio: .init(data: wavData.base64EncodedString()),
            request: .init()
        )
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(configuredResourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw DiarizationAPIError.invalidResponse
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .userAuthenticationRequired {
            throw DiarizationAPIError.unauthorized
        } catch {
            throw DiarizationAPIError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw DiarizationAPIError.invalidResponse
        }
        try Self.validateHTTPStatus(http.statusCode)

        guard let providerStatus = http.value(forHTTPHeaderField: "X-Api-Status-Code"),
              let statusCode = Int(providerStatus) else {
            throw DiarizationAPIError.invalidResponse
        }
        switch statusCode {
        case 20_000_000:
            return try Self.parseResponse(data)
        case 20_000_003:
            return DiarizationChunkResult(durationMs: 0, segments: [])
        case 45_000_081:
            throw DiarizationAPIError.network
        case 55_000_000...55_999_999:
            throw DiarizationAPIError.serverError(statusCode: statusCode)
        default:
            throw DiarizationAPIError.clientError(statusCode: statusCode)
        }
    }

    static func parseResponse(_ data: Data) throws -> DiarizationChunkResult {
        let dto: ResponseDTO
        do {
            dto = try JSONDecoder().decode(ResponseDTO.self, from: data)
        } catch {
            throw DiarizationAPIError.invalidResponse
        }
        guard let result = dto.result,
              let utterances = result.utterances else {
            throw DiarizationAPIError.invalidResponse
        }
        var segments: [DiarizationChunkResult.Segment] = []
        var seen = Set<String>()
        for utterance in utterances {
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

    private static func validateHTTPStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200..<300: return
        case 401, 403: throw DiarizationAPIError.unauthorized
        case 429: throw DiarizationAPIError.rateLimited
        case 500...599: throw DiarizationAPIError.serverError(statusCode: statusCode)
        default: throw DiarizationAPIError.clientError(statusCode: statusCode)
        }
    }

    private static func silentWAV() -> Data {
        let pcm = Data(repeating: 0, count: 3_200)
        var wav = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt32(16_000), to: &wav)
        appendLittleEndian(UInt32(32_000), to: &wav)
        appendLittleEndian(UInt16(2), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private struct RequestDTO: Encodable {
        let user: UserDTO
        let audio: AudioDTO
        let request: RecognitionRequestDTO

        struct UserDTO: Encodable { let uid: String }
        struct AudioDTO: Encodable { let data: String }
        struct RecognitionRequestDTO: Encodable {
            let modelName = "bigmodel"
            let enableITN = true
            let enablePunc = true
            let showUtterances = true
            let enableSpeakerInfo = true

            enum CodingKeys: String, CodingKey {
                case modelName = "model_name"
                case enableITN = "enable_itn"
                case enablePunc = "enable_punc"
                case showUtterances = "show_utterances"
                case enableSpeakerInfo = "enable_speaker_info"
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

        struct AudioInfoDTO: Decodable { let duration: Int64? }
        struct ResultDTO: Decodable {
            let duration: Int64?
            let utterances: [UtteranceDTO]?
            let additions: ResultAdditionsDTO?
        }
        struct ResultAdditionsDTO: Decodable { let duration: FlexibleString? }
        struct UtteranceDTO: Decodable {
            let startTime: Int64?
            let endTime: Int64?
            let text: String?
            let additions: AdditionsDTO?
            let speaker: FlexibleString?

            enum CodingKeys: String, CodingKey {
                case startTime = "start_time"
                case endTime = "end_time"
                case text, additions, speaker
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
