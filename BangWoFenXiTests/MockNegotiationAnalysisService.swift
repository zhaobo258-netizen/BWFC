import Foundation
@testable import BangWoFenXi

/// Mock 谈判分析服务：按脚本返回 DTO 或错误；记录调用内容。
final class MockNegotiationAnalysisService: NegotiationAnalysisServicing, @unchecked Sendable {
    var resultQueue: [AnalysisOutputDTO] = []
    var errorQueue: [any Error] = []
    var persistentError: (any Error)?
    /// 每次调用前的人为延迟（毫秒）
    var delayMs: UInt64 = 0

    private(set) var calls: [(instructions: String, inputJSON: String)] = []

    func analyze(instructions: String, inputJSON: String) async throws -> AnalysisOutputDTO {
        calls.append((instructions, inputJSON))
        if delayMs > 0 {
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        if !errorQueue.isEmpty { throw errorQueue.removeFirst() }
        if let persistentError { throw persistentError }
        if !resultQueue.isEmpty { return resultQueue.removeFirst() }
        // 默认：空结果（合法但无内容）
        return AnalysisOutputDTO(
            currentTopic: nil, topics: [], ourPositions: [],
            counterpartPositions: [], confirmedItems: [], openItems: [],
            keyFacts: [], insights: []
        )
    }
}
