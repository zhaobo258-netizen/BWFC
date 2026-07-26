import Foundation
@testable import BangWoFenXi

/// Mock V2 通用分析服务：按脚本返回 DTO 或错误；记录调用内容。
final class MockConversationAnalysisService: ConversationAnalysisServicing, @unchecked Sendable {
    var resultQueue: [ConversationAnalysisOutputDTO] = []
    var errorQueue: [any Error] = []
    var persistentError: (any Error)?
    /// 每次调用前的人为延迟（毫秒）
    var delayMs: UInt64 = 0
    var suspendNextCall = false

    private(set) var calls: [(instructions: String, inputJSON: String)] = []
    private(set) var hasSuspendedCall = false
    private var suspendedContinuation: CheckedContinuation<Void, Never>?

    func analyze(instructions: String, inputJSON: String) async throws -> ConversationAnalysisOutputDTO {
        calls.append((instructions, inputJSON))
        if suspendNextCall {
            suspendNextCall = false
            await withCheckedContinuation { continuation in
                hasSuspendedCall = true
                suspendedContinuation = continuation
            }
        }
        if delayMs > 0 {
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        if !errorQueue.isEmpty { throw errorQueue.removeFirst() }
        if let persistentError { throw persistentError }
        if !resultQueue.isEmpty { return resultQueue.removeFirst() }
        // 默认：空结果（合法但无内容）
        return ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: nil, scenarioConfidence: nil, items: []
        )
    }

    func resumeSuspendedCall() {
        hasSuspendedCall = false
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        continuation?.resume()
    }
}
