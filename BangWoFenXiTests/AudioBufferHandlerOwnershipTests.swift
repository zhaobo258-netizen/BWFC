import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

/// 采集缓冲回调的归属校验（Bug 3）：
/// audioCapture 是单例，工作台与旧会中页都会登记 onBuffer。
/// token 归属保证旧会话既收不到音频，也不会误清新会话的回调。
@Suite("采集缓冲回调归属")
struct AudioBufferHandlerOwnershipTests {

    /// 回调是 @Sendable，用引用类型计数避免捕获可变局部变量
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    @Test("切换会话后旧 token 的回调不再收到音频")
    func staleSessionStopsReceivingBuffers() throws {
        let capture = MockAudioCaptureService()
        let oldToken = UUID()
        let newToken = UUID()
        let oldCount = Counter()
        let newCount = Counter()

        capture.setBufferHandler(token: oldToken) { _ in oldCount.increment() }
        capture.setBufferHandler(token: newToken) { _ in newCount.increment() }

        let buffer = try #require(MockAudioCaptureService.makeSilentBuffer())
        capture.simulateBuffer(buffer)

        #expect(oldCount.value == 0)
        #expect(newCount.value == 1)
        #expect(capture.bufferHandlerToken == newToken)
    }

    @Test("旧会话的清理不会误伤新会话的回调")
    func staleClearDoesNotAffectCurrentHandler() throws {
        let capture = MockAudioCaptureService()
        let oldToken = UUID()
        let newToken = UUID()
        let received = Counter()

        capture.setBufferHandler(token: oldToken) { _ in }
        capture.setBufferHandler(token: newToken) { _ in received.increment() }
        // 旧视图 onDisappear 迟到：token 不匹配，应当什么都不做
        capture.clearBufferHandler(token: oldToken)

        let buffer = try #require(MockAudioCaptureService.makeSilentBuffer())
        capture.simulateBuffer(buffer)

        #expect(received.value == 1)
        #expect(capture.bufferHandlerToken == newToken)
        #expect(capture.ignoredClearCount == 1)
    }

    @Test("离开页面清理后不再投递音频")
    func clearStopsDelivery() throws {
        let capture = MockAudioCaptureService()
        let token = UUID()
        let received = Counter()

        capture.setBufferHandler(token: token) { _ in received.increment() }
        capture.clearBufferHandler(token: token)

        let buffer = try #require(MockAudioCaptureService.makeSilentBuffer())
        capture.simulateBuffer(buffer)

        #expect(received.value == 0)
        #expect(capture.bufferHandlerToken == nil)
    }

    @Test("真实采集服务同样遵守归属判断")
    func realServiceHonorsOwnership() {
        let capture = AVAudioCaptureService()
        let first = UUID()
        let second = UUID()

        capture.setBufferHandler(token: first) { _ in }
        #expect(capture.bufferHandlerToken == first)

        capture.setBufferHandler(token: second) { _ in }
        capture.clearBufferHandler(token: first)
        // 归属已易主，旧 token 的清理无效
        #expect(capture.bufferHandlerToken == second)

        capture.clearBufferHandler(token: second)
        #expect(capture.bufferHandlerToken == nil)
    }
}
