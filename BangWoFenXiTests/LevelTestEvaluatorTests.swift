import Foundation
import Testing
@testable import BangWoFenXi

/// 5 秒电平测试评估器（纯逻辑）
@Suite("电平测试评估")
struct LevelTestEvaluatorTests {

    @Test("空样本视为无声")
    func emptySamples() {
        let result = LevelTestEvaluator.evaluate([])
        #expect(result.peak == 0)
        #expect(result.average == 0)
        #expect(result.verdict == .silent)
    }

    @Test("全部趋近零 → 未检测到声音")
    func silentSamples() {
        let result = LevelTestEvaluator.evaluate([0.0, 0.0005, 0.0002, 0.0])
        #expect(result.verdict == .silent)
    }

    @Test("有微弱信号但峰值不足 → 音量偏小")
    func tooQuietSamples() {
        let result = LevelTestEvaluator.evaluate([0.002, 0.01, 0.005, 0.003])
        #expect(result.verdict == .tooQuiet)
    }

    @Test("峰值达标 → 音量正常")
    func goodSamples() {
        let result = LevelTestEvaluator.evaluate([0.01, 0.2, 0.05, 0.03])
        #expect(result.verdict == .good)
        #expect(result.peak == 0.2)
        #expect(abs(result.average - (0.29 / 4)) < 0.0001)
    }

    @Test("阈值边界：恰好低于正常阈值为偏小，恰好达到为正常")
    func thresholdBoundaries() {
        let justBelow = LevelTestEvaluator.evaluate([LevelTestEvaluator.goodPeakThreshold - 0.001])
        #expect(justBelow.verdict == .tooQuiet)
        let exactly = LevelTestEvaluator.evaluate([LevelTestEvaluator.goodPeakThreshold])
        #expect(exactly.verdict == .good)
        let silentBelow = LevelTestEvaluator.evaluate([LevelTestEvaluator.silentPeakThreshold - 0.0001])
        #expect(silentBelow.verdict == .silent)
    }
}
