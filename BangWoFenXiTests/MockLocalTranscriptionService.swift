import Foundation
import AVFoundation
@testable import BangWoFenXi

/// Mock 本地转写服务：不触碰 SpeechAnalyzer，按脚本向结果流注入内容。
final class MockLocalTranscriptionService: LocalTranscriptionServicing, @unchecked Sendable {
    /// 可注入的可用性结果（默认全部就绪）
    var availability = TranscriptionAvailability(
        transcriberAvailable: true,
        mandarinSupported: true,
        assetState: .installed,
        issues: []
    )

    private var continuation: AsyncStream<LocalTranscriptResult>.Continuation?
    let results: AsyncStream<LocalTranscriptResult>

    private(set) var startSessionCalls: [[String]] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var fedBufferCount = 0
    private(set) var installCallCount = 0
    private(set) var availabilityProbeCount = 0
    var startError: (any Error)?

    /// 安装脚本：设置后 installMandarinAssets 抛出该错误
    var installError: (any Error)?
    /// 安装时上报的进度序列
    var installProgressSteps: [Double] = [0.3, 0.7, 1.0]
    /// 安装成功后的可用性（模拟「下载完成 → installed」）
    var availabilityAfterInstall: TranscriptionAvailability?

    init() {
        var captured: AsyncStream<LocalTranscriptResult>.Continuation!
        results = AsyncStream { captured = $0 }
        continuation = captured
    }

    func checkMandarinAvailability() async -> TranscriptionAvailability {
        availabilityProbeCount += 1
        return availability
    }

    func startSession(contextualStrings: [String]) async throws {
        if let startError { throw startError }
        startSessionCalls.append(contextualStrings)
    }

    func installMandarinAssets(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        installCallCount += 1
        if let installError { throw installError }
        for step in installProgressSteps {
            onProgress(step)
        }
        if let availabilityAfterInstall {
            availability = availabilityAfterInstall
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) async {
        fedBufferCount += 1
    }

    /// finishSession 时结束结果流（真实服务行为；文件转写 Runner 测试需要）
    var finishEndsStream = false
    var finalResultsOnFinish: [LocalTranscriptResult] = []

    func finishSession() async {
        finishCount += 1
        for result in finalResultsOnFinish {
            continuation?.yield(result)
        }
        if finishEndsStream {
            continuation?.finish()
        }
    }

    func cancelSession() async {
        cancelCount += 1
        if finishEndsStream {
            continuation?.finish()
        }
    }

    // MARK: - 测试辅助

    /// 向结果流注入一条结果（模拟 SpeechAnalyzer 产出）
    func emit(_ result: LocalTranscriptResult) {
        continuation?.yield(result)
    }

    /// 结束结果流
    func finishStream() {
        continuation?.finish()
    }
}
