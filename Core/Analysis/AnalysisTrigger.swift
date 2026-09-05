import Foundation

/// 分析触发器（纯逻辑，实施计划 10.4）：
/// - 至少积累 3 个新最终片段，或距上次成功分析超过 45 秒，才允许触发；
/// - 新内容到达后防抖约 10 秒，最早待分析片段达到最大等待后不再延后；
/// - 失败后保留上一版，并按失败退避间隔重试（避免热循环）。
struct AnalysisTrigger: Equatable, Sendable {
    /// 触发所需的最少新最终片段数
    var minNewSegments: Int = 3
    /// 距上次成功分析的闲置阈值，也是待分析片段的最大等待毫秒
    var maxIdleMs: Int64 = 45_000
    /// 防抖毫秒（新内容到达后需安静这么久）
    var debounceMs: Int64 = 10_000
    /// 失败后的最小重试间隔毫秒
    var failureRetryMs: Int64 = 30_000

    /// 自上次成功（或会话开始）积累的新最终片段数
    var newSegmentCount: Int { pendingSegmentTimes.count }
    private var pendingSegmentTimes: [Int64] = []
    /// 上次成功分析时间（毫秒时间戳）
    private(set) var lastSuccessAtMs: Int64?
    /// 最近一次内容变化时间
    private(set) var lastChangeAtMs: Int64?
    /// 最近一次失败时间
    private(set) var lastFailureAtMs: Int64?

    init() {}

    /// 实时录音预设（老板 2026-07-26 优化指示）：现场对话更看重跟手感——
    /// 2 个新片段即可触发、防抖 5 秒、闲置上限 30 秒；失败退避保持 30 秒防热循环。
    /// 导入流水线与默认值不变（批处理不需要抢节奏）。
    static var liveRecording: AnalysisTrigger {
        var trigger = AnalysisTrigger()
        trigger.minNewSegments = 2
        trigger.maxIdleMs = 30_000
        trigger.debounceMs = 5_000
        return trigger
    }

    /// 新最终片段到达
    mutating func noteNewSegment(atMs now: Int64) {
        pendingSegmentTimes.append(now)
        lastChangeAtMs = now
    }

    /// 分析成功：只消费本次请求已纳入的片段计数。
    /// 不传消费数时保持旧语义，重置全部计数。
    mutating func noteSuccess(atMs now: Int64, consumingNewSegmentCount consumedCount: Int? = nil) {
        if let consumedCount {
            pendingSegmentTimes.removeFirst(min(pendingSegmentTimes.count, max(0, consumedCount)))
        } else {
            pendingSegmentTimes.removeAll(keepingCapacity: true)
        }
        lastSuccessAtMs = now
        lastFailureAtMs = nil
    }

    /// 分析失败：保留上一版，记录失败时间用于退避
    mutating func noteFailure(atMs now: Int64) {
        lastFailureAtMs = now
    }

    /// 触发条件是否满足（片段数 ≥ 3 或闲置 > 45 秒；无任何内容时不触发）
    func conditionMet(atMs now: Int64) -> Bool {
        guard newSegmentCount > 0 else { return false }
        if newSegmentCount >= minNewSegments { return true }
        if maximumWaitElapsed(atMs: now) { return true }
        if let lastSuccessAtMs, now - lastSuccessAtMs > maxIdleMs {
            return true
        }
        return false
    }

    private func maximumWaitElapsed(atMs now: Int64) -> Bool {
        guard let firstPendingAtMs = pendingSegmentTimes.first else { return false }
        return now - firstPendingAtMs >= maxIdleMs
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
            && (debounceSatisfied(atMs: now) || maximumWaitElapsed(atMs: now))
            && failureBackoffSatisfied(atMs: now)
    }

    /// 距可触发还差多少毫秒（用于定时唤醒；已可触发返回 0；条件未满足返回 nil）
    func msUntilReady(atMs now: Int64) -> Int64? {
        guard conditionMet(atMs: now) else { return nil }
        let debounceRemaining = lastChangeAtMs.map { max(0, debounceMs - (now - $0)) } ?? 0
        let maximumWaitRemaining = pendingSegmentTimes.first.map { max(0, maxIdleMs - (now - $0)) } ?? 0
        let retryRemaining = lastFailureAtMs.map { max(0, failureRetryMs - (now - $0)) } ?? 0
        return max(min(debounceRemaining, maximumWaitRemaining), retryRemaining)
    }
}
