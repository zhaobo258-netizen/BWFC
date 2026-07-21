import Foundation

/// 云端模型配置（实施计划 7.1：模型 ID 必须集中在这一处，
/// 不散落在视图和业务代码里；不要在首版做可任意切换模型的设置页）。
///
/// 当前 provider 分工：
/// - 说话人识别：OpenAI 兼容接口（保持现状）
/// - 谈判文字分析：本机 Kimi 网关（Anthropic 风格 messages 接口）
enum CloudModelConfig {
    // MARK: - 说话人识别（OpenAI 兼容，保持现状）

    /// 说话人识别模型：Audio Transcriptions 接口
    static let diarizationModelID = "gpt-4o-transcribe-diarize"
    /// 说话人识别 API 基础地址（所有请求必须使用 HTTPS）
    static let diarizationBaseURL = URL(string: "https://api.openai.com/v1")!
    /// 兼容别名：说话人识别模块沿用此入口
    static let apiBaseURL = diarizationBaseURL

    // MARK: - 谈判文字分析（Kimi 网关）

    /// 分析 provider 名称（设置页展示）
    static let analysisProviderName = "Kimi"
    /// 分析模型（Anthropic 风格 messages 接口）
    static let analysisModelID = "kimi-for-coding"
    /// 分析网关基础地址（以 / 结尾；消息路径见 analysisMessagesPath）
    static let analysisBaseURL = URL(string: "https://agent-gw.kimi.com/coding/")!
    /// messages 接口路径（相对基础地址）
    static let analysisMessagesPath = "v1/messages"
    /// 单次分析最大输出 token 数（结构化输出需要足够空间）
    static let analysisMaxTokens = 4096
    /// Anthropic messages 协议版本头
    static let anthropicVersion = "2023-06-01"
}
