import Foundation
import Testing
@testable import BangWoFenXi

/// 云端识别接口集成测试（URLProtocol Mock，不依赖真实网络，实施计划 14.2）。
/// 套件内串行（.serialized）+ 套件专属 protocol 存储，杜绝并行干扰。
@Suite("云端识别接口", .serialized)
final class DiarizationAPITests {
    let session: URLSession
    let service: OpenAIDiarizationService
    let keychainServiceName = "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)"

    private var storage: MockURLProtocolStorage { DiarizationMockURLProtocol.storage }

    init() {
        DiarizationMockURLProtocol.storage.reset()
        session = DiarizationMockURLProtocol.makeSession()
        service = OpenAIDiarizationService(
            session: session,
            apiKeyStore: CloudAPIKeyStore(service: keychainServiceName, account: "test-key")
        )
    }

    deinit {
        // 不重置 protocol 存储（同 AnalysisAPITests 的释放环考虑）
        try? KeychainService(service: keychainServiceName).delete(account: "test-key")
    }

    private func saveTestKey() throws {
        try KeychainService(service: keychainServiceName).save("sk-test-fake-key", account: "test-key")
    }

    /// 造一个临时音频文件
    private func makeTempFile(named name: String = "chunk.wav") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-\(name)")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url) // 假 RIFF 头
        return url
    }

    // MARK: - 请求组装

    @Test("请求组装：模型/语言/格式/代号正确，不含真实姓名与明文样本")
    func requestAssembly() async throws {
        try saveTestKey()
        let chunk = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: chunk) }
        let sample = try makeTempFile(named: "sample.wav")
        defer { try? FileManager.default.removeItem(at: sample) }

        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"duration":20.0,"segments":[]}"#.utf8))
        }

        _ = try await service.transcribeChunk(
            at: chunk,
            knownSpeakers: [KnownSpeakerReference(alias: "p_01", sampleURL: sample)]
        )

        let request = try #require(storage.capturedRequests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-fake-key")

        // URLSession 可能把 httpBody 转为 httpBodyStream，两种形态都要兼容
        let body = try #require(mockRequestBodyData(of: request))
        let bodyText = String(decoding: body, as: UTF8.self)
        #expect(bodyText.contains("gpt-4o-transcribe-diarize"), "模型 ID 必须来自集中配置")
        #expect(bodyText.contains(#"name="language""#))
        #expect(bodyText.contains("zh"))
        #expect(bodyText.contains("diarized_json"))
        #expect(bodyText.contains(#"name="known_speaker_names[]""#))
        #expect(bodyText.contains("p_01"), "云端只传本地代号")
        #expect(bodyText.contains("data:audio/wav;base64,"), "样本以数据 URL 传输")
        // 敏感信息检查：请求体不得出现真实姓名类内容（本测试未注入姓名，仅验证代号路径）
        #expect(!bodyText.contains("张总"))
    }

    // MARK: - 响应解析

    @Test("识别成功：只读取总时长、起止、文字与 speaker")
    func successParsing() async throws {
        try saveTestKey()
        let chunk = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: chunk) }

        storage.requestHandler = { request in
            let json = #"{"duration":20.5,"segments":[{"start":0.0,"end":5.25,"text":"如果年度量能能保证。","speaker":"p_01"},{"start":6.0,"end":12.5,"text":"量能可以谈。","speaker":"p_02"}],"extra_ignored":"x"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }

        let result = try await service.transcribeChunk(at: chunk, knownSpeakers: [])
        #expect(result.durationMs == 20_500)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].startMs == 0)
        #expect(result.segments[0].endMs == 5_250)
        #expect(result.segments[0].text == "如果年度量能能保证。")
        #expect(result.segments[0].speakerLabel == "p_01")
        #expect(result.segments[1].startMs == 6_000)
        #expect(result.segments[1].speakerLabel == "p_02")
    }

    @Test("空结果：segments 为空不报错")
    func emptyResult() async throws {
        try saveTestKey()
        let chunk = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: chunk) }
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"duration":20.0,"segments":[]}"#.utf8))
        }
        let result = try await service.transcribeChunk(at: chunk, knownSpeakers: [])
        #expect(result.segments.isEmpty)
    }

    // MARK: - 错误分类（实施计划 11.2）

    @Test("401 → unauthorized（Key 无效）")
    func unauthorized() async throws {
        try saveTestKey()
        let chunk = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: chunk) }
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        await #expect(throws: DiarizationAPIError.unauthorized) {
            try await service.transcribeChunk(at: chunk, knownSpeakers: [])
        }
    }

    @Test("429 → rateLimited（限流退避）")
    func rateLimited() async throws {
        try saveTestKey()
        let chunk = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: chunk) }
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        await #expect(throws: DiarizationAPIError.rateLimited) {
            try await service.transcribeChunk(at: chunk, knownSpeakers: [])
        }
    }

    @Test("500 → serverError（服务失败退避）")
    func serverError() async throws {
        try saveTestKey()
        let chunk = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: chunk) }
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        await #expect(throws: DiarizationAPIError.serverError(statusCode: 500)) {
            try await service.transcribeChunk(at: chunk, knownSpeakers: [])
        }
    }

    @Test("网络错误（超时/断网）→ network")
    func networkError() async throws {
        try saveTestKey()
        let chunk = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: chunk) }
        storage.requestHandler = { _ in throw URLError(.timedOut) }
        await #expect(throws: DiarizationAPIError.network) {
            try await service.transcribeChunk(at: chunk, knownSpeakers: [])
        }
    }

    @Test("未配置 Key → missingAPIKey，不发请求")
    func missingKey() async throws {
        let chunk = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: chunk) }
        await #expect(throws: DiarizationAPIError.missingAPIKey) {
            try await service.transcribeChunk(at: chunk, knownSpeakers: [])
        }
        #expect(storage.capturedRequests.isEmpty, "未配置 Key 不得发请求")
    }

    @Test("响应体损坏 → invalidResponse")
    func invalidResponse() async throws {
        try saveTestKey()
        let chunk = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: chunk) }
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not json".utf8))
        }
        await #expect(throws: DiarizationAPIError.invalidResponse) {
            try await service.transcribeChunk(at: chunk, knownSpeakers: [])
        }
    }
}

/// multipart 构建器
@Suite("multipart 构建")
struct MultipartFormBuilderTests {
    @Test("字段与文件按规范拼装")
    func structure() {
        var builder = MultipartFormBuilder(boundary: "TESTBOUNDARY")
        builder.addField(name: "model", value: "test-model")
        builder.addArrayField(name: "names[]", values: ["p_01", "p_02"])
        builder.addFile(name: "file", fileName: "a.wav", mimeType: "audio/wav", fileData: Data([1, 2, 3]))
        let body = builder.finish()
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.hasPrefix("--TESTBOUNDARY\r\n"))
        #expect(text.hasSuffix("--TESTBOUNDARY--\r\n"))
        #expect(text.contains(#"Content-Disposition: form-data; name="model""#))
        #expect(text.contains("test-model"))
        #expect(text.components(separatedBy: #"name="names[]""#).count == 3, "数组字段每个元素一个 part")
        #expect(text.contains(#"filename="a.wav""#))
        #expect(text.contains("Content-Type: audio/wav"))
        #expect(builder.contentType.contains("boundary=TESTBOUNDARY"))
    }
}
