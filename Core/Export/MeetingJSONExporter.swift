import Foundation

/// JSON 原始结构导出（实施计划阶段 5）：
/// 会议结构、人员代号、片段、分析快照；可重新解析，片段 ID 与证据引用完整。
/// 直接复用模型的 Codable 结构，外加格式版本与导出时间信封。
struct MeetingJSONExportEnvelope: Codable {
    /// 导出格式版本（后续兼容依据）
    var formatVersion: Int
    /// 导出时间
    var exportedAt: Date
    /// 会议完整结构（含参会人代号、片段、分析快照）
    var meeting: Meeting
}

enum MeetingJSONExporter {
    /// 当前导出格式版本
    static let currentFormatVersion = 1

    /// 生成导出 JSON 数据（prettyPrinted + sortedKeys，便于 diff 与人工检查）
    static func makeJSONData(meeting: Meeting, exportedAt: Date = Date()) throws -> Data {
        let envelope = MeetingJSONExportEnvelope(
            formatVersion: currentFormatVersion,
            exportedAt: exportedAt,
            meeting: meeting
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    /// 重新解析导出的 JSON（往返一致性校验与后续导入使用）
    static func parse(data: Data) throws -> MeetingJSONExportEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingJSONExportEnvelope.self, from: data)
    }
}
