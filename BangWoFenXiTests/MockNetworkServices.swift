import Foundation
@testable import BangWoFenXi

/// URLProtocol Mock 存储（每个套件独立实例，避免并行测试互相污染）
final class MockURLProtocolStorage: @unchecked Sendable {
    var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    var capturedRequests: [URLRequest] = []
    func reset() {
        requestHandler = nil
        capturedRequests = []
    }
}

/// URLProtocol Mock 基类：拦截 URLSession 请求，按脚本返回响应；不依赖真实网络。
/// 每个测试套件使用独立的子类（独立静态存储），从根本上避免并行干扰。
class MockURLProtocolBase: URLProtocol, @unchecked Sendable {
    /// 子类必须覆盖：本类的独立存储
    class var sharedStorage: MockURLProtocolStorage {
        fatalError("子类必须覆盖 sharedStorage")
    }

    /// 配置使用本 Mock 的 URLSession
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let storage = type(of: self).sharedStorage
        storage.capturedRequests.append(request)
        guard let handler = storage.requestHandler else {
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

/// 阶段 3 云端识别接口测试专用
final class DiarizationMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

/// 火山引擎极速识别测试专用
final class VolcengineMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

final class IFlytekMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

/// 阶段 4 谈判分析接口测试专用
final class AnalysisMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

/// Kimi 网关分析接口测试专用
final class KimiMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

/// Key 分家隔离测试专用（分人侧）
final class IsolationDiarizationMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

/// Key 分家隔离测试专用（分析侧）
final class IsolationKimiMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

/// 从请求中提取请求体（兼容 httpBody / httpBodyStream 两种形态）
func mockRequestBodyData(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 8192)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

/// Mock 云端识别服务：按脚本返回结果或错误序列。
final class MockDiarizationService: DiarizationServicing, @unchecked Sendable {
    var knownSpeakerMatchingCapability: KnownSpeakerMatchingCapability {
        .supported(maximumSpeakers: KnownSpeakerReference.maximumCount)
    }
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
