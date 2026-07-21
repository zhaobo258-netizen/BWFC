import Foundation
import Security

/// Keychain 错误
enum KeychainError: Error, Equatable {
    /// Security 框架返回的非预期状态码
    case unexpectedStatus(OSStatus)
    /// 读出的数据无法解码为 UTF-8 字符串
    case dataCorrupted
}

extension KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain 操作失败（状态码 \(status)）"
        case .dataCorrupted:
            return "Keychain 数据损坏"
        }
    }
}

/// Keychain 读写服务（实施计划 12.1：API Key 只存 Keychain，不落盘明文）。
/// 使用 generic password；数据标记为 ThisDeviceOnly，不随备份迁移。
struct KeychainService: Sendable {
    /// service 名，隔离不同用途的条目；测试必须使用独立 service 并在结束后清理
    let service: String

    init(service: String) {
        self.service = service
    }

    /// 保存（已存在则覆盖更新）
    func save(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // 先尝试更新已有条目
        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        // 不存在则新增
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// 读取；不存在时返回 nil
    func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        return value
    }

    /// 删除；条目不存在视为成功（幂等）
    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// 云端服务 provider（Key 分家：各自独立 Keychain 条目，互不外借）
enum CloudProvider: String, Sendable, CaseIterable {
    /// 谈判文字分析（Kimi 网关）
    case analysis
    /// 说话人识别（OpenAI 兼容 diarize 接口）
    case diarization

    /// Keychain account 名
    var account: String {
        switch self {
        case .analysis: return "kimi"
        case .diarization: return "diarization"
        }
    }

    /// 界面显示名
    var displayName: String {
        switch self {
        case .analysis: return "分析（Kimi）"
        case .diarization: return "分人（OpenAI 兼容）"
        }
    }

    /// 历史遗留的统一 account（迁移来源）
    static let legacyAccount = "openai"
}

/// 云端 API Key 的专用封装（实施计划 12.1：API Key 只进 Keychain）。
/// service/account 可注入，便于测试隔离；按 provider 分条目存取，互不外借。
struct CloudAPIKeyStore: Sendable {
    /// 生产环境使用的 Keychain service 名
    static let defaultService = "com.zhaobo.BangWoFenXi.cloud-api-key"

    private let keychain: KeychainService
    private let account: String

    init(service: String = CloudAPIKeyStore.defaultService,
         account: String = CloudProvider.legacyAccount) {
        self.keychain = KeychainService(service: service)
        self.account = account
    }

    /// 按 provider 取对应条目的存储
    static func store(
        for provider: CloudProvider,
        service: String = CloudAPIKeyStore.defaultService
    ) -> CloudAPIKeyStore {
        CloudAPIKeyStore(service: service, account: provider.account)
    }

    /// 是否已配置 API Key
    var hasConfiguredKey: Bool {
        (try? keychain.read(account: account)).map { !$0.isEmpty } ?? false
    }

    /// 保存 API Key
    func saveKey(_ key: String) throws {
        try keychain.save(key, account: account)
    }

    /// 读取 API Key（仅供网络层使用；严禁写入日志）
    func readKey() throws -> String? {
        try keychain.read(account: account)
    }

    /// 删除 API Key
    func deleteKey() throws {
        try keychain.delete(account: account)
    }

    /// 旧版统一条目迁移：早期版本只有一个 account=openai 条目。
    /// 若旧条目有值且「分析（kimi）」条目为空：用户当年存的就是分析 Key，
    /// 自动迁移到 kimi 条目并清空旧条目，避免用户重输。
    /// 分人条目不做猜测性迁移（无法判断旧值属于哪个服务，只能按分析处理）。
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
        do {
            try analysis.saveKey(legacyValue)
            try legacy.deleteKey()
            AppLog.persistence.info("API Key 已从旧版统一条目迁移到分析条目")
        } catch {
            // 迁移失败不清空旧条目，下次启动重试；只记录脱敏错误类型
            AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent(
                "key_migration_failed", error: String(describing: type(of: error))
            ))
        }
    }
}
