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
    var startError: (any Error)?

    init() {
        var captured: AsyncStream<LocalTranscriptResult>.Continuation!
        results = AsyncStream { captured = $0 }
        continuation = captured
    }

    func checkMandarinAvailability() async -> TranscriptionAvailability {
        availability
    }

    func startSession(contextualStrings: [String]) async throws {
        if let startError { throw startError }
        startSessionCalls.append(contextualStrings)
    }

    func feed(_ buffer: AVAudioPCMBuffer) async {
        fedBufferCount += 1
    }

    func finishSession() async {
        finishCount += 1
    }

    func cancelSession() async {
        cancelCount += 1
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
