import Foundation
import Testing
@testable import BangWoFenXi

/// 日志脱敏测试（实施计划 12.1 / 14.1：敏感信息不得进入日志）。
/// 验证：传入含姓名 / API Key / 转写正文的输入，输出中不出现原文。
@Suite("日志脱敏")
struct LogSanitizerTests {

    /// 显式声明的敏感词（如参会人姓名）必须被替换
    @Test("敏感词替换")
    func sensitiveValuesAreRedacted() {
        let input = "说话人张总的分片上传失败，重试时王经理的样本也报错"
        let output = LogSanitizer.sanitize(input, sensitiveValues: ["张总", "王经理"])
        #expect(!output.contains("张总"), "输出不得包含姓名原文")
        #expect(!output.contains("王经理"), "输出不得包含姓名原文")
        #expect(output.contains(LogSanitizer.redactedPlaceholder))
    }

    /// 常见 API Key 形态必须被替换
    @Test("API Key 形态替换", arguments: [
        ("认证失败，key=sk-abc123DEF456", "sk-abc123"),
        ("请求头 Authorization: Bearer sk-proj-xyz789_UVW-012", "sk-proj-xyz789"),
        ("配置内容 api_key: sk-live-000011112222", "sk-live-0000"),
        ("token=ghp_exampletoken12345", "ghp_exampletoken12345")
    ])
    func apiKeyPatternsAreRedacted(input: String, forbidden: String) {
        let output = LogSanitizer.sanitize(input)
        #expect(!output.contains(forbidden), "输出不得包含 Key/Token 原文：\(input)")
    }

    /// 转写正文类自由文本：声明为敏感后不得残留原句
    @Test("转写正文脱敏")
    func transcriptContentRedactedWhenDeclaredSensitive() {
        let transcript = "如果年度量能能保证，我们可以再讨论两个点"
        let input = "分析失败，片段内容：\(transcript)"
        let output = LogSanitizer.sanitize(input, sensitiveValues: [transcript])
        #expect(!output.contains("年度量能"), "输出不得包含转写正文")
        #expect(!output.contains(transcript), "输出不得包含转写正文")
    }

    /// 结构化事件格式化：只含允许字段，错误信息经过脱敏
    @Test("结构化事件只含允许字段")
    func formatEventContainsOnlyAllowedFields() {
        let segmentID = UUID()
        let output = LogSanitizer.formatEvent(
            "chunk_upload_failed",
            segmentID: segmentID,
            durationMs: 1234,
            statusCode: 401,
            error: "张总的 Key sk-secret999 无效",
            sensitiveValues: ["张总"]
        )
        #expect(output.contains("event=chunk_upload_failed"))
        #expect(output.contains("segment=\(segmentID.uuidString)"))
        #expect(output.contains("duration_ms=1234"))
        #expect(output.contains("status=401"))
        #expect(!output.contains("张总"), "事件日志不得包含姓名")
        #expect(!output.contains("sk-secret999"), "事件日志不得包含 Key")
    }

    /// 空敏感词与空字符串输入不会导致异常
    @Test("边界输入不崩溃")
    func edgeCasesDoNotCrash() {
        #expect(LogSanitizer.sanitize("") == "")
        #expect(
            LogSanitizer.sanitize("普通错误描述", sensitiveValues: ["", "不存在的内容"]) == "普通错误描述"
        )
    }

    /// 不含敏感信息的普通错误描述应保持可读
    @Test("普通错误描述保持可读")
    func benignErrorMessageSurvives() {
        #expect(LogSanitizer.sanitize("连接超时，已安排第 2 次重试") == "连接超时，已安排第 2 次重试")
    }
}
