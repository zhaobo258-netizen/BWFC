import Foundation

/// 音频输入设备描述
struct AudioInputDevice: Hashable, Sendable {
    /// 系统设备唯一标识
    let id: String
    /// 显示名称（如「MacBook Pro 麦克风」）
    let name: String
}

/// 音频采集服务协议（实施计划 7.2：AudioCaptureService）。
/// 阶段 1 实现真实采集（AVAudioEngine + 录音文件写入）。
protocol AudioCaptureServicing: Sendable {
    /// 列出可用输入设备
    func availableInputDevices() async throws -> [AudioInputDevice]
    /// 开始采集（同时写本地完整录音文件）
    func startCapture() async throws
    /// 暂停采集（不结束文件和会议）
    func pauseCapture() async throws
    /// 继续采集
    func resumeCapture() async throws
    /// 停止采集并安全关闭文件
    func stopCapture() async throws
}

/// 占位实现：接线用，调用即报「未实现」
struct UnimplementedAudioCaptureService: AudioCaptureServicing {
    func availableInputDevices() async throws -> [AudioInputDevice] {
        throw ServiceNotReadyError.notImplemented("音频采集")
    }
    func startCapture() async throws {
        throw ServiceNotReadyError.notImplemented("音频采集")
    }
    func pauseCapture() async throws {
        throw ServiceNotReadyError.notImplemented("音频采集")
    }
    func resumeCapture() async throws {
        throw ServiceNotReadyError.notImplemented("音频采集")
    }
    func stopCapture() async throws {
        throw ServiceNotReadyError.notImplemented("音频采集")
    }
}
