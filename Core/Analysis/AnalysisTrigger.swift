import Foundation

/// 分析触发器（纯逻辑，实施计划 10.4）：
/// - 至少积累 3 个新最终片段，或距上次成功分析超过 45 秒，才允许触发；
/// - 新内容到达后防抖约 10 秒；
/// - 失败后保留上一版，并按失败退避间隔重试（避免热循环）。
struct AnalysisTrigger: Equatable, Sendable {
    /// 触发所需的最少新最终片段数
    var minNewSegments: Int = 3
    /// 距上次成功分析的最大闲置毫秒
    var maxIdleMs: Int64 = 45_000
    /// 防抖毫秒（新内容到达后需安静这么久）
    var debounceMs: Int64 = 10_000
    /// 失败后的最小重试间隔毫秒
    var failureRetryMs: Int64 = 30_000

    /// 自上次成功（或会话开始）积累的新最终片段数
    private(set) var newSegmentCount = 0
    /// 上次成功分析时间（毫秒时间戳）
    private(set) var lastSuccessAtMs: Int64?
    /// 最近一次内容变化时间
    private(set) var lastChangeAtMs: Int64?
    /// 最近一次失败时间
    private(set) var lastFailureAtMs: Int64?

    init() {}

    /// 新最终片段到达
    mutating func noteNewSegment(atMs now: Int64) {
        newSegmentCount += 1
        lastChangeAtMs = now
    }

    /// 分析成功：重置计数与游标
    mutating func noteSuccess(atMs now: Int64) {
        newSegmentCount = 0
        lastSuccessAtMs = now
        lastFailureAtMs = nil
    }

    /// 分析失败：保留上一版，记录失败时间用于退避
    mutating func noteFailure(atMs now: Int64) {
        lastFailureAtMs = now
    }

    /// 触发条件是否满足（片段数 ≥ 3 或闲置 > 45 秒；无任何内容时不触发）
    func conditionMet(atMs now: Int64) -> Bool {
        guard newSegmentCount > 0 || lastChangeAtMs != nil else { return false }
        if newSegmentCount >= minNewSegments { return true }
        if let lastSuccessAtMs, now - lastSuccessAtMs > maxIdleMs, newSegmentCount > 0 {
            return true
        }
        // 会话开始以来尚未成功过：超过 45 秒且有新内容也允许触发
        if lastSuccessAtMs == nil, let lastChangeAtMs, now - lastChangeAtMs > maxIdleMs, newSegmentCount > 0 {
            return true
        }
        return false
    }

    /// 防抖是否已过（距最近一次内容变化 ≥ 10 秒）
    func debounceSatisfied(atMs now: Int64) -> Bool {
        guard let lastChangeAtMs else { return true }
        return now - lastChangeAtMs >= debounceMs
    }

    /// 失败退避是否已过
    func failureBackoffSatisfied(atMs now: Int64) -> Bool {
        guard let lastFailureAtMs else { return true }
        return now - lastFailureAtMs >= failureRetryMs
    }

    /// 是否可以立即发起分析
    func readyToFire(atMs now: Int64) -> Bool {
        conditionMet(atMs: now)
            && debounceSatisfied(atMs: now)
            && failureBackoffSatisfied(atMs: now)
    }

    /// 距可触发还差多少毫秒（用于定时唤醒；已可触发返回 0；条件未满足返回 nil）
    func msUntilReady(atMs now: Int64) -> Int64? {
        guard conditionMet(atMs: now) else { return nil }
        guard failureBackoffSatisfied(atMs: now) else {
            guard let lastFailureAtMs else { return nil }
            return max(0, failureRetryMs - (now - lastFailureAtMs))
        }
        guard let lastChangeAtMs else { return 0 }
        return max(0, debounceMs - (now - lastChangeAtMs))
    }
}
