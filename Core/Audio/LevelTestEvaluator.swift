import Foundation

/// 5 秒电平测试结果评估（纯逻辑，可单测）。
/// 阈值依据：RMS 经显示放大后，正常说话峰值通常远高于 0.02；
/// 完全无声（设备无效 / 被静音）峰值趋近 0。
enum LevelTestEvaluator {
    /// 评估结论
    enum Verdict: String, Sendable {
        case good      // 音量正常
        case tooQuiet  // 音量偏小
        case silent    // 未检测到声音
    }

    struct Result: Equatable, Sendable {
        /// 采样中的峰值电平
        let peak: Float
        /// 平均电平
        let average: Float
        /// 结论
        let verdict: Verdict
    }

    /// 判定为「未检测到声音」的峰值阈值
    static let silentPeakThreshold: Float = 0.001
    /// 判定为「音量正常」的峰值阈值
    static let goodPeakThreshold: Float = 0.02

    static func evaluate(_ samples: [Float]) -> Result {
        let peak = samples.max() ?? 0
        let average = samples.isEmpty ? 0 : samples.reduce(0, +) / Float(samples.count)
        let verdict: Verdict
        if peak < silentPeakThreshold {
            verdict = .silent
        } else if peak < goodPeakThreshold {
            verdict = .tooQuiet
        } else {
            verdict = .good
        }
        return Result(peak: peak, average: average, verdict: verdict)
    }
}

extension LevelTestEvaluator.Verdict {
    /// 中文说明（设置与会前准备界面使用）
    var displayName: String {
        switch self {
        case .good: return "音量正常"
        case .tooQuiet: return "音量偏小，请靠近麦克风或调高输入音量"
        case .silent: return "未检测到声音，请检查麦克风连接与系统输入设置"
        }
    }
}
