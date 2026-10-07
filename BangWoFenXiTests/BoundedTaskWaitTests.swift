import Foundation
import Testing
@testable import BangWoFenXi

/// 有意不响应 Task.cancel 的受控服务；测试结束主动释放，不泄漏等待任务。
actor UncooperativeTestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

@Suite("收尾有限等待")
@MainActor
struct BoundedTaskWaitTests {
    @Test("正常完成返回任务的结果")
    func completedResult() async {
        let task = Task { 42 }
        let result = await awaitTaskResult(task, timeout: .seconds(1))
        guard case .completed(let value) = result else {
            Issue.record("应返回完成值")
            return
        }
        #expect(value == 42)
    }

    @Test("业务操作失效后立即退出等待，不依赖底层完成")
    func invalidatedOperationReturnsImmediately() async {
        let gate = UncooperativeTestGate()
        let task = Task { await gate.wait(); return 42 }
        var invalidated = false
        let waiter = Task {
            await awaitTaskResult(task, timeout: .seconds(30)) { invalidated }
        }
        try? await Task.sleep(for: .milliseconds(20))
        invalidated = true
        let result = await awaitTaskResult(waiter, timeout: .seconds(1))
        if case .completed(.cancelled) = result {} else {
            Issue.record("业务取消后必须立即退出等待")
        }
        task.cancel()
        await gate.releaseAll()
    }

    @Test("不合作任务超时后仍能返回")
    func timeoutDoesNotAwaitUncooperativeTask() async {
        let gate = UncooperativeTestGate()
        let task = Task { await gate.wait(); return 42 }
        let startedAt = ContinuousClock.now
        let result = await awaitTaskResult(task, timeout: .milliseconds(50))
        if case .timedOut = result {} else { Issue.record("应返回超时") }
        #expect(startedAt.duration(to: .now) < .seconds(1))
        task.cancel()
        await gate.releaseAll()
    }
}
