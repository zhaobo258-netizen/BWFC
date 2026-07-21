import Foundation
import AVFoundation

/// 麦克风权限（实施计划 5.1：首次使用请求麦克风权限）
enum MicrophonePermission {
    /// 当前授权状态
    static var currentStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 请求授权；已决定过则直接返回当前结果
    static func requestAccess() async -> Bool {
        switch currentStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
