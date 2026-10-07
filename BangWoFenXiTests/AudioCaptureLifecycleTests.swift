import Foundation
import AVFoundation
import AudioToolbox
import Testing
@testable import BangWoFenXi

@Suite("采集停机与 tap 并发")
struct AudioCaptureLifecycleTests {
    @Test("停机等待 tap 时不持状态锁，且最后一帧在关闭文件前落盘")
    func stopDrainsFinalBufferWithoutDeadlock() throws {
        let fixture = try CaptureLifecycleFixture()
        defer { fixture.remove() }
        let engine = SyntheticCaptureEngine()
        let capture = AVAudioCaptureService(engine: engine)
        let url = fixture.directory.appending(path: "tail.caf")
        try capture.startCapture(fileURL: url)
        engine.operationsDeliveringTap = [.stop]

        capture.stopCapture()

        #expect(engine.blockedTapOperations.isEmpty,
                "停机不能持有 processTapBuffer 所需的状态锁")
        #expect(try AVAudioFile(forReading: url).length == SyntheticCaptureEngine.frameCount,
                "引擎排空的尾帧必须写入，不能在 stop 前禁写或提前释放文件")
        // 重复清理不能重开文件或再写入旧会话。
        capture.stopCapture()
        #expect(try AVAudioFile(forReading: url).length == SyntheticCaptureEngine.frameCount)
    }

    @Test("启动、暂停、恢复及电平监听的引擎调用均允许 tap 完成")
    func allEngineTransitionsReleaseCallbackStateLock() throws {
        let fixture = try CaptureLifecycleFixture()
        defer { fixture.remove() }
        let engine = SyntheticCaptureEngine()
        engine.operationsDeliveringTap = Set(SyntheticCaptureEngine.Operation.allCases)
        let capture = AVAudioCaptureService(engine: engine)

        try capture.startCapture(fileURL: fixture.directory.appending(path: "transitions.caf"))
        capture.pauseCapture()
        try capture.resumeCapture()
        capture.stopCapture()
        try capture.startLevelMonitoring()
        capture.stopLevelMonitoring()

        #expect(engine.blockedTapOperations.isEmpty,
                "所有引擎操作都可能等待实时回调，不仅限于 stop")
        #expect(Set(engine.completedTapOperations) == Set(SyntheticCaptureEngine.Operation.allCases))
    }

    @Test("新录音等待旧录音排空，旧 stop 不能关闭新文件")
    func concurrentRestartIsSerializedBehindStop() throws {
        let fixture = try CaptureLifecycleFixture()
        defer { fixture.remove() }
        let engine = SyntheticCaptureEngine()
        let capture = AVAudioCaptureService(engine: engine)
        let oldURL = fixture.directory.appending(path: "old.caf")
        let newURL = fixture.directory.appending(path: "new.caf")
        try capture.startCapture(fileURL: oldURL)

        let stopEntered = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        let restartAttempted = DispatchSemaphore(value: 0)
        let restartFinished = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        let restartError = CaptureTestResult()
        engine.beforeNextStop = {
            stopEntered.signal()
            _ = releaseStop.wait(timeout: .now() + 5)
        }
        DispatchQueue.global().async {
            capture.stopCapture()
            stopFinished.signal()
        }
        #expect(stopEntered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            restartAttempted.signal()
            do { try capture.startCapture(fileURL: newURL) }
            catch { restartError.record(error) }
            restartFinished.signal()
        }
        #expect(restartAttempted.wait(timeout: .now() + 5) == .success)
        // 人为冻结旧 stop；新 start 必须等待，不能趁 tap 状态锁空闲时插入。
        #expect(restartFinished.wait(timeout: .now() + 0.1) == .timedOut)
        releaseStop.signal()
        #expect(stopFinished.wait(timeout: .now() + 5) == .success)
        #expect(restartFinished.wait(timeout: .now() + 5) == .success)
        #expect(restartError.message == nil)

        engine.deliverTap()
        capture.stopCapture()
        #expect(try AVAudioFile(forReading: oldURL).length == 0)
        #expect(try AVAudioFile(forReading: newURL).length == SyntheticCaptureEngine.frameCount)
    }
}

private struct CaptureLifecycleFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureLifecycleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class CaptureTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessage: String?
    var message: String? { lock.withLock { storedMessage } }
    func record(_ error: any Error) { lock.withLock { storedMessage = String(describing: error) } }
}

/// 用真实 AVAudioFile + 合成 PCM 重建系统报告中的环：控制线程等待 tap，tap 读取采集状态。
/// 有限等待使回归失败表现为断言，而非把测试执行器永久挂死。
private final class SyntheticCaptureEngine: AudioCaptureEngine, @unchecked Sendable {
    enum Operation: String, CaseIterable, Sendable {
        case inputFormat, installTap, prepare, start, pause, stop
    }

    static let frameCount: Int64 = 128
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let lock = NSLock()
    private let tapQueue = DispatchQueue(label: "CaptureLifecycleTests.tap")
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var deliveringOperations: Set<Operation> = []
    private var blockedOperations: [Operation] = []
    private var completedOperations: [Operation] = []
    private var stopHook: (@Sendable () -> Void)?

    var operationsDeliveringTap: Set<Operation> {
        get { lock.withLock { deliveringOperations } }
        set { lock.withLock { deliveringOperations = newValue } }
    }
    var blockedTapOperations: [Operation] { lock.withLock { blockedOperations } }
    var completedTapOperations: [Operation] { lock.withLock { completedOperations } }
    var beforeNextStop: (@Sendable () -> Void)? {
        get { lock.withLock { stopHook } }
        set { lock.withLock { stopHook = newValue } }
    }
    var inputFormat: AVAudioFormat { perform(.inputFormat); return format }
    var inputAudioUnit: AudioUnit? { nil }
    var notificationObject: AnyObject { self }

    func installTap(format: AVAudioFormat, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.withLock { self.handler = handler }
        perform(.installTap)
    }
    func prepare() { perform(.prepare) }
    func start() throws { perform(.start) }
    func pause() { perform(.pause) }
    func stop() {
        let hook = lock.withLock {
            let hook = stopHook
            stopHook = nil
            return hook
        }
        hook?()
        perform(.stop)
    }

    func deliverTap() {
        guard let callback = lock.withLock({ handler }),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.frameCount))
        else { return }
        buffer.frameLength = AVAudioFrameCount(Self.frameCount)
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: Int(Self.frameCount))
        callback(buffer)
    }

    private func perform(_ operation: Operation) {
        guard lock.withLock({ deliveringOperations.contains(operation) && handler != nil }) else { return }
        let finished = DispatchSemaphore(value: 0)
        tapQueue.async { [self] in
            deliverTap()
            finished.signal()
        }
        let completed = finished.wait(timeout: .now() + 2) == .success
        lock.withLock {
            if completed { completedOperations.append(operation) }
            else { blockedOperations.append(operation) }
        }
    }
}
