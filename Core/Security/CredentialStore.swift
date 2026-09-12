import Foundation
import Security

/// 本机凭证存储错误。code 为钥匙串 OSStatus，operation 标记出错动作。
enum CredentialStoreError: Error {
    case keychainFailure(code: OSStatus, operation: String)
    case readbackMismatch(account: String)
}

/// 本机凭证存储。值写入系统钥匙串（kSecClassGenericPassword），不再落 UserDefaults 明文。
/// service/account 共同隔离不同 provider 与测试条目。
///
/// 迁移规则（对历史 UserDefaults 条目，惰性触发于首次 read/contains）：
/// 先写钥匙串并读回校验，确认钥匙串真实持有后才删除旧明文；任一步失败则保留旧值下次重试。
/// 钥匙串已有条目时视为钥匙串是事实来源，仅清理旧明文，不回写覆盖。
struct LocalCredentialStore: Sendable {
    let service: String

    init(service: String) {
        self.service = service
    }

    func save(_ value: String, account: String) throws {
        try writeToKeychain(value, account: account)
        removeLegacyEntry(account: account)
    }

    func read(account: String) throws -> String? {
        if let migrated = migrateLegacyEntryIfNeeded(account: account) {
            return migrated
        }
        return try readFromKeychain(account: account)
    }

    func contains(account: String) -> Bool {
        if migrateLegacyEntryIfNeeded(account: account) != nil {
            return true
        }
        return keychainItemStatus(account: account) == errSecSuccess
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw CredentialStoreError.keychainFailure(code: status, operation: "删除")
        }
    }

    // MARK: - 钥匙串读写

    private func writeToKeychain(_ value: String, account: String) throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(code: status, operation: "写入")
        }

        do {
            guard try readFromKeychain(account: account) == value else {
                throw CredentialStoreError.readbackMismatch(account: account)
            }
        } catch {
            SecItemDelete(query as CFDictionary)
            throw error
        }
    }

    private func readFromKeychain(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychainFailure(code: status, operation: "读取")
        }
    }

    private func keychainItemStatus(account: String) -> OSStatus {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - UserDefaults 历史明文迁移

    private func migrateLegacyEntryIfNeeded(account: String) -> String? {
        let key = legacyStorageKey(account: account)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        let legacyValue = UserDefaults.standard.string(forKey: key) ?? ""
        guard !legacyValue.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        if keychainItemStatus(account: account) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        do {
            try writeToKeychain(legacyValue, account: account)
        } catch {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: key)
        return legacyValue
    }

    private func removeLegacyEntry(account: String) {
        UserDefaults.standard.removeObject(forKey: legacyStorageKey(account: account))
    }

    private func legacyStorageKey(account: String) -> String {
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

/// 云端 API Key 的本机存储封装（系统钥匙串）；不同 provider 使用独立条目。
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
