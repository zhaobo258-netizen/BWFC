import Foundation

/// 历史来源「回到完整对话」的轮次定位请求（M3/A 收尾）。
/// - `id`: 每次点击生成的新 UUID，即使定位同一轮也会触发 onChange；
/// - `turnID`: 历史轮次的稳定标识（与消息 turnID / requestID 同源）。
/// 值类型、可测试，不与控制器耦合。
struct AIChatNavigationRequest: Equatable, Identifiable, Sendable {
    var id: UUID
    var turnID: UUID

    init(id: UUID = UUID(), turnID: UUID) {
        self.id = id
        self.turnID = turnID
    }
}

/// 轮次定位纯逻辑：在当前保留的消息里找该轮 assistant 回复。
/// 找不到（超过 60 条被裁剪 / 已被清空）如实返回 nil，不冒充定位到最新一轮。
enum AIChatTurnLocator {
    /// 该轮 assistant 消息 id；没有则返回 nil。
    static func assistantMessageID(
        turnID: UUID,
        in messages: [ProjectAIChatMessage]
    ) -> UUID? {
        messages.last { message in
            message.role == .assistant && (message.turnID ?? message.requestID) == turnID
        }?.id
    }

    /// 该轮（user/assistant 任一条）是否仍在保留记录中。
    static func isRetained(
        turnID: UUID,
        in messages: [ProjectAIChatMessage]
    ) -> Bool {
        messages.contains { ($0.turnID ?? $0.requestID) == turnID }
    }
}
