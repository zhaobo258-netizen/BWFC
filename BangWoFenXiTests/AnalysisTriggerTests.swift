import Foundation
import Testing
@testable import BangWoFenXi

/// 分析触发器（实施计划 10.4：≥3 新片段或 >45 秒、10 秒防抖、失败退避）
@Suite("分析触发器")
struct AnalysisTriggerTests {

    @Test("无内容不触发")
    func noContentNoFire() {
        let trigger = AnalysisTrigger()
        #expect(!trigger.readyToFire(atMs: 100_000))
        #expect(trigger.msUntilReady(atMs: 100_000) == nil)
    }

    @Test("不足 3 个新片段且未超 45 秒：不触发")
    func belowThresholdNoFire() {
        var trigger = AnalysisTrigger()
        trigger.noteNewSegment(atMs: 1_000)
        trigger.noteNewSegment(atMs: 2_000)
        #expect(!trigger.conditionMet(atMs: 20_000))
    }

    @Test("满 3 个新片段：条件满足但需过防抖")
    func threeSegmentsNeedDebounce() {
        var trigger = AnalysisTrigger()
        trigger.noteNewSegment(atMs: 100_000)
        trigger.noteNewSegment(atMs: 101_000)
        trigger.noteNewSegment(atMs: 102_000)
        #expect(trigger.conditionMet(atMs: 102_000))
        // 防抖 10 秒：111.9s 不可触发，112s（最后变化 +10s）起可触发
        #expect(!trigger.readyToFire(atMs: 111_999))
        #expect(trigger.readyToFire(atMs: 112_000))
    }

    @Test("不足 3 片段但距上次成功超 45 秒：触发")
    func idleTimeoutFires() {
        var trigger = AnalysisTrigger()
        trigger.noteNewSegment(atMs: 1_000)
        trigger.noteSuccess(atMs: 10_000)
        trigger.noteNewSegment(atMs: 20_000) // 1 个新片段
        // 50s：距成功 40s（未超 45s）→ 不满足
        #expect(!trigger.conditionMet(atMs: 50_000))
        // 55.1s：距成功 45.1s（超过 45s）且防抖（30s）已过 → 可触发
        #expect(trigger.readyToFire(atMs: 55_100))
    }

    @Test("从未成功过：45 秒闲置 + 有新内容也触发")
    func firstAnalysisAfter45s() {
        var trigger = AnalysisTrigger()
        trigger.noteNewSegment(atMs: 1_000)
        #expect(!trigger.conditionMet(atMs: 40_000))
        #expect(trigger.conditionMet(atMs: 47_000))
    }

    @Test("成功后重置计数")
    func successResetsCount() {
        var trigger = AnalysisTrigger()
        trigger.noteNewSegment(atMs: 1_000)
        trigger.noteNewSegment(atMs: 2_000)
        trigger.noteNewSegment(atMs: 3_000)
        trigger.noteSuccess(atMs: 20_000)
        #expect(!trigger.conditionMet(atMs: 30_000))
        #expect(trigger.newSegmentCount == 0)
    }

    @Test("成功只消费本次请求观测到的计数")
    func successConsumesObservedCountOnly() {
        var trigger = AnalysisTrigger()
        trigger.noteNewSegment(atMs: 1_000)
        trigger.noteNewSegment(atMs: 2_000)
        let observedCount = trigger.newSegmentCount
        trigger.noteNewSegment(atMs: 3_000)

        trigger.noteSuccess(atMs: 20_000, consumingNewSegmentCount: observedCount)

        #expect(trigger.newSegmentCount == 1, "请求在途到达的片段计数必须保留")
    }

    @Test("失败后退避 30 秒，期间不触发")
    func failureBackoff() {
        var trigger = AnalysisTrigger()
        trigger.noteNewSegment(atMs: 1_000)
        trigger.noteNewSegment(atMs: 2_000)
        trigger.noteNewSegment(atMs: 3_000)
        #expect(trigger.readyToFire(atMs: 13_001))
        trigger.noteFailure(atMs: 13_001)
        #expect(!trigger.readyToFire(atMs: 20_000), "失败退避期内不得重试（防热循环）")
        #expect(trigger.readyToFire(atMs: 43_002), "退避过后允许重试")
    }

    @Test("msUntilReady：防抖剩余时间")
    func untilReady() {
        var trigger = AnalysisTrigger()
        trigger.noteNewSegment(atMs: 10_000)
        trigger.noteNewSegment(atMs: 10_000)
        trigger.noteNewSegment(atMs: 10_000)
        #expect(trigger.msUntilReady(atMs: 12_000) == 8_000)
        #expect(trigger.msUntilReady(atMs: 25_000) == 0)
    }
}
