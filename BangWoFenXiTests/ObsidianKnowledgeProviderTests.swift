import Foundation
import Testing
@testable import BangWoFenXi

@Suite("Obsidian 本地历史资料检索")
struct ObsidianKnowledgeProviderTests {
    @Test("自然中文请求匹配标题、目录和正文，过滤请求话术与无关目录加分")
    func naturalLanguageSearchFindsTopicAcrossFields() async throws {
        let vault = try fixtureVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("# 星川合作计划\n确认渠道试点的负责人。", at: "2_项目/计划.md", in: vault)
        try write("# 会议纪要\n门店试点采用分组复盘。", at: "2_项目/星川/纪要.md", in: vault)
        try write("# 区域走访\n本次与星川讨论门店铺货节奏。", at: "00_inbox/走访.md", in: vault)
        try write("# 普通历史资料\n你是否能看到 Obsidian 里面的所有资料？", at: "3_知识库/说明.md", in: vault)
        try write("# 无关培训\n陈列和价格牌保持清晰。", at: "3_知识库/培训.md", in: vault)

        let provider = ObsidianKnowledgeProvider(vaultURL: vault)
        let results = try await provider.search("你是否能看到 Obsidian 里面关于星川的所有资料？", limit: 6)

        #expect(Set(results.map(\.sourceId)) == ["2_项目/计划.md", "2_项目/星川/纪要.md", "00_inbox/走访.md"])
        #expect(results.allSatisfy { $0.provider == .obsidian && !$0.excerpt.isEmpty })
    }

    @Test("正文深处的命中段落及相邻解释会进入摘录")
    func excerptIncludesDistantMatchAndAdjacentExplanation() async throws {
        let vault = try fixtureVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let introduction = String(repeating: "这是不相关的开场记录。", count: 500)
        try write("# 综合会议\n\(introduction)\n## 星川渠道问题\n本次决定先在三家样板店验证补货周期。\n由区域负责人下周提供复盘。",
                  at: "综合会议.md", in: vault)

        let results = try await ObsidianKnowledgeProvider(vaultURL: vault).search("星川", limit: 6)
        let result = try #require(results.first)
        #expect(result.excerpt.contains("星川渠道问题"))
        #expect(result.excerpt.contains("三家样板店验证补货周期"))
        #expect(result.excerpt.count <= 1_800)
    }

    @Test("摘录保留多个实际命中段落且遵守总长度预算")
    func excerptIncludesSeparatedPassages() async throws {
        let vault = try fixtureVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let unrelated = (0..<40).map { "普通流程记录第\($0)条。" }.joined(separator: "\n")
        try write("# 走访记录\n星川首次走访：客户希望减少断货。\n先确认缺货原因。\n\(unrelated)\n星川再次走访：双方约定周三检查库存。\n后续保持每周一次跟进。",
                  at: "走访记录.md", in: vault)

        let results = try await ObsidianKnowledgeProvider(vaultURL: vault).search("星川", limit: 6)
        let excerpt = try #require(results.first?.excerpt)
        #expect(excerpt.contains("客户希望减少断货"))
        #expect(excerpt.contains("周三检查库存"))
        #expect(excerpt.contains("…"))
        #expect(excerpt.count <= 1_800)
    }

    @Test("标题命中时保留没有重复主题词的后续正文")
    func headingMatchIncludesFollowingBody() async throws {
        let vault = try fixtureVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("# 星川\n已确认先进行区域小范围试点。\n负责人将在下周反馈结果。", at: "背景.md", in: vault)

        let results = try await ObsidianKnowledgeProvider(vaultURL: vault).search("星川", limit: 6)
        #expect(results.first?.excerpt.contains("区域小范围试点") == true)
        #expect(results.first?.excerpt.contains("下周反馈结果") == true)
    }

    @Test("同一 Provider 在缓存期发现新增、修改和删除的笔记")
    func indexRefreshesWithinCachePeriod() async throws {
        let vault = try fixtureVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let provider = ObsidianKnowledgeProvider(vaultURL: vault)
        #expect(try await provider.search("星川", limit: 6).isEmpty)

        try write("# 首次记录\n星川计划先验证三个门店。", at: "记录.md", in: vault)
        #expect(try await provider.search("星川", limit: 6).count == 1)

        try write("# 更新后的记录\n星川改为先验证六个门店，由新负责人推进。", at: "记录.md", in: vault)
        let updated = try await provider.search("星川", limit: 6)
        #expect(updated.first?.title == "更新后的记录")
        #expect(updated.first?.excerpt.contains("六个门店") == true)
        #expect(updated.first?.excerpt.contains("三个门店") == false)

        try FileManager.default.removeItem(at: vault.appending(path: "记录.md"))
        #expect(try await provider.search("星川", limit: 6).isEmpty)
    }

    @Test("只有通用请求话术或完全无关关键词时不返回整库笔记")
    func genericRequestsAndNoMatchesReturnNoResults() async throws {
        let vault = try fixtureVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("# 资料使用说明\n这些笔记可供查看。", at: "3_知识库/说明.md", in: vault)
        let provider = ObsidianKnowledgeProvider(vaultURL: vault)

        #expect(try await provider.search("你是否能看到 Obsidian 里面的所有资料？", limit: 6).isEmpty)
        #expect(try await provider.search("从未出现的独特品牌", limit: 6).isEmpty)
        #expect(try await provider.search("  ", limit: 6).isEmpty)
    }

    @Test("每轮返回数量有硬上限，零条请求不触发结果")
    func resultLimitIsBounded() async throws {
        let vault = try fixtureVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        for index in 0..<25 {
            try write("# 星川记录\n合成门店编号 \(index)。", at: "记录\(index).md", in: vault)
        }
        let provider = ObsidianKnowledgeProvider(vaultURL: vault)
        #expect(try await provider.search("星川", limit: 0).isEmpty)
        #expect(try await provider.search("星川", limit: 6).count == 6)
        #expect(try await provider.search("星川", limit: 100).count == 20)
    }

    @Test("Vault 删除或根路径不是目录时抛出不可用，而不是没有匹配")
    func unavailableVaultIsNotAnEmptySearch() async throws {
        let vault = try fixtureVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("# 星川\n试点记录。", at: "记录.md", in: vault)
        let provider = ObsidianKnowledgeProvider(vaultURL: vault)
        #expect(try await provider.search("星川", limit: 6).count == 1)
        try FileManager.default.removeItem(at: vault)
        await #expect(throws: KnowledgeProviderError.unavailable) {
            try await provider.search("星川", limit: 6)
        }
        try Data("这是文件，不是 Vault 目录。".utf8).write(to: vault)
        await #expect(throws: KnowledgeProviderError.unavailable) {
            try await provider.search("星川", limit: 6)
        }
    }

    private func fixtureVault() throws -> URL {
        let vault = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-obsidian-retrieval-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        return vault
    }

    private func write(_ text: String, at path: String, in vault: URL) throws {
        let url = vault.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
