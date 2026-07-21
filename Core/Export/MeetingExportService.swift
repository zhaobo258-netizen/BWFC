import Foundation

/// 会议导出服务协议（实施计划 4.1：导出 Markdown 纪要和 JSON 原始结构）。
/// 阶段 5 实现。
protocol MeetingExportServicing: Sendable {
    /// 导出 Markdown 纪要
    func exportMarkdown(for meetingID: UUID) async throws -> URL
    /// 导出 JSON 原始结构
    func exportJSON(for meetingID: UUID) async throws -> URL
}

/// 占位实现：接线用，调用即报「未实现」
struct UnimplementedMeetingExportService: MeetingExportServicing {
    func exportMarkdown(for meetingID: UUID) async throws -> URL {
        throw ServiceNotReadyError.notImplemented("导出")
    }
    func exportJSON(for meetingID: UUID) async throws -> URL {
        throw ServiceNotReadyError.notImplemented("导出")
    }
}
