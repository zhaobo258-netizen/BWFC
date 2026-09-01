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
    /// 默认分析模型：Kimi K3 256K。官方建议日常任务优先使用该版本，
    /// 与 K3 同属旗舰模型且比 1M 版本节省额度；设置页可改为 K3 1M。
    static let analysisModelID = "k3-256k"
    /// 分析网关基础地址（以 / 结尾；消息路径见 analysisMessagesPath）。
    /// 2026-07-24 起切换到 kimi-code 新体系网关（旧 agent-gw.kimi.com 为遗留通道，
    /// 新体系 OAuth token 在旧通道全部 401，实测确认）。
    static let analysisBaseURL = URL(string: "https://api.kimi.com/coding/")!
    /// messages 接口路径（相对基础地址）
    static let analysisMessagesPath = "v1/messages"
    /// Kimi Code 托管网页搜索服务；与模型消息共用 OAuth 登录凭证。
    static let kimiWebSearchURL = URL(
        string: "https://api.kimi.com/coding/v1/search"
    )!
    /// K3 始终思考；为思考与结构化正文共同预留预算。
    static let analysisMaxTokens = 32768
    /// 分析请求超时（秒；thinking 模型在长上下文下响应较慢）
    static let analysisRequestTimeout: TimeInterval = 240
    /// Anthropic messages 协议版本头
    static let anthropicVersion = "2023-06-01"

    // MARK: - Kimi 账号 OAuth（设备码登录 + 自动刷新）

    /// 授权服务器（kimi-code 体系；与 kimi CLI 同一套流程与 client_id）
    static let kimiOAuthHost = URL(string: "https://auth.kimi.com")!
    /// 设备码授权路径
    static let kimiOAuthDeviceAuthorizationPath = "api/oauth/device_authorization"
    /// token 颁发/刷新路径
    static let kimiOAuthTokenPath = "api/oauth/token"
    /// 公开 client_id（设备码流程无密钥；该值编译在官方 kimi CLI 内，非机密）
    static let kimiOAuthClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    /// access_token 剩余有效期低于该秒数时先刷新再发请求
    /// （token 实际有效期 900 秒；分析请求最长可跑 240 秒，留足余量）
    static let kimiOAuthRefreshLeewaySeconds: TimeInterval = 300
}
