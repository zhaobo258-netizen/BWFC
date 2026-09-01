import Foundation
import Testing
@testable import BangWoFenXi

/// 谈判分析接口集成测试（URLProtocol Mock，不依赖真实网络，实施计划 14.2）。
/// 套件内串行（.serialized）+ 套件专属 protocol 存储，杜绝并行干扰。
@Suite("谈判分析接口", .serialized)
final class AnalysisAPITests {
    let service: OpenAIAnalysisService
    let credentialServiceName = "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)"

    private var storage: MockURLProtocolStorage { AnalysisMockURLProtocol.storage }

    init() {
        AnalysisMockURLProtocol.storage.reset()
        service = OpenAIAnalysisService(
            session: AnalysisMockURLProtocol.makeSession(),
            apiKeyStore: CloudAPIKeyStore(service: credentialServiceName, account: "test-key")
        )
    }

    deinit {
        // 不重置 protocol 存储：handler 可能仍在被 URLSession 使用，
        // 此处释放闭包（其捕获了 self）会形成释放环；下个用例 init 时会重置。
        try? LocalCredentialStore(service: credentialServiceName).delete(account: "test-key")
    }

    private func saveTestKey() throws {
        try LocalCredentialStore(service: credentialServiceName).save("sk-test-fake-key", account: "test-key")
    }

    /// 合法的结构化输出（静态：handler 不得捕获 self，避免 deinit 释放环）
    private static func validOutputJSON(segmentID: UUID) -> String {
        """
        {
          "current_topic": "年度量能",
          "topics": [{"title":"年度量能","status":"discussing","evidence_segment_ids":["\(segmentID.uuidString)"]}],
          "our_positions": [],
          "counterpart_positions": [{"text":"对方要求保证年度量能","evidence_segment_ids":["\(segmentID.uuidString)"]}],
          "confirmed_items": [],
          "open_items": [],
          "key_facts": [],
          "insights": [{"category":"possible_motive","subject_participant_id":"p_01","statement":"对方可能在用量能换返点。","epistemic_status":"inference","confidence":"medium","evidence_segment_ids":["\(segmentID.uuidString)"]}]
        }
        """
    }

    /// 包装为 Responses API 信封（静态：handler 不得捕获 self）
    private static func envelope(_ outputText: String) -> Data {
        let escaped = outputText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        // 模板已含 text 值的前后引号，直接拼接转义后的内容
        let json = #"{"output":[{"content":[{"type":"output_text","text":""# + escaped + #""}]}]}"#
        return Data(json.utf8)
    }

    @Test("成功：解析结构化输出；请求含 store:false、严格 schema、集中模型 ID")
    func successAndRequestShape() async throws {
        try saveTestKey()
        let segmentID = UUID()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.envelope(Self.validOutputJSON(segmentID: segmentID)))
        }

        let dto = try await service.analyze(instructions: AnalysisSystemPrompt.text, inputJSON: "{}")
        #expect(dto.currentTopic == "年度量能")
        #expect(dto.counterpartPositions.count == 1)
        #expect(dto.insights.count == 1)
        #expect(dto.insights[0].category == "possible_motive")
        #expect(dto.insights[0].epistemicStatus == "inference")
        #expect(dto.insights[0].evidenceSegmentIds == [segmentID.uuidString])

        let request = try #require(storage.capturedRequests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        let body = try #require(mockRequestBodyData(of: request))
        let bodyText = String(decoding: body, as: UTF8.self)
        #expect(bodyText.contains(#""store":false"#), "必须设置 store:false（实施计划 12.1）")
        #expect(bodyText.contains(#""strict":true"#), "必须使用严格 Structured Outputs")
        #expect(bodyText.contains(CloudModelConfig.analysisModelID), "模型 ID 必须来自集中配置")
        #expect(bodyText.contains("negotiation_analysis"))
        #expect(bodyText.contains("evidence_segment_ids"))
    }

    @Test("结构化输出文本不是合法 JSON → invalidResponse（丢弃并保留上一版）")
    func invalidOutputDiscarded() async throws {
        try saveTestKey()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.envelope("这不是 JSON"))
        }
        await #expect(throws: AnalysisAPIError.invalidResponse) {
            _ = try await service.analyze(instructions: "", inputJSON: "{}")
        }
    }

    @Test("输出缺字段（不合 schema）→ invalidResponse")
    func missingFieldsDiscarded() async throws {
        try saveTestKey()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.envelope(#"{"current_topic":"x"}"#))
        }
        await #expect(throws: AnalysisAPIError.invalidResponse) {
            _ = try await service.analyze(instructions: "", inputJSON: "{}")
        }
    }

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
}
