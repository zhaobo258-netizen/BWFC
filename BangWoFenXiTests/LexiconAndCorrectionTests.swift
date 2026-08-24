import Foundation
import Testing
@testable import BangWoFenXi

/// 全局专业词库（解析/合并/持久化）
@Suite("专业词库")
struct LexiconStoreTests {

    @Test("解析：按行与中文分隔符拆分，去空白、注释与超长词，去重保序")
    func parse() {
        let text = """
        # 注释行
        经销商
        快消、动销
        经销商
        SKU，B2B

          压货  
        """
        let terms = LexiconStore.parse(text)
        #expect(terms == ["经销商", "快消", "动销", "SKU", "B2B", "压货"])
    }

    @Test("合并：既有在前新增在后，不重复")
    func merge() {
        let merged = LexiconStore.merge(["甲", "乙"], adding: ["乙", "丙"])
        #expect(merged == ["甲", "乙", "丙"])
    }

    @Test("持久化回环 + 缺失文件返回空")
    func roundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "lexicon-test-\(UUID().uuidString)")
        let store = LexiconStore(baseDirectory: dir)
        #expect(store.load().terms.isEmpty)
        try store.save(terms: ["经销商", "快消"],
                       corrections: [CorrectionRule(wrong: "经消商", right: "经销商")])
        let loaded = store.load()
        #expect(loaded.terms == ["经销商", "快消"])
        #expect(loaded.corrections == [CorrectionRule(wrong: "经消商", right: "经销商")])
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("旧格式（无 corrections 字段）容错")
    func legacyPayloadTolerance() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "lexicon-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"terms":["甲"],"updatedAt":1000}"#
        try Data(json.utf8).write(to: dir.appending(path: LexiconStore.fileName))
        let store = LexiconStore(baseDirectory: dir)
        let loaded = store.load()
        #expect(loaded.terms == ["甲"])
        #expect(loaded.corrections.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("设置中心支持词条与纠错规则完整增删改")
    @MainActor
    func environmentCRUD() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lexicon-environment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "bwfx-lexicon-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: directory),
            keychainServiceName: "com.zhaobo.BangWoFenXi.tests.lexicon.\(UUID().uuidString)",
            aiProviderConfigurationStore: AIProviderConfigurationStore(
                defaults: defaults
            ),
            externalMCPConfigurationStore: ExternalMCPConfigurationStore(
                defaults: defaults
            )
        )

        try environment.addLexiconTerm("经销商")
        try environment.addLexiconTerm("动销")
        try environment.updateLexiconTerm("动销", to: "终端动销")
        #expect(environment.lexiconTerms == ["经销商", "终端动销"])
        try environment.removeLexiconTerm("经销商")
        #expect(environment.lexiconTerms == ["终端动销"])

        try environment.addCorrectionRule(wrong: "经消商", right: "经销商")
        let rule = try #require(environment.correctionRules.first)
        try environment.updateCorrectionRule(
            rule,
            wrong: "经消商",
            right: "渠道经销商"
        )
        #expect(environment.correctionRules.first?.right == "渠道经销商")
        let updatedRule = try #require(environment.correctionRules.first)
        try environment.removeCorrectionRule(updatedRule)
        #expect(environment.correctionRules.isEmpty)
        try environment.clearLexicon()
        #expect(environment.lexiconTerms.isEmpty)
        #expect(environment.lexiconRevision >= 7)
    }

    @Test("改词撞已有词：抛错、原词条与总数都不丢")
    @MainActor
    func updateTermCollisionKeepsBothTerms() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lexicon-collision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "bwfx-lexicon-collision-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: directory),
            keychainServiceName: "com.zhaobo.BangWoFenXi.tests.lexicon.\(UUID().uuidString)",
            aiProviderConfigurationStore: AIProviderConfigurationStore(defaults: defaults),
            externalMCPConfigurationStore: ExternalMCPConfigurationStore(defaults: defaults)
        )

        try environment.addLexiconTerm("经销商")
        try environment.addLexiconTerm("动销")

        #expect(throws: LexiconEditError.duplicateTerm("经销商")) {
            try environment.updateLexiconTerm("动销", to: "经销商")
        }
        #expect(environment.lexiconTerms == ["经销商", "动销"])

        #expect(throws: LexiconEditError.emptyTerm) {
            try environment.updateLexiconTerm("动销", to: "   ")
        }
        #expect(throws: LexiconEditError.termNotFound("不存在的词")) {
            try environment.updateLexiconTerm("不存在的词", to: "新词")
        }
        #expect(environment.lexiconTerms == ["经销商", "动销"])

        // 改成自己：静默成功，不重复写盘
        let revisionBefore = environment.lexiconRevision
        try environment.updateLexiconTerm("动销", to: "动销")
        #expect(environment.lexiconTerms == ["经销商", "动销"])
        #expect(environment.lexiconRevision == revisionBefore)

        // 正常改词仍生效，且保持原有位置
        try environment.updateLexiconTerm("动销", to: "终端动销")
        #expect(environment.lexiconTerms == ["经销商", "终端动销"])
    }
}

/// 转写纠错引擎（全局替换 + 自动套用）
@Suite("转写纠错")
struct TranscriptCorrectorTests {

    private func segment(_ text: String, state: SegmentState = .final) -> TranscriptSegment {
        TranscriptSegment(startMs: 0, endMs: 1000, text: text, source: .local, state: state)
    }

    @Test("全局替换：命中片段改字并标人工已修订，未命中不动")
    func applyGlobal() {
        let hit = segment("这家经消商的动销不错")
        let miss = segment("今天天气不错")
        let count = TranscriptCorrector.applyGlobal(
            wrong: "经消商", right: "经销商", segments: [hit, miss])
        #expect(count == 1)
        #expect(hit.text == "这家经销商的动销不错")
        #expect(hit.state == .edited)
        #expect(hit.source == .manual)
        #expect(hit.textWasUserEdited == true)
        #expect(miss.text == "今天天气不错")
        #expect(miss.state == .final)
    }

    @Test("临时片段跳过（马上会被最终结果替换）")
    func provisionalSkipped() {
        let prov = segment("经消商", state: .provisional)
        let count = TranscriptCorrector.applyGlobal(
            wrong: "经消商", right: "经销商", segments: [prov])
        #expect(count == 0)
        #expect(prov.text == "经消商")
    }

    @Test("一个片段多处命中：全部替换，计数按片段")
    func multipleOccurrences() {
        let s = segment("经消商找经消商")
        let count = TranscriptCorrector.applyGlobal(
            wrong: "经消商", right: "经销商", segments: [s])
        #expect(count == 1)
        #expect(s.text == "经销商找经销商")
    }

    @Test("AI 纠错必须引用当前逐字稿中真实命中的片段")
    func verifiedMatch() {
        let hit = segment("我选幻影身机")
        let unrelated = segment("另一段话")
        let provisional = segment("幻影身机", state: .provisional)

        #expect(TranscriptCorrector.hasVerifiedMatch(
            wrong: "幻影身机",
            right: "旷野之息",
            evidenceSegmentIDs: [hit.id],
            segments: [hit, unrelated, provisional]
        ))
        #expect(!TranscriptCorrector.hasVerifiedMatch(
            wrong: "幻影身机",
            right: "旷野之息",
            evidenceSegmentIDs: [unrelated.id],
            segments: [hit, unrelated, provisional]
        ))
        #expect(!TranscriptCorrector.hasVerifiedMatch(
            wrong: "幻影身机",
            right: "旷野之息",
            evidenceSegmentIDs: [provisional.id],
            segments: [hit, unrelated, provisional]
        ))
    }

    @Test("自动纠错：按规则集顺序替换")
    func autoCorrect() {
        let rules = [
            CorrectionRule(wrong: "经消商", right: "经销商"),
            CorrectionRule(wrong: "快销", right: "快消")
        ]
        #expect(TranscriptCorrector.autoCorrect("经消商做快销", rules: rules) == "经销商做快消")
        #expect(TranscriptCorrector.autoCorrect("无关文字", rules: rules) == "无关文字")
        #expect(TranscriptCorrector.autoCorrect("文字", rules: []) == "文字")
    }

    @Test("规则合法性：空/相同/正词含错词均拒绝")
    func ruleValidity() {
        #expect(TranscriptCorrector.isValidRule(wrong: "经消商", right: "经销商"))
        #expect(!TranscriptCorrector.isValidRule(wrong: "", right: "对"))
        #expect(!TranscriptCorrector.isValidRule(wrong: "同", right: "同"))
        #expect(!TranscriptCorrector.isValidRule(wrong: "销", right: "经销商"),
                "正词包含错词会导致反复套用时无限膨胀")
    }

    @Test("规则合并：同错词后写覆盖")
    func mergeRule() {
        let rules = [CorrectionRule(wrong: "甲", right: "乙")]
        let merged = TranscriptCorrector.mergeRule(
            CorrectionRule(wrong: "甲", right: "丙"), into: rules)
        #expect(merged == [CorrectionRule(wrong: "甲", right: "丙")])
    }

    @Test("命中计数：排除临时片段")
    func matchCount() {
        let segments = [
            segment("经消商 A"), segment("经消商 B"),
            segment("经消商临时", state: .provisional), segment("无关")
        ]
        #expect(TranscriptCorrector.matchCount(of: "经消商", in: segments) == 2)
        #expect(TranscriptCorrector.matchCount(of: "", in: segments) == 0)
    }
}

/// 词库进入分析系统指令（已知名词表）
@Suite("分析已知名词表")
struct KnownTermsPromptTests {

    @Test("空词库不追加任何内容")
    func emptyTermsNoSection() {
        #expect(ConversationAnalysisPrompt.knownTermsSection([]).isEmpty)
        #expect(ConversationAnalysisPrompt.text(scenario: nil, knownTerms: [])
                == ConversationAnalysisPrompt.text(scenario: nil))
    }

    @Test("词条出现在指令中且红线原文不变")
    func termsAppended() {
        let text = ConversationAnalysisPrompt.text(scenario: nil, knownTerms: ["经销商", "动销"])
        #expect(text.contains("经销商、动销"))
        #expect(text.contains(ConversationAnalysisPrompt.rules), "红线 rules 必须原文保留")
    }

    @Test("超过 200 词截断")
    func capAt200() {
        let terms = (1...300).map { "词\($0)" }
        let section = ConversationAnalysisPrompt.knownTermsSection(terms)
        #expect(section.contains("词200"))
        #expect(!section.contains("词201"))
    }
}
