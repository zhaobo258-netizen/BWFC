import Foundation

/// 只限定调用方的等待时间，不依赖底层任务响应取消。
/// 超时/取消后由调用方取消原任务，并保留它所处理的数据或恢复入口。
enum BoundedTaskResult<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
    case cancelled
}

@MainActor
private final class TaskCompletionBox<Value: Sendable> {
    var result: BoundedTaskResult<Value>?
}

/// TaskGroup 在离开作用域时还会等待全部子任务；观察独立 Task 才能在
/// 外部服务或 XPC 不合作时真正返回。观察者不持有 UI 或业务控制器。
@MainActor
func awaitTaskResult<Value: Sendable>(
    _ task: Task<Value, Never>,
    timeout: Duration,
    shouldCancel: @MainActor () -> Bool = { false }
) async -> BoundedTaskResult<Value> {
    let completion = TaskCompletionBox<Value>()
    let observer = Task {
        let value = await task.value
        guard !Task.isCancelled else { return }
        completion.result = .completed(value)
    }
    defer { observer.cancel() }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
        if Task.isCancelled || shouldCancel() { return .cancelled }
        if let result = completion.result { return result }
        guard ContinuousClock.now < deadline else { return .timedOut }
        do { try await Task.sleep(for: .milliseconds(20)) }
        catch { return .cancelled }
    }
}
