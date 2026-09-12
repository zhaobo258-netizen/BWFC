import Foundation

/// 本机明文凭证存储。值写入当前 App 的 UserDefaults 域，不访问系统钥匙串。
/// service/account 共同隔离不同 provider 与测试条目。
struct LocalCredentialStore: Sendable {
    let service: String

    init(service: String) {
        self.service = service
    }

    func save(_ value: String, account: String) throws {
        UserDefaults.standard.set(value, forKey: storageKey(account: account))
    }

    func read(account: String) throws -> String? {
        UserDefaults.standard.string(forKey: storageKey(account: account))
    }

    func contains(account: String) -> Bool {
        UserDefaults.standard.object(forKey: storageKey(account: account)) != nil
    }

    func delete(account: String) throws {
        UserDefaults.standard.removeObject(forKey: storageKey(account: account))
    }

    private func storageKey(account: String) -> String {
        "bwfx.local-credential.\(encoded(service)).\(encoded(account))"
    }

    private func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum CloudProvider: String, Sendable, CaseIterable {
    case analysis
    case diarization

    var account: String {
        switch self {
        case .analysis: return "kimi"
        case .diarization: return "diarization"
        }
    }

    var displayName: String {
        switch self {
        case .analysis: return "分析（Kimi）"
        case .diarization: return "分人（OpenAI 兼容）"
        }
    }

    static let legacyAccount = "openai"
}

/// 云端 API Key 的本机明文存储封装；不同 provider 使用独立条目。
struct CloudAPIKeyStore: Sendable {
    static let defaultService = "com.zhaobo.BangWoFenXi.credentials.local.v1"
    static let legacyAdHocService = "com.zhaobo.BangWoFenXi.credentials.local.legacy"

    private let localStore: LocalCredentialStore
    private let account: String

    init(
        service: String = CloudAPIKeyStore.defaultService,
        account: String = CloudProvider.legacyAccount
    ) {
        self.localStore = LocalCredentialStore(service: service)
        self.account = account
    }

    static func store(
        for provider: CloudProvider,
        service: String = CloudAPIKeyStore.defaultService
    ) -> CloudAPIKeyStore {
        CloudAPIKeyStore(service: service, account: provider.account)
    }

    var hasConfiguredKey: Bool {
        localStore.contains(account: account)
    }

    func saveKey(_ key: String) throws {
        try localStore.save(key, account: account)
    }

    func readKey() throws -> String? {
        try localStore.read(account: account)
    }

    func deleteKey() throws {
        try localStore.delete(account: account)
    }

    static func migrateLegacyKeyIfNeeded(
        service: String = CloudAPIKeyStore.defaultService
    ) {
        let legacy = CloudAPIKeyStore(service: service, account: CloudProvider.legacyAccount)
        let analysis = CloudAPIKeyStore.store(for: .analysis, service: service)
        guard !analysis.hasConfiguredKey,
              let legacyValue = try? legacy.readKey(),
              !legacyValue.isEmpty else {
            return
        }
        try? analysis.saveKey(legacyValue)
        try? legacy.deleteKey()
    }

    static func migrateAdHocServiceCredentialsIfNeeded(
        from legacyService: String = CloudAPIKeyStore.legacyAdHocService,
        to service: String = CloudAPIKeyStore.defaultService
    ) {
        guard legacyService != service else { return }
        let migrations: [(source: String, destination: String)] =
            CloudProvider.allCases.map { ($0.account, $0.account) }
            + [(KimiOAuthTokenStore.account, KimiOAuthTokenStore.account)]
            + [(CloudProvider.legacyAccount, CloudProvider.analysis.account)]
        let current = LocalCredentialStore(service: service)
        guard migrations.contains(where: { !current.contains(account: $0.destination) }) else {
            return
        }
        let legacy = LocalCredentialStore(service: legacyService)
        for migration in migrations {
            guard !current.contains(account: migration.destination),
                  legacy.contains(account: migration.source),
                  let value = try? legacy.read(account: migration.source),
                  !value.isEmpty else {
                continue
            }
            try? current.save(value, account: migration.destination)
        }
    }
}
