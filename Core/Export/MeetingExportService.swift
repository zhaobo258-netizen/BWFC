import Foundation

/// 会议导出服务协议（实施计划 4.1：导出 Markdown 纪要和 JSON 原始结构）。
/// 只负责生成内容；保存位置由用户通过系统保存面板选择（阶段 5）。
protocol MeetingExportServicing: Sendable {
    /// 生成 Markdown 纪要文本
    func makeMarkdown(for meetingID: UUID) throws -> String
    /// 生成 JSON 原始结构数据
    func makeJSONData(for meetingID: UUID) throws -> Data
}

/// 导出错误
enum MeetingExportError: Error, Equatable {
    case meetingNotFound(UUID)
}

/// 本地导出实现：从持久化存储读取会议并生成内容
struct LocalMeetingExportService: MeetingExportServicing {
    private let meetingStore: any MeetingStoring

    init(meetingStore: any MeetingStoring) {
        self.meetingStore = meetingStore
    }

    func makeMarkdown(for meetingID: UUID) throws -> String {
        let meeting = try load(meetingID)
        return MeetingMarkdownExporter.makeMarkdown(meeting: meeting)
    }

    func makeJSONData(for meetingID: UUID) throws -> Data {
        let meeting = try load(meetingID)
        return try MeetingJSONExporter.makeJSONData(meeting: meeting)
    }

    private func load(_ meetingID: UUID) throws -> Meeting {
        guard let meeting = try meetingStore.loadMeetings().first(where: { $0.id == meetingID }) else {
            throw MeetingExportError.meetingNotFound(meetingID)
        }
        return meeting
    }
}
