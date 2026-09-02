import Foundation
import AVFoundation
@testable import BangWoFenXi

/// Mock 音频采集服务：不触碰硬件，记录调用序列，可模拟电平与设备断开。
/// 供 MeetingRecordingService 等上层逻辑的单元测试使用。
final class MockAudioCaptureService: AudioCaptureServicing, @unchecked Sendable {
    // 调用记录
    private(set) var selectDeviceCalls: [String?] = []
    private(set) var startCaptureURLs: [URL] = []
    private(set) var appendCaptureURLs: [URL] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var levelMonitorStartCount = 0
    private(set) var levelMonitorStopCount = 0

    /// 可注入的失败：设置后对应操作抛出该错误
    var startCaptureError: (any Error)?
    var selectDeviceError: (any Error)?
    var resumeError: (any Error)?
    var existingAudioDurationMs: Int64 = 0

    /// 模拟设备列表
    var devices: [AudioInputDevice] = [
        AudioInputDevice(id: "mock-builtin", name: "模拟内置麦克风"),
        AudioInputDevice(id: "mock-usb", name: "模拟 USB 麦克风")
    ]

    var onLevel: (@Sendable (Float) -> Void)?
    var onDeviceDisconnected: (@Sendable () -> Void)?
    var onWriteFailure: (@Sendable () -> Void)?

    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private(set) var bufferHandlerToken: UUID?
    /// 归属不匹配而被忽略的清理次数（供测试断言旧会话不会误清新回调）
    private(set) var ignoredClearCount = 0

    func setBufferHandler(
        token: UUID,
        _ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) {
        bufferHandler = handler
        bufferHandlerToken = handler == nil ? nil : token
    }

    func clearBufferHandler(token: UUID) {
        guard bufferHandlerToken == token else {
            ignoredClearCount += 1
            return
        }
        bufferHandler = nil
        bufferHandlerToken = nil
    }

    private(set) var activeDeviceID: String?
    var activeDeviceName: String? {
        devices.first(where: { $0.id == activeDeviceID })?.name
    }

    func inputDevices() -> [AudioInputDevice] { devices }

    func selectInputDevice(id: String?) throws {
        if let selectDeviceError { throw selectDeviceError }
        selectDeviceCalls.append(id)
        activeDeviceID = id
    }

    func startCapture(fileURL: URL) throws {
        if let startCaptureError { throw startCaptureError }
        startCaptureURLs.append(fileURL)
    }

    func startAppendingCapture(fileURL: URL) throws -> Int64 {
        if let startCaptureError { throw startCaptureError }
        appendCaptureURLs.append(fileURL)
        return existingAudioDurationMs
    }

    func pauseCapture() { pauseCount += 1 }

    func resumeCapture() throws {
        if let resumeError { throw resumeError }
        resumeCount += 1
    }

    func stopCapture() { stopCount += 1 }

    func startLevelMonitoring() throws { levelMonitorStartCount += 1 }

    func stopLevelMonitoring() { levelMonitorStopCount += 1 }

    // MARK: - 测试辅助

    /// 模拟设备断开（触发与真实实现相同的回调路径）
    func simulateDeviceDisconnect() {
        onDeviceDisconnected?()
    }

    /// 模拟录音文件连续写失败达到采集层阈值后的回调
    func simulateWriteFailure() {
        onWriteFailure?()
    }

    /// 模拟上报一次电平
    func simulateLevel(_ level: Float) {
        onLevel?(level)
    }

    /// 模拟一次采集缓冲分发（走与真实实现相同的归属判断路径）
    func simulateBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferHandler?(buffer)
    }

    /// 构造一段静音缓冲，仅用于验证回调是否投递
    static func makeSilentBuffer(frames: AVAudioFrameCount = 512) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frames
        ) else { return nil }
        buffer.frameLength = frames
        return buffer
    }
}
