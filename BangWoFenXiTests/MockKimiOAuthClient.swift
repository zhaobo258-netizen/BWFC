import Foundation
@testable import BangWoFenXi

/// Kimi OAuth 客户端 Mock：设备授权/轮询/刷新按脚本成败，记录调用。
final class MockKimiOAuthClient: KimiOAuthClientProtocol, @unchecked Sendable {
    private let lock = NSLock()

    var deviceAuthorization = KimiDeviceAuthorization(
        deviceCode: "device-code-1",
        userCode: "ABCD-1234",
        verificationUriComplete: "https://auth.example.com/device?code=ABCD-1234",
        expiresIn: 600,
        intervalSeconds: 1
    )
    var startError: KimiOAuthError?
    /// 轮询结果队列（依次消费；耗尽后重复最后一个）
    var pollResults: [Result<KimiOAuthTokens, KimiOAuthError>] = []
    /// 刷新结果队列（依次消费；耗尽后重复最后一个）
    var refreshResults: [Result<KimiOAuthTokens, KimiOAuthError>] = []

    private var _startCalls = 0
    private var _pollCalls: [String] = []
    private var _refreshCalls: [String] = []

    var startCalls: Int { lock.withLock { _startCalls } }
    var pollCalls: [String] { lock.withLock { _pollCalls } }
    var refreshCalls: [String] { lock.withLock { _refreshCalls } }

    func startDeviceAuthorization() async throws -> KimiDeviceAuthorization {
        lock.withLock { _startCalls += 1 }
        if let startError { throw startError }
        return deviceAuthorization
    }

    func pollDeviceToken(deviceCode: String) async throws -> KimiOAuthTokens {
        let result: Result<KimiOAuthTokens, KimiOAuthError>? = lock.withLock {
            _pollCalls.append(deviceCode)
            guard !pollResults.isEmpty else { return nil }
            return pollResults.count > 1 ? pollResults.removeFirst() : pollResults[0]
        }
        guard let result else { throw KimiOAuthError.invalidResponse }
        return try result.get()
    }

    func refresh(refreshToken: String) async throws -> KimiOAuthTokens {
        let result: Result<KimiOAuthTokens, KimiOAuthError>? = lock.withLock {
            _refreshCalls.append(refreshToken)
            guard !refreshResults.isEmpty else { return nil }
            return refreshResults.count > 1 ? refreshResults.removeFirst() : refreshResults[0]
        }
        guard let result else { throw KimiOAuthError.invalidResponse }
        return try result.get()
    }
}
