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
    private var pendingForceFullTranscript = false
    private var speakerContextRevision: UInt64 = 0
    private var pendingSpeakerContextRevisions: [UUID: UInt64] = [:]
    private var lastSpeakerContextChangeAtMs: Int64?
    private weak var project: Project?
    /// 快照更新后的持久化回调（视图/流水线注入）
    var onSnapshotUpdated: (() -> Void)?
    /// 人工确认说话人时的同步持久化边界；失败必须回滚内存快照。
    var persistManualSpeakerConfirmation: (() throws -> Void)?
    /// 全局词库（已知名词表；环境注入，进入系统指令帮助还原同音误写）
    var knownTermsProvider: () -> [String] = { [] }
    /// 实时「识别中」尾巴片段（09 号计划需求 3-②；工作台对实时录音会话注入）：
    /// 追加进分析输入作补充上下文，让实时总结/开花不再等云端说话人确认。
    /// 触发计数与游标仍只认最终片段——尾巴不驱动触发、不推进 analyzedThroughMs。
    var provisionalTailProvider: () -> TranscriptSegment? = { nil }
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

    /// 旧片段的说话人/角色修正后，将它重新纳入下一次增量分析。
    func noteSpeakerContextChanged(segmentIDs: [UUID]) {
        guard let project else { return }
        let eligibleIds = Set(project.segments.lazy
            .filter { $0.state == .final || $0.state == .edited }
            .map(\.id))
        let changedIds = Set(segmentIDs).intersection(eligibleIds)
        guard !changedIds.isEmpty else { return }

        for id in changedIds {
            speakerContextRevision += 1
            pendingSpeakerContextRevisions[id] = speakerContextRevision
        }
        lastSpeakerContextChangeAtMs = nowMs()
    }

    /// 用户确认某条分析内容归属谁：只改分析卡片，不把多条证据静默回写成同一说话人。
    /// 以新快照持久化，避免下次打开或下一轮增量又丢失这次人工确认。
    @discardableResult
    func confirmSubjectSpeaker(itemID: UUID, speakerID: UUID) -> Bool {
        guard let project,
              project.speakers.contains(where: { $0.id == speakerID }),
              let snapshot = currentSnapshot,
              let itemIndex = snapshot.items.firstIndex(where: { $0.id == itemID }) else {
            return false
        }
        let previousSnapshots = project.analysisSnapshots
        let previousOverrides = project.analysisSpeakerOverrides
        let previousCurrentSnapshot = currentSnapshot
        var items = snapshot.items
        let confirmedItem = items[itemIndex]
        items[itemIndex].subjectSpeakerId = speakerID
        items[itemIndex].lastUpdatedAt = Date()
        let override = AnalysisSpeakerOverride(
            category: confirmedItem.category,
            evidenceSegmentIds: confirmedItem.evidenceSegmentIds,
            speakerId: speakerID
        )
        project.analysisSpeakerOverrides.removeAll { existing in
            existing.category == override.category
                && existing.evidenceSegmentIds == override.evidenceSegmentIds
        }
        project.analysisSpeakerOverrides.append(override)
        let version = max(
            snapshot.version + 1,
            (project.analysisSnapshots.map(\.version).max() ?? 0) + 1
        )
        let updated = ConversationAnalysisSnapshot(
            version: version,
            analyzedThroughMs: snapshot.analyzedThroughMs,
            headline: snapshot.headline,
            detectedScenario: snapshot.detectedScenario,
            scenarioConfidence: snapshot.scenarioConfidence,
            items: items
        )
        currentSnapshot = updated
        project.analysisSnapshots.append(updated)
        project.analysisSnapshots = ConversationAnalysisSnapshotRetention.keepingMostRecent(
            project.analysisSnapshots
        )
        do {
            if let persistManualSpeakerConfirmation {
                try persistManualSpeakerConfirmation()
            } else {
                onSnapshotUpdated?()
            }
            lastErrorDescription = nil
            return true
        } catch {
            project.analysisSnapshots = previousSnapshots
            project.analysisSpeakerOverrides = previousOverrides
            currentSnapshot = previousCurrentSnapshot
            lastErrorDescription = "说话人确认未保存"
            return false
        }
    }

    /// 周期驱动（界面定时器）：满足条件且防抖已过则发起
    func tick() async {
        guard project != nil else { return }
        if case .suspended = state { return }
        let now = nowMs()
        guard analysisReady(atMs: now) else { return }
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
            pendingForceFullTranscript = pendingForceFullTranscript || forceFullTranscript
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
        let observedNewSegmentCount = trigger.newSegmentCount
        let observedSpeakerContextRevisions = pendingSpeakerContextRevisions
        let speakerContextSegmentIds = Set(observedSpeakerContextRevisions.keys)
        let cursor = currentSnapshot?.analyzedThroughMs ?? 0
        let eligible = project.segments.filter { $0.state == .final || $0.state == .edited }
        let newSegments: [TranscriptSegment]
        if forceFullTranscript {
            newSegments = eligible.sorted { $0.startMs < $1.startMs }
        } else {
            newSegments = eligible
                .filter { $0.endMs > cursor || speakerContextSegmentIds.contains($0.id) }
                .sorted { $0.startMs < $1.startMs }
        }
        guard !newSegments.isEmpty else {
            if !forceFullTranscript {
                trigger.noteSuccess(
                    atMs: nowMs(),
                    consumingNewSegmentCount: observedNewSegmentCount
                ) // 无新内容：避免空转
            }
            clearProcessedSpeakerContext(observedSpeakerContextRevisions)
            await firePendingRequestIfReady()
            return
        }
        // 实时尾巴：只作为补充上下文（最终分析不带——完整定稿转写已覆盖）
        let provisionalTail = forceFullTranscript ? nil : provisionalTailProvider()

        do {
            let inputJSON = try ConversationAnalysisInputAssembler.makeInputJSON(
                project: project,
                previousSnapshot: forceFullTranscript ? nil : currentSnapshot,
                newSegments: newSegments,
                provisionalTail: provisionalTail
            )
            let dto = try await service.analyze(
                instructions: ConversationAnalysisPrompt.text(
                    scenario: effectiveScenario(of: project),
                    knownTerms: knownTermsProvider()
                ),
                inputJSON: inputJSON
            )
            // 临时尾巴的 id 当轮有效（模型可引用为证据）；定稿后旧 id 悬空，
            // 相关条目在下一轮增量中被重写，证据校验/种子候选对悬空 id 已有防护
            var validIds = Set(project.segments.map(\.id))
            if let provisionalTail { validIds.insert(provisionalTail.id) }
            let aliasMap = Dictionary(
                project.speakers.map { ($0.cloudAlias, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            let throughMs = max(cursor, newSegments.map(\.endMs).max() ?? cursor)
            let snapshot = ConversationAnalysisSnapshotBuilder.build(
                from: dto,
                validSegmentIds: validIds,
                speakerIdByAlias: aliasMap,
                version: (currentSnapshot?.version ?? 0) + 1,
                analyzedThroughMs: throughMs,
                speakerOverrides: project.analysisSpeakerOverrides
            )
            // 原子替换 + 落库容器
            project.analysisSnapshots.append(snapshot)
            project.analysisSnapshots = ConversationAnalysisSnapshotRetention.keepingMostRecent(
                project.analysisSnapshots
            )
            currentSnapshot = snapshot
            // 场景自动建议：用户未手选且模型给出建议时采纳（用户随时可改）
            if !project.scenarioWasUserSelected,
               let suggested = snapshot.detectedScenario,
               project.scenario != suggested {
                project.scenario = suggested
                onScenarioSuggested?()
            }
            let now = nowMs()
            trigger.noteSuccess(
                atMs: now,
                consumingNewSegmentCount: observedNewSegmentCount
            )
            clearProcessedSpeakerContext(observedSpeakerContextRevisions)
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
                state = .suspended(
                    reason: "当前分析模型凭证无效或模型未开通（401）。请在设置中检查连接与模型。"
                )
            } else if error == .missingAPIKey {
                state = .suspended(reason: "AI 未连接。在设置中连接分析模型后即可启用。")
            } else if error == .credentialAccessRequired {
                state = .suspended(
                    reason: "App 更新后需要重新连接 AI；请前往设置登录或保存 API Key。录音与转写不受影响。"
                )
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

        await firePendingRequestIfReady()
    }

    private func analysisReady(atMs now: Int64) -> Bool {
        if trigger.readyToFire(atMs: now) { return true }
        guard !pendingSpeakerContextRevisions.isEmpty,
              let lastSpeakerContextChangeAtMs else { return false }
        return now - lastSpeakerContextChangeAtMs >= trigger.debounceMs
            && trigger.failureBackoffSatisfied(atMs: now)
    }

    private func clearProcessedSpeakerContext(_ processed: [UUID: UInt64]) {
        for (id, revision) in processed where pendingSpeakerContextRevisions[id] == revision {
            pendingSpeakerContextRevisions.removeValue(forKey: id)
        }
        if pendingSpeakerContextRevisions.isEmpty {
            lastSpeakerContextChangeAtMs = nil
        }
    }

    private func firePendingRequestIfReady() async {
        guard pendingFire else { return }
        let forceFullTranscript = pendingForceFullTranscript
        pendingFire = false
        pendingForceFullTranscript = false

        if case .suspended = state { return }
        guard forceFullTranscript || analysisReady(atMs: nowMs()) else { return }

        analyzing = false
        if case .analyzing = state { state = .idle }
        await fire(forceFullTranscript: forceFullTranscript)
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
        case .credentialAccessRequired: return "凭证需重连"
        case .clientError: return "请求被拒"
        }
    }
}
