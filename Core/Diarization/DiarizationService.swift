import Foundation

/// 云端说话人识别服务协议（实施计划 7.3 / 10.1）。
/// 阶段 3 实现：20 秒分片、2 秒重叠、known_speaker 只传本地代号。
protocol DiarizationServicing: Sendable {
    /// 上传一个音频分片并返回带说话人代号的确认片段
    /// - Parameters:
    ///   - chunkURL: 临时分片文件
    ///   - absoluteStartMs: 分片在会议时间轴上的绝对起始毫秒
    func transcribeChunk(at chunkURL: URL, absoluteStartMs: Int64) async throws
    /// 云端连接测试（设置页使用）：只返回可用/不可用与脱敏错误
    func testConnection() async throws -> Bool
}

/// 占位实现：接线用，调用即报「未实现」
struct UnimplementedDiarizationService: DiarizationServicing {
    func transcribeChunk(at chunkURL: URL, absoluteStartMs: Int64) async throws {
        throw ServiceNotReadyError.notImplemented("云端说话人识别")
    }
    func testConnection() async throws -> Bool {
        throw ServiceNotReadyError.notImplemented("连接测试")
    }
}
