import Foundation
import Testing
@testable import BangWoFenXi

/// LocalCredentialStore 钥匙串迁移行为（2026-09-13 审计批次1-R4）。
/// 通用存取语义已由 LocalCredentialStoreTests 覆盖，本套件只测 UserDefaults→钥匙串迁移。
/// 每个用例使用独立 UUID service，避免触碰真实条目与其他套件并发冲突。
@Suite("本机凭证钥匙串迁移", .serialized)
struct LocalCredentialStoreMigrationTests {
    private func makeStore() -> LocalCredentialStore {
        LocalCredentialStore(service: "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)")
    }

    /// 复刻 v1 明文时代的 UserDefaults 键格式，作为迁移路径的回归锚点。
    private func legacyKey(service: String, account: String) -> String {
        func encoded(_ value: String) -> String {
            Data(value.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
        }
        return "bwfx.local-credential.\(encoded(service)).\(encoded(account))"
    }

    @Test("历史 UserDefaults 明文在首次读取时迁移进钥匙串并清除旧值")
    func migrationOnRead() throws {
        let store = makeStore()
        let key = legacyKey(service: store.service, account: "acct")
        UserDefaults.standard.set("旧明文key", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let migrated = try store.read(account: "acct")
        #expect(migrated == "旧明文key")
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        // 迁移后第二次读取走钥匙串路径，结果一致
        #expect(try store.read(account: "acct") == "旧明文key")
    }

    @Test("钥匙串已有条目时旧明文只清理不覆盖钥匙串")
    func keychainWinsOverLegacy() throws {
        let store = makeStore()
        let key = legacyKey(service: store.service, account: "acct")
        try store.save("钥匙串值", account: "acct")
        UserDefaults.standard.set("过期旧值", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(try store.read(account: "acct") == "钥匙串值")
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    @Test("空历史值直接清理，不进入钥匙串")
    func emptyLegacyValueCleaned() throws {
        let store = makeStore()
        let key = legacyKey(service: store.service, account: "acct")
        UserDefaults.standard.set("", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(try store.read(account: "acct") == nil)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(!store.contains(account: "acct"))
    }

    @Test("保存新值后历史明文同账户一并清除")
    func saveRemovesLegacyEntry() throws {
        let store = makeStore()
        let key = legacyKey(service: store.service, account: "acct")
        UserDefaults.standard.set("旧值", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        try store.save("新值", account: "acct")
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(try store.read(account: "acct") == "新值")
    }
}
