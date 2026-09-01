import Foundation
import Testing
@testable import BangWoFenXi

@Suite("火山引擎分人服务", .serialized)
final class VolcengineDiarizationServiceTests {
    let session: URLSession
    let keyStore: CloudAPIKeyStore
    let accessTokenStore: CloudAPIKeyStore
    let service: VolcengineDiarizationService
    let credentialServiceName = "com.zhaobo.BangWoFenXi.tests.volcengine.\(UUID().uuidString)"

    private var storage: MockURLProtocolStorage { VolcengineMockURLProtocol.storage }

    init() {
        VolcengineMockURLProtocol.storage.reset()
        session = VolcengineMockURLProtocol.makeSession()
        keyStore = CloudAPIKeyStore(
            service: credentialServiceName,
            account: VolcengineDiarizationService.credentialAccount
        )
        accessTokenStore = CloudAPIKeyStore(
            service: credentialServiceName,
            account: VolcengineDiarizationService.accessTokenCredentialAccount
        )
        service = VolcengineDiarizationService(
            session: session,
            apiKeyStore: keyStore,
            accessTokenStore: accessTokenStore
        )
    }

    deinit {
        try? keyStore.deleteKey()
        try? accessTokenStore.deleteKey()
    }

    @Test("服务接口双凭据使用 App Key 与 Access Key 请求头")
    func serviceCredentialsRequest() async throws {
        try keyStore.saveKey("test-app-key")
        try accessTokenStore.saveKey("test-access-token")
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Api-Status-Code": "20000003"]
            )!
            return (response, Data())
        }

        #expect(try await service.testConnection())
        let request = try #require(storage.capturedRequests.first)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Api-App-Key") == "test-app-key")
        #expect(request.value(forHTTPHeaderField: "X-Api-Access-Key") == "test-access-token")
        let body = try #require(mockRequestBodyData(of: request))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let user = try #require(json["user"] as? [String: Any])
        #expect(user["uid"] as? String == "test-app-key")
    }

    @Test("新版控制台单 Key 请求正确且解析匿名说话人")
    func requestAndParse() async throws {
        try keyStore.saveKey("test-api-key")
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Api-Status-Code": "20000000"]
            )!
            let body = Data("""
            {"audio_info":{"duration":1200},"result":{"utterances":[
              {"start_time":0,"end_time":600,"text":"你好","additions":{"speaker":"1"}},
              {"start_time":600,"end_time":1200,"text":"您好","additions":{"speaker_id":2}}
            ]}}
            """.utf8)
            return (response, body)
        }
        let chunkURL = FileManager.default.temporaryDirectory
            .appending(path: "volc-http-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: chunkURL) }
        try Data("RIFF-test-audio".utf8).write(to: chunkURL)

        let result = try await service.transcribeChunk(at: chunkURL, knownSpeakers: [])
        #expect(result.durationMs == 1_200)
        #expect(result.segments.map { $0.speakerLabel } == ["1", "2"])
        #expect(result.segments.map { $0.text } == ["你好", "您好"])

        let request = try #require(storage.capturedRequests.first)
        #expect(request.url == VolcengineDiarizationService.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-api-key")
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.bigasr.auc_turbo")
        #expect(request.value(forHTTPHeaderField: "X-Api-Sequence") == "-1")
        #expect(request.value(forHTTPHeaderField: "X-Api-App-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Api-Access-Key") == nil)

        let body = try #require(mockRequestBodyData(of: request))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let user = try #require(json["user"] as? [String: Any])
        let audio = try #require(json["audio"] as? [String: Any])
        let recognition = try #require(json["request"] as? [String: Any])
        #expect(user["uid"] as? String == "test-api-key")
        #expect((audio["data"] as? String)?.isEmpty == false)
        #expect(recognition["model_name"] as? String == "bigmodel")
        #expect(recognition["enable_speaker_info"] as? Bool == true)
        #expect(recognition["show_utterances"] as? Bool == true)
    }

    @Test("静音状态码可用于零业务数据连接测试")
    func silentConnectionTest() async throws {
        try keyStore.saveKey("test-api-key")
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Api-Status-Code": "20000003"]
            )!
            return (response, Data())
        }
        #expect(try await service.testConnection())
        let request = try #require(storage.capturedRequests.first)
        let body = try #require(mockRequestBodyData(of: request))
        #expect(body.count > 4_000)
    }

    @Test("HTTP 与火山业务状态码分层映射")
    func errorMapping() async throws {
        try keyStore.saveKey("test-api-key")
        let chunkURL = FileManager.default.temporaryDirectory
            .appending(path: "volc-errors-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: chunkURL) }
        try Data("RIFF-test-audio".utf8).write(to: chunkURL)

        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        await #expect(throws: DiarizationAPIError.unauthorized) {
            try await service.transcribeChunk(at: chunkURL, knownSpeakers: [])
        }

        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Api-Status-Code": "55000031"]
            )!
            return (response, Data())
        }
        await #expect(throws: DiarizationAPIError.serverError(statusCode: 55_000_031)) {
            try await service.transcribeChunk(at: chunkURL, knownSpeakers: [])
        }
    }

    @Test("响应校验拒绝无效时间戳")
    func responseValidation() {
        let invalid = Data("""
        {"result":{"utterances":[{"start_time":20,"end_time":10,"text":"错误"}]}}
        """.utf8)
        #expect(throws: DiarizationAPIError.invalidResponse) {
            try VolcengineDiarizationService.parseResponse(invalid)
        }
    }

    @Test("缺少独立 Key 时零请求")
    func missingKey() async {
        await #expect(throws: DiarizationAPIError.missingAPIKey) {
            try await service.testConnection()
        }
        #expect(storage.capturedRequests.isEmpty)
    }
}
