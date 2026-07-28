import Foundation
import Testing
@testable import BangWoFenXi

final class AIProviderMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

@Suite("分析模型配置", .serialized)
struct AIProviderConfigurationTests {
    @Test("OpenAI 兼容地址只接受 HTTPS 或本机 HTTP")
    func baseURLValidation() {
        #expect(AIProviderConfiguration.validatedBaseURL(
            "https://api.openai.com/v1/"
        )?.absoluteString == "https://api.openai.com/v1")
        #expect(AIProviderConfiguration.validatedBaseURL(
            "http://localhost:11434/v1"
        ) != nil)
        #expect(AIProviderConfiguration.validatedBaseURL(
            "http://127.0.0.1:8080/v1"
        ) != nil)
        #expect(AIProviderConfiguration.validatedBaseURL(
            "http://example.com/v1"
        ) == nil)
        #expect(AIProviderConfiguration.validatedBaseURL(
            "file:///tmp/model"
        ) == nil)
        #expect(AIProviderConfiguration.validatedBaseURL(
            "https://user:secret@example.com/v1"
        ) == nil)
    }

    @Test("配置可编解码且删除自定义配置回到 Kimi")
    func codingAndFallback() throws {
        let suiteName = "bwfx-ai-config-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIProviderConfigurationStore(defaults: defaults)
        let configured = AIProviderConfiguration(
            selectedProvider: .openAICompatible,
            openAIBaseURL: "https://example.com/v1",
            openAIModelID: "model-a"
        )
        try store.save(configured)
        #expect(store.load() == configured)

        try store.selectKimiAndClearCustomConfiguration()
        let fallback = store.load()
        #expect(fallback.selectedProvider == .kimi)
        #expect(fallback.openAIModelID.isEmpty)
    }

    @Test("每次请求读取一次配置快照，修改只影响下一次请求")
    func nextRequestUsesNewConfiguration() async throws {
        let suiteName = "bwfx-ai-registry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIProviderConfigurationStore(defaults: defaults)
        let serviceName = "com.zhaobo.BangWoFenXi.tests.ai.\(UUID().uuidString)"
        let openAIKeyStore = CloudAPIKeyStore(
            service: serviceName,
            account: AIProviderConfigurationStore.openAIKeychainAccount
        )
        defer {
            try? openAIKeyStore.deleteKey()
            try? KeychainService(service: serviceName).delete(account: "kimi")
        }
        try openAIKeyStore.saveKey("openai-compatible-key")
        try store.save(AIProviderConfiguration(
            selectedProvider: .openAICompatible,
            openAIBaseURL: "https://example.com/v1",
            openAIModelID: "model-a"
        ))

        AIProviderMockURLProtocol.storage.reset()
        AIProviderMockURLProtocol.storage.requestHandler = { request in
            let body = try #require(mockRequestBodyData(of: request))
            let object = try #require(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let model = try #require(object["model"] as? String)
            let response = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "reply-\(model)"]]]
            ])
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                response
            )
        }

        let kimiStore = CloudAPIKeyStore.store(
            for: .analysis,
            service: serviceName
        )
        let registry = AIProviderRegistry(
            configurationStore: store,
            openAIKeyStore: openAIKeyStore,
            kimiTransport: KimiAnalysisService(apiKeyStore: kimiStore),
            makeSession: { AIProviderMockURLProtocol.makeSession() }
        )

        let first = try await registry.generate(
            AITextGenerationRequest(system: "system", input: "input")
        )
        #expect(first.text == "reply-model-a")
        #expect(first.provider.modelID == "model-a")

        try store.save(AIProviderConfiguration(
            selectedProvider: .openAICompatible,
            openAIBaseURL: "https://example.com/v1",
            openAIModelID: "model-b"
        ))
        let second = try await registry.generate(
            AITextGenerationRequest(system: "system", input: "input")
        )
        #expect(second.text == "reply-model-b")
        #expect(second.provider.modelID == "model-b")
        #expect(AIProviderMockURLProtocol.storage.capturedRequests.count == 2)
    }

    @Test("连接测试只发送最小探测内容且自定义 Key 与 Kimi Key 隔离")
    func minimalProbeAndKeyIsolation() async throws {
        let suiteName = "bwfx-ai-probe-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIProviderConfigurationStore(defaults: defaults)
        let serviceName = "com.zhaobo.BangWoFenXi.tests.ai.\(UUID().uuidString)"
        let custom = CloudAPIKeyStore(
            service: serviceName,
            account: AIProviderConfigurationStore.openAIKeychainAccount
        )
        let kimi = CloudAPIKeyStore.store(for: .analysis, service: serviceName)
        defer {
            try? custom.deleteKey()
            try? kimi.deleteKey()
        }
        try custom.saveKey("custom-key")
        try kimi.saveKey("kimi-key")
        #expect(try custom.readKey() == "custom-key")
        #expect(try kimi.readKey() == "kimi-key")

        try store.save(AIProviderConfiguration(
            selectedProvider: .openAICompatible,
            openAIBaseURL: "https://example.com/v1",
            openAIModelID: "probe-model"
        ))
        AIProviderMockURLProtocol.storage.reset()
        AIProviderMockURLProtocol.storage.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer custom-key")
            let body = try #require(mockRequestBodyData(of: request))
            let text = String(decoding: body, as: UTF8.self)
            #expect(text.contains("ping"))
            #expect(!text.contains("project"))
            #expect(!text.contains("逐字稿"))
            let response = Data(#"{"choices":[{"message":{"content":"pong"}}]}"#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                response
            )
        }
        let registry = AIProviderRegistry(
            configurationStore: store,
            openAIKeyStore: custom,
            kimiTransport: KimiAnalysisService(apiKeyStore: kimi),
            makeSession: { AIProviderMockURLProtocol.makeSession() }
        )
        let descriptor = try await registry.testActiveConnection()
        #expect(descriptor.modelID == "probe-model")
        #expect(AIProviderMockURLProtocol.storage.capturedRequests.count == 1)
    }
}
