import Foundation
import Testing
@testable import BangWoFenXi

@Suite("项目对话来源安全入口")
struct ProjectAIChatSourceTests {
    private func source(id: String = "obsidian_1", location: String) -> ProjectAIChatSource {
        ProjectAIChatSource(
            id: id,
            providerName: "测试来源",
            title: "合成历史资料",
            excerpt: "合成资料片段",
            sourceLocation: location
        )
    }

    @Test("仅 Obsidian 本机 Markdown 来源可打开或定位")
    func localMarkdownSource() {
        let url = URL(fileURLWithPath: "/tmp/synthetic-vault/知识资料/历史.md")
        let entry = source(location: url.absoluteString)
        #expect(entry.isObsidian)
        #expect(entry.localFileURL == url)
        #expect(entry.openableURL == url)
        #expect(source(location: "file:///tmp/synthetic-vault/NOTE.MD").isObsidian)
    }

    @Test("拒绝非本机、非 Markdown 及注入 URL 入口", arguments: [
        "file://localhost/tmp/history.md",
        "file://remote-server/share/history.md",
        "file:///tmp/history.app",
        "file:///tmp/history.sh",
        "file:///tmp/history.md?command=run",
        "file:///tmp/history.md#execute",
        "https://example.com/history.md",
        "obsidian://open?vault=synthetic",
        "javascript:alert(1)"
    ])
    func rejectsUnsafeLocalURLs(location: String) {
        let entry = source(location: location)
        #expect(!entry.isObsidian)
        #expect(entry.localFileURL == nil)
        #expect(entry.openableURL == nil)
    }

    @Test("网页来源不能打开本机文件或任意 scheme")
    func webURLAllowlist() {
        #expect(source(id: "web_1", location: "file:///tmp/history.md").openableURL == nil)
        #expect(source(id: "web_1", location: "obsidian://open?vault=synthetic").openableURL == nil)
        #expect(source(id: "web_1", location: "javascript:alert(1)").openableURL == nil)
        #expect(source(id: "web_1", location: "https://").openableURL == nil)
        #expect(source(id: "web_1", location: "https://user:password@example.com/doc").openableURL == nil)
        let entry = source(id: "web_1", location: "https://example.com/history")
        #expect(!entry.isObsidian)
        #expect(entry.openableURL == URL(string: "https://example.com/history"))
    }

    @Test("旧来源缺失相对路径仍可解码")
    func legacyDecoding() throws {
        let json = #"{"id":"web_1","providerName":"测试来源","title":"合成资料","excerpt":"合成摘录","sourceLocation":"https://example.com/history"}"#
        let entry = try JSONDecoder().decode(ProjectAIChatSource.self, from: Data(json.utf8))
        #expect(entry.relativePath == nil)
        #expect(entry.openableURL != nil)
    }

    @Test("本机路径与相对路径分别保存")
    func relativePathRoundTrip() throws {
        var entry = source(location: "file:///tmp/synthetic-vault/history.md")
        entry.relativePath = "history.md"
        let decoded = try JSONDecoder().decode(
            ProjectAIChatSource.self,
            from: JSONEncoder().encode(entry)
        )
        #expect(decoded.relativePath == "history.md")
        #expect(decoded.localFileURL == URL(string: "file:///tmp/synthetic-vault/history.md"))
    }
}
