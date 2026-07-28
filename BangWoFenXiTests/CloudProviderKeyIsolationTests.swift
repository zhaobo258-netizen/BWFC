import Foundation
import Testing
@testable import BangWoFenXi

/// Key 分家：分条目存取、互不外借、未配置零请求、旧条目迁移、401 隔离
@Suite("Key 分家", .serialized)
final class CloudProviderKeyIsolationTests {
    let serviceName = "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)"

    private func store(for provider: CloudProvider) -> CloudAPIKeyStore {
        CloudAPIKeyStore.store(for: provider, service: serviceName)
    }

    private var legacyStore: CloudAPIKeyStore {
        CloudAPIKeyStore(service: serviceName, account: CloudProvider.legacyAccount)
    }

    deinit {
        for account in ["kimi", "diarization", CloudProvider.legacyAccount, KimiOAuthTokenStore.account] {
            try? KeychainService(service: serviceName).delete(account: account)
        }
    }

    // MARK: - 分条目存取

    @Test("分析与分人条目互相独立，互不外借")
    func independentEntries() throws {
        try store(for: .analysis).saveKey("analysis-key-aaa")
        try store(for: .diarization).saveKey("diarization-key-bbb")

        #expect(try store(for: .analysis).readKey() == "analysis-key-aaa")
        #expect(try store(for: .diarization).readKey() == "diarization-key-bbb")

        // 删除一个不影响另一个
        try store(for: .analysis).deleteKey()
        #expect(!store(for: .analysis).hasConfiguredKey)
        #expect(store(for: .diarization).hasConfiguredKey)
    }

    // MARK: - 未配置零请求

    @Test("分人条目为空（分析条目有值）：分人服务 missingAPIKey 且不发请求")
    func diarizationNeverBorrowsAnalysisKey() async throws {
        try store(for: .analysis).saveKey("kimi-key")
        let service = OpenAIDiarizationService(
            session: IsolationDiarizationMockURLProtocol.makeSession(),
            apiKeyStore: store(for: .diarization)
        )
        IsolationDiarizationMockURLProtocol.storage.reset()
        let chunk = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        try Data([0x01]).write(to: chunk)
        defer { try? FileManager.default.removeItem(at: chunk) }

        await #expect(throws: DiarizationAPIError.missingAPIKey) {
            try await service.transcribeChunk(at: chunk, knownSpeakers: [])
        }
        #expect(IsolationDiarizationMockURLProtocol.storage.capturedRequests.isEmpty,
                "分人 Key 未配置时不得发请求（绝不拿分析 Key 去试 OpenAI）")
    }

    @Test("分析条目为空（分人条目有值）：分析服务 missingAPIKey 且不发请求")
    func analysisNeverBorrowsDiarizationKey() async throws {
        try store(for: .diarization).saveKey("openai-key")
        let analysisStore = store(for: .analysis)
        let service = KimiAnalysisService(
            session: IsolationKimiMockURLProtocol.makeSession(),
            apiKeyStore: analysisStore,
            // OAuth 凭证存储同样隔离到测试 service（不触碰生产条目）
            credentials: KimiCredentialProvider(
                tokenStore: KimiOAuthTokenStore(service: serviceName),
                staticKeyStore: analysisStore,
                client: MockKimiOAuthClient()
            )
        )
        IsolationKimiMockURLProtocol.storage.reset()

        await #expect(throws: AnalysisAPIError.missingAPIKey) {
            _ = try await service.analyze(instructions: "", inputJSON: "{}")
        }
        #expect(IsolationKimiMockURLProtocol.storage.capturedRequests.isEmpty)
    }

    // MARK: - 旧条目迁移

    @Test("迁移：旧 openai 条目有值且 kimi 为空 → 迁移到 kimi 并清空旧条目")
    func legacyMigration() throws {
        try legacyStore.saveKey("legacy-kimi-key")
        #expect(!store(for: .analysis).hasConfiguredKey)

        CloudAPIKeyStore.migrateLegacyKeyIfNeeded(service: serviceName)

        #expect(try store(for: .analysis).readKey() == "legacy-kimi-key", "旧值必须迁移到分析条目")
        #expect(!legacyStore.hasConfiguredKey, "迁移后旧条目必须清空")
        #expect(!store(for: .diarization).hasConfiguredKey, "分人条目不做猜测性迁移")
    }

    @Test("迁移跳过：kimi 已有值时保留旧条目不动；旧条目为空时无操作")
    func migrationSkipped() throws {
        // kimi 已配置：不迁移（旧条目保留，避免覆盖用户新设置）
        try store(for: .analysis).saveKey("new-kimi-key")
        try legacyStore.saveKey("legacy-key")
        CloudAPIKeyStore.migrateLegacyKeyIfNeeded(service: serviceName)
        #expect(try store(for: .analysis).readKey() == "new-kimi-key")
        #expect(legacyStore.hasConfiguredKey, "kimi 已有值时旧条目保持不动")

        // 旧条目为空：无操作
        try legacyStore.deleteKey()
        CloudAPIKeyStore.migrateLegacyKeyIfNeeded(service: serviceName)
        #expect(try store(for: .analysis).readKey() == "new-kimi-key")
    }

    @Test("迁移幂等：连续两次执行结果一致")
    func migrationIdempotent() throws {
        try legacyStore.saveKey("legacy-kimi-key")
        CloudAPIKeyStore.migrateLegacyKeyIfNeeded(service: serviceName)
        CloudAPIKeyStore.migrateLegacyKeyIfNeeded(service: serviceName)
        #expect(try store(for: .analysis).readKey() == "legacy-kimi-key")
        #expect(!legacyStore.hasConfiguredKey)
    }

    // MARK: - AppEnvironment 分 provider 状态

    @Test("AppEnvironment：分 provider 配置状态与 keyStore 入口")
    @MainActor
    func environmentPerProviderState() throws {
        let suiteName = "bwfx-key-isolation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let env = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: FileManager.default.temporaryDirectory),
            keychainServiceName: serviceName,
            aiProviderConfigurationStore: AIProviderConfigurationStore(
                defaults: defaults
            )
        )
        #expect(!env.isAnalysisConfigured)
        #expect(!env.isDiarizationConfigured)
        #expect(!env.isCloudConfigured)

        try env.keyStore(for: .diarization).saveKey("diarization-key")
        env.refreshCloudConfiguration()
        #expect(!env.isAnalysisConfigured)
        #expect(env.isDiarizationConfigured)
        #expect(env.isCloudConfigured, "任一 provider 配置即视为云端可用")
        #expect(env.isConfigured(.diarization))
        #expect(!env.isConfigured(.analysis))

        // Kimi 账号登录（OAuth 凭证存在）同样计入「分析已配置」
        try env.kimiOAuthTokenStore.save(KimiOAuthTokens(
            accessToken: "at", refreshToken: "rt",
            expiresAt: Date().addingTimeInterval(900)
        ))
        env.refreshCloudConfiguration()
        #expect(env.isAnalysisConfigured, "账号登录后无需静态 Key 即视为已配置")
        #expect(!env.isConfigured(.analysis), "静态 Key 条目本身仍为空")

        try env.kimiOAuthTokenStore.delete()
        env.refreshCloudConfiguration()
        #expect(!env.isAnalysisConfigured)
    }
}

/// 分人编排的未配置态（零请求、灰态、配置后恢复）
@Suite("分人未配置态")
@MainActor
final class DiarizationUnconfiguredTests {
    let tempDirectory: URL
    let fileStore: MeetingFileStore
    let keychainServiceName = "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)"

    init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileStore = MeetingFileStore(baseDirectory: tempDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
        try? KeychainService(service: keychainServiceName).delete(account: "diarization")
    }

    private var keyStore: CloudAPIKeyStore {
        CloudAPIKeyStore.store(for: .diarization, service: keychainServiceName)
    }

    @Test("未配置分人 Key：start 进入 unconfigured，零上传调用；配置后恢复正常")
    func unconfiguredZeroRequests() async throws {
        let mock = MockDiarizationService()
        let transcriptController = LocalTranscriptionController(service: MockLocalTranscriptionService())
        let controller = DiarizationController(
            diarization: mock,
            fileStore: fileStore,
            transcriptController: transcriptController,
            keyStore: keyStore
        )
        let meeting = Meeting(title: "未配置测试")
        try meeting.transition(to: .ready)
        try await transcriptController.start(for: meeting) { nil }

        controller.start(for: meeting) { nil }
        #expect(controller.cloudState == .unconfigured, "未配置必须为灰态 unconfigured")

        // 恢复入口在未配置时不得触发处理
        controller.retryAwaitingUserChunks()
        controller.resumeAfterKeyFix()
        #expect(controller.cloudState == .unconfigured)
        #expect(mock.calls.isEmpty, "未配置时绝不发请求")

        // 配置后恢复
        try keyStore.saveKey("diarization-key")
        controller.resumeAfterKeyFix()
        #expect(controller.cloudState == .idle)
        await transcriptController.cancel()
    }
}
