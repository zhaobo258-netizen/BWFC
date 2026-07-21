import Foundation

/// 谈判分析调度控制器（阶段 4，实施计划 10.4）：
/// 触发条件 / 防抖 / 串行单请求 / 游标推进 / 失败保留上一版 / 快照原子替换。
@MainActor
@Observable
final class NegotiationAnalysisController {
    /// 云端分析状态（顶部状态栏显示）
    enum AnalysisState: Equatable {
        case idle
        case analyzing
        case suspended(reason: String) // 401 / 未配置 Key
    }

    private let service: any NegotiationAnalysisServicing
    private let triggerConfig: AnalysisTrigger
    /// 可注入的当前时间（测试可驱动）
    private let nowMs: () -> Int64

    /// 当前生效快照（UI 以整个快照原子替换，不逐字段闪烁）
    private(set) var currentSnapshot: AnalysisSnapshot?
    private(set) var state: AnalysisState = .idle
    /// 最近一次成功分析时间
    private(set) var lastSuccessAt: Date?
    /// 最近一次失败的脱敏描述
    private(set) var lastErrorDescription: String?
    /// 最近一次失败的类别（界面友好文案；成功时清空）
    private(set) var lastFailureKind: String?

    private var trigger: AnalysisTrigger
    private var analyzing = false
    private var pendingFire = false
    private weak var meeting: Meeting?
    /// 持久化回调（视图层注入）
    var onSnapshotUpdated: (() -> Void)?

    init(
        service: any NegotiationAnalysisServicing,
        triggerConfig: AnalysisTrigger = AnalysisTrigger(),
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.service = service
        self.triggerConfig = triggerConfig
        self.nowMs = nowMs
        self.trigger = triggerConfig
    }

    // MARK: - 会话

    /// 绑定会议（会中界面 onAppear）
    func attach(to meeting: Meeting) {
        self.meeting = meeting
        // 恢复既有最新快照（例如重启后回到会中/会后）
        currentSnapshot = meeting.snapshots.max(by: { $0.version < $1.version })
    }

    /// 新最终片段到达（本地或云端确认，由 LocalTranscriptionController 回调）
    func noteNewFinalSegment() {
        trigger.noteNewSegment(atMs: nowMs())
    }

    /// 周期驱动（由界面定时器调用）：满足条件且防抖已过则发起分析
    func tick() async {
        guard meeting != nil else { return }
        if case .suspended = state { return }
        let now = nowMs()
        guard trigger.readyToFire(atMs: now) else { return }
        await fire()
    }

    /// 会议结束后：用完整最终转写再生成一次「最终分析」（实施计划 10.4）
    func generateFinalAnalysis() async {
        if case .suspended = state { return }
        await fire(forceFullTranscript: true)
    }

    /// 状态栏文案（诚实化：失败后不得继续只显示「正常 + 旧时间」，
    /// 上一版结果仍保持可见）。
    var statusDescription: String {
        switch state {
        case .analyzing:
            return "分析中…"
        case .suspended:
            return "云端分析暂停"
        case .idle:
            if let kind = lastFailureKind {
                if let lastSuccessAt {
                    return "上次更新 \(Self.timeString(lastSuccessAt)) · 最近重试失败（\(kind)），将自动重试"
                }
                return "分析暂不可用（\(kind)），将自动重试"
            }
            if let lastSuccessAt {
                return "分析正常（更新于 \(Self.timeString(lastSuccessAt))）"
            }
            return "分析待内容积累"
        }
    }

    /// 是否有未恢复的分析失败（状态栏橙色显示）
    var hasRecentFailure: Bool {
        lastFailureKind != nil
    }

    private static func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// 错误 → 界面友好类别文案（脱敏）
    private static func failureKind(of error: AnalysisAPIError) -> String {
        switch error {
        case .timeout: return "超时"
        case .network: return "网络中断"
        case .rateLimited: return "限流"
        case .serverError: return "服务繁忙"
        case .truncated: return "输出截断"
        case .invalidResponse: return "结果不合规"
        case .unauthorized: return "Key 无效"
        case .missingAPIKey: return "未配置 Key"
        case .clientError: return "请求被拒"
        }
    }

    /// API Key 修复后恢复
    func resumeAfterKeyFix() {
        if case .suspended = state { state = .idle }
    }

    // MARK: - 分析执行

    /// 发起一次分析（串行：同一时间最多一个请求；期间到达的新内容记为待处理）
    private func fire(forceFullTranscript: Bool = false) async {
        guard let meeting else { return }
        if analyzing {
            // 只记录最新待处理游标：当前请求结束后合并到下一次
            pendingFire = true
            return
        }
        analyzing = true
        state = .analyzing
        let startedAt = Date()
        defer {
            analyzing = false
            if case .analyzing = state { state = .idle }
        }

        // 选择分析对象：云端确认或人工修订的片段（实施计划 7.3 / 4.1）
        let cursor = meeting.lastAnalyzedSegmentEndMs
        let eligible = meeting.segments.filter { $0.state == .final || $0.state == .edited }
        let newSegments: [TranscriptSegment]
        if forceFullTranscript {
            newSegments = eligible.sorted { $0.startMs < $1.startMs }
        } else {
            newSegments = eligible
                .filter { $0.endMs > cursor }
                .sorted { $0.startMs < $1.startMs }
        }
        guard !newSegments.isEmpty else {
            if forceFullTranscript == false {
                trigger.noteSuccess(atMs: nowMs()) // 无新内容：视为同步完成，避免空转
            }
            return
        }

        do {
            let inputJSON = try AnalysisInputAssembler.makeInputJSON(
                meeting: meeting,
                previousSnapshot: currentSnapshot,
                newSegments: newSegments
            )
            let dto = try await service.analyze(
                instructions: AnalysisSystemPrompt.text,
                inputJSON: inputJSON
            )
            // 证据校验：引用不存在片段的项在构建时过滤
            let validIds = Set(meeting.segments.map(\.id))
            let aliasMap = Dictionary(
                meeting.participants.map { ($0.cloudAlias, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            let throughMs = newSegments.map(\.endMs).max() ?? cursor
            let snapshot = AnalysisSnapshotBuilder.build(
                from: dto,
                validSegmentIds: validIds,
                participantIdByAlias: aliasMap,
                version: (currentSnapshot?.version ?? 0) + 1,
                analyzedThroughMs: throughMs
            )
            // 原子替换（UI 整版更新，不逐字段闪烁）
            meeting.snapshots.append(snapshot)
            currentSnapshot = snapshot
            meeting.lastAnalyzedSegmentEndMs = throughMs
            let now = nowMs()
            trigger.noteSuccess(atMs: now)
            lastSuccessAt = Date(timeIntervalSince1970: TimeInterval(now) / 1000)
            lastErrorDescription = nil
            lastFailureKind = nil
            AppLog.logInfo(AppLog.analysis, LogSanitizer.formatEvent(
                "analysis_ok",
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "segments=\(newSegments.count) insights=\(snapshot.insights.count) topics=\(snapshot.topics.count)"
            ))
            onSnapshotUpdated?()
        } catch let error as AnalysisAPIError {
            trigger.noteFailure(atMs: nowMs())
            lastErrorDescription = error.localizedDescription
            lastFailureKind = Self.failureKind(of: error)
            if error == .unauthorized {
                // 401 语义收窄：仅暂停分析（Kimi）自身，分人与本地不受影响
                state = .suspended(reason: "分析 Key 无效（401）。请在设置中检查「分析（Kimi）Key」，说话人识别不受影响。")
            } else if error == .missingAPIKey {
                state = .suspended(reason: "未配置分析（Kimi）Key。本地录音与转写正常。")
            }
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "analysis_failed",
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: String(describing: error)
            ))
        } catch {
            trigger.noteFailure(atMs: nowMs())
            lastErrorDescription = "分析失败，已保留上一版结果"
            lastFailureKind = "未知错误"
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "analysis_failed",
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: String(describing: type(of: error))
            ))
        }

        // 分析期间有新内容到达：立即合并到下一次请求
        if pendingFire {
            pendingFire = false
            let now = nowMs()
            // 新内容仍需过防抖；若已过则立即补一轮
            if trigger.readyToFire(atMs: now) {
                await fire()
            }
        }
    }
}
