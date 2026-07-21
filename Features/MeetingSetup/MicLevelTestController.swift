import Foundation

/// 5 秒麦克风电平测试控制器（实施计划 5.2：选择和测试麦克风）。
/// 采集电平样本 5 秒后用 LevelTestEvaluator 给出结论。
@MainActor
@Observable
final class MicLevelTestController {
    /// 测试时长（秒）
    static let testDuration: TimeInterval = 5

    private(set) var isTesting = false
    /// 实时电平（0…1，驱动进度条）
    private(set) var liveLevel: Float = 0
    private(set) var result: LevelTestEvaluator.Result?
    /// 剩余秒数（界面倒计时显示）
    private(set) var remainingSeconds: Int = Int(testDuration)

    private var samples: [Float] = []
    private var countdownTask: Task<Void, Never>?
    private weak var capture: (any AudioCaptureServicing)?

    /// 开始测试；重复调用会先取消上一次
    func start(using capture: any AudioCaptureServicing, deviceID: String?) {
        cancel()
        self.capture = capture
        samples = []
        result = nil
        liveLevel = 0
        remainingSeconds = Int(Self.testDuration)

        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.isTesting else { return }
                self.samples.append(level)
                self.liveLevel = level
            }
        }

        do {
            try capture.selectInputDevice(id: deviceID)
            try capture.startLevelMonitoring()
        } catch {
            // 只保留脱敏错误类型
            AppLog.logError(AppLog.audio, LogSanitizer.formatEvent("level_test_start_failed", error: String(describing: type(of: error))))
            capture.onLevel = nil
            return
        }

        isTesting = true
        countdownTask = Task { [weak self] in
            // 每秒更新倒计时，5 秒后结束评估
            for remaining in stride(from: Int(Self.testDuration) - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.remainingSeconds = remaining
            }
            self?.finish()
        }
    }

    /// 取消测试（视图消失或用户中断）
    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        if isTesting {
            capture?.stopLevelMonitoring()
        }
        capture?.onLevel = nil
        isTesting = false
    }

    /// 结束并评估
    private func finish() {
        capture?.stopLevelMonitoring()
        capture?.onLevel = nil
        isTesting = false
        result = LevelTestEvaluator.evaluate(samples)
    }
}
