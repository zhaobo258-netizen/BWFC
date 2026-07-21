import Foundation

/// 本地转写服务协议（实施计划 7.3：Apple Speech 设备端即时转写）。
/// 阶段 2 基于 SpeechAnalyzer / SpeechTranscriber 实现。
protocol LocalTranscriptionServicing: Sendable {
    /// 检查中文（普通话）转写是否可用，不可用必须返回真实原因
    func checkMandarinAvailability() async throws -> Bool
    /// 开始接收音频缓冲并产出临时/最终片段
    func startTranscription() async throws
    /// 停止转写
    func stopTranscription() async throws
}

/// 占位实现：接线用，调用即报「未实现」
struct UnimplementedLocalTranscriptionService: LocalTranscriptionServicing {
    func checkMandarinAvailability() async throws -> Bool {
        throw ServiceNotReadyError.notImplemented("本地转写")
    }
    func startTranscription() async throws {
        throw ServiceNotReadyError.notImplemented("本地转写")
    }
    func stopTranscription() async throws {
        throw ServiceNotReadyError.notImplemented("本地转写")
    }
}
