import Foundation

/// 分析接口错误（分类驱动调度行为，实施计划 11.2）
enum AnalysisAPIError: Error, Equatable, Sendable {
    /// 401：凭证无效或所选模型未授权 → 云端分析暂停，修复后可重试
    case unauthorized
    /// 429：限流 → 失败退避
    case rateLimited
    /// 5xx：服务失败 → 失败退避
    case serverError(statusCode: Int)
    /// 其他 4xx
    case clientError(statusCode: Int)
    /// 请求超时（thinking 模型长上下文响应慢；与断网区分）
    case timeout
    /// 网络层失败（断网、连接失败等非超时类）
    case network
    /// stop_reason = max_tokens：输出被长度截断（thinking 预算挤占 text）
    case truncated
    /// 响应或结构化输出无法解析 → 丢弃该快照并保留上一版（实施计划 11.2）
    case invalidResponse
    /// 未配置 API Key
    case missingAPIKey
    /// 本机凭证存储暂时不可读取
    case credentialAccessRequired
}

extension AnalysisAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "凭证无效或所选模型未开通（401），请在设置中检查后重试"
        case .rateLimited: return "云端限流（429），稍后自动重试"
        case .serverError(let code): return "云端服务失败（\(code)），稍后自动重试"
        case .clientError(let code): return "请求被拒绝（\(code)）"
        case .timeout: return "请求超时（模型响应过慢），将自动重试"
        case .network: return "网络连接失败，稍后自动重试"
        case .truncated: return "分析输出被长度限制截断，已丢弃并保留上一版"
        case .invalidResponse: return "分析结果不合规，已丢弃并保留上一版"
        case .missingAPIKey: return "未配置 API Key"
        case .credentialAccessRequired:
            return "当前 App 无法读取旧凭证，请前往设置重新登录或保存 API Key"
        }
    }
}

/// 谈判分析服务协议（实施计划 10.2 / 16）。
/// 协议隔离云端实现，为后续阶段（以及未来可能的回应策略扩展）保留替换点。
protocol NegotiationAnalysisServicing: Sendable {
    /// 执行一次增量分析
    /// - Parameters:
    ///   - instructions: 系统指令（AnalysisSystemPrompt.text）
    ///   - inputJSON: 增量输入（AnalysisInputAssembler 组装，含不可信包裹）
    /// - Returns: 通过严格 schema 的输出 DTO（尚未做证据校验）
    func analyze(instructions: String, inputJSON: String) async throws -> AnalysisOutputDTO
    /// 连接测试（设置页使用）：只返回可用/不可用，错误按统一分类抛出（脱敏）
    func testConnection() async throws -> Bool
}
