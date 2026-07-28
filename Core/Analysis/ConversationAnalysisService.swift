import Foundation

/// V2 通用分析服务协议（03 §9.1）
protocol ConversationAnalysisServicing: Sendable {
    /// instructions = 语义分析师系统指令；inputJSON = 组装好的请求输入
    func analyze(instructions: String, inputJSON: String) async throws -> ConversationAnalysisOutputDTO
}

/// Kimi 网关实现：与 V1 谈判分析共用同一传输层（KimiAnalysisService.rawAnalysisText），
/// 只是系统指令换成语义分析师 + V2 JSON 合同，解码为 V2 DTO。
struct KimiConversationAnalysisService: ConversationAnalysisServicing {
    private let generationService: any AITextGenerationServing

    init(transport: KimiAnalysisService = KimiAnalysisService()) {
        self.generationService = KimiTextGenerationService(transport: transport)
    }

    init(generationService: any AITextGenerationServing) {
        self.generationService = generationService
    }

    func analyze(instructions: String, inputJSON: String) async throws -> ConversationAnalysisOutputDTO {
        let response = try await generationService.generate(
            AITextGenerationRequest(
                system: instructions + "\n\n" + ConversationAnalysisPrompt.jsonOutputSuffix,
                input: inputJSON
            )
        )
        let trimmed = KimiAnalysisService.strippedJSONText(response.text)
        guard let data = trimmed.data(using: .utf8),
              let dto = try? JSONDecoder().decode(ConversationAnalysisOutputDTO.self, from: data) else {
            let closed = trimmed.hasSuffix("}") || trimmed.hasSuffix("]")
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "conversation_analysis_output_invalid",
                error: "len=\(trimmed.count) closed=\(closed)"
            ))
            throw AnalysisAPIError.invalidResponse
        }
        return dto
    }
}
