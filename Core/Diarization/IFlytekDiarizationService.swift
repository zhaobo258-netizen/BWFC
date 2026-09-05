import CryptoKit
import Foundation

struct IFlytekCredentials: Codable, Equatable, Sendable {
    static let credentialAccount = "diarization-iflytek-credentials"

    var accessKeyID: String
    var accessKeySecret: String

    var isValid: Bool {
        !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func load(from store: CloudAPIKeyStore) throws -> IFlytekCredentials {
        guard let raw = try store.readKey(),
              let data = raw.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(Self.self, from: data),
              credentials.isValid else {
            throw DiarizationAPIError.missingAPIKey
        }
        return credentials
    }

    func save(to store: CloudAPIKeyStore) throws {
        guard isValid else { throw DiarizationAPIError.missingAPIKey }
        let data = try JSONEncoder().encode(self)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw DiarizationAPIError.invalidResponse
        }
        try store.saveKey(raw)
    }
}

enum IFlytekRequestSigner {
    static func makeURL(
        baseURL: URL,
        path: String,
        parameters: [String: String],
        accessKeySecret: String
    ) throws -> (url: URL, signature: String) {
        let encodedPairs = parameters
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
        let baseString = encodedPairs.joined(separator: "&")
        let key = SymmetricKey(data: Data(accessKeySecret.utf8))
        let signature = Data(
            HMAC<Insecure.SHA1>.authenticationCode(
                for: Data(baseString.utf8),
                using: key
            )
        ).base64EncodedString()
        let query = encodedPairs.joined(separator: "&")
        guard let url = URL(string: baseURL.absoluteString + path + "?" + query) else {
            throw DiarizationAPIError.invalidResponse
        }
        return (url, signature)
    }

    static func dateTime(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }

    static func randomString() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

struct IFlytekVoiceprintService: Sendable {
    static let endpoint = URL(string: "https://office-api-personal-dx.iflyaisol.com")!
    static let minimumSampleDurationMs: Int64 = 10_000

    private let session: URLSession
    private let appID: String
    private let credentialStore: CloudAPIKeyStore
    private let endpointURL: URL
    private let now: @Sendable () -> Date
    private let randomString: @Sendable () -> String

    init(
        session: URLSession = .shared,
        appID: String,
        credentialStore: CloudAPIKeyStore,
        endpointURL: URL = Self.endpoint,
        now: @escaping @Sendable () -> Date = { Date() },
        randomString: @escaping @Sendable () -> String = {
            IFlytekRequestSigner.randomString()
        }
    ) {
        self.session = session
        self.appID = appID
        self.credentialStore = credentialStore
        self.endpointURL = endpointURL
        self.now = now
        self.randomString = randomString
    }

    func register(sampleURL: URL) async throws -> String {
        try validateSample(sampleURL)
        let body = VoiceprintRequestBody(
            audioData: try voiceprintUploadData(from: sampleURL).base64EncodedString(),
            audioType: "raw",
            uid: "bwfx",
            featureID: nil,
            featureIDs: nil
        )
        let envelope = try await request(path: "/res/feature/v1/register", body: body)
        guard let nestedData = envelope.data?.data(using: .utf8),
              let registration = try? JSONDecoder().decode(RegistrationData.self, from: nestedData),
              registration.status == 1,
              !registration.featureID.isEmpty else {
            throw DiarizationAPIError.invalidResponse
        }
        return registration.featureID
    }

    func update(featureID: String, sampleURL: URL) async throws {
        try validateSample(sampleURL)
        let body = VoiceprintRequestBody(
            audioData: try voiceprintUploadData(from: sampleURL).base64EncodedString(),
            audioType: "raw",
            uid: nil,
            featureID: featureID,
            featureIDs: nil
        )
        _ = try await request(path: "/res/feature/v1/update", body: body)
    }

    func delete(featureIDs: [String]) async throws {
        guard !featureIDs.isEmpty else { return }
        let body = VoiceprintRequestBody(
            audioData: nil,
            audioType: nil,
            uid: nil,
            featureID: nil,
            featureIDs: featureIDs
        )
        _ = try await request(path: "/res/feature/v1/delete", body: body)
    }

    static func sampleSHA256(at url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func validateSample(_ url: URL) throws {
        let duration: Int64
        do {
            duration = try AudioChunkExtractor.durationMs(of: url)
        } catch {
            throw DiarizationAPIError.invalidKnownSpeakerSample(
                alias: "voiceprint",
                issue: .fileMissingOrUnreadable
            )
        }
        guard duration >= Self.minimumSampleDurationMs else {
            throw DiarizationAPIError.invalidKnownSpeakerSample(
                alias: "voiceprint",
                issue: .providerMinimumDuration(
                    actualMs: duration,
                    minimumMs: Self.minimumSampleDurationMs
                )
            )
        }
    }

    private func voiceprintUploadData(from sourceURL: URL) throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory.appending(
            path: "bwfx-iflytek-upload-\(UUID().uuidString).wav",
            directoryHint: .notDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try AudioChunkExtractor.convertToIFlytekVoiceprintWAV(
            from: sourceURL,
            to: temporaryURL
        )
        return try Data(contentsOf: temporaryURL)
    }

    private func request(
        path: String,
        body: VoiceprintRequestBody
    ) async throws -> VoiceprintEnvelope {
        let credentials = try IFlytekCredentials.load(from: credentialStore)
        let parameters = [
            "appId": appID,
            "accessKeyId": credentials.accessKeyID,
            "dateTime": IFlytekRequestSigner.dateTime(now()),
            "signatureRandom": randomString()
        ]
        let signed = try IFlytekRequestSigner.makeURL(
            baseURL: endpointURL,
            path: path,
            parameters: parameters,
            accessKeySecret: credentials.accessKeySecret
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signed.signature, forHTTPHeaderField: "signature")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await perform(request)
        try validateHTTP(response)
        guard let envelope = try? JSONDecoder().decode(VoiceprintEnvelope.self, from: data) else {
            throw DiarizationAPIError.invalidResponse
        }
        try validateBusinessCode(envelope.code, message: envelope.desc ?? "讯飞声纹服务拒绝请求")
        return envelope
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw DiarizationAPIError.network
        }
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DiarizationAPIError.invalidResponse
        }
        try IFlytekDiarizationService.validateHTTPStatus(http.statusCode)
    }

    private struct VoiceprintRequestBody: Encodable {
        var audioData: String?
        var audioType: String?
        var uid: String?
        var featureID: String?
        var featureIDs: [String]?

        enum CodingKeys: String, CodingKey {
            case audioData = "audio_data"
            case audioType = "audio_type"
            case uid
            case featureID = "feature_id"
            case featureIDs = "feature_ids"
        }
    }

    private struct VoiceprintEnvelope: Decodable {
        var code: String
        var desc: String?
        var data: String?
    }

    private struct RegistrationData: Decodable {
        var featureID: String
        var status: Int

        enum CodingKeys: String, CodingKey {
            case featureID = "feature_id"
            case status
        }
    }
}

struct IFlytekDiarizationService: DiarizationServicing, Sendable {
    static let endpoint = URL(string: "https://office-api-ist-dx.iflyaisol.com")!

    private let session: URLSession
    private let appID: String
    private let credentialStore: CloudAPIKeyStore
    private let endpointURL: URL
    private let now: @Sendable () -> Date
    private let randomString: @Sendable () -> String
    private let sleep: @Sendable (Int64) async -> Void
    private let maximumPollCount: Int

    var recordingLimits: DiarizationRecordingLimits? {
        DiarizationRecordingLimits(maximumBytes: 500_000_000, maximumDurationMs: 18_000_000)
    }

    var knownSpeakerMatchingCapability: KnownSpeakerMatchingCapability {
        .supported(maximumSpeakers: 64)
    }

    init(
        session: URLSession = .shared,
        appID: String,
        credentialStore: CloudAPIKeyStore,
        endpointURL: URL = Self.endpoint,
        now: @escaping @Sendable () -> Date = { Date() },
        randomString: @escaping @Sendable () -> String = {
            IFlytekRequestSigner.randomString()
        },
        sleep: @escaping @Sendable (Int64) async -> Void = { milliseconds in
            try? await Task.sleep(for: .milliseconds(milliseconds))
        },
        maximumPollCount: Int = 45
    ) {
        self.session = session
        self.appID = appID
        self.credentialStore = credentialStore
        self.endpointURL = endpointURL
        self.now = now
        self.randomString = randomString
        self.sleep = sleep
        self.maximumPollCount = maximumPollCount
    }

    func transcribeChunk(
        at chunkURL: URL,
        knownSpeakers: [KnownSpeakerReference]
    ) async throws -> DiarizationChunkResult {
        try await transcribe(at: chunkURL, knownSpeakers: knownSpeakers, pollCount: maximumPollCount)
    }

    func transcribeRecording(
        at audioURL: URL,
        knownSpeakers: [KnownSpeakerReference]
    ) async throws -> DiarizationChunkResult {
        try await transcribe(at: audioURL, knownSpeakers: knownSpeakers, pollCount: max(maximumPollCount, 1_800))
    }

    private func transcribe(
        at chunkURL: URL,
        knownSpeakers: [KnownSpeakerReference],
        pollCount: Int
    ) async throws -> DiarizationChunkResult {
        try Task.checkCancellation()
        let registeredSpeakers = knownSpeakers.compactMap {
            reference -> (reference: KnownSpeakerReference, featureID: String)? in
            guard let featureID = reference.iflytekFeatureID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !featureID.isEmpty else {
                return nil
            }
            return (reference, featureID)
        }
        guard registeredSpeakers.count <= 64 else {
            throw DiarizationAPIError.tooManyKnownSpeakers(
                maximum: 64,
                actual: registeredSpeakers.count
            )
        }
        let credentials = try IFlytekCredentials.load(from: credentialStore)
        let audioData: Data
        let durationMs: Int64
        do {
            audioData = try Data(contentsOf: chunkURL)
            durationMs = try AudioChunkExtractor.durationMs(of: chunkURL)
        } catch {
            throw DiarizationAPIError.network
        }
        guard !audioData.isEmpty, durationMs > 0 else {
            throw DiarizationAPIError.invalidResponse
        }
        let featureIDs = registeredSpeakers.map(\.featureID)

        let signatureRandom = randomString()
        let upload = try await upload(
            audioData: audioData,
            durationMs: durationMs,
            featureIDs: featureIDs,
            credentials: credentials,
            signatureRandom: signatureRandom
        )
        let aliasesByRole = Dictionary(
            uniqueKeysWithValues: registeredSpeakers.enumerated().map {
                (String($0.offset + 1), $0.element.reference.alias)
            }
        )
        let aliasesByFeatureID = Dictionary(
            uniqueKeysWithValues: registeredSpeakers.map {
                ($0.featureID, $0.reference.alias)
            }
        )
        for attempt in 0..<pollCount {
            try Task.checkCancellation()
            if attempt > 0 { await sleep(2_000) }
            try Task.checkCancellation()
            let envelope = try await query(
                orderID: upload.orderID,
                credentials: credentials,
                signatureRandom: signatureRandom
            )
            guard let orderInfo = envelope.content?.orderInfo else {
                throw DiarizationAPIError.invalidResponse
            }
            switch orderInfo.status {
            case 0, 3:
                continue
            case 4:
                guard let raw = envelope.content?.orderResult, !raw.isEmpty else {
                    throw DiarizationAPIError.invalidResponse
                }
                return try Self.parseOrderResult(
                    raw,
                    durationMs: orderInfo.originalDuration ?? durationMs,
                    aliasesByRole: aliasesByRole,
                    aliasesByFeatureID: aliasesByFeatureID
                )
            default:
                throw DiarizationAPIError.providerError(
                    code: String(orderInfo.status),
                    message: "转写订单失败"
                )
            }
        }
        throw DiarizationAPIError.network
    }

    func testConnection() async throws -> Bool {
        let credentials = try IFlytekCredentials.load(from: credentialStore)
        let envelope = try await queryEnvelope(
            orderID: "BWFX" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            credentials: credentials,
            signatureRandom: randomString()
        )
        if envelope.code == "000000" || envelope.code == "100001" || envelope.code == "100037" {
            return true
        }
        try validateBusinessCode(
            envelope.code,
            message: envelope.descInfo ?? "讯飞转写服务拒绝请求"
        )
        return false
    }

    private func upload(
        audioData: Data,
        durationMs: Int64,
        featureIDs: [String],
        credentials: IFlytekCredentials,
        signatureRandom: String
    ) async throws -> UploadResult {
        var parameters = [
            "appId": appID,
            "accessKeyId": credentials.accessKeyID,
            "dateTime": IFlytekRequestSigner.dateTime(now()),
            "signatureRandom": signatureRandom,
            "fileSize": String(audioData.count),
            "fileName": "chunk.wav",
            "language": "autodialect",
            "duration": String(durationMs),
            "roleType": featureIDs.isEmpty ? "1" : "3",
            "roleNum": "0"
        ]
        if !featureIDs.isEmpty {
            parameters["featureIds"] = featureIDs.joined(separator: ",")
        }
        let signed = try IFlytekRequestSigner.makeURL(
            baseURL: endpointURL,
            path: "/v2/upload",
            parameters: parameters,
            accessKeySecret: credentials.accessKeySecret
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(signed.signature, forHTTPHeaderField: "signature")
        request.httpBody = audioData
        let envelope = try await send(request)
        guard let orderID = envelope.content?.orderID, !orderID.isEmpty else {
            throw DiarizationAPIError.invalidResponse
        }
        return UploadResult(orderID: orderID)
    }

    private func query(
        orderID: String,
        credentials: IFlytekCredentials,
        signatureRandom: String
    ) async throws -> APIEnvelope {
        let envelope = try await queryEnvelope(
            orderID: orderID,
            credentials: credentials,
            signatureRandom: signatureRandom
        )
        try validateBusinessCode(
            envelope.code,
            message: envelope.descInfo ?? "讯飞转写服务拒绝请求"
        )
        return envelope
    }

    private func queryEnvelope(
        orderID: String,
        credentials: IFlytekCredentials,
        signatureRandom: String
    ) async throws -> APIEnvelope {
        let parameters = [
            "accessKeyId": credentials.accessKeyID,
            "dateTime": IFlytekRequestSigner.dateTime(now()),
            "orderId": orderID,
            "resultType": "transfer",
            "signatureRandom": signatureRandom
        ]
        let signed = try IFlytekRequestSigner.makeURL(
            baseURL: endpointURL,
            path: "/v2/getResult",
            parameters: parameters,
            accessKeySecret: credentials.accessKeySecret
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signed.signature, forHTTPHeaderField: "signature")
        request.httpBody = Data("{}".utf8)
        return try await rawSend(request)
    }

    private func send(_ request: URLRequest) async throws -> APIEnvelope {
        let envelope = try await rawSend(request)
        try validateBusinessCode(
            envelope.code,
            message: envelope.descInfo ?? "讯飞转写服务拒绝请求"
        )
        return envelope
    }

    private func rawSend(_ request: URLRequest) async throws -> APIEnvelope {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiarizationAPIError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw DiarizationAPIError.invalidResponse
        }
        try Self.validateHTTPStatus(http.statusCode)
        guard let envelope = try? JSONDecoder().decode(APIEnvelope.self, from: data) else {
            throw DiarizationAPIError.invalidResponse
        }
        return envelope
    }

    static func validateHTTPStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200..<300: return
        case 401, 403: throw DiarizationAPIError.unauthorized
        case 429: throw DiarizationAPIError.rateLimited
        case 500...599: throw DiarizationAPIError.serverError(statusCode: statusCode)
        default: throw DiarizationAPIError.clientError(statusCode: statusCode)
        }
    }

    static func parseOrderResult(
        _ raw: String,
        durationMs: Int64,
        aliasesByRole: [String: String],
        aliasesByFeatureID: [String: String]
    ) throws -> DiarizationChunkResult {
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(OrderResultDTO.self, from: data) else {
            throw DiarizationAPIError.invalidResponse
        }
        var segments: [DiarizationChunkResult.Segment] = []
        var previousSpeaker: String?
        for lattice in result.lattice {
            guard let bestData = lattice.json1Best.data(using: .utf8),
                  let best = try? JSONDecoder().decode(BestDTO.self, from: bestData),
                  let start = Int64(best.st.bg),
                  let end = Int64(best.st.ed),
                  start >= 0,
                  end > start else {
                throw DiarizationAPIError.invalidResponse
            }
            let text = best.st.rt
                .flatMap(\.ws)
                .compactMap { $0.cw.first?.word }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let role = best.st.rl?.trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker: String?
            if let role, role == "0" {
                speaker = previousSpeaker
            } else if let role, !role.isEmpty {
                speaker = aliasesByRole[role]
                    ?? aliasesByFeatureID[role]
                    ?? "speaker_\(role)"
            } else {
                speaker = nil
            }
            previousSpeaker = speaker ?? previousSpeaker
            segments.append(.init(
                startMs: start,
                endMs: end,
                text: text,
                speakerLabel: speaker
            ))
        }
        let resolvedDuration = max(durationMs, segments.map(\.endMs).max() ?? 0)
        return DiarizationChunkResult(durationMs: resolvedDuration, segments: segments)
    }

    private struct UploadResult { var orderID: String }

    private struct APIEnvelope: Decodable {
        var code: String
        var descInfo: String?
        var content: ContentDTO?

        struct ContentDTO: Decodable {
            var orderID: String?
            var orderInfo: OrderInfoDTO?
            var orderResult: String?

            enum CodingKeys: String, CodingKey {
                case orderID = "orderId"
                case orderInfo, orderResult
            }
        }

        struct OrderInfoDTO: Decodable {
            var status: Int
            var originalDuration: Int64?
        }
    }

    private struct OrderResultDTO: Decodable {
        var lattice: [LatticeDTO]
    }

    private struct LatticeDTO: Decodable {
        var json1Best: String

        enum CodingKeys: String, CodingKey {
            case json1Best = "json_1best"
        }
    }

    private struct BestDTO: Decodable {
        var st: StatementDTO
    }

    private struct StatementDTO: Decodable {
        var bg: String
        var ed: String
        var rl: String?
        var rt: [ResultTokenDTO]
    }

    private struct ResultTokenDTO: Decodable {
        var ws: [WordSlotDTO]
    }

    private struct WordSlotDTO: Decodable {
        var cw: [CandidateWordDTO]
    }

    private struct CandidateWordDTO: Decodable {
        var word: String

        enum CodingKeys: String, CodingKey {
            case word = "w"
        }
    }
}

private func validateBusinessCode(_ code: String, message: String) throws {
    switch code {
    case "000000":
        return
    case "000002", "100007", "100008", "100009":
        throw DiarizationAPIError.unauthorized
    case "100012":
        throw DiarizationAPIError.rateLimited
    case "999999":
        throw DiarizationAPIError.serverError(statusCode: 999_999)
    default:
        throw DiarizationAPIError.providerError(code: code, message: message)
    }
}
