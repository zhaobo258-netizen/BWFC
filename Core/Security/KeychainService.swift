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

/// 云端 API Key 的专用封装（实施计划 12.1：API Key 只进 Keychain）。
/// service/account 可注入，便于测试隔离。
struct CloudAPIKeyStore: Sendable {
    /// 生产环境使用的 Keychain service 名
    static let defaultService = "com.zhaobo.BangWoFenXi.cloud-api-key"
    static let defaultAccount = "openai"

    private let keychain: KeychainService
    private let account: String

    init(service: String = CloudAPIKeyStore.defaultService,
         account: String = CloudAPIKeyStore.defaultAccount) {
        self.keychain = KeychainService(service: service)
        self.account = account
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
}
