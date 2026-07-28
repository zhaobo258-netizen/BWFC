import Foundation

actor ObsidianKnowledgeProvider: KnowledgeProvider {
    let kind: KnowledgeProviderKind = .obsidian
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
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else { return [] }
        try rebuildIndexIfNeeded()
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

        return scored.prefix(max(1, limit)).map { entry, score in
            KnowledgeConnection(
                provider: .obsidian,
                sourceId: entry.relativePath,
                title: entry.title,
                excerpt: Self.excerpt(from: entry.searchableText, terms: terms),
                sourceLocation: entry.fileURL.path,
                relevance: min(score / 100, 1),
                retrievedAt: Date()
            )
        }
    }

    /// 全库正文索引的总字符预算：防止 5000 篇 × 80K 字符的极端 Vault
    /// 把索引撑到数百 MB。超出预算后仅索引标题（仍可按标题命中）。
    private static let totalSearchableCharacterBudget = 12_000_000

    private func rebuildIndexIfNeeded(now: Date = Date()) throws {
        if let indexedAt, now.timeIntervalSince(indexedAt) < 300 {
            return
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw KnowledgeProviderError.permissionDenied
        }

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
                  let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let searchableText = String(text.prefix(min(80_000, max(0, remainingTextBudget))))
            remainingTextBudget -= searchableText.count
            rebuilt.append(IndexEntry(
                fileURL: fileURL,
                relativePath: relativePath,
                title: Self.title(from: text, fallback: fileURL.deletingPathExtension().lastPathComponent),
                searchableText: searchableText,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                folderPriority: Self.folderPriority(relativePath)
            ))
        }
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

    private static func searchTerms(from query: String) -> [String] {
        let stopWords: Set<String> = ["一个", "一些", "相关", "内容", "问题", "这个", "那个", "以及", "如何"]
        var terms: [String] = []
        var seen = Set<String>()
        let rawParts = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for raw in rawParts {
            let part = normalized(raw)
            if part.count >= 2, !stopWords.contains(part), seen.insert(part).inserted {
                terms.append(part)
            }
            let characters = Array(part)
            if characters.contains(where: { character in
                character.unicodeScalars.contains {
                    (0x4E00...0x9FFF).contains(Int($0.value))
                }
            }),
               characters.count > 4 {
                for index in 0..<(characters.count - 1) {
                    let pair = String(characters[index...index + 1])
                    if !stopWords.contains(pair), seen.insert(pair).inserted {
                        terms.append(pair)
                    }
                }
            }
        }
        return Array(terms.prefix(20))
    }

    private static func score(entry: IndexEntry, query: String, terms: [String]) -> Double {
        let title = normalized(entry.title)
        let body = normalized(entry.searchableText)
        var score = entry.folderPriority
        if title.contains(query) { score += 60 }
        if body.contains(query) { score += 24 }
        for term in terms {
            if title.contains(term) { score += 12 }
            if body.contains(term) { score += 3 }
        }
        return score
    }

    private static func folderPriority(_ relativePath: String) -> Double {
        if relativePath.hasPrefix("3_知识库/") { return 12 }
        if relativePath.hasPrefix("2_项目/") { return 6 }
        if relativePath.hasPrefix("00_inbox/") { return 3 }
        return 0
    }

    private static func excerpt(from text: String, terms: [String]) -> String {
        let flattened = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let lowered = flattened.lowercased()
        let match = terms.compactMap { lowered.range(of: $0)?.lowerBound }.min()
        guard let match else {
            return String(flattened.prefix(260))
        }
        let offset = lowered.distance(from: lowered.startIndex, to: match)
        let startOffset = max(0, offset - 70)
        let start = flattened.index(flattened.startIndex, offsetBy: startOffset)
        let end = flattened.index(start, offsetBy: min(300, flattened.distance(from: start, to: flattened.endIndex)))
        let prefix = startOffset > 0 ? "…" : ""
        let suffix = end < flattened.endIndex ? "…" : ""
        return prefix + flattened[start..<end] + suffix
    }

    private struct IndexEntry: Sendable {
        var fileURL: URL
        var relativePath: String
        var title: String
        var searchableText: String
        var modifiedAt: Date
        var folderPriority: Double
    }
}
