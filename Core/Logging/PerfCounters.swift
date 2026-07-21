import Foundation
import OSLog

/// 性能计数与仪表（渲染风暴排查专用）：
/// 在关键发布点计数（脱敏：只记次数与时间，不记内容），
/// 供实机验证「到底是谁在高频发布」。
/// 通过 UserDefaults 键 `bwfxDebugCounters=YES` 在界面开启调试计数条。
enum PerfCounters {
    /// 计数项（顺序即界面展示顺序）
    enum Counter: String, CaseIterable, Sendable {
        case levelCallback          = "电平回调"
        case bufferFed              = "缓冲喂入"
        case provisionalResult      = "临时结果"
        case finalResult            = "最终结果"
        case provisionalSuppressed  = "临时节流抑制"
        case segmentsPublish        = "片段发布"
        case segmentsNoChangeSkip   = "无变化跳过"
        case cloudSegmentApplied    = "云端片段"
        case timerTick              = "计时器"
    }

    /// signpost 日志（Points of Interest 类别，可用 Instruments 观测）
    private static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: AppLog.subsystem, category: .pointsOfInterest)
    )

    private static let lock = NSLock()
    // 计数存储：由 lock 保护（编译器静态检查以 nonisolated(unsafe) 豁免）
    nonisolated(unsafe) private static var counts: [Counter: UInt64] = [:]
    nonisolated(unsafe) private static var startedAt = Date()

    /// 递增计数（热路径安全：仅加锁自增）
    static func increment(_ counter: Counter) {
        lock.withLock {
            counts[counter, default: 0] += 1
        }
    }

    /// 递增并发出 signpost 事件（低频事件使用，如片段发布）
    static func incrementWithSignpost(_ counter: Counter) {
        let value = lock.withLock { () -> UInt64 in
            counts[counter, default: 0] += 1
            return counts[counter] ?? 0
        }
        signposter.emitEvent("perf", "\(counter.rawValue)=\(value)")
    }

    /// 当前快照（调试界面读取）
    static func snapshot() -> [(counter: Counter, count: UInt64)] {
        lock.withLock {
            Counter.allCases.map { ($0, counts[$0] ?? 0) }
        }
    }

    /// 运行时长（秒）
    static var uptimeSeconds: TimeInterval {
        Date().timeIntervalSince(startedAt)
    }

    /// 清零（测试与新会话使用）
    static func reset() {
        lock.withLock {
            counts = [:]
            startedAt = Date()
        }
    }

    /// 调试开关（UserDefaults: bwfxDebugCounters）
    static var isDebugOverlayEnabled: Bool {
        UserDefaults.standard.bool(forKey: "bwfxDebugCounters")
    }
}
