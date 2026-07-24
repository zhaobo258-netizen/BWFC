import Foundation

/// V2 通用分析调度控制器（阶段 D，03 §9.2 / §10.3）：
/// 触发/防抖/串行单请求/游标/失败保留上一版/快照原子替换——与 V1 同纪律；
/// 权威数据为 Project（scenario、speakers、segments、analysisSnapshots）。
@MainActor
@Observable
final class ConversationAnalysisController {
    enum AnalysisState: Equatable {
        case idle
        case analyzing
        case suspended(reason: String) // 401 / 未配置 Key
    }

    private let service: any ConversationAnalysisServicing
    private let nowMs: () -> Int64

    /// 当前生效快照（UI 整版替换）
    private(set) var currentSnapshot: ConversationAnalysisSnapshot?
    private(set) var state: AnalysisState = .idle
    private(set) var lastSuccessAt: Date?
    private(set) var lastErrorDescription: String?
    private(set) var lastFailureKind: String?

    private var trigger: AnalysisTrigger
    private var analyzing = false
    private var pendingFire = false
    private weak var project: Project?
    /// 快照更新后的持久化回调（视图/流水线注入）
    var onSnapshotUpdated: (() -> Void)?
    /// 模型建议场景被采纳后的回调（UI 刷新场景标签）
    var onScenarioSuggested: (() -> Void)?

    init(
        service: any ConversationAnalysisServicing,
        triggerConfig: AnalysisTrigger = AnalysisTrigger(),
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.service = service
        self.nowMs = nowMs
        self.trigger = triggerConfig
    }

    // MARK: - 会话

    func attach(to project: Project) {
        self.project = project
        currentSnapshot = project.analysisSnapshots.max(by: { $0.version < $1.version })
    }

    /// 新最终片段到达（转写控制器回调）
    func noteNewFinalSegment() {
        trigger.noteNewSegment(atMs: nowMs())
    }

    /// 周期驱动（界面定时器）：满足条件且防抖已过则发起
    func tick() async {
        guard project != nil else { return }
        if case .suspended = state { return }
        let now = nowMs()
        guard trigger.readyToFire(atMs: now) else { return }
        await fire()
    }

    /// 结束/导入完成后：用完整最终转写一次性生成「最终分析」
    func generateFinalAnalysis() async {
        if case .suspended = state { return }
        await fire(forceFullTranscript: true)
    }

    /// API Key 修复后恢复
    func resumeAfterKeyFix() {
        if case .suspended = state { state = .idle }
    }

    /// 状态栏文案（诚实化，与 V1 同口径）
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

    var hasRecentFailure: Bool { lastFailureKind != nil }

    // MARK: - 执行

    private func fire(forceFullTranscript: Bool = false) async {
        guard let project else { return }
        if analyzing {
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

        // 只消费最终/人工修订片段；增量按游标（上一版快照的 analyzedThroughMs）
        let cursor = currentSnapshot?.analyzedThroughMs ?? 0
        let eligible = project.segments.filter { $0.state == .final || $0.state == .edited }
        let newSegments: [TranscriptSegment]
        if forceFullTranscript {
            newSegments = eligible.sorted { $0.startMs < $1.startMs }
        } else {
            newSegments = eligible
                .filter { $0.endMs > cursor }
                .sorted { $0.startMs < $1.startMs }
        }
        guard !newSegments.isEmpty else {
            if !forceFullTranscript {
                trigger.noteSuccess(atMs: nowMs()) // 无新内容：避免空转
            }
            return
        }

        do {
            let inputJSON = try ConversationAnalysisInputAssembler.makeInputJSON(
                project: project,
                previousSnapshot: forceFullTranscript ? nil : currentSnapshot,
                newSegments: newSegments
            )
            let dto = try await service.analyze(
                instructions: ConversationAnalysisPrompt.text(scenario: effectiveScenario(of: project)),
                inputJSON: inputJSON
            )
            let validIds = Set(project.segments.map(\.id))
            let aliasMap = Dictionary(
                project.speakers.map { ($0.cloudAlias, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            let throughMs = newSegments.map(\.endMs).max() ?? cursor
            let snapshot = ConversationAnalysisSnapshotBuilder.build(
                from: dto,
                validSegmentIds: validIds,
                speakerIdByAlias: aliasMap,
                version: (currentSnapshot?.version ?? 0) + 1,
                analyzedThroughMs: throughMs
            )
            // 原子替换 + 落库容器
            project.analysisSnapshots.append(snapshot)
            currentSnapshot = snapshot
            // 场景自动建议：用户未手选且模型给出建议时采纳（用户随时可改）
            if !project.scenarioWasUserSelected,
               let suggested = snapshot.detectedScenario,
               project.scenario != suggested {
                project.scenario = suggested
                onScenarioSuggested?()
            }
            let now = nowMs()
            trigger.noteSuccess(atMs: now)
            lastSuccessAt = Date(timeIntervalSince1970: TimeInterval(now) / 1000)
            lastErrorDescription = nil
            lastFailureKind = nil
            AppLog.logInfo(AppLog.analysis, LogSanitizer.formatEvent(
                "conversation_analysis_ok",
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "segments=\(newSegments.count) items=\(snapshot.items.count)"
            ))
            onSnapshotUpdated?()
        } catch let error as AnalysisAPIError {
            trigger.noteFailure(atMs: nowMs())
            lastErrorDescription = error.localizedDescription
            lastFailureKind = Self.failureKind(of: error)
            if error == .unauthorized {
                state = .suspended(reason: "分析 Key 无效（401）。请在设置中检查「分析（Kimi）Key」。")
            } else if error == .missingAPIKey {
                state = .suspended(reason: "分析 Key 未配置。在设置中填写后即可启用 AI 分析。")
            }
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "conversation_analysis_failed",
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: String(describing: error)
            ))
        } catch {
            trigger.noteFailure(atMs: nowMs())
            lastErrorDescription = error.localizedDescription
            lastFailureKind = "未知错误"
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "conversation_analysis_failed", error: String(describing: type(of: error))
            ))
        }

        if pendingFire {
            pendingFire = false
            await fire()
        }
    }

    /// 生效场景：用户手选优先；否则用项目当前（可能来自上一版自动建议）
    private func effectiveScenario(of project: Project) -> ProjectScenario? {
        project.scenario
    }

    private static func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

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
}
