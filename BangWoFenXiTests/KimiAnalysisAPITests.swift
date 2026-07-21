import Foundation
import Testing
@testable import BangWoFenXi

/// Kimi 网关分析接口集成测试（URLProtocol Mock，不依赖真实网络）。
/// Anthropic 风格 messages 形态：x-api-key 头、anthropic-version 头、
/// content 数组含 thinking/text 块、无 store 字段、围栏剥离。
@Suite("Kimi 分析接口", .serialized)
final class KimiAnalysisAPITests {
    let service: KimiAnalysisService
    let keychainServiceName = "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)"

    private var storage: MockURLProtocolStorage { KimiMockURLProtocol.storage }

    init() {
        KimiMockURLProtocol.storage.reset()
        service = KimiAnalysisService(
            session: KimiMockURLProtocol.makeSession(),
            apiKeyStore: CloudAPIKeyStore(service: keychainServiceName, account: "test-key")
        )
    }

    deinit {
        // 不重置 protocol 存储（避免释放环；下个用例 init 时重置）
        try? KeychainService(service: keychainServiceName).delete(account: "test-key")
    }

    private func saveTestKey() throws {
        try KeychainService(service: keychainServiceName).save("sk-test-fake-key", account: "test-key")
    }

    /// 合法的分析输出 JSON
    private static func validOutputJSON(segmentID: UUID) -> String {
        """
        {"current_topic":"年度量能","topics":[{"title":"年度量能","status":"discussing","evidence_segment_ids":["\(segmentID.uuidString)"]}],"our_positions":[],"counterpart_positions":[],"confirmed_items":[],"open_items":[],"key_facts":[],"insights":[{"category":"possible_motive","subject_participant_id":"p_01","statement":"对方可能在用量能换返点。","epistemic_status":"inference","confidence":"medium","evidence_segment_ids":["\(segmentID.uuidString)"]}]}
        """
    }

    /// Anthropic messages 响应信封（静态：handler 不得捕获 self）
    private static func messagesEnvelope(text: String, includeThinking: Bool = true) -> Data {
        var blocks: [[String: Any]] = []
        if includeThinking {
            blocks.append(["type": "thinking", "thinking": "（推理过程，不应被当作输出）"])
        }
        blocks.append(["type": "text", "text": text])
        let body: [String: Any] = [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "model": "kimi-for-coding",
            "content": blocks,
            "stop_reason": "end_turn"
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - 请求形态

    @Test("请求形态：x-api-key、anthropic-version、body 结构正确、无 store 字段")
    func requestShape() async throws {
        try saveTestKey()
        let segmentID = UUID()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.messagesEnvelope(text: Self.validOutputJSON(segmentID: segmentID)))
        }

        _ = try await service.analyze(instructions: AnalysisSystemPrompt.text, inputJSON: "{\"probe\":1}")

        let request = try #require(storage.capturedRequests.first)
        #expect(request.url?.absoluteString == "https://agent-gw.kimi.com/coding/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test-fake-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(mockRequestBodyData(of: request))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "kimi-for-coding")
        #expect(object["max_tokens"] as? Int == CloudModelConfig.analysisMaxTokens)
        #expect(object["store"] == nil, "Kimi 接口不得发送 store 字段")
        let system = try #require(object["system"] as? String)
        #expect(system.contains("不输出回应建议"), "系统指令必须包含 10.3 约束")
        #expect(system.contains("只输出一个 JSON 对象"), "系统指令必须包含纯文本 JSON 输出约束")
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "{\"probe\":1}", "用户消息为组装的增量上下文 JSON")
    }

    // MARK: - 响应解析

    @Test("含 thinking + text 块：正确提取 text 并解码")
    func extractTextBlocks() async throws {
        try saveTestKey()
        let segmentID = UUID()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.messagesEnvelope(
                text: Self.validOutputJSON(segmentID: segmentID), includeThinking: true
            ))
        }
        let dto = try await service.analyze(instructions: "", inputJSON: "{}")
        #expect(dto.currentTopic == "年度量能")
        #expect(dto.insights.count == 1)
        #expect(dto.insights[0].category == "possible_motive")
        #expect(dto.insights[0].evidenceSegmentIds == [segmentID.uuidString])
    }

    @Test("```json 围栏包裹的输出也能解析")
    func fencedJSONParses() async throws {
        try saveTestKey()
        let segmentID = UUID()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let fenced = "```json\n" + Self.validOutputJSON(segmentID: segmentID) + "\n```"
            return (response, Self.messagesEnvelope(text: fenced, includeThinking: false))
        }
        let dto = try await service.analyze(instructions: "", inputJSON: "{}")
        #expect(dto.currentTopic == "年度量能")
        #expect(dto.insights.count == 1)
    }

    @Test("只有 thinking 没有 text → invalidResponse")
    func thinkingOnlyInvalid() async throws {
        try saveTestKey()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "content": [["type": "thinking", "thinking": "只有推理没有输出"]]
            ]
            return (response, try! JSONSerialization.data(withJSONObject: body))
        }
        await #expect(throws: AnalysisAPIError.invalidResponse) {
            _ = try await service.analyze(instructions: "", inputJSON: "{}")
        }
    }

    @Test("text 块不是合法 JSON → invalidResponse（保留上一版语义）")
    func badJSONInvalid() async throws {
        try saveTestKey()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.messagesEnvelope(text: "这不是 JSON 输出", includeThinking: false))
        }
        await #expect(throws: AnalysisAPIError.invalidResponse) {
            _ = try await service.analyze(instructions: "", inputJSON: "{}")
        }
    }

    // MARK: - 错误分类

    @Test("401 → unauthorized；429 → rateLimited；500 → serverError；超时 → network")
    func errorClassification() async throws {
        try saveTestKey()
        for (statusCode, expected) in [
            (401, AnalysisAPIError.unauthorized),
            (429, AnalysisAPIError.rateLimited),
            (500, AnalysisAPIError.serverError(statusCode: 500))
        ] {
            storage.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            await #expect(throws: expected) {
                _ = try await service.analyze(instructions: "", inputJSON: "{}")
            }
        }
        storage.requestHandler = { _ in throw URLError(.timedOut) }
        await #expect(throws: AnalysisAPIError.network) {
            _ = try await service.analyze(instructions: "", inputJSON: "{}")
        }
    }

    @Test("未配置 Key → missingAPIKey，不发请求")
    func missingKey() async throws {
        await #expect(throws: AnalysisAPIError.missingAPIKey) {
            _ = try await service.analyze(instructions: "", inputJSON: "{}")
        }
        #expect(storage.capturedRequests.isEmpty)
    }

    // MARK: - 连接测试

    @Test("连接测试：200 → 可用；401 → unauthorized")
    func connectionTest() async throws {
        try saveTestKey()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.messagesEnvelope(text: "pong", includeThinking: false))
        }
        #expect(try await service.testConnection() == true)
        // 连接测试必须是最小请求（小 max_tokens）
        let request = try #require(storage.capturedRequests.first)
        let body = try #require(mockRequestBodyData(of: request))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((object["max_tokens"] as? Int ?? 0) <= 16)

        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        await #expect(throws: AnalysisAPIError.unauthorized) {
            _ = try await service.testConnection()
        }
    }
}
