import Foundation

actor ObsidianKnowledgeProvider: KnowledgeProvider {
    let kind: KnowledgeProviderKind = .obsidian
    nonisolated let providerID = "obsidian"
    let displayName = "Obsidian"

    private let vaultURL: URL
    private let ignoredRootNames: Set<String>
    private var entries: [IndexEntry] = []
    private var indexedAt: Date?

    init(vaultURL: URL, ignoredRootNames: Set<String> = ["帮我分析"]) {
        self.vaultURL = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        self.ignoredRootNames = ignoredRootNames
    }

    func healthCheck() async -> KnowledgeProviderHealth {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            return KnowledgeProviderHealth(isAvailable: false, message: "Vault 不存在或授权已失效")
        }
        do {
            try rebuildIndexIfNeeded()
            return KnowledgeProviderHealth(
                isAvailable: true,
                message: "可检索 \(entries.count) 篇 Markdown"
            )
        } catch {
            return KnowledgeProviderHealth(isAvailable: false, message: "Vault 读取失败")
        }
    }

    func search(_ query: String, limit: Int = 5) async throws -> [KnowledgeConnection] {
        let normalizedQuery = Self.normalized(String(query.prefix(2_000)))
        let resultLimit = min(max(0, limit), 20)
        guard !normalizedQuery.isEmpty, resultLimit > 0 else { return [] }
        // 每轮发现新增/修改/删除的笔记；未变文件复用正文，避免反复读取整个 Vault。
        try rebuildIndexIfNeeded(refresh: true)
        let terms = Self.searchTerms(from: normalizedQuery)
        guard !terms.isEmpty else { return [] }

        let scored = entries.compactMap { entry -> (IndexEntry, Double)? in
            let score = Self.score(entry: entry, query: normalizedQuery, terms: terms)
            return score > 0 ? (entry, score) : nil
        }
        .sorted {
            $0.1 == $1.1
                ? $0.0.modifiedAt > $1.0.modifiedAt
                : $0.1 > $1.1
        }

        var results: [KnowledgeConnection] = []
        // 返回前再次实际读取，不能把缓存当作仍有访问权限或仍然存在的证明。
        // 也允许标题命中的笔记在全库正文预算耗尽后，按本轮候选预算读取正文。
        for (entry, _) in scored.prefix(40) {
            guard Self.relativePath(of: entry.fileURL, under: vaultURL) == entry.relativePath,
                  let values = try? entry.fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 2_000_000,
                  let text = try? String(contentsOf: entry.fileURL, encoding: .utf8) else { continue }
            var current = entry
            current.title = Self.title(from: text, fallback: entry.fileURL.deletingPathExtension().lastPathComponent)
            current.searchableText = String(text.prefix(80_000))
            let score = Self.score(entry: current, query: normalizedQuery, terms: terms)
            guard score > 0 else { continue }
            results.append(KnowledgeConnection(
                provider: .obsidian,
                providerId: providerID,
                sourceId: current.relativePath,
                title: current.title,
                excerpt: Self.excerpt(from: current.searchableText, terms: terms),
                sourceLocation: current.fileURL.path,
                relevance: min(score / 100, 1),
                retrievedAt: Date()
            ))
            if results.count == resultLimit { break }
        }
        return results
    }

    /// 全库正文索引的总字符预算：防止 5000 篇 × 80K 字符的极端 Vault
    /// 把索引撑到数百 MB。超出预算后仅索引标题（仍可按标题命中）。
    private static let totalSearchableCharacterBudget = 12_000_000

    private func rebuildIndexIfNeeded(now: Date = Date(), refresh: Bool = false) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw KnowledgeProviderError.unavailable }
        guard FileManager.default.isReadableFile(atPath: vaultURL.path) else {
            throw KnowledgeProviderError.permissionDenied
        }
        if !refresh, let indexedAt, now.timeIntervalSince(indexedAt) < 300 {
            return
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let rootURL = vaultURL
        var rootEnumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                // 子目录不可读可跳过；整个 Vault 不可读不能伪装成“没有相关资料”。
                if url.standardizedFileURL.resolvingSymlinksInPath() == rootURL {
                    rootEnumerationFailed = true
                    return false
                }
                return true
            }
        ) else {
            throw KnowledgeProviderError.permissionDenied
        }

        let cached = Dictionary(entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var rebuilt: [IndexEntry] = []
        var remainingTextBudget = Self.totalSearchableCharacterBudget
        for case let fileURL as URL in enumerator {
            // symlink 指向 Vault 之外的内容不入索引（越界即跳过，不合成假相对路径）
            guard let relativePath = Self.relativePath(of: fileURL, under: vaultURL) else {
                continue
            }
            if let rootName = relativePath.split(separator: "/").first.map(String.init),
               ignoredRootNames.contains(rootName) {
                if let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                   values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard fileURL.pathExtension.lowercased() == "md",
                  let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 2_000_000 else {
                continue
            }
            guard rebuilt.count < 5_000,
                  FileManager.default.isReadableFile(atPath: fileURL.path) else {
                continue
            }
            if let previous = cached[relativePath],
               previous.modifiedAt == values.contentModificationDate,
               previous.fileSize == values.fileSize,
               previous.searchableText.count <= remainingTextBudget {
                rebuilt.append(previous)
                remainingTextBudget -= previous.searchableText.count
                continue
            }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let searchableText = String(text.prefix(min(80_000, max(0, remainingTextBudget))))
            remainingTextBudget -= searchableText.count
            rebuilt.append(IndexEntry(
                fileURL: fileURL,
                relativePath: relativePath,
                title: Self.title(from: text, fallback: fileURL.deletingPathExtension().lastPathComponent),
                searchableText: searchableText,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                fileSize: values.fileSize ?? 0,
                folderPriority: Self.folderPriority(relativePath)
            ))
        }
        guard !rootEnumerationFailed else { throw KnowledgeProviderError.permissionDenied }
        entries = rebuilt
        indexedAt = now
    }

    /// 相对路径；解析 symlink 后不在 Vault 内时返回 nil（调用方跳过该文件）
    private static func relativePath(of fileURL: URL, under rootURL: URL) -> String? {
        let root = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
    }

    private static func title(from text: String, fallback: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).prefix(80)
        if let frontmatterTitle = lines.first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("title:")
        }) {
            let value = frontmatterTitle.split(separator: ":", maxSplits: 1)
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let value, !value.isEmpty { return value }
        }
        if let heading = lines.first(where: { $0.hasPrefix("# ") }) {
            let value = heading.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return fallback
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchTerms(from query: String) -> [SearchTerm] {
        // 此处只做本地词法检索，不把用户原话交给云端规划。
        // 先移除请求话术，防止“Obsidian 里面关于…的所有资料”抢占主题词预算。
        let requestPhrases = [
            "你是否能够看到", "你是否能看到", "能不能看到", "是否能看到", "你能看到", "能够看到", "可以看到", "能看到",
            "是否可以", "能不能", "你是否", "你可以", "你能", "请帮我", "帮我", "请问", "麻烦", "告诉我",
            "回顾一下", "整理一下", "回忆一下", "总结一下", "分析一下", "查一下", "找一下",
            "历史资料", "历史笔记", "历史记录", "所有资料", "所有笔记", "全部资料", "全部笔记",
            "obsidian", "知识库", "关于", "有关", "里面", "里边", "当中", "中的", "相关",
            "有哪些", "是什么", "怎么样", "之前的", "过去的", "我之前", "我过去", "我的",
            "检索", "搜索", "查询", "查找", "资料", "笔记", "文档", "内容", "全部", "所有"
        ].sorted { $0.count > $1.count }
        var topicalQuery = query
        for phrase in requestPhrases {
            topicalQuery = topicalQuery.replacingOccurrences(of: phrase, with: " ")
        }
        let stopWords: Set<String> = [
            "一个", "一些", "问题", "这个", "那个", "以及", "如何", "是否", "能够", "看到",
            "什么", "怎么", "现在", "之前", "以前", "历史", "请你", "请问", "可以", "谢谢"
        ]
        var terms: [SearchTerm] = []
        var seen = Set<String>()
        let rawParts = topicalQuery.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var fallbackTerms: [String] = []
        for raw in rawParts {
            let part = normalized(raw).trimmingCharacters(in: CharacterSet(charactersIn: "的了呢吗吧啊请"))
            if part.count >= 2, !stopWords.contains(part), seen.insert(part).inserted {
                terms.append(SearchTerm(text: part, weight: 1))
            }
            let characters = Array(part)
            if characters.contains(where: { character in
                character.unicodeScalars.contains {
                    (0x4E00...0x9FFF).contains(Int($0.value))
                }
            }),
               characters.count > 2 {
                for index in 0..<(characters.count - 1) {
                    let pair = String(characters[index...index + 1])
                    if !stopWords.contains(pair) { fallbackTerms.append(pair) }
                }
            }
        }
        for term in fallbackTerms where seen.insert(term).inserted {
            terms.append(SearchTerm(text: term, weight: 0.35))
        }
        return Array(terms.prefix(32))
    }

    private static func score(entry: IndexEntry, query: String, terms: [SearchTerm]) -> Double {
        let title = normalized(entry.title)
        let path = normalized(entry.relativePath)
        let body = normalized(entry.searchableText)
        var score = 0.0
        if title.contains(query) { score += 60 }
        if path.contains(query) { score += 30 }
        if body.contains(query) { score += 24 }
        for term in terms {
            if title.contains(term.text) { score += 20 * term.weight }
            if path.contains(term.text) { score += 14 * term.weight }
            if body.contains(term.text) { score += 6 * term.weight }
        }
        // 目录偏好只能调整真实命中之间的排序，不能让无关笔记变成搜索结果。
        return score > 0 ? score + entry.folderPriority : 0
    }

    private static func folderPriority(_ relativePath: String) -> Double {
        if relativePath.hasPrefix("3_知识库/") { return 12 }
        if relativePath.hasPrefix("2_项目/") { return 6 }
        if relativePath.hasPrefix("00_inbox/") { return 3 }
        return 0
    }

    private static func excerpt(from text: String, terms: [SearchTerm]) -> String {
        let budget = 1_800
        let paragraphs = text.components(separatedBy: .newlines).compactMap { raw -> String? in
            let paragraph = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return paragraph.isEmpty ? nil : paragraph
        }.enumerated().map { (index: $0.offset, text: $0.element) }
        let ranked = paragraphs.compactMap { paragraph -> (index: Int, text: String, score: Double)? in
            let matched = terms.filter { paragraph.text.range(of: $0.text, options: .caseInsensitive) != nil }
            guard !matched.isEmpty else { return nil }
            let score = matched.reduce(0) { $0 + $1.weight }
                + (paragraph.text.hasPrefix("#") ? 0 : 0.25)
            return (paragraph.index, paragraph.text, score)
        }.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }
        guard !ranked.isEmpty else {
            // 按目录/标题命中的笔记仍提供正文，但明确截断，不能代表完整笔记。
            return String(text.prefix(budget - 1)) + (text.count >= budget ? "…" : "")
        }

        var selected: [(index: Int, text: String)] = []
        var included = Set<Int>()
        var remaining = budget
        for paragraph in ranked.prefix(4) {
            guard remaining > 40 else { break }
            guard !included.contains(paragraph.index) else { continue }
            // 标题/列表项的主题往往只写一次，保留相邻正文才能解释其含义。
            let lower = max(0, paragraph.index - 1)
            let upper = min(paragraphs.count - 1, paragraph.index + 2)
            let context = paragraphs[lower...upper].filter { !included.contains($0.index) }
            let passage = context.map(\.text).joined(separator: "\n")
            let window = excerptWindow(passage, terms: terms, limit: min(900, remaining - 3))
            selected.append((context.first?.index ?? paragraph.index, window))
            included.formUnion(context.map(\.index))
            remaining -= window.count + 3
        }
        // 摘录按原文顺序排列；省略号标识被跳过的内容。
        return selected.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n…\n")
    }

    private static func excerptWindow(_ text: String, terms: [SearchTerm], limit: Int) -> String {
        guard text.count > limit else { return text }
        let match = terms.compactMap { term -> (String.Index, Double)? in
            text.range(of: term.text, options: .caseInsensitive).map { ($0.lowerBound, term.weight) }
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.first?.0 ?? text.startIndex
        let offset = text.distance(from: text.startIndex, to: match)
        let startOffset = max(0, offset - 160)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(start, offsetBy: min(limit - 2, text.distance(from: start, to: text.endIndex)))
        return (startOffset > 0 ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }

    private struct SearchTerm {
        var text: String
        var weight: Double
    }

    private struct IndexEntry: Sendable {
        var fileURL: URL
        var relativePath: String
        var title: String
        var searchableText: String
        var modifiedAt: Date
        var fileSize: Int
        var folderPriority: Double
    }
}
