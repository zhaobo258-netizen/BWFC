import Foundation

/// 可用性缓存策略（纯逻辑，可单测）：
/// 有效期内复用检查结果，过期才重新探测。
/// 用于消除「热路径反复调用 Speech 可用性（XPC 探测）」的回归。
struct AvailabilityCachePolicy: Sendable, Equatable {
    /// 缓存有效期（秒）
    let ttl: TimeInterval

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// 上次检查结果是否仍可复用
    /// - Parameters:
    ///   - checkedAt: 上次检查时间（nil = 从未检查，不可复用）
    ///   - now: 当前时间
    func shouldReuse(checkedAt: Date?, now: Date) -> Bool {
        guard let checkedAt else { return false }
        let age = now.timeIntervalSince(checkedAt)
        return age >= 0 && age < ttl
    }
}
