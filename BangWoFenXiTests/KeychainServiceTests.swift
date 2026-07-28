import Foundation
import LocalAuthentication
import Security
import Testing
@testable import BangWoFenXi

/// Keychain 服务测试（实施计划 14.1：Keychain 存取和删除）。
/// 使用独立 service 名，测试结束后清理，不触碰生产条目。
@Suite("Keychain 读写服务")
final class KeychainServiceTests {
    /// 每次测试使用唯一 service，避免与真实数据或其他测试互相污染
    let serviceName: String
    let sut: KeychainService

    init() {
        serviceName = "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)"
        sut = KeychainService(service: serviceName)
    }

    deinit {
        // 清理测试条目
        for account in [
            "test-account",
            "test-account-2",
            "never-saved",
            "test-cloud-key",
            "cache-account"
        ] {
            try? sut.delete(account: account)
        }
    }

    /// 保存后能读出同样的值
    @Test("保存与读取")
    func saveAndRead() throws {
        try sut.save("test-secret-value-123", account: "test-account")
        #expect(try sut.read(account: "test-account") == "test-secret-value-123")
    }

    /// 重复保存同一 account 应覆盖更新
    @Test("重复保存覆盖更新")
    func saveOverwritesExistingValue() throws {
        try sut.save("old-value", account: "test-account")
        try sut.save("new-value", account: "test-account")
        #expect(try sut.read(account: "test-account") == "new-value")
    }

    /// 不同 account 互不影响
    @Test("多账户互相独立")
    func multipleAccountsAreIndependent() throws {
        try sut.save("value-a", account: "test-account")
        try sut.save("value-b", account: "test-account-2")
        #expect(try sut.read(account: "test-account") == "value-a")
        #expect(try sut.read(account: "test-account-2") == "value-b")
    }

    /// 删除后读取返回 nil
    @Test("删除后读取为空")
    func deleteRemovesValue() throws {
        try sut.save("to-be-deleted", account: "test-account")
        #expect(try sut.read(account: "test-account") != nil)
        try sut.delete(account: "test-account")
        #expect(try sut.read(account: "test-account") == nil)
    }

    /// 删除不存在的条目应幂等成功
    @Test("删除不存在条目幂等")
    func deleteNonexistentItemDoesNotThrow() throws {
        try sut.delete(account: "never-saved")
    }

    /// 读取不存在的条目返回 nil 而不是报错
    @Test("读取不存在条目返回空")
    func readNonexistentReturnsNil() throws {
        #expect(try sut.read(account: "never-saved") == nil)
    }

    @Test("自动读取禁止弹出系统鉴权界面")
    func automaticReadDisablesAuthenticationUI() {
        let query = sut.readQuery(account: "test-account")
        #expect(
            (query[kSecUseAuthenticationContext as String] as? LAContext)?
                .interactionNotAllowed == true
        )
    }

    @Test("首次成功读取后同一进程复用内存凭证")
    func successfulReadUsesProcessCache() throws {
        let account = "cache-account"
        let value = "process-cache-test-value"
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        #expect(SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess)
        #expect(try sut.read(account: account) == value)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        #expect(
            SecItemDelete(deleteQuery as CFDictionary) == errSecSuccess
        )
        #expect(try sut.read(account: account) == value)

        try sut.delete(account: account)
        #expect(try sut.read(account: account) == nil)
    }

    /// CloudAPIKeyStore 封装：保存 / 状态 / 删除（同样使用测试专用 service）
    @Test("云端 API Key 存储生命周期")
    func cloudAPIKeyStoreLifecycle() throws {
        let store = CloudAPIKeyStore(service: serviceName, account: "test-cloud-key")
        #expect(store.hasConfiguredKey == false)
        try store.saveKey("fake-test-key")
        #expect(store.hasConfiguredKey)
        #expect(try store.readKey() == "fake-test-key")
        try store.deleteKey()
        #expect(store.hasConfiguredKey == false)
        #expect(try store.readKey() == nil)
    }
}
