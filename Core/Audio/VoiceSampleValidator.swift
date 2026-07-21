import Foundation

/// 声音样本校验（纯逻辑，实施计划 7.5）：
/// 每份参考音频必须为单人、清晰、2–10 秒。
enum VoiceSampleValidator {
    /// 最短时长（毫秒）
    static let minDurationMs: Int64 = 2_000
    /// 最长时长（毫秒）
    static let maxDurationMs: Int64 = 10_000
    /// 有效音量峰值下限（复用电平评估阈值）
    static let minPeakLevel: Float = LevelTestEvaluator.goodPeakThreshold

    enum Verdict: Equatable, Sendable {
        case ok
        case tooShort
        case tooLong
        case tooQuiet
    }

    /// 校验样本时长与有效音量（时长与单人说话条件由录制界面引导）
    static func validate(durationMs: Int64, peakLevel: Float) -> Verdict {
        if durationMs < minDurationMs { return .tooShort }
        if durationMs > maxDurationMs { return .tooLong }
        if peakLevel < minPeakLevel { return .tooQuiet }
        return .ok
    }
}

extension VoiceSampleValidator.Verdict {
    /// 中文说明（设置与会前准备界面使用）
    var displayName: String {
        switch self {
        case .ok: return "样本合格"
        case .tooShort: return "样本不足 2 秒，请重录"
        case .tooLong: return "样本超过 10 秒，请重录"
        case .tooQuiet: return "样本音量过低，请靠近麦克风重录"
        }
    }

    /// 是否合格
    var isOK: Bool { self == .ok }
}
