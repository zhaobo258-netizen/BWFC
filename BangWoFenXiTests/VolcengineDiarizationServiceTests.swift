import Foundation
import Testing
@testable import BangWoFenXi

@Suite("火山引擎分人服务")
struct VolcengineDiarizationServiceTests {
    @Test("使用新控制台 API Key 鉴权并解析匿名说话人")
    func requestAndParse() async throws {
        let serviceName = "com.zhaobo.BangWoFenXi.tests.volcengine.\(UUID().uuidString)"
        let keyStore = CloudAPIKeyStore(
            service: serviceName,
            account: VolcengineDiarizationService.keychainAccount
        )
        defer { try? keyStore.deleteKey() }
        try keyStore.saveKey("test-api-key")

        let response = Data("""
        {"result":{"duration":1200,"utterances":[
          {"start_time":0,"end_time":600,"text":"你好","definite":true,"additions":{"speaker":"1"}},
          {"start_time":600,"end_time":1200,"text":"您好","definite":true,"additions":{"speaker_id":2}}
        ]}}
        """.utf8)
        let connection = MockVolcengineConnection(receiveFrames: [makeVolcengineResponse(payload: response)])
        let transport = MockVolcengineTransport(connection: connection)
        let service = VolcengineDiarizationService(
            apiKeyStore: keyStore,
            resourceID: "volc.seedasr.sauc.duration",
            transport: transport,
            timeout: .seconds(1)
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "volc-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([1, 2, 3, 4]).write(to: fileURL)

        let result = try await service.transcribeChunk(at: fileURL, knownSpeakers: [])
        #expect(result.durationMs == 1_200)
        #expect(result.segments.map { $0.speakerLabel } == ["1", "2"])
        #expect(result.segments.map { $0.text } == ["你好", "您好"])

        let request = try #require(transport.request)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-api-key")
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration")
        #expect(request.value(forHTTPHeaderField: "X-Api-App-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Api-Access-Key") == nil)

        let sent = await connection.sentFrames
        #expect(sent.count == 2)
        #expect(sent[0][1] == 0x11)
        #expect(sent[1][1] == 0x23)
        #expect(!String(decoding: sent[0], as: UTF8.self).contains("test-api-key"))
    }

    @Test("过滤非确定句并拒绝无效时间戳")
    func responseValidation() throws {
        let partial = Data("""
        {"result":{"utterances":[
          {"start_time":0,"end_time":10,"text":"中间态","definite":false,"speaker":"A"},
          {"start_time":10,"end_time":20,"text":"确定句","definite":true,"speaker":"B"}
        ]}}
        """.utf8)
        let result = try VolcengineDiarizationService.parseResponse(partial)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerLabel == "B")

        let invalid = Data("""
        {"result":{"utterances":[{"start_time":20,"end_time":10,"text":"错误"}]}}
        """.utf8)
        #expect(throws: DiarizationAPIError.invalidResponse) {
            try VolcengineDiarizationService.parseResponse(invalid)
        }
    }

    @Test("缺少独立 Key 时零连接")
    func missingKey() async {
        let keyStore = CloudAPIKeyStore(
            service: "com.zhaobo.BangWoFenXi.tests.volcengine.\(UUID().uuidString)",
            account: VolcengineDiarizationService.keychainAccount
        )
        let connection = MockVolcengineConnection(receiveFrames: [])
        let transport = MockVolcengineTransport(connection: connection)
        let service = VolcengineDiarizationService(
            apiKeyStore: keyStore,
            resourceID: "volc.seedasr.sauc.duration",
            transport: transport
        )
        await #expect(throws: DiarizationAPIError.missingAPIKey) {
            try await service.testConnection()
        }
        #expect(transport.request == nil)
    }
}

private final class MockVolcengineTransport: VolcengineWebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let connection: MockVolcengineConnection
    private var storedRequest: URLRequest?

    init(connection: MockVolcengineConnection) {
        self.connection = connection
    }

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func connect(request: URLRequest) async throws -> any VolcengineWebSocketConnection {
        lock.withLock { storedRequest = request }
        return connection
    }
}

private actor MockVolcengineConnection: VolcengineWebSocketConnection {
    private(set) var sentFrames: [Data] = []
    private var receiveFrames: [Data]

    init(receiveFrames: [Data]) {
        self.receiveFrames = receiveFrames
    }

    func send(_ data: Data) {
        sentFrames.append(data)
    }

    func receive() throws -> Data {
        guard !receiveFrames.isEmpty else { throw URLError(.cannotParseResponse) }
        return receiveFrames.removeFirst()
    }

    func close() {}
}

private func makeVolcengineResponse(payload: Data) -> Data {
    var data = Data([0x11, 0x92, 0x10, 0x00])
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}
