import Foundation
import AVFoundation

/// 本地同声转写控制器（阶段 2）：
/// 驱动 LocalTranscriptionServicing，把结果流经 TranscriptReconciler 合并为
/// 无重复的片段序列；会议时间轴由 RecordingTimeline 逆映射得到。
/// 临时片段只用于界面展示，不写库；最终片段写入会议并触发持久化。
@MainActor
@Observable
final class LocalTranscriptionController {
    /// 转写运行状态
    enum RunState: Equatable {
        case idle
        case running
        case unavailable(String) // 附真实原因
    }

    private let service: any LocalTranscriptionServicing

    /// 可用性检查结果（界面展示与开始拦截共用）
    private(set) var availability: TranscriptionAvailability?
    private(set) var runState: RunState = .idle
    /// 当前片段序列（最终 + 尾部临时）
    private(set) var segments: [TranscriptSegment] = []
    /// 脱敏错误描述（界面提示）
    private(set) var lastErrorDescription: String?

    private var reconciler = TranscriptReconciler()
    private var collectTask: Task<Void, Never>?
    private var timelineProvider: (() -> RecordingTimeline?)?
    private weak var meeting: Meeting?
    /// 最终片段入库回调（由视图层注入持久化）
    var onFinalSegment: (() -> Void)?
    /// 新最终片段到达回调（阶段 4：驱动分析调度器）
    var onNewFinalSegment: (() -> Void)?

    /// 语言资源下载进度（nil = 未在下载；0…1）
    private(set) var assetDownloadProgress: Double?
    /// 下载失败的脱敏提示（展示并可重试）
    private(set) var assetInstallError: String?

    /// 当前是否可一键下载中文语言资源（supported 但未安装）
    var canInstallChineseAssets: Bool {
        availability?.assetState == .supportedNotInstalled && assetDownloadProgress == nil
    }

    /// 一键下载中文语言资源（实施计划：AssetInventory 下载路径）。
    /// 完成后自动重新检查可用性并清除不可用状态；失败显示真实错误可重试。
    func installChineseAssets() async {
        guard availability?.assetState == .supportedNotInstalled else { return }
        assetDownloadProgress = 0
        assetInstallError = nil
        do {
            try await service.installMandarinAssets { [weak self] value in
                Task { @MainActor in
                    self?.assetDownloadProgress = value
                }
            }
            assetDownloadProgress = nil
            // 完成后自动重查（强制刷新，绕过 TTL 缓存）：恢复 ready 则清除不可用状态
            let updated = await checkAvailability(forceRefresh: true)
            if updated.isReady {
                runState = .idle
                lastErrorDescription = nil
            }
        } catch {
            assetDownloadProgress = nil
            assetInstallError = "下载失败：\(error.localizedDescription)"
            AppLog.transcription.error("\(LogSanitizer.formatEvent("asset_install_failed", error: String(describing: type(of: error))))")
        }
    }

    init(service: any LocalTranscriptionServicing,
         availabilityCacheTTL: TimeInterval = 30) {
        self.service = service
        self.availabilityCachePolicy = AvailabilityCachePolicy(ttl: availabilityCacheTTL)
    }

    // MARK: - 可用性检查（TTL 缓存，杜绝热路径反复探测）

    /// 控制器侧可用性缓存有效期（秒；init 可注入，测试用小值）
    static let defaultAvailabilityCacheTTL: TimeInterval = 30
    private let availabilityCachePolicy: AvailabilityCachePolicy
    private var availabilityCheckedAt: Date?

    /// 检查普通话可用性（会中界面 onAppear 与开始录音前调用）。
    /// TTL 内直接复用缓存；forceRefresh 用于下载完成后强制重查。
    @discardableResult
    func checkAvailability(forceRefresh: Bool = false) async -> TranscriptionAvailability {
        if !forceRefresh,
           let checkedAt = availabilityCheckedAt,
           availabilityCachePolicy.shouldReuse(checkedAt: checkedAt, now: Date()),
           let availability {
            return availability
        }
        let result = await service.checkMandarinAvailability()
        availability = result
        availabilityCheckedAt = Date()
        if !result.isReady, runState == .idle {
            runState = .unavailable(result.issueSummary ?? "本地转写不可用")
        }
        return result
    }

    /// 开始转写（录音已启动后调用）。
    /// 上下文词汇 = 专业词汇 + 参会人姓名与角色（仅改善识别，不改写原意）。
    func start(
        for meeting: Meeting,
        timelineProvider: @escaping () -> RecordingTimeline?
    ) async throws {
        let current: TranscriptionAvailability
        if let availability {
            current = availability
        } else {
            current = await checkAvailability()
        }
        guard current.isReady else {
            let reason = current.issueSummary ?? "本地转写不可用"
            runState = .unavailable(reason)
            throw LocalTranscriptionError.notReady(current.issues)
        }

        self.meeting = meeting
        self.timelineProvider = timelineProvider
        reconciler.reset()
        segments = []

        let contextual = meeting.glossary
            + meeting.participants.map(\.displayName)
            + meeting.participants.map(\.role).filter { !$0.isEmpty }
        do {
            try await service.startSession(contextualStrings: contextual)
        } catch {
            lastErrorDescription = error.localizedDescription
            runState = .unavailable(error.localizedDescription)
            AppLog.transcription.error("\(LogSanitizer.formatEvent("transcription_start_failed", error: String(describing: type(of: error))))")
            throw error
        }

        runState = .running
        collectTask = Task { [weak self] in
            guard let self else { return }
            for await result in service.results {
                self.consume(result)
            }
        }
    }

    /// 送入一个采集缓冲（非隔离入口：采集实时线程直接调用，
    /// 经 Sendable 盒子转发给转写服务；服务无会话时自动丢弃）。
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        let boxed = SendableAudioBuffer(buffer)
        Task { [service] in
            await service.feed(boxed.buffer)
        }
    }

    /// 结束转写：丢弃尾部临时片段（最终片段已即时入库）
    func finish() async {
        collectTask?.cancel()
        collectTask = nil
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        await service.finishSession()
        reconciler.dropProvisional()
        publishSegments()
        runState = .idle
    }

    /// 立即取消（录音异常中止等场景）
    func cancel() async {
        collectTask?.cancel()
        collectTask = nil
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        await service.cancelSession()
        reconciler.reset()
        segments = []
        runState = .idle
    }

    // MARK: - 结果消费与发布节流

    /// 临时结果发布最小间隔（秒）：volatile 结果高频到达，
    /// 每次到达都全量发布会驱动整个转写面板重建（渲染风暴回归的根因），
    /// 因此节流为最多每秒数次；最终结果永远立即发布。
    static let provisionalPublishInterval: TimeInterval = 0.25

    /// 片段序列发布次数（回归测试观测口：验证单位时间发布上限）
    private(set) var segmentsPublishCount = 0

    private var lastProvisionalPublishAt: Date = .distantPast
    private var pendingFlushTask: Task<Void, Never>?

    /// 发布当前片段序列（唯一出口，计数可观测）。
    /// 差分保护：内容签名无变化时跳过，不触发任何界面更新（渲染风暴根治点）。
    private func publishSegments() {
        let all = reconciler.allSegments
        var hasher = Hasher()
        for segment in all {
            hasher.combine(segment.id)
            hasher.combine(segment.startMs)
            hasher.combine(segment.endMs)
            hasher.combine(segment.text)
            hasher.combine(segment.state)
            hasher.combine(segment.source)
            hasher.combine(segment.isStarred)
            hasher.combine(segment.participantId)
        }
        let signature = hasher.finalize()
        guard signature != lastPublishedSignature else {
            PerfCounters.increment(.segmentsNoChangeSkip)
            return
        }
        lastPublishedSignature = signature
        segments = all
        segmentsPublishCount += 1
        PerfCounters.incrementWithSignpost(.segmentsPublish)
    }

    private var lastPublishedSignature: Int?

    /// 临时结果：立即发布或登记一次尾随刷新（节流）
    private func publishProvisionalThrottled() {
        let now = Date()
        if now.timeIntervalSince(lastProvisionalPublishAt) >= Self.provisionalPublishInterval {
            lastProvisionalPublishAt = now
            publishSegments()
            return
        }
        // 间隔内：只登记一次尾随刷新，保证最终文字一致
        PerfCounters.increment(.provisionalSuppressed)
        guard pendingFlushTask == nil else { return }
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.provisionalPublishInterval * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.lastProvisionalPublishAt = Date()
            self.pendingFlushTask = nil
            self.publishSegments()
        }
    }

    /// 应用云端确认片段（阶段 3：由 DiarizationController 调用，作为唯一合并点）。
    /// 人工已修订片段不被覆盖（TranscriptReconciler 保证）。
    func applyCloudSegment(
        wallStartMs: Int64,
        wallEndMs: Int64,
        text: String,
        participantId: UUID?,
        remoteSpeakerLabel: String?
    ) {
        let outcome = reconciler.applyCloudFinal(
            startMs: wallStartMs,
            endMs: wallEndMs,
            text: text,
            participantId: participantId,
            remoteSpeakerLabel: remoteSpeakerLabel
        )
        switch outcome {
        case .inserted(let segment):
            meeting?.segments.append(segment)
            onFinalSegment?()
            onNewFinalSegment?()
        case .updated:
            // 就地更新的片段已在会议片段数组中（同一实例）
            onFinalSegment?()
            onNewFinalSegment?()
        case .skippedManual, .duplicate, .discardedEmpty:
            break
        }
        PerfCounters.increment(.cloudSegmentApplied)
        publishSegments()
    }

    /// 会话结束时把 reconciler 的最终片段与会议片段对齐（不新增，仅刷新视图）
    func refreshSegments() {
        publishSegments()
    }

    private func consume(_ result: LocalTranscriptResult) {
        // 音频流时间 → 会议时间轴（含暂停区间的还原）
        let timeline = timelineProvider?()
        let startWallMs = timeline?.wallMs(forEffectiveAudioMs: result.startAudioMs) ?? result.startAudioMs
        let endWallMs = timeline?.wallMs(forEffectiveAudioMs: result.endAudioMs) ?? result.endAudioMs

        if result.isFinal {
            PerfCounters.increment(.finalResult)
            let outcome = reconciler.applyFinal(
                startMs: startWallMs,
                endMs: endWallMs,
                text: result.text
            )
            if case .inserted(let segment) = outcome {
                meeting?.segments.append(segment)
                onFinalSegment?()
                onNewFinalSegment?()
            }
            // 最终结果：立即发布（并取消未执行的尾随刷新）
            pendingFlushTask?.cancel()
            pendingFlushTask = nil
            publishSegments()
        } else {
            PerfCounters.increment(.provisionalResult)
            _ = reconciler.upsertProvisional(
                startMs: startWallMs,
                endMs: endWallMs,
                text: result.text
            )
            // 临时结果：节流发布（渲染风暴防护）
            publishProvisionalThrottled()
        }
    }
}
