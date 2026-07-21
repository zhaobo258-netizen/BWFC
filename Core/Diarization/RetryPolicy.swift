import Foundation

/// 有限重试策略（纯逻辑，实施计划 7.4）：
/// 指数退避；超过上限进入「待用户重试」，不得无限循环。
struct RetryPolicy: Equatable, Sendable {
    /// 首次重试延迟（毫秒）
    var baseDelayMs: Int64 = 1_000
    /// 退避倍率
    var multiplier: Double = 2.0
    /// 单次延迟上限（毫秒）
    var maxDelayMs: Int64 = 30_000
    /// 最大尝试次数（含首次）
    var maxAttempts: Int = 5

    /// 第 attempt 次尝试前的退避延迟（attempt 从 1 开始：第 1 次为首次尝试，无延迟）
    func delayMs(beforeAttempt attempt: Int) -> Int64 {
        guard attempt > 1 else { return 0 }
        let exponent = Double(attempt - 2)
        let delay = Double(baseDelayMs) * pow(multiplier, exponent)
        return Int64(min(Double(maxDelayMs), delay))
    }

    /// 是否还允许继续尝试（attempt 为已失败的次数）
    func shouldRetry(afterFailures attempt: Int) -> Bool {
        attempt < maxAttempts
    }
}
