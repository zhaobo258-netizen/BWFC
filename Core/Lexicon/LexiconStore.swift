import Foundation

/// 纠错规则（老板 2026-07-27 需求 2）：错词 → 正词，全局替换并对后续转写自动套用。
struct CorrectionRule: Codable, Equatable, Sendable, Identifiable {
    var wrong: String
    var right: String
    var id: String { wrong + "→" + right }
}

/// 全局专业词库（老板 2026-07-27 需求 1）：提前导入专有名词，
/// 本地转写作为上下文词汇（contextualStrings，改善识别不改写原意），
/// 云端分析作为「已知名词表」（还原同音误写）；纠错规则一并存放。
/// 存储：<base>/lexicon.json（App 级，与项目无关；原子写）。
struct LexiconStore: Sendable {
    static let fileName = "lexicon.json"
    let fileURL: URL

    init(baseDirectory: URL) {
        fileURL = baseDirectory.appending(path: Self.fileName)
    }

    struct Payload: Codable {
        var terms: [String]
        var corrections: [CorrectionRule]?
        var updatedAt: Date
    }

    /// 读取（文件缺失/损坏返回空，不阻塞任何流程）
    func load() -> (terms: [String], corrections: [CorrectionRule]) {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return ([], [])
        }
        return (payload.terms, payload.corrections ?? [])
    }

    func save(terms: [String], corrections: [CorrectionRule]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(
            Payload(terms: terms, corrections: corrections, updatedAt: Date()))
        try data.write(to: fileURL, options: .atomic)
    }

    /// 解析导入文本：按行拆分（兼容顿号/逗号分隔），去空白、去注释行（#）、去重保序
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let separators = CharacterSet(charactersIn: "\n\r、，,")
        for piece in text.components(separatedBy: separators) {
            let term = piece.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, !term.hasPrefix("#"), term.count <= 40 else { continue }
            if seen.insert(term).inserted { result.append(term) }
        }
        return result
    }

    /// 合并新词条（去重保序：既有在前，新增在后）
    static func merge(_ existing: [String], adding: [String]) -> [String] {
        var seen = Set(existing)
        var result = existing
        for term in adding where seen.insert(term).inserted {
            result.append(term)
        }
        return result
    }
}

/// 转写纠错引擎（纯函数，可单测）。
enum TranscriptCorrector {
    /// 全局纠错：把所有片段文字中的 wrong 替换为 right。
    /// 被修改的片段标记为人工已修订（source=.manual/state=.edited），
    /// 享受既有的「不被云端结果覆盖」保护。临时片段跳过（马上会被最终结果替换）。
    /// 返回修改的片段数。
    @discardableResult
    static func applyGlobal(wrong: String, right: String,
                            segments: [TranscriptSegment], at now: Date = Date()) -> Int {
        guard isValidRule(wrong: wrong, right: right) else { return 0 }
        var changed = 0
        for segment in segments where segment.state != .provisional {
            guard segment.text.contains(wrong) else { continue }
            segment.text = segment.text.replacingOccurrences(of: wrong, with: right)
            segment.source = .manual
            segment.state = .edited
            segment.updatedAt = now
            changed += 1
        }
        return changed
    }

    static func hasVerifiedMatch(
        wrong: String,
        right: String,
        evidenceSegmentIDs: [UUID],
        segments: [TranscriptSegment]
    ) -> Bool {
        guard isValidRule(wrong: wrong, right: right),
              !evidenceSegmentIDs.isEmpty else {
            return false
        }
        let evidence = Set(evidenceSegmentIDs)
        return segments.contains {
            evidence.contains($0.id)
                && $0.state != .provisional
                && $0.text.contains(wrong)
        }
    }

    /// 对一段文字套用规则集（转写合并点自动纠错；本地与云端两条路径都过这里，
    /// 保证同一段文字两侧结果一致，不影响去重判定）。
    static func autoCorrect(_ text: String, rules: [CorrectionRule]) -> String {
        guard !rules.isEmpty else { return text }
        var result = text
        for rule in rules where isValidRule(wrong: rule.wrong, right: rule.right) {
            result = result.replacingOccurrences(of: rule.wrong, with: rule.right)
        }
        return result
    }

    /// 命中片段数（纠错弹层预览）
    static func matchCount(of wrong: String, in segments: [TranscriptSegment]) -> Int {
        guard !wrong.isEmpty else { return 0 }
        return segments.filter { $0.state != .provisional && $0.text.contains(wrong) }.count
    }

    /// 规则合法性：两边非空、不相同、错词不包含正词也不被正词包含（防替换循环与自吞）
    static func isValidRule(wrong: String, right: String) -> Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty, w != r else { return false }
        guard !r.contains(w) else { return false } // 正词含错词：替换后再套用会无限膨胀
        return true
    }

    /// 规则合并：同错词后写覆盖，保序
    static func mergeRule(_ rule: CorrectionRule, into rules: [CorrectionRule]) -> [CorrectionRule] {
        var result = rules.filter { $0.wrong != rule.wrong }
        result.append(rule)
        return result
    }
}
