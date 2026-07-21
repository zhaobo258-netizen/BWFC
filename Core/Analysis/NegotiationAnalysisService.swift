import Foundation

/// 谈判分析服务协议（实施计划 7.2 / 10.2 / 16）。
/// 协议隔离云端实现，为后续阶段（以及未来可能的回应策略扩展）保留替换点。
/// 阶段 4 实现：Responses API + Structured Outputs，增量上下文，串行请求。
protocol NegotiationAnalysisServicing: Sendable {
    /// 基于「上一版结构状态 + 新增最终片段」生成新的分析快照
    /// - Parameters:
    ///   - meetingID: 会议 ID
    ///   - throughMs: 本次分析处理到的时间轴毫秒
    func generateSnapshot(for meetingID: UUID, throughMs: Int64) async throws
    /// 会议结束后基于完整最终转写生成最终分析
    func generateFinalSnapshot(for meetingID: UUID) async throws
}

/// 占位实现：接线用，调用即报「未实现」
struct UnimplementedNegotiationAnalysisService: NegotiationAnalysisServicing {
    func generateSnapshot(for meetingID: UUID, throughMs: Int64) async throws {
        throw ServiceNotReadyError.notImplemented("谈判分析")
    }
    func generateFinalSnapshot(for meetingID: UUID) async throws {
        throw ServiceNotReadyError.notImplemented("谈判分析")
    }
}
