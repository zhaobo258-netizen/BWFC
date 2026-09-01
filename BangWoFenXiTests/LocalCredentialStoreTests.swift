import Foundation
import Testing
@testable import BangWoFenXi

@Suite("本机凭证存储", .serialized)
final class LocalCredentialStoreTests {
    let serviceName: String
    let sut: LocalCredentialStore

    init() {
        serviceName = "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)"
        sut = LocalCredentialStore(service: serviceName)
    }

    deinit {
        for account in ["test-account", "test-account-2", "never-saved"] {
            try? sut.delete(account: account)
        }
    }

    @Test("保存与读取")
    func saveAndRead() throws {
        try sut.save("test-secret-value-123", account: "test-account")
        #expect(try sut.read(account: "test-account") == "test-secret-value-123")
    }

    @Test("重复保存覆盖更新")
    func saveOverwritesExistingValue() throws {
        try sut.save("old-value", account: "test-account")
        try sut.save("new-value", account: "test-account")
        #expect(try sut.read(account: "test-account") == "new-value")
    }

    @Test("多账户互相独立")
    func multipleAccountsAreIndependent() throws {
        try sut.save("value-a", account: "test-account")
        try sut.save("value-b", account: "test-account-2")
        #expect(try sut.read(account: "test-account") == "value-a")
        #expect(try sut.read(account: "test-account-2") == "value-b")
    }

    @Test("不同 service 互相独立")
    func multipleServicesAreIndependent() throws {
        let other = LocalCredentialStore(service: "\(serviceName).other")
        defer { try? other.delete(account: "test-account") }
        try sut.save("primary", account: "test-account")
        try other.save("secondary", account: "test-account")
        #expect(try sut.read(account: "test-account") == "primary")
        #expect(try other.read(account: "test-account") == "secondary")
    }

    @Test("新实例可读取已保存值")
    func valuePersistsAcrossInstances() throws {
        try sut.save("persistent-value", account: "test-account")
        let reopened = LocalCredentialStore(service: serviceName)
        #expect(try reopened.read(account: "test-account") == "persistent-value")
    }

    @Test("删除后读取为空")
    func deleteRemovesValue() throws {
        try sut.save("to-be-deleted", account: "test-account")
        try sut.delete(account: "test-account")
        #expect(try sut.read(account: "test-account") == nil)
    }

    @Test("删除不存在条目幂等")
    func deleteNonexistentItemDoesNotThrow() throws {
        try sut.delete(account: "never-saved")
    }

    @Test("云端 API Key 存储生命周期")
    func cloudAPIKeyStoreLifecycle() throws {
        let store = CloudAPIKeyStore(service: serviceName, account: "test-account")
        #expect(!store.hasConfiguredKey)
        try store.saveKey("fake-test-key")
        #expect(store.hasConfiguredKey)
        #expect(try store.readKey() == "fake-test-key")
        try store.deleteKey()
        #expect(!store.hasConfiguredKey)
    }
}
