import Foundation

/// 云端说话人识别编排（阶段 3，实施计划 7.4 / 10.1 / 11.2）：
/// 分片产出 → 上传 → 结果合并 → 失败退避 → 队列持久化（重启恢复）。
/// 合并本身委托给 LocalTranscriptionController（唯一合并点，保证本地/云端/人工一致）。
@MainActor
@Observable
final class DiarizationController {
    /// 云端识别状态（顶部状态栏显示）
    enum CloudState: Equatable {
        /// 空闲（无待处理分片）
        case idle
        /// 处理中（含队列等待数）
        case working(pending: Int)
        /// 云端暂停：401（本地录音与转写继续，修复后可重试）
        case suspended(reason: String)
        /// 分人 Key 未配置（灰色显示；绝不借用分析 Key 发请求）
        case unconfigured
    }

    private let diarization: any DiarizationServicing
    /// 会议开始时冻结；设置变化只影响下一次创建的控制器。
    private let configurationSnapshot: DiarizationProviderConfiguration
    private let fileStore: MeetingFileStore
    private let transcriptController: LocalTranscriptionController
    private let retryPolicy: RetryPolicy
    private let planner: ChunkPlanner
    /// 分人 provider 的 Key 存储（判断是否可发请求）
    private let keyStore: CloudAPIKeyStore
    /// 可注入的延迟函数（测试用，避免真实等待）
    private let sleep: (Int64) async -> Void

    /// 分片队列（持久化到 chunks/queue.json）
    private(set) var queue: [ChunkQueueEntry] = []
    private(set) var cloudState: CloudState = .idle
    /// 最近一次云端确认时间（顶部状态栏显示）
    private(set) var lastConfirmedAt: Date?

    private var nextChunkIndex = 0
    private var queueStore: ChunkQueueStore?
    private weak var meeting: Meeting?
    private var timelineProvider: (() -> RecordingTimeline?)?
    private var mapper = SpeakerMapper(participants: [])
    private var processingTask: Task<Void, Never>?
    private var draining = false
    private var suspensionCause: SuspensionCause?

    private enum SuspensionCause: Equatable {
        case providerCredential
        case knownSpeakerConfiguration
        case providerConfigurationMismatch
    }

    private struct UploadedChunk {
        var result: DiarizationChunkResult
        /// 本次请求真实发送给 provider 的 known speaker 代号。
        var knownAliases: Set<String>
    }

    /// 队列变化回调（视图层刷新）
    var onQueueChanged: (() -> Void)?

    init(
        diarization: any DiarizationServicing,
        fileStore: MeetingFileStore,
        transcriptController: LocalTranscriptionController,
        retryPolicy: RetryPolicy = RetryPolicy(),
        planner: ChunkPlanner = ChunkPlanner(),
        keyStore: CloudAPIKeyStore = CloudAPIKeyStore.store(for: .diarization),
        configurationSnapshot: DiarizationProviderConfiguration = DiarizationProviderConfiguration(),
        sleep: @escaping (Int64) async -> Void = { ms in
            try? await Task.sleep(for: .milliseconds(ms))
        }
    ) {
        self.diarization = diarization
        self.fileStore = fileStore
        self.transcriptController = transcriptController
        self.retryPolicy = retryPolicy
        self.planner = planner
        self.keyStore = keyStore
        self.configurationSnapshot = configurationSnapshot
        self.sleep = sleep
    }

    // MARK: - 会话

    /// 启动云端识别编排（录音已开始）。
    /// 恢复既有队列（App 重启后补传）；分人 Key 未配置时进入 unconfigured
    /// （灰色显示，绝不借用分析 Key 发请求；说话人显示为待识别，可手动标注）。
    func start(for meeting: Meeting, timelineProvider: @escaping () -> RecordingTimeline?) {
        self.meeting = meeting
        self.timelineProvider = timelineProvider
        self.mapper = SpeakerMapper(participants: meeting.participants)
        suspensionCause = nil

        let store = ChunkQueueStore(fileURL: fileStore.chunkQueueFileURL(for: meeting.id))
        queueStore = store
        if let restored = try? store.load(), !restored.isEmpty {
            // 崩溃时处于 uploading 的条目按失败处理，允许重试
            queue = restored.map { entry in
                var entry = entry
                if entry.status == .uploading { entry.status = .failed }
                if entry.providerConfigurationFingerprint.isEmpty,
                   entry.provider == configurationSnapshot.selectedProvider {
                    entry.providerConfigurationFingerprint = configurationSnapshot.fingerprint
                }
                return entry
            }
            nextChunkIndex = (queue.map(\.index).max() ?? -1) + 1
            // 恢复后补传：检查分片文件是否还在（已成功条目缺失文件则丢弃）
            queue = queue.filter { entry in
                guard entry.needsProcessing else { return true }
                return FileManager.default.fileExists(
                    atPath: fileStore.chunksDirectory(for: meeting.id)
                        .appending(path: entry.fileName).path
                )
            }
            try? store.save(queue)
        }

        if queue.contains(where: {
            $0.needsProcessing
                && ($0.provider != configurationSnapshot.selectedProvider
                    || $0.providerConfigurationFingerprint != configurationSnapshot.fingerprint)
        }) {
            suspensionCause = .providerConfigurationMismatch
            cloudState = .suspended(
                reason: "待处理分片属于另一套云端配置。请恢复原配置后重开会议；系统不会静默改投其他 provider。"
            )
            return
        }

        // 未配置分人 Key：零请求，仅保留本地能力
        guard isProviderConfigured else {
            cloudState = .unconfigured
            return
        }
        cloudState = .idle
        kickProcessing()
    }

    /// 说话人列表变化后刷新映射（工作台「说话人」面板编辑后调用；
    /// 后续分片按新映射解析，已确认片段不回改）。
    /// 手工指认的标签映射跨重建保留（09 号计划需求 2）。
    func refreshKnownSpeakers() {
        guard let meeting else { return }
        let manual = mapper.manualAssignments
        var rebuilt = SpeakerMapper(participants: meeting.participants)
        let validIds = Set(meeting.participants.map(\.id))
        rebuilt.restoreManualAssignments(manual.filter { validIds.contains($0.value) })
        mapper = rebuilt
        guard suspensionCause == .knownSpeakerConfiguration else { return }
        suspensionCause = nil
        guard isProviderConfigured else {
            cloudState = .unconfigured
            return
        }
        cloudState = .idle
        kickProcessing()
    }

    /// 手工指认云端标签归属（09 号计划需求 2）。
    /// generic label 已按 chunk 加作用域，仅回填该次请求的同标签片段；
    /// 后续分片要等声纹样本作为 known alias 真实发送后才稳定映射。
    func assignRemoteLabel(_ label: String, to participantId: UUID) {
        mapper.assign(remoteLabel: label, to: participantId)
    }

    /// 停止编排（不等待队列完成；结束会议请用 finishAndDrain）
    func cancel() {
        processingTask?.cancel()
        processingTask = nil
    }

    // MARK: - 分片产出

    /// 按当前音频进度产出新分片（录音中由界面定时器周期调用）
    func pollProgress() {
        guard canProduceChunkFiles() else { return }
        guard let meeting, meeting.status == .recording,
              let timeline = timelineProvider?() else { return }
        let uptoAudioMs = timeline.effectiveAudioMs(at: Date())
        produceChunks(uptoAudioMs: uptoAudioMs)
    }

    /// 按给定音频进度产出新分片（纯逻辑入口，测试可直接驱动）
    func produceChunks(uptoAudioMs: Int64) {
        guard canProduceChunkFiles() else { return }
        guard let meeting, let timeline = timelineProvider?() else { return }
        let windows = planner.pendingWindows(uptoAudioMs: uptoAudioMs, nextIndex: nextChunkIndex)
        for window in windows {
            enqueue(window: window, meeting: meeting, timeline: timeline)
        }
        if !windows.isEmpty {
            kickProcessing()
        }
    }

    /// 结束会议：切尾部残缺分片并入队，等待队列处理完毕（finalizing）。
    /// 返回时队列要么全部成功，要么进入 suspended / awaitingUserRetry。
    /// - Parameter uptoAudioMs: 尾部截止的音频进度；nil 表示按当前时间线计算（测试可注入）
    func finishAndDrain(uptoAudioMs: Int64? = nil) async {
        // 未配置时连尾片也不切盘；start 仍然保留会议与时间线上下文。
        guard canProduceChunkFiles() else { return }
        if let meeting {
            let audioMs = uptoAudioMs ?? timelineProvider?()?.effectiveAudioMs(at: Date()) ?? 0
            if audioMs > 0, let timeline = timelineProvider?(),
               let tail = planner.finalWindow(uptoAudioMs: audioMs, nextIndex: nextChunkIndex) {
                enqueue(window: tail, meeting: meeting, timeline: timeline)
            }
        }
        draining = true
        kickProcessing()
        // 等待直到没有可处理条目（或暂停）；轮询间隔用真实延迟，退避才走注入
        while draining {
            if case .suspended = cloudState { break }
            if case .unconfigured = cloudState { break }
            let hasWork = queue.contains { $0.needsProcessing }
            if !hasWork { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        draining = false
    }

    /// 产出一个分片：从完整录音提取文件 → 入队 → 持久化
    private func enqueue(window: ChunkWindow, meeting: Meeting, timeline: RecordingTimeline) {
        do {
            guard let audioURL = try fileStore.audioFileURL(for: meeting) else { return }
            let chunksDir = try fileStore.ensureChunksDirectory(for: meeting.id)
            let fileName = MeetingFileStore.chunkFileName(index: window.index)
            let chunkURL = chunksDir.appending(path: fileName)
            try AudioChunkExtractor.extract(
                from: audioURL,
                startMs: window.audioStartMs,
                endMs: window.audioEndMs,
                to: chunkURL
            )
            let entry = ChunkQueueEntry(
                index: window.index,
                audioStartMs: window.audioStartMs,
                audioEndMs: window.audioEndMs,
                wallStartMs: timeline.wallMs(forEffectiveAudioMs: window.audioStartMs),
                wallEndMs: timeline.wallMs(forEffectiveAudioMs: window.audioEndMs),
                fileName: fileName,
                provider: configurationSnapshot.selectedProvider,
                providerConfigurationFingerprint: configurationSnapshot.fingerprint,
                status: .pending,
                attemptCount: 0
            )
            queue.append(entry)
            nextChunkIndex = window.index + 1
            persistQueue()
        } catch {
            // 提取失败：只记录脱敏错误，不阻断录音
            AppLog.logError(AppLog.diarization, LogSanitizer.formatEvent("chunk_extract_failed", error: String(describing: type(of: error))))
        }
    }

    // MARK: - 上传处理

    /// 触发处理循环（幂等）
    private func kickProcessing() {
        guard processingTask == nil else { return }
        if case .suspended = cloudState { return }
        if case .unconfigured = cloudState { return }
        processingTask = Task { [weak self] in
            await self?.processQueue()
        }
    }

    private func processQueue() async {
        defer {
            processingTask = nil
            updateCloudState()
        }
        while !Task.isCancelled {
            guard let entryIndex = queue.firstIndex(where: {
                $0.status == .pending || $0.status == .failed
            }) else { return }

            var entry = queue[entryIndex]
            // 失败重试：先退避
            if entry.status == .failed {
                let delay = retryPolicy.delayMs(beforeAttempt: entry.attemptCount + 1)
                if delay > 0 { await sleep(delay) }
            }
            entry.status = .uploading
            queue[entryIndex] = entry
            persistQueue()

            do {
                AppLog.logInfo(
                    AppLog.diarization,
                    LogSanitizer.formatEvent(
                        "chunk_upload_started",
                        error: "index=\(entry.index),file=\(entry.fileName)"
                    )
                )
                let startedAt = Date()
                let uploaded = try await upload(entry: entry)
                let uploadDurationMs = Int(startedAt.timeIntervalSinceNow.magnitude * 1_000)
                AppLog.logInfo(
                    AppLog.diarization,
                    LogSanitizer.formatEvent(
                        "chunk_upload_succeeded",
                        durationMs: uploadDurationMs,
                        statusCode: 200,
                        error: "index=\(entry.index),segments=\(uploaded.result.segments.count)"
                    )
                )
                try applyResult(
                    uploaded.result,
                    knownAliases: uploaded.knownAliases,
                    for: entry
                )
                queue[entryIndex].status = .succeeded
                // 上传成功且结果已持久化后删除临时分片文件（实施计划 7.4）
                if let meeting {
                    try? FileManager.default.removeItem(
                        at: fileStore.chunksDirectory(for: meeting.id)
                            .appending(path: entry.fileName)
                    )
                }
                lastConfirmedAt = Date()
            } catch let error as DiarizationAPIError {
                AppLog.logWarning(
                    AppLog.diarization,
                    LogSanitizer.formatEvent(
                        "chunk_upload_failed",
                        statusCode: nil,
                        error: "index=\(entry.index),reason=\(error.localizedDescription)"
                    )
                )
                handleUploadError(error, entryIndex: entryIndex)
                if case .suspended = cloudState { return }
                if queue[entryIndex].status == .awaitingUserRetry { continue }
            } catch {
                AppLog.logError(
                    AppLog.diarization,
                    LogSanitizer.formatEvent(
                        "chunk_upload_failed",
                        error: "index=\(entry.index),reason=\(String(describing: error))"
                    )
                )
                handleUploadError(.network, entryIndex: entryIndex)
            }
            persistQueue()
        }
    }

    /// 调用云端识别
    private func upload(entry: ChunkQueueEntry) async throws -> UploadedChunk {
        guard let meeting else { throw DiarizationAPIError.network }
        let chunkURL = fileStore.chunksDirectory(for: meeting.id)
            .appending(path: entry.fileName)
        var speakers: [KnownSpeakerReference] = []
        let supportsKnownSpeakers: Bool
        if case .supported = diarization.knownSpeakerMatchingCapability {
            supportsKnownSpeakers = true
        } else {
            supportsKnownSpeakers = false
        }
        for participant in meeting.participants where supportsKnownSpeakers {
            guard let relativePath = participant.voiceReferencePath else { continue }
            let alias = participant.cloudAlias
            guard let durationMs = participant.voiceReferenceDurationMs,
                  (VoiceSampleValidator.minDurationMs...VoiceSampleValidator.maxDurationMs)
                    .contains(durationMs) else {
                throw DiarizationAPIError.invalidKnownSpeakerSample(
                    alias: alias,
                    issue: .invalidDuration(actualMs: participant.voiceReferenceDurationMs)
                )
            }
            let url: URL
            do {
                url = try fileStore.absoluteURL(forRelativePath: relativePath)
            } catch {
                throw DiarizationAPIError.invalidKnownSpeakerSample(
                    alias: alias,
                    issue: .invalidPath
                )
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw DiarizationAPIError.invalidKnownSpeakerSample(
                    alias: alias,
                    issue: .fileMissingOrUnreadable
                )
            }
            speakers.append(KnownSpeakerReference(alias: alias, sampleURL: url))
        }
        guard speakers.count <= KnownSpeakerReference.maximumCount else {
            throw DiarizationAPIError.tooManyKnownSpeakers(
                maximum: KnownSpeakerReference.maximumCount,
                actual: speakers.count
            )
        }
        let result = try await diarization.transcribeChunk(
            at: chunkURL,
            knownSpeakers: speakers
        )
        return UploadedChunk(result: result, knownAliases: Set(speakers.map(\.alias)))
    }

    /// 云端相对时间 → 会议时间轴 → 交给合并点
    private func applyResult(
        _ result: DiarizationChunkResult,
        knownAliases: Set<String>,
        for entry: ChunkQueueEntry
    ) throws {
        for segment in result.segments {
            let storedLabel: String?
            let participantId: UUID?

            if let label = segment.speakerLabel, !label.isEmpty,
               knownAliases.contains(label),
               let knownParticipantId = mapper.participantId(forKnownAlias: label) {
                // 只有本次确实发送过声纹样本的代号才能跨分片稳定映射。
                storedLabel = label
                participantId = knownParticipantId
            } else if let label = segment.speakerLabel, !label.isEmpty {
                // generic label 不保证跨请求一致，必须按 chunk 隔离。
                let scopedLabel = SpeakerMapper.scopedRemoteLabel(
                    label,
                    chunkIndex: entry.index
                )
                storedLabel = scopedLabel
                mapper.register(remoteLabel: scopedLabel)
                if case .known(let id) = mapper.resolve(remoteLabel: scopedLabel) {
                    participantId = id
                } else {
                    participantId = nil
                }
            } else {
                storedLabel = nil
                participantId = nil
            }
            transcriptController.applyCloudSegment(
                wallStartMs: entry.wallStartMs + segment.startMs,
                wallEndMs: entry.wallStartMs + segment.endMs,
                text: segment.text,
                participantId: participantId,
                remoteSpeakerLabel: storedLabel
            )
        }
    }

    /// 上传失败分类处理（实施计划 11.2；401 语义收窄到分人 provider 自身）
    private func handleUploadError(_ error: DiarizationAPIError, entryIndex: Int) {
        let attemptCount = queue[entryIndex].attemptCount
        switch error {
        case .unauthorized:
            // 分人 Key 无效：仅暂停分人 provider，本地录音与分析继续
            queue[entryIndex].status = .pending
            suspensionCause = .providerCredential
            cloudState = .suspended(reason: "分人 Key 无效（401）。请在设置中检查「分人 Key」，分析（Kimi）不受影响。")
            AppLog.logError(AppLog.diarization, LogSanitizer.formatEvent("cloud_suspended", statusCode: 401))
        case .missingAPIKey:
            // 运行中 Key 被删除：视为未配置，零请求
            queue[entryIndex].status = .pending
            suspensionCause = nil
            cloudState = .unconfigured
        case .credentialAccessRequired:
            queue[entryIndex].status = .pending
            suspensionCause = .providerCredential
            cloudState = .suspended(
                reason: "App 更新后需要重新保存分人 Key。本地录音与转写不受影响。"
            )
        case .tooManyKnownSpeakers(let maximum, let actual):
            queue[entryIndex].status = .pending
            suspensionCause = .knownSpeakerConfiguration
            AppLog.logWarning(
                AppLog.diarization,
                LogSanitizer.formatEvent(
                    "chunk_error_too_many_speakers",
                    error: "index=\(entryIndex),max=\(maximum),actual=\(actual),attempt=\(attemptCount)"
                )
            )
            cloudState = .suspended(
                reason: "声纹配置暂停：已配置 \(actual) 个声纹样本，单次分人最多支持 \(maximum) 个，本次未上传。修正后将自动继续。"
            )
        case .invalidKnownSpeakerSample:
            queue[entryIndex].status = .pending
            suspensionCause = .knownSpeakerConfiguration
            cloudState = .suspended(
                reason: "声纹配置暂停：\(error.localizedDescription)。请修正或移除该样本，保存后将自动继续。"
            )
        case .knownSpeakerMatchingUnsupported:
            queue[entryIndex].status = .pending
            suspensionCause = .providerConfigurationMismatch
            cloudState = .suspended(
                reason: "当前分人服务不支持历史人物声纹匹配。本地录音与匿名分人继续可用，请切换支持已知说话人的服务后重试。"
            )
        case .rateLimited, .serverError, .network:
            queue[entryIndex].attemptCount += 1
            if retryPolicy.shouldRetry(afterFailures: queue[entryIndex].attemptCount) {
                queue[entryIndex].status = .failed
                AppLog.logWarning(AppLog.diarization, LogSanitizer.formatEvent("chunk_retry_scheduled", statusCode: nil, error: String(describing: error)))
            } else {
                // 超过上限：待用户重试，不得无限循环
                queue[entryIndex].status = .awaitingUserRetry
                AppLog.logError(AppLog.diarization, LogSanitizer.formatEvent("chunk_awaiting_user_retry"))
            }
        case .clientError, .invalidResponse:
            // 请求/响应问题：不重试，直接待用户处理
            queue[entryIndex].status = .awaitingUserRetry
            AppLog.logWarning(
                AppLog.diarization,
                LogSanitizer.formatEvent(
                    "chunk_error_non_retriable",
                    error: "attempt=\(attemptCount),index=\(entryIndex),reason=\(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - 用户操作

    /// 用户手动重试「待重试」分片（重置失败计数）
    func retryAwaitingUserChunks() {
        guard suspensionCause != .providerConfigurationMismatch else { return }
        guard isProviderConfigured else {
            cloudState = .unconfigured
            return
        }
        for index in queue.indices where queue[index].status == .awaitingUserRetry {
            queue[index].status = .pending
            queue[index].attemptCount = 0
        }
        if case .suspended = cloudState {
            suspensionCause = nil
            cloudState = .idle
        }
        if case .unconfigured = cloudState { cloudState = .idle }
        persistQueue()
        kickProcessing()
    }

    /// API Key 修复后恢复云端处理
    func resumeAfterKeyFix() {
        guard isProviderConfigured else {
            cloudState = .unconfigured
            return
        }
        guard suspensionCause != .knownSpeakerConfiguration,
              suspensionCause != .providerConfigurationMismatch else { return }
        if case .suspended = cloudState {
            suspensionCause = nil
            cloudState = .idle
        }
        if case .unconfigured = cloudState { cloudState = .idle }
        kickProcessing()
    }

    /// 待用户重试的分片数
    var awaitingUserRetryCount: Int {
        queue.filter { $0.status == .awaitingUserRetry }.count
    }

    /// 待识别说话人标签（用于手动映射 UI）
    var unknownSpeakerLabels: [String] {
        var seen: [String] = []
        for segment in transcriptController.segments where segment.participantId == nil {
            if let label = segment.remoteSpeakerLabel, !seen.contains(label) {
                seen.append(label)
            }
        }
        return seen
    }

    /// 未知标签的展示名（「待识别 A/B」）
    func displayName(forRemoteLabel label: String?) -> String {
        mapper.resolve(remoteLabel: label).displayText
    }

    // MARK: - 内部

    /// 未配置时不产生任何云端专用分片文件。
    /// 运行中 Key 被删除时也在下一次 poll 立即收敛为 unconfigured。
    private func canProduceChunkFiles() -> Bool {
        guard isProviderConfigured else {
            cloudState = .unconfigured
            return false
        }
        if case .unconfigured = cloudState {
            return false
        }
        return true
    }

    private var isProviderConfigured: Bool {
        switch configurationSnapshot.selectedProvider {
        case .disabled:
            return false
        case .openAICompatible:
            return configurationSnapshot.isValid && keyStore.hasConfiguredKey
        case .volcengine:
            return configurationSnapshot.isValid && keyStore.hasConfiguredKey
        }
    }

    private func updateCloudState() {
        if case .suspended = cloudState { return }
        if case .unconfigured = cloudState { return }
        let pending = queue.filter { $0.needsProcessing }.count
        cloudState = pending > 0 ? .working(pending: pending) : .idle
        onQueueChanged?()
    }

    private func persistQueue() {
        guard let queueStore else { return }
        try? queueStore.save(queue)
        updateCloudState()
    }
}

private extension SpeakerMapper.Resolution {
    var displayText: String {
        switch self {
        case .known: return ""
        case .unknown(let name): return name
        }
    }
}
