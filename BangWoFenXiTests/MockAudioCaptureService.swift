import Foundation
@testable import BangWoFenXi

/// Mock 音频采集服务：不触碰硬件，记录调用序列，可模拟电平与设备断开。
/// 供 MeetingRecordingService 等上层逻辑的单元测试使用。
final class MockAudioCaptureService: AudioCaptureServicing, @unchecked Sendable {
    // 调用记录
    private(set) var selectDeviceCalls: [String?] = []
    private(set) var startCaptureURLs: [URL] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var levelMonitorStartCount = 0
    private(set) var levelMonitorStopCount = 0

    /// 可注入的失败：设置后对应操作抛出该错误
    var startCaptureError: (any Error)?
    var selectDeviceError: (any Error)?
    var resumeError: (any Error)?

    /// 模拟设备列表
    var devices: [AudioInputDevice] = [
        AudioInputDevice(id: "mock-builtin", name: "模拟内置麦克风"),
        AudioInputDevice(id: "mock-usb", name: "模拟 USB 麦克风")
    ]

    var onLevel: (@Sendable (Float) -> Void)?
    var onDeviceDisconnected: (@Sendable () -> Void)?

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

    /// 模拟上报一次电平
    func simulateLevel(_ level: Float) {
        onLevel?(level)
    }
}
