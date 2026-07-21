import Foundation
import OSLog

/// 统一日志入口（实施计划 12.1）：
/// 只记录时间、片段 ID、耗时、状态码和脱敏错误；
/// 严禁记录转写原文、会议背景、参会人姓名、API Key 或音频路径。
enum AppLog {
    static let subsystem = "com.zhaobo.BangWoFenXi"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let diarization = Logger(subsystem: subsystem, category: "diarization")
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// 错误日志（脱敏后的错误类别/状态码/耗时等安全字段以 public 记录，
    /// 便于实机诊断；正文/姓名/Key 仍由 LogSanitizer 拦截，严禁传入）。
    static func logError(_ logger: Logger, _ sanitizedMessage: String) {
        logger.error("\(sanitizedMessage, privacy: .public)")
    }

    /// 警告日志（同上的 public 安全字段约定）
    static func logWarning(_ logger: Logger, _ sanitizedMessage: String) {
        logger.warning("\(sanitizedMessage, privacy: .public)")
    }
}

/// 日志脱敏与格式化工具。
/// 所有自由文本在进入 Logger 前必须经过 sanitize；结构化事件请使用 formatEvent。
enum LogSanitizer {
    /// 脱敏占位符
    static let redactedPlaceholder = "〈已脱敏〉"

    /// 常见敏感形态：API Key（sk-... / sk-proj-...）、Bearer Token、Key= 形式
    private static let sensitivePatterns: [NSRegularExpression] = {
        let patterns = [
            #"sk-[A-Za-z0-9\-_]{3,}"#,
            #"Bearer\s+[A-Za-z0-9\-._~+/=]{3,}"#,
            #"(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*\S+"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// 对自由文本脱敏：
    /// 1. 替换显式声明的敏感词（如参会人姓名、真实 Key 值）；
    /// 2. 按形态替换 API Key / Token 等。
    static func sanitize(_ message: String, sensitiveValues: [String] = []) -> String {
        var result = message
        for value in sensitiveValues where !value.isEmpty {
            result = result.replacingOccurrences(of: value, with: redactedPlaceholder)
        }
        for pattern in sensitivePatterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = pattern.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: redactedPlaceholder
            )
        }
        return result
    }

    /// 生成一条结构化日志正文：只含事件名、片段 ID、耗时、状态码与脱敏错误。
    /// - Parameters:
    ///   - event: 事件名（英文短标识，如 chunk_upload_failed）
    ///   - segmentID: 相关片段 ID（可选）
    ///   - durationMs: 耗时毫秒（可选）
    ///   - statusCode: HTTP 状态码（可选）
    ///   - error: 错误描述，会经过脱敏；调用方不得传入原文、姓名或 Key
    static func formatEvent(
        _ event: String,
        segmentID: UUID? = nil,
        durationMs: Int? = nil,
        statusCode: Int? = nil,
        error: String? = nil,
        sensitiveValues: [String] = []
    ) -> String {
        var fields: [String] = ["event=\(event)"]
        if let segmentID {
            fields.append("segment=\(segmentID.uuidString)")
        }
        if let durationMs {
            fields.append("duration_ms=\(durationMs)")
        }
        if let statusCode {
            fields.append("status=\(statusCode)")
        }
        if let error {
            fields.append("error=\(sanitize(error, sensitiveValues: sensitiveValues))")
        }
        return fields.joined(separator: " ")
    }
}
