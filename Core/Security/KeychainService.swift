import Foundation
import LocalAuthentication
import Security

/// Keychain 错误
enum KeychainError: Error, Equatable {
    /// Security 框架返回的非预期状态码
    case unexpectedStatus(OSStatus)
    /// 当前 App 身份无权静默读取；自动任务不得唤起系统密码框
    case interactionNotAllowed
    /// 读出的数据无法解码为 UTF-8 字符串
    case dataCorrupted
}

extension KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain 操作失败（状态码 \(status)）"
        case .interactionNotAllowed:
            return "AI 凭证需要重新连接；请前往设置登录或重新保存 API Key"
        case .dataCorrupted:
            return "Keychain 数据损坏"
        }
    }
}

private final class KeychainValueCache: @unchecked Sendable {
    static let shared = KeychainValueCache()

    private struct Key: Hashable {
        var service: String
        var account: String
    }

    private let lock = NSLock()
    private var values: [Key: String] = [:]

    func value(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[Key(service: service, account: account)]
    }

    func store(_ value: String, service: String, account: String) {
        lock.lock()
        values[Key(service: service, account: account)] = value
        lock.unlock()
    }

    func remove(service: String, account: String) {
        lock.lock()
        values.removeValue(forKey: Key(service: service, account: account))
        lock.unlock()
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
            KeychainValueCache.shared.store(
                value,
                service: service,
                account: account
            )
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
        KeychainValueCache.shared.store(
            value,
            service: service,
            account: account
        )
    }

    /// 首次读到值后进程内缓存，同一次启动不会重复走 SecItem。
    /// 读不到时抛错而不阻塞，由业务层在设置页提供重新连接入口，
    /// 录音与本地转写继续运行。
    ///
    /// 注意：**这里挡不住系统的钥匙串授权框**，原因见 `readQuery`。
    func read(account: String) throws -> String? {
        if let cached = KeychainValueCache.shared.value(
            service: service,
            account: account
        ) {
            return cached
        }
        let query = readQuery(account: account)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw KeychainError.interactionNotAllowed
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        KeychainValueCache.shared.store(
            value,
            service: service,
            account: account
        )
        return value
    }

    /// 老式（文件）钥匙串的逐条 ACL 授权框**无法从调用方抑制**：2026-07-29 用
    /// 与本 App 同身份同 entitlements 的探针实测，`LAContext.interactionNotAllowed`
    /// 与已弃用的 `kSecUseAuthenticationUIFail` 都拦不住它——跨签名身份读取时
    /// SecurityAgent 照样弹框，调用会一直阻塞到用户处理。
    /// 保留 `interactionNotAllowed` 只为拦住 LocalAuthentication（Touch ID / 密码）
    /// 这一类交互，不要据此以为读取是绝对静默的。
    ///
    /// 真正让读取静默的是签名身份一致：稳定身份写入的条目被稳定身份读取
    /// 恒为 `errSecSuccess`，重新打包（CDHash 变化）不受影响。跨身份的历史条目
    /// 需要用户在授权框上点一次「始终允许」，此后永久静默。
    ///
    /// 想彻底摆脱这套 ACL 得换现代（data protection）钥匙串，但那需要 Apple
    /// Team ID：自签名下 `kSecUseDataProtectionKeychain` 返回 -34018，
    /// 显式声明 `keychain-access-groups` 会让进程被内核直接 SIGKILL。
    func readQuery(account: String) -> [String: Any] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
    }

    func contains(account: String) -> Bool {
        if KeychainValueCache.shared.value(
            service: service,
            account: account
        ) != nil {
            return true
        }
        var query = readQuery(account: account)
        query.removeValue(forKey: kSecReturnData as String)
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
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
        KeychainValueCache.shared.remove(
            service: service,
            account: account
        )
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
    /// v2 由稳定签名版本创建；旧 ad-hoc 条目原样保留，避免访问旧 ACL 时弹窗。
    static let defaultService = "com.zhaobo.BangWoFenXi.credentials.v2"
    static let legacyAdHocService =
        "com.zhaobo.BangWoFenXi.cloud-api-key"

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
        keychain.contains(account: account)
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

    /// ad-hoc 签名时代的条目存在旧 service 下；改用 v2 service 时只留了常量、没写迁移，
    /// 导致凭证「断链」：v2 为空，旧条目仍在，界面表现为「AI 未接入」。
    /// 本迁移只读旧条目、只写新条目，**绝不删除旧条目** —— 旧条目可能是用户仅有的凭证副本，
    /// 且其 ACL 属于另一签名身份，删除有触发系统授权框的风险。
    ///
    /// 读取**不能**假定静默：旧条目由 ad-hoc 身份写入，用当前身份取密文会触发
    /// 系统 ACL 授权框并阻塞（见 `readQuery`）。所以先确认确有缺口再碰旧 service——
    /// 目标条目齐全时整个迁移直接返回，一次 SecItem 都不发，
    /// 免得每次启动都为一件早就做完的事去敲旧条目。
    static func migrateAdHocServiceCredentialsIfNeeded(
        from legacyService: String = CloudAPIKeyStore.legacyAdHocService,
        to service: String = CloudAPIKeyStore.defaultService
    ) {
        guard legacyService != service else { return }
        // 源 → 目标 account 映射。openai 放最后：仅当 kimi 未被填上时才兜底，
        // 因此不会复制任何没有读取方的密文。
        let migrations: [(source: String, destination: String)] =
            CloudProvider.allCases.map { ($0.account, $0.account) }
            + [(KimiOAuthTokenStore.account, KimiOAuthTokenStore.account)]
            + [(CloudProvider.legacyAccount, CloudProvider.analysis.account)]
        let current = KeychainService(service: service)
        // 先只做一次「有没有缺口」的判断；全都齐了就一次 SecItem 都不发。
        guard migrations.contains(where: { !current.contains(account: $0.destination) }) else {
            return
        }
        let legacy = KeychainService(service: legacyService)
        for migration in migrations {
            // 必须逐轮重查：openai 兜底排在最后，若 kimi 刚在本轮被填上，
            // 这里要能看见并跳过，否则会用旧 openai 值盖掉刚迁好的 kimi。
            guard !current.contains(account: migration.destination) else { continue }
            // 旧条目不存在时只查属性、不取密文，避免为一个空条目触发授权框。
            guard legacy.contains(account: migration.source) else { continue }
            do {
                guard let value = try legacy.read(account: migration.source),
                      !value.isEmpty else { continue }
                try current.save(value, account: migration.destination)
                AppLog.persistence.info("凭证已从旧 service 迁移到当前 service")
            } catch {
                AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent(
                    "adhoc_service_migration_failed",
                    error: String(describing: type(of: error))
                ))
            }
        }
    }
}
