import Foundation
import Testing
@testable import BangWoFenXi

/// 转写文本规范化与相似度（去重规则的文本部分）
@Suite("转写文本工具")
struct TranscriptTextTests {

    @Test("规范化：忽略空白、标点与大小写")
    func normalization() {
        #expect(TranscriptText.normalized("我们可以再讨论两个点。")
            == TranscriptText.normalized("我们可以再讨论两个点"))
        #expect(TranscriptText.normalized("Hello, World!")
            == TranscriptText.normalized("hello world"))
        #expect(TranscriptText.normalized("返点、账期；SKU")
            == TranscriptText.normalized("返点账期SKU"))
    }

    @Test("相似度：完全相同为 1，明显不同趋近 0")
    func similarityExtremes() {
        #expect(TranscriptText.similarity("年度量能与返点", "年度量能与返点") == 1)
        #expect(TranscriptText.similarity("年度量能与返点", "完全无关的另一句话") < 0.3)
        #expect(TranscriptText.similarity("如果量能保证我们可以再讨论两个点", "如果量能保证，我们可以再讨论两个点") == 1)
    }

    @Test("相似度：高度相似（少量差异）不低于 0.8")
    func similarityHighForMinorDifferences() {
        let a = "如果年度量能能保证我们可以再讨论两个点"
        let b = "如果年度量能能保证我们可以再讨论三个点"
        #expect(TranscriptText.similarity(a, b) >= 0.8)
    }

    @Test("极短文本：互相包含视为相似")
    func shortTextContainment() {
        #expect(TranscriptText.similarity("好的", "好") == 1)
        #expect(TranscriptText.similarity("好的", "不行") == 0)
    }
}

/// 本地转写合并器：临时/最终替换与去重（实施计划 7.4 本地阶段；
/// 「20 分钟评测录音无重复片段」由本套规则保证）
@Suite("转写合并器")
struct TranscriptReconcilerTests {

    // MARK: - 临时片段

    @Test("临时片段：同一 ID 就地更新文字，不新增")
    func provisionalUpsertInPlace() {
        var reconciler = TranscriptReconciler()
        let first = reconciler.upsertProvisional(startMs: 1000, endMs: 2000, text: "如果年度")
        let second = reconciler.upsertProvisional(startMs: 1000, endMs: 2500, text: "如果年度量能")

        #expect(first?.id == second?.id, "临时片段必须复用同一 ID（就地更新不跳动）")
        #expect(reconciler.allSegments.count == 1)
        #expect(reconciler.allSegments.first?.text == "如果年度量能")
        #expect(reconciler.allSegments.first?.state == .provisional)
        #expect(reconciler.allSegments.first?.endMs == 2500)
    }

    @Test("空白临时文字不产生片段")
    func blankProvisionalIgnored() {
        var reconciler = TranscriptReconciler()
        #expect(reconciler.upsertProvisional(startMs: 0, endMs: 1000, text: "   ") == nil)
        #expect(reconciler.allSegments.isEmpty)
    }

    // MARK: - 临时 → 最终替换

    @Test("最终结果取代临时片段：无重复句")
    func finalReplacesProvisional() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.upsertProvisional(startMs: 1000, endMs: 3000, text: "如果年度量能能保证我们可以再讨论")
        let outcome = reconciler.applyFinal(startMs: 1000, endMs: 3000,
                                            text: "如果年度量能能保证，我们可以再讨论两个点。")
        guard case .inserted(let final) = outcome else {
            Issue.record("应插入最终片段")
            return
        }
        #expect(reconciler.allSegments.count == 1, "临时被最终替换后不得残留两条")
        #expect(reconciler.allSegments.first?.id == final.id)
        #expect(reconciler.allSegments.first?.state == .final)
        #expect(reconciler.provisional == nil)
    }

    @Test("新的临时片段在最终确认后继续出现")
    func provisionalAfterFinal() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.upsertProvisional(startMs: 0, endMs: 2000, text: "第一句临时")
        _ = reconciler.applyFinal(startMs: 0, endMs: 2000, text: "第一句最终。")
        _ = reconciler.upsertProvisional(startMs: 2000, endMs: 4000, text: "第二句临时")
        #expect(reconciler.allSegments.count == 2)
        #expect(reconciler.allSegments.last?.state == .provisional)
    }

    // MARK: - 最终片段去重

    @Test("同文本同时间 → 判重")
    func duplicateSameTextSameTime() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyFinal(startMs: 1000, endMs: 3000, text: "如果年度量能能保证。")
        let outcome = reconciler.applyFinal(startMs: 1000, endMs: 3000, text: "如果年度量能能保证。")
        guard case .duplicate = outcome else {
            Issue.record("同文本同时间必须判重")
            return
        }
        #expect(reconciler.finalized.count == 1)
    }

    @Test("同文本 ±2 秒抖动窗口内 → 判重")
    func duplicateSameTextWithinJitter() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyFinal(startMs: 1000, endMs: 3000, text: "我们可以再讨论两个点。")
        // 起点差 1.5 秒，且无时间重叠
        let outcome = reconciler.applyFinal(startMs: 2500, endMs: 4500, text: "我们可以再讨论两个点")
        guard case .duplicate = outcome else {
            Issue.record("抖动窗口内的同文本必须判重")
            return
        }
        #expect(reconciler.finalized.count == 1)
    }

    @Test("同文本但相距远超抖动窗口 → 保留（不同的发言）")
    func sameTextFarApartKept() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyFinal(startMs: 1_000, endMs: 3_000, text: "我们再确认一下。")
        let outcome = reconciler.applyFinal(startMs: 600_000, endMs: 602_000, text: "我们再确认一下。")
        guard case .inserted = outcome else {
            Issue.record("相距 10 分钟的同文本是不同发言，必须保留")
            return
        }
        #expect(reconciler.finalized.count == 2)
    }

    @Test("高度重叠 + 高相似度 → 判重")
    func duplicateOverlapWithSimilarText() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyFinal(startMs: 1000, endMs: 5000,
                                  text: "如果年度量能能保证我们可以再讨论两个点")
        // 重叠 75%（3 秒 / 4 秒），文本仅末尾一词不同
        let outcome = reconciler.applyFinal(startMs: 2000, endMs: 6000,
                                            text: "如果年度量能能保证我们可以再讨论两个点。")
        guard case .duplicate = outcome else {
            Issue.record("高重叠 + 高相似必须判重")
            return
        }
        #expect(reconciler.finalized.count == 1)
    }

    @Test("高度重叠但文本明显不同 → 保留（不丢内容）")
    func overlapWithDifferentTextKept() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyFinal(startMs: 1000, endMs: 5000,
                                  text: "如果年度量能能保证我们可以再讨论两个点")
        let outcome = reconciler.applyFinal(startMs: 2000, endMs: 6000,
                                            text: "返点需要和回款周期放在一起确认")
        guard case .inserted = outcome else {
            Issue.record("文本明显不同的内容必须保留")
            return
        }
        #expect(reconciler.finalized.count == 2)
    }

    @Test("低重叠 + 高相似但超出抖动窗口 → 保留")
    func lowOverlapKept() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyFinal(startMs: 0, endMs: 10_000,
                                  text: "如果年度量能能保证我们可以再讨论两个点")
        // 仅重叠 2 秒（20% < 50%），起点差 8 秒超出抖动窗口
        let outcome = reconciler.applyFinal(startMs: 8_000, endMs: 18_000,
                                            text: "如果年度量能能保证我们可以再讨论两个点")
        guard case .inserted = outcome else {
            Issue.record("低重叠不应判重")
            return
        }
        #expect(reconciler.finalized.count == 2)
    }

    @Test("空白最终文字被丢弃")
    func blankFinalDiscarded() {
        var reconciler = TranscriptReconciler()
        #expect(reconciler.applyFinal(startMs: 0, endMs: 1000, text: "  ") == .discardedEmpty)
        #expect(reconciler.finalized.isEmpty)
    }

    @Test("乱序到达：按开始时间排序插入")
    func outOfOrderInsertedSorted() {
        var reconciler = TranscriptReconciler()
        _ = reconciler.applyFinal(startMs: 5000, endMs: 6000, text: "第三句")
        _ = reconciler.applyFinal(startMs: 1000, endMs: 2000, text: "第一句")
        _ = reconciler.applyFinal(startMs: 3000, endMs: 4000, text: "第二句")
        #expect(reconciler.finalized.map(\.startMs) == [1000, 3000, 5000])
        #expect(reconciler.allSegments.map(\.text) == ["第一句", "第二句", "第三句"])
    }

    // MARK: - 20 分钟无重复模拟（实施计划 3.2 目标的本地部分）

    @Test("20 分钟模拟：含引擎重发与边界重叠，最终无重复片段")
    func twentyMinuteSimulationNoDuplicates() {
        var reconciler = TranscriptReconciler()
        // 20 分钟 = 1,200,000ms；每 5 秒一句，共 240 句独特内容
        let segmentDuration: Int64 = 5_000
        let uniqueCount = 240

        for index in 0..<uniqueCount {
            let start = Int64(index) * segmentDuration
            let text = "第\(index)句：关于第\(index)项条款的讨论内容。"
            // 每句先出 2 次临时（模拟渐进式识别）
            _ = reconciler.upsertProvisional(startMs: start, endMs: start + segmentDuration,
                                             text: String(text.prefix(6)))
            _ = reconciler.upsertProvisional(startMs: start, endMs: start + segmentDuration,
                                             text: text)
            // 再出最终
            _ = reconciler.applyFinal(startMs: start, endMs: start + segmentDuration, text: text)

            // 模拟 10% 的引擎重发（±1 秒抖动）
            if index % 10 == 0 {
                _ = reconciler.applyFinal(startMs: start + 1_000, endMs: start + segmentDuration + 1_000,
                                          text: text)
            }
            // 模拟 10% 的边界重叠重发（重叠 60%）
            if index % 10 == 5 {
                _ = reconciler.applyFinal(startMs: start + 2_000, endMs: start + segmentDuration + 2_000,
                                          text: text)
            }
        }

        #expect(reconciler.finalized.count == uniqueCount,
                "240 句独特内容经重发与重叠后必须恰好 240 条，实际 \(reconciler.finalized.count)")
        // 文本两两不同（无重复句）
        let texts = reconciler.finalized.map { TranscriptText.normalized($0.text) }
        #expect(Set(texts).count == uniqueCount)
        // 顺序正确
        let starts = reconciler.finalized.map(\.startMs)
        #expect(starts == starts.sorted())
    }
}
