import Foundation

/// 云端模型配置（实施计划 7.1：模型 ID 必须集中在这一处，
/// 不散落在视图和业务代码里；不要在首版做可任意切换模型的设置页）。
enum CloudModelConfig {
    /// 说话人识别模型：Audio Transcriptions 接口
    static let diarizationModelID = "gpt-4o-transcribe-diarize"

    /// 谈判分析模型：Responses API。
    /// 开发期使用账户当前可用的 GPT-5 系列模型；发布前固定为评测通过的具体版本。
    static let analysisModelID = "gpt-5"

    /// API 基础地址（所有请求必须使用 HTTPS）
    static let apiBaseURL = URL(string: "https://api.openai.com/v1")!
}
