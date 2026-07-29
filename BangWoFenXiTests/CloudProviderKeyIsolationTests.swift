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

    // MARK: - 跨 service 迁移（ad-hoc 时代条目 → 当前 service）

    @Test("跨 service 迁移：搬来分析 Key 与登录凭证，且旧条目必须原样保留")
    func adHocServiceMigrationCopiesAndPreservesLegacy() throws {
        let oldService = "\(serviceName).adhoc"
        let oldKeychain = KeychainService(service: oldService)
        defer {
            for account in ["kimi", "diarization", CloudProvider.legacyAccount,
                            KimiOAuthTokenStore.account] {
                try? oldKeychain.delete(account: account)
            }
        }
        try oldKeychain.save("adhoc-kimi-key", account: CloudProvider.analysis.account)
        try oldKeychain.save("{\"access_token\":\"a\"}", account: KimiOAuthTokenStore.account)

        CloudAPIKeyStore.migrateAdHocServiceCredentialsIfNeeded(
            from: oldService, to: serviceName
        )

        #expect(try store(for: .analysis).readKey() == "adhoc-kimi-key")
        #expect(
            try KeychainService(service: serviceName)
                .read(account: KimiOAuthTokenStore.account) == "{\"access_token\":\"a\"}"
        )
        // 旧条目是老板仅有的凭证副本，删除有风险；迁移只读不删
        #expect(try oldKeychain.read(account: CloudProvider.analysis.account) == "adhoc-kimi-key",
                "旧 service 的分析条目必须原样保留")
        #expect(try oldKeychain.read(account: KimiOAuthTokenStore.account) != nil,
                "旧 service 的登录凭证必须原样保留")
        #expect(!store(for: .diarization).hasConfiguredKey, "旧 service 没有分人条目时不得凭空创建")
    }

    @Test("跨 service 迁移：当前 service 已有值时不覆盖；同名 service 直接跳过")
    func adHocServiceMigrationSkipsWhenPresent() throws {
        let oldService = "\(serviceName).adhoc"
        let oldKeychain = KeychainService(service: oldService)
        defer { try? oldKeychain.delete(account: CloudProvider.analysis.account) }
        try oldKeychain.save("adhoc-kimi-key", account: CloudProvider.analysis.account)
        try store(for: .analysis).saveKey("current-kimi-key")

        CloudAPIKeyStore.migrateAdHocServiceCredentialsIfNeeded(
            from: oldService, to: serviceName
        )
        #expect(try store(for: .analysis).readKey() == "current-kimi-key", "不得覆盖当前 service 已有凭证")

        // 源与目标同名：直接跳过，不做自我复制
        try store(for: .analysis).deleteKey()
        CloudAPIKeyStore.migrateAdHocServiceCredentialsIfNeeded(
            from: serviceName, to: serviceName
        )
        #expect(!store(for: .analysis).hasConfiguredKey)
    }

    /// 目标条目齐全时必须彻底不碰旧 service：旧条目是 ad-hoc 身份写的，
    /// 取它的密文会触发系统 ACL 授权框并阻塞主流程。用一个「一读就失败」的
    /// 哨兵 service 当旧 service——只要迁移真去读了它，值就会被写进目标条目。
    @Test("跨 service 迁移：目标齐全时完全不触碰旧 service")
    func adHocServiceMigrationSkipsLegacyWhenComplete() throws {
        let oldService = "\(serviceName).adhoc"
        let oldKeychain = KeychainService(service: oldService)
        defer {
            try? oldKeychain.delete(account: CloudProvider.analysis.account)
            try? oldKeychain.delete(account: CloudProvider.diarization.account)
            try? oldKeychain.delete(account: KimiOAuthTokenStore.account)
            try? oldKeychain.delete(account: CloudProvider.legacyAccount)
        }
        // 旧 service 每个源条目都放一个「毒药」值
        try oldKeychain.save("STALE-analysis", account: CloudProvider.analysis.account)
        try oldKeychain.save("STALE-diarization", account: CloudProvider.diarization.account)
        try oldKeychain.save("STALE-oauth", account: KimiOAuthTokenStore.account)
        try oldKeychain.save("STALE-openai", account: CloudProvider.legacyAccount)

        // 当前 service 所有目标条目都已就位
        try store(for: .analysis).saveKey("fresh-analysis")
        try store(for: .diarization).saveKey("fresh-diarization")
        try KeychainService(service: serviceName)
            .save("fresh-oauth", account: KimiOAuthTokenStore.account)

        CloudAPIKeyStore.migrateAdHocServiceCredentialsIfNeeded(
            from: oldService, to: serviceName
        )

        #expect(try store(for: .analysis).readKey() == "fresh-analysis")
        #expect(try store(for: .diarization).readKey() == "fresh-diarization")
        #expect(try KeychainService(service: serviceName)
            .read(account: KimiOAuthTokenStore.account) == "fresh-oauth")
        #expect(!KeychainService(service: serviceName)
            .contains(account: CloudProvider.legacyAccount),
                "openai 兜底不得凭空创建目标条目")
    }

    @Test("跨 service 迁移：旧 service 只有 openai 条目时兜底填入分析条目")
    func adHocServiceMigrationFallsBackToLegacyAccount() throws {
        let oldService = "\(serviceName).adhoc"
        let oldKeychain = KeychainService(service: oldService)
        defer { try? oldKeychain.delete(account: CloudProvider.legacyAccount) }
        try oldKeychain.save("adhoc-openai-key", account: CloudProvider.legacyAccount)

        CloudAPIKeyStore.migrateAdHocServiceCredentialsIfNeeded(
            from: oldService, to: serviceName
        )

        #expect(try store(for: .analysis).readKey() == "adhoc-openai-key")
        #expect(try oldKeychain.read(account: CloudProvider.legacyAccount) == "adhoc-openai-key",
                "旧条目必须原样保留")
    }

    @Test("跨 service 迁移幂等：连续两次执行结果一致")
    func adHocServiceMigrationIdempotent() throws {
        let oldService = "\(serviceName).adhoc"
        let oldKeychain = KeychainService(service: oldService)
        defer { try? oldKeychain.delete(account: CloudProvider.analysis.account) }
        try oldKeychain.save("adhoc-kimi-key", account: CloudProvider.analysis.account)

        CloudAPIKeyStore.migrateAdHocServiceCredentialsIfNeeded(
            from: oldService, to: serviceName
        )
        CloudAPIKeyStore.migrateAdHocServiceCredentialsIfNeeded(
            from: oldService, to: serviceName
        )
        #expect(try store(for: .analysis).readKey() == "adhoc-kimi-key")
        #expect(try oldKeychain.read(account: CloudProvider.analysis.account) == "adhoc-kimi-key")
    }

    @Test("跨 service 迁移后 OAuth 凭证可正常解码")
    func adHocServiceMigrationPreservesOAuthRoundTrip() throws {
        let oldService = "\(serviceName).adhoc"
        let oldStore = KimiOAuthTokenStore(service: oldService)
        defer { try? oldStore.delete() }
        let tokens = KimiOAuthTokens(
            accessToken: "access-abc",
            refreshToken: "refresh-def",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try oldStore.save(tokens)

        CloudAPIKeyStore.migrateAdHocServiceCredentialsIfNeeded(
            from: oldService, to: serviceName
        )

        #expect(try KimiOAuthTokenStore(service: serviceName).read() == tokens)
        #expect(try oldStore.read() == tokens, "旧 service 的登录凭证必须原样保留")
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
