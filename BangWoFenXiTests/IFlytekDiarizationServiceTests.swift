import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

@Suite("讯飞转写与声纹", .serialized)
final class IFlytekDiarizationServiceTests {
    let session: URLSession
    let credentialStore: CloudAPIKeyStore
    let credentialServiceName = "com.zhaobo.BangWoFenXi.tests.iflytek.\(UUID().uuidString)"

    private var storage: MockURLProtocolStorage { IFlytekMockURLProtocol.storage }

    init() {
        IFlytekMockURLProtocol.storage.reset()
        session = IFlytekMockURLProtocol.makeSession()
        credentialStore = CloudAPIKeyStore(
            service: credentialServiceName,
            account: IFlytekCredentials.credentialAccount
        )
    }

    deinit {
        try? credentialStore.deleteKey()
    }

    @Test("鉴权签名与讯飞官方示例算法一致")
    func signatureVector() throws {
        let signed = try IFlytekRequestSigner.makeURL(
            baseURL: IFlytekDiarizationService.endpoint,
            path: "/v2/getResult",
            parameters: [
                "appId": "d83cc043",
                "accessKeyId": "test-key",
                "dateTime": "2026-09-02T12:00:00+0800",
                "signatureRandom": "ABC123xyz789QWER"
            ],
            accessKeySecret: "test-secret"
        )
        #expect(signed.signature == "Skk8MU1sa4WUfxNyaadV0pHGjrM=")
        #expect(signed.url.absoluteString.contains("dateTime=2026-09-02T12%3A00%3A00%2B0800"))
    }

    @Test("解析双层 JSON，将声纹角色顺序映射为本地代号")
    func parsesNestedOrderResult() throws {
        let first = #"{"st":{"bg":"0","ed":"900","rl":"1","rt":[{"ws":[{"cw":[{"w":"你好","wp":"n"}]},{"cw":[{"w":"。","wp":"p"}]}]}]}}"#
        let second = #"{"st":{"bg":"1000","ed":"1800","rl":"2","rt":[{"ws":[{"cw":[{"w":"收到","wp":"n"}]}]}]}}"#
        let rawData = try JSONSerialization.data(withJSONObject: [
            "lattice": [
                ["json_1best": first],
                ["json_1best": second]
            ]
        ])
        let raw = try #require(String(data: rawData, encoding: .utf8))

        let result = try IFlytekDiarizationService.parseOrderResult(
            raw,
            durationMs: 2_000,
            aliasesByRole: ["1": "p_01", "2": "p_02"],
            aliasesByFeatureID: [:]
        )
        #expect(result.durationMs == 2_000)
        #expect(result.segments.map(\.text) == ["你好。", "收到"])
        #expect(result.segments.map(\.speakerLabel) == ["p_01", "p_02"])
    }

    @Test("已注册声纹随分片上传并返回具体人物代号")
    func transcribesWithRegisteredVoiceprint() async throws {
        try saveCredentials()
        let chunk = try makeSilentWAV(durationMs: 1_000)
        defer { try? FileManager.default.removeItem(at: chunk) }
        let sample = try makeSilentWAV(durationMs: 10_000)
        defer { try? FileManager.default.removeItem(at: sample) }
        let best = #"{"st":{"bg":"0","ed":"800","rl":"1","rt":[{"ws":[{"cw":[{"w":"讯飞测试","wp":"n"}]}]}]}}"#
        let orderData = try JSONSerialization.data(withJSONObject: [
            "lattice": [["json_1best": best]]
        ])
        let orderResult = try #require(String(data: orderData, encoding: .utf8))
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            if request.url?.path == "/v2/upload" {
                return (response, Data(#"{"code":"000000","descInfo":"success","content":{"orderId":"order-1"}}"#.utf8))
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "code": "000000",
                "descInfo": "success",
                "content": [
                    "orderInfo": ["status": 4, "originalDuration": 1_000],
                    "orderResult": orderResult
                ]
            ])
            return (response, body)
        }
        let service = makeService()

        let result = try await service.transcribeChunk(
            at: chunk,
            knownSpeakers: [
                KnownSpeakerReference(
                    alias: "p_01",
                    sampleURL: sample,
                    iflytekFeatureID: "feature-1"
                )
            ]
        )
        #expect(result.segments.first?.speakerLabel == "p_01")
        #expect(storage.capturedRequests.count == 2)
        let uploadURL = try #require(storage.capturedRequests.first?.url)
        let components = try #require(URLComponents(url: uploadURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(query["roleType"] == "3")
        #expect(query["featureIds"] == "feature-1")
        #expect(query["appId"] == "test-app")
        #expect(storage.capturedRequests.first?.value(forHTTPHeaderField: "signature")?.isEmpty == false)
    }

    @Test("人物未注册讯飞声纹时继续匿名分人")
    func missingVoiceprintFallsBackToAnonymousDiarization() async throws {
        try saveCredentials()
        let chunk = try makeSilentWAV(durationMs: 1_000)
        defer { try? FileManager.default.removeItem(at: chunk) }
        let best = #"{"st":{"bg":"0","ed":"800","rl":"1","rt":[{"ws":[{"cw":[{"w":"继续识别","wp":"n"}]}]}]}}"#
        let orderData = try JSONSerialization.data(withJSONObject: [
            "lattice": [["json_1best": best]]
        ])
        let orderResult = try #require(String(data: orderData, encoding: .utf8))
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            if request.url?.path == "/v2/upload" {
                return (response, Data(#"{"code":"000000","descInfo":"success","content":{"orderId":"order-anonymous"}}"#.utf8))
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "code": "000000",
                "descInfo": "success",
                "content": [
                    "orderInfo": ["status": 4, "originalDuration": 1_000],
                    "orderResult": orderResult
                ]
            ])
            return (response, body)
        }
        let service = makeService()

        let result = try await service.transcribeChunk(
            at: chunk,
            knownSpeakers: [KnownSpeakerReference(alias: "p_01", sampleURL: chunk)]
        )
        #expect(result.segments.first?.speakerLabel == "speaker_1")
        let uploadURL = try #require(storage.capturedRequests.first?.url)
        let query = Dictionary(
            uniqueKeysWithValues: (
                URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            ).map { ($0.name, $0.value ?? "") }
        )
        #expect(query["roleType"] == "1")
        #expect(query["featureIds"] == nil)
    }

    @Test("部分人物未注册时只上传已注册声纹且角色顺序正确")
    func mixedVoiceprintsUseRegisteredSpeakersOnly() async throws {
        try saveCredentials()
        let chunk = try makeSilentWAV(durationMs: 1_000)
        defer { try? FileManager.default.removeItem(at: chunk) }
        let best = #"{"st":{"bg":"0","ed":"800","rl":"1","rt":[{"ws":[{"cw":[{"w":"已注册人物","wp":"n"}]}]}]}}"#
        let orderData = try JSONSerialization.data(withJSONObject: [
            "lattice": [["json_1best": best]]
        ])
        let orderResult = try #require(String(data: orderData, encoding: .utf8))
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            if request.url?.path == "/v2/upload" {
                return (response, Data(#"{"code":"000000","descInfo":"success","content":{"orderId":"order-mixed"}}"#.utf8))
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "code": "000000",
                "descInfo": "success",
                "content": [
                    "orderInfo": ["status": 4, "originalDuration": 1_000],
                    "orderResult": orderResult
                ]
            ])
            return (response, body)
        }

        let result = try await makeService().transcribeChunk(
            at: chunk,
            knownSpeakers: [
                KnownSpeakerReference(alias: "p_01", sampleURL: chunk),
                KnownSpeakerReference(
                    alias: "p_02",
                    sampleURL: chunk,
                    iflytekFeatureID: "feature-2"
                )
            ]
        )
        #expect(result.segments.first?.speakerLabel == "p_02")
        let uploadURL = try #require(storage.capturedRequests.first?.url)
        let query = Dictionary(
            uniqueKeysWithValues: (
                URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            ).map { ($0.name, $0.value ?? "") }
        )
        #expect(query["roleType"] == "3")
        #expect(query["featureIds"] == "feature-2")
    }

    @Test("连接测试不上传音频")
    func connectionProbeUsesInvalidOrderOnly() async throws {
        try saveCredentials()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"code":"100001","descInfo":"order not found"}"#.utf8))
        }
        #expect(try await makeService().testConnection())
        let request = try #require(storage.capturedRequests.first)
        #expect(request.url?.path == "/v2/getResult")
        #expect(mockRequestBodyData(of: request) == Data("{}".utf8))
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let queryNames = Set((components.queryItems ?? []).map(\.name))
        #expect(!queryNames.contains("appId"))
        #expect(!queryNames.contains("ts"))
    }

    @Test("十秒样本可注册并返回 feature id")
    func registersVoiceprint() async throws {
        try saveCredentials()
        let sample = try makeSilentWAV(durationMs: 10_000)
        defer { try? FileManager.default.removeItem(at: sample) }
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (
                response,
                Data(#"{"code":"000000","desc":"success","data":"{\"feature_id\":\"feature-registered\",\"status\":1}"}"#.utf8)
            )
        }
        let service = IFlytekVoiceprintService(
            session: session,
            appID: "test-app",
            credentialStore: credentialStore,
            now: { Date(timeIntervalSince1970: 1_788_323_200) },
            randomString: { "ABC123xyz789QWER" }
        )

        #expect(try await service.register(sampleURL: sample) == "feature-registered")
        let request = try #require(storage.capturedRequests.first)
        #expect(request.url?.path == "/res/feature/v1/register")
        let body = try #require(mockRequestBodyData(of: request))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let audioBase64 = try #require(json["audio_data"] as? String)
        let audioData = try #require(Data(base64Encoded: audioBase64))
        let uploadedURL = FileManager.default.temporaryDirectory
            .appending(path: "iflytek-uploaded-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: uploadedURL) }
        try audioData.write(to: uploadedURL)
        let uploaded = try AVAudioFile(forReading: uploadedURL)
        #expect(uploaded.fileFormat.sampleRate == 16_000)
        #expect(uploaded.fileFormat.channelCount == 1)
        #expect(uploaded.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(json["audio_type"] as? String == "raw")
    }

    private func makeService() -> IFlytekDiarizationService {
        IFlytekDiarizationService(
            session: session,
            appID: "test-app",
            credentialStore: credentialStore,
            now: { Date(timeIntervalSince1970: 1_788_323_200) },
            randomString: { "ABC123xyz789QWER" },
            sleep: { _ in },
            maximumPollCount: 2
        )
    }

    private func saveCredentials() throws {
        try IFlytekCredentials(
            accessKeyID: "test-key",
            accessKeySecret: "test-secret"
        ).save(to: credentialStore)
    }

    private func makeSilentWAV(durationMs: Int) throws -> URL {
        let sampleRate = 16_000
        let sampleCount = sampleRate * durationMs / 1_000
        let pcm = Data(repeating: 0, count: sampleCount * 2)
        var wav = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt32(sampleRate), to: &wav)
        appendLittleEndian(UInt32(sampleRate * 2), to: &wav)
        appendLittleEndian(UInt16(2), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "iflytek-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
