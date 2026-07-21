import Foundation
@testable import BangWoFenXi

/// URLProtocol Mock：拦截 URLSession 请求，按脚本返回响应；不依赖真实网络。
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// 请求处理器（线程安全访问）
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// 记录捕获的请求
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset() {
        requestHandler = nil
        capturedRequests = []
    }

    /// 配置使用该 Mock 的 URLSession
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.capturedRequests.append(request)
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Mock 云端识别服务：按脚本返回结果或错误序列。
final class MockDiarizationService: DiarizationServicing, @unchecked Sendable {
    /// 依次返回的结果（队列消费完后返回空结果）
    var resultQueue: [DiarizationChunkResult] = []
    /// 依次抛出的错误（优先于结果）
    var errorQueue: [any Error] = []
    /// 持续性错误（errorQueue 用尽后仍抛出）
    var persistentError: (any Error)?
    /// 每次调用前的人为延迟（毫秒，用于测试时序）
    var delayMs: UInt64 = 0

    private(set) var calls: [(url: URL, speakers: [KnownSpeakerReference])] = []

    func transcribeChunk(
        at chunkURL: URL,
        knownSpeakers: [KnownSpeakerReference]
    ) async throws -> DiarizationChunkResult {
        calls.append((chunkURL, knownSpeakers))
        if delayMs > 0 {
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        if !errorQueue.isEmpty { throw errorQueue.removeFirst() }
        if let persistentError { throw persistentError }
        if !resultQueue.isEmpty { return resultQueue.removeFirst() }
        return DiarizationChunkResult(durationMs: 20_000, segments: [])
    }

    func testConnection() async throws -> Bool { true }
}
