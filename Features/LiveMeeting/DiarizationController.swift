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
        /// 队列已恢复但未在处理（重开录音的只读展示；含待处理与待重试数）
        case restored(pending: Int, awaitingRetry: Int)
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
    private var processingGeneration = 0
    private(set) var queuePersistenceError: String?

    enum DrainOutcome: Equatable {
        case completed
        case deferred
        case cancelled
    }
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

    /// 回看已有录音也恢复分组；不读取凭据、不启动转写或上传队列。
    /// 同时只读恢复持久化队列用于展示（15 号计划 F01：重开录音失败可见、可重试）。
    func attach(to meeting: Meeting) {
        if self.meeting?.id != meeting.id {
            mapper = SpeakerMapper(participants: [])
        }
        self.meeting = meeting
        transcriptController.attach(to: meeting)
        rebuildSpeakerMapper()
        restoreQueueForDisplay(for: meeting)
    }

    /// 回看项目时只读恢复持久化队列：不保存、不启动上传。
    /// 计数与重试入口按这份数据工作；真正继续处理走 retryAwaitingUserChunks。
    private func restoreQueueForDisplay(for meeting: Meeting) {
        let store = ChunkQueueStore(fileURL: fileStore.chunkQueueFileURL(for: meeting.id))
        guard let restored = try? store.load(), !restored.isEmpty else { return }
        queueStore = store
        // 崩溃时处于 uploading 的条目按失败展示（与 start 的恢复语义一致）
        queue = restored.map { entry in
            var entry = entry
            if entry.status == .uploading { entry.status = .failed }
            if entry.providerConfigurationFingerprint.isEmpty,
               entry.provider == configurationSnapshot.selectedProvider {
                entry.providerConfigurationFingerprint = configurationSnapshot.fingerprint
            }
            return entry
        }
        // 需要处理但分片文件已不存在的条目无法重试，不参与计数
        queue = queue.filter { entry in
            guard entry.needsProcessing else { return true }
            return FileManager.default.fileExists(
                atPath: fileStore.chunksDirectory(for: meeting.id)
                    .appending(path: entry.fileName).path
            )
        }
        updateCloudState()
    }

    private func rebuildSpeakerMapper() {
        guard let meeting else { return }
        var rebuilt = SpeakerMapper(participants: meeting.participants)
        let validIDs = Set(meeting.participants.map(\.id))
        var confirmedAssignments: [String: Set<UUID>] = [:]
        let previouslyRegistered = mapper.registeredUnknownLabels
        for segment in meeting.segments.sorted(by: {
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            if $0.endMs != $1.endMs { return $0.endMs < $1.endMs }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            guard let label = segment.remoteSpeakerLabel, !label.isEmpty else { continue }
            if segment.participantId == nil || previouslyRegistered.contains(label) {
                rebuilt.register(remoteLabel: label)
            }
            if segment.speakerWasUserConfirmed == true,
               let participantID = segment.participantId, validIDs.contains(participantID) {
                confirmedAssignments[label, default: []].insert(participantID)
            }
        }
        let manual = mapper.manualAssignments.filter { validIDs.contains($0.value) }
        rebuilt.restoreManualAssignments(manual.filter { confirmedAssignments[$0.key] == nil })
        for (label, participants) in confirmedAssignments where participants.count == 1 {
            if let participantID = participants.first {
                rebuilt.assign(remoteLabel: label, to: participantID)
            }
        }
        mapper = rebuilt
    }

    /// 启动云端识别编排（录音已开始）。
    /// 恢复既有队列（App 重启后补传）；分人 Key 未配置时进入 unconfigured
    /// （灰色显示，绝不借用分析 Key 发请求；说话人显示为待识别，可手动标注）。
    func start(for meeting: Meeting, timelineProvider: @escaping () -> RecordingTimeline?) {
        cancel()
        mapper = SpeakerMapper(participants: [])
        attach(to: meeting)
        self.timelineProvider = timelineProvider
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
            if let existingAudioDurationMs = timelineProvider()?.initialEffectiveAudioOffsetMs,
               existingAudioDurationMs > 0,
               let tail = queue.max(by: { $0.index < $1.index }),
               tail.audioEndMs <= existingAudioDurationMs,
               tail.audioEndMs - tail.audioStartMs < planner.chunkLengthMs {
                queue.removeAll { $0.index == tail.index }
                try? FileManager.default.removeItem(
                    at: fileStore.chunksDirectory(for: meeting.id)
                        .appending(path: tail.fileName)
                )
            }
            nextChunkIndex = (queue.map(\.index).max() ?? -1) + 1
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
        rebuildSpeakerMapper()
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
    /// generic label 在有相邻分片重叠证据时会沿用本地稳定标签；
    /// 因此一次人工指认可同时回填旧片段，并约束后续能证明同一人的分片。
    func assignRemoteLabel(_ label: String, to participantId: UUID) {
        mapper.assign(remoteLabel: label, to: participantId)
    }

    /// 不等待 Provider 取消确认；保留队列和音频，下次可显式重试。
    func cancel() {
        processingGeneration += 1
        draining = false
        processingTask?.cancel()
        processingTask = nil
        for index in queue.indices where queue[index].status == .uploading {
            queue[index].status = .pending
        }
        persistQueue()
    }

    // MARK: - 分片产出

    /// 按当前音频进度产出新分片（录音中由界面定时器周期调用）
    func pollProgress() {
        guard canProduceChunkFiles() else { return }
        guard let meeting, meeting.status == .recording,
              let timeline = timelineProvider?() else { return }
        let timelineAudioMs = timeline.effectiveAudioMs(at: Date())
        let uptoAudioMs = min(timelineAudioMs, recordedAudioMs)
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

    /// 尾片先入队落盘，等待有限时间；到期保留未完成分片供显式重试。
    /// Provider 不响应取消时也不会卡住录音收尾，迟到结果由代际检查拒绝。
    @discardableResult
    func finishAndDrain(
        uptoAudioMs: Int64? = nil,
        timeout: Duration = .seconds(8)
    ) async -> DrainOutcome {
        guard canProduceChunkFiles() else {
            return queue.contains { $0.status != .succeeded } || queuePersistenceError != nil
                ? .deferred : .completed
        }
        if let meeting {
            let timelineAudioMs = timelineProvider?().map { $0.effectiveAudioMs(at: Date()) } ?? 0
            let audioMs = min(uptoAudioMs ?? timelineAudioMs, recordedAudioMs)
            if audioMs > 0, let timeline = timelineProvider?(),
               let tail = planner.finalWindow(uptoAudioMs: audioMs, nextIndex: nextChunkIndex) {
                enqueue(window: tail, meeting: meeting, timeline: timeline)
            }
        }
        draining = true
        kickProcessing()
        let generation = processingGeneration
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while draining, generation == processingGeneration {
            if Task.isCancelled {
                cancel()
                return .cancelled
            }
            if case .suspended = cloudState { break }
            if case .unconfigured = cloudState { break }
            if !queue.contains(where: { $0.needsProcessing }) { break }
            if ContinuousClock.now >= deadline {
                cancel()
                return .deferred
            }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch {
                cancel()
                return .cancelled
            }
        }
        guard generation == processingGeneration else { return .cancelled }
        draining = false
        return queue.contains { $0.status != .succeeded } || queuePersistenceError != nil
            ? .deferred : .completed
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
        processingGeneration += 1
        let generation = processingGeneration
        processingTask = Task { [weak self] in
            await self?.processQueue(generation: generation)
        }
    }

    private func processQueue(generation: Int) async {
        defer {
            if generation == processingGeneration {
                processingTask = nil
                updateCloudState()
            }
        }
        while !Task.isCancelled, generation == processingGeneration {
            guard let entryIndex = queue.firstIndex(where: {
                $0.status == .pending || $0.status == .failed
            }) else { return }

            var entry = queue[entryIndex]
            // 失败重试：先退避
            if entry.status == .failed {
                let delay = retryPolicy.delayMs(beforeAttempt: entry.attemptCount + 1)
                if delay > 0 { await sleep(delay) }
            }
            guard !Task.isCancelled, generation == processingGeneration else { return }
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
                guard !Task.isCancelled, generation == processingGeneration else { return }
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
                // 成功后清掉上一次失败的诊断残留，避免误读
                queue[entryIndex].lastFailureKind = nil
                queue[entryIndex].lastOrderID = nil
                queue[entryIndex].lastProviderStatus = nil
                // 上传成功且结果已持久化后删除临时分片文件（实施计划 7.4）
                if let meeting {
                    try? FileManager.default.removeItem(
                        at: fileStore.chunksDirectory(for: meeting.id)
                            .appending(path: entry.fileName)
                    )
                }
                lastConfirmedAt = Date()
            } catch let error as DiarizationAPIError {
                guard !Task.isCancelled, generation == processingGeneration else { return }
                AppLog.logWarning(
                    AppLog.diarization,
                    LogSanitizer.formatEvent(
                        "chunk_upload_failed",
                        statusCode: nil,
                        error: "index=\(entry.index),reason=\(error.localizedDescription)"
                    )
                )
                handleUploadError(error, entryIndex: entryIndex)
                persistQueue()
                if case .suspended = cloudState { return }
                if queue[entryIndex].status == .awaitingUserRetry { continue }
            } catch {
                guard !Task.isCancelled, generation == processingGeneration else { return }
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
            speakers.append(KnownSpeakerReference(
                alias: alias,
                sampleURL: url,
                iflytekFeatureID: participant.iflytekFeatureID
            ))
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
        let transmittedSpeakers: [KnownSpeakerReference]
        if configurationSnapshot.selectedProvider == .iflytek {
            transmittedSpeakers = speakers.filter {
                $0.iflytekFeatureID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
            }
        } else {
            transmittedSpeakers = speakers
        }
        return UploadedChunk(
            result: result,
            knownAliases: Set(transmittedSpeakers.map(\.alias))
        )
    }

    /// 云端相对时间 → 会议时间轴 → 交给合并点
    private func applyResult(
        _ result: DiarizationChunkResult,
        knownAliases: Set<String>,
        for entry: ChunkQueueEntry
    ) throws {
        let timeline = timelineProvider?()
        let mappedSegments = result.segments.map { segment in
            var mapped = segment
            let start = entry.audioStartMs + segment.startMs
            let end = entry.audioStartMs + segment.endMs
            mapped.startMs = (timeline?.wallMs(forEffectiveAudioMs: start)
                ?? HistoricalSpeakerRelabeler.wallMs(
                    forAudioMs: start, pauseIntervals: meeting?.pauseIntervals ?? []
                )) - entry.wallStartMs
            mapped.endMs = (timeline?.wallMs(forEffectiveAudioMs: end)
                ?? HistoricalSpeakerRelabeler.wallMs(
                    forAudioMs: end, pauseIntervals: meeting?.pauseIntervals ?? []
                )) - entry.wallStartMs
            return mapped
        }
        let stitchedLabels = SpeakerMapper.stitchedRemoteLabels(
            for: mappedSegments.filter {
                guard let label = $0.speakerLabel else { return false }
                return !knownAliases.contains(label)
            },
            chunkIndex: entry.index,
            wallStartMs: entry.wallStartMs,
            existingSegments: meeting?.segments ?? []
        )
        for segment in mappedSegments {
            let storedLabel: String?
            let participantId: UUID?

            if let label = segment.speakerLabel, !label.isEmpty,
               knownAliases.contains(label),
               let knownParticipantId = mapper.participantId(forKnownAlias: label) {
                // 只有本次确实发送过声纹样本的代号才能跨分片稳定映射。
                storedLabel = label
                participantId = knownParticipantId
            } else if let label = segment.speakerLabel, !label.isEmpty {
                let stableLabel = stitchedLabels[label]
                    ?? SpeakerMapper.scopedRemoteLabel(
                        label,
                        chunkIndex: entry.index
                    )
                storedLabel = stableLabel
                mapper.register(remoteLabel: stableLabel)
                if case .known(let id) = mapper.resolve(remoteLabel: stableLabel) {
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
    /// 每个分支都记录脱敏失败类别（15 号计划 F07）；订单关联只由 provider 提供。
    private func handleUploadError(_ error: DiarizationAPIError, entryIndex: Int) {
        let attemptCount = queue[entryIndex].attemptCount
        switch error {
        case .unauthorized:
            // 分人 Key 无效：仅暂停分人 provider，本地录音与分析继续
            queue[entryIndex].status = .pending
            queue[entryIndex].lastFailureKind = "auth"
            suspensionCause = .providerCredential
            cloudState = .suspended(reason: "分人 Key 无效（401）。请在设置中检查「分人 Key」，分析（Kimi）不受影响。")
            AppLog.logError(AppLog.diarization, LogSanitizer.formatEvent("cloud_suspended", statusCode: 401))
        case .missingAPIKey:
            // 运行中 Key 被删除：视为未配置，零请求
            queue[entryIndex].status = .pending
            queue[entryIndex].lastFailureKind = "unconfigured"
            suspensionCause = nil
            cloudState = .unconfigured
        case .credentialAccessRequired:
            queue[entryIndex].status = .pending
            queue[entryIndex].lastFailureKind = "credential"
            suspensionCause = .providerCredential
            cloudState = .suspended(
                reason: "App 更新后需要重新保存分人 Key。本地录音与转写不受影响。"
            )
        case .tooManyKnownSpeakers(let maximum, let actual):
            queue[entryIndex].status = .pending
            queue[entryIndex].lastFailureKind = "too_many_speakers"
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
            queue[entryIndex].lastFailureKind = "known_speaker_sample"
            suspensionCause = .knownSpeakerConfiguration
            cloudState = .suspended(
                reason: "声纹配置暂停：\(error.localizedDescription)。请修正或移除该样本，保存后将自动继续。"
            )
        case .knownSpeakerMatchingUnsupported:
            queue[entryIndex].status = .pending
            queue[entryIndex].lastFailureKind = "matching_unsupported"
            suspensionCause = .providerConfigurationMismatch
            cloudState = .suspended(
                reason: "当前分人服务不支持历史人物声纹匹配。本地录音与匿名分人继续可用，请切换支持已知说话人的服务后重试。"
            )
        case .rateLimited, .serverError, .network:
            queue[entryIndex].lastFailureKind = switch error {
            case .rateLimited: "rate_limited"
            case .serverError: "server"
            default: "network"
            }
            queue[entryIndex].attemptCount += 1
            if retryPolicy.shouldRetry(afterFailures: queue[entryIndex].attemptCount) {
                queue[entryIndex].status = .failed
                AppLog.logWarning(AppLog.diarization, LogSanitizer.formatEvent("chunk_retry_scheduled", statusCode: nil, error: String(describing: error)))
            } else {
                // 超过上限：待用户重试，不得无限循环
                queue[entryIndex].status = .awaitingUserRetry
                AppLog.logError(AppLog.diarization, LogSanitizer.formatEvent("chunk_awaiting_user_retry"))
            }
        case .clientError(let statusCode):
            queue[entryIndex].status = .awaitingUserRetry
            queue[entryIndex].lastFailureKind = "client"
            queue[entryIndex].lastProviderStatus = statusCode
            AppLog.logWarning(
                AppLog.diarization,
                LogSanitizer.formatEvent(
                    "chunk_error_non_retriable",
                    error: "attempt=\(attemptCount),index=\(entryIndex),reason=\(error.localizedDescription)"
                )
            )
        case .invalidResponse:
            queue[entryIndex].status = .awaitingUserRetry
            queue[entryIndex].lastFailureKind = "invalid_response"
            AppLog.logWarning(
                AppLog.diarization,
                LogSanitizer.formatEvent(
                    "chunk_error_non_retriable",
                    error: "attempt=\(attemptCount),index=\(entryIndex),reason=\(error.localizedDescription)"
                )
            )
        case .providerError(let code, _):
            queue[entryIndex].status = .awaitingUserRetry
            queue[entryIndex].lastFailureKind = "provider_\(code)"
            AppLog.logWarning(
                AppLog.diarization,
                LogSanitizer.formatEvent(
                    "chunk_error_non_retriable",
                    error: "attempt=\(attemptCount),index=\(entryIndex),reason=\(error.localizedDescription)"
                )
            )
        case .orderFailed(let orderID, let status, let failType, _):
            // 官方 failType 分类（15 号计划 B.1）：上传/识别失败可退避重试，
            // 转码、时长、静音等输入或配置问题待用户处理，不盲目重试。
            queue[entryIndex].lastOrderID = orderID
            queue[entryIndex].lastProviderStatus = status
            let kind = DiarizationAPIError.orderFailureKind(failType)
            queue[entryIndex].lastFailureKind = kind.rawValue
            switch kind {
            case .upload, .recognition:
                queue[entryIndex].attemptCount += 1
                if retryPolicy.shouldRetry(afterFailures: queue[entryIndex].attemptCount) {
                    queue[entryIndex].status = .failed
                    AppLog.logWarning(AppLog.diarization, LogSanitizer.formatEvent(
                        "chunk_retry_scheduled",
                        error: "index=\(entryIndex),failType=\(failType.map(String.init) ?? "nil")"
                    ))
                } else {
                    queue[entryIndex].status = .awaitingUserRetry
                    AppLog.logError(AppLog.diarization, LogSanitizer.formatEvent("chunk_awaiting_user_retry"))
                }
            case .transcode, .durationLimit, .durationMismatch, .silence, .unknown:
                queue[entryIndex].status = .awaitingUserRetry
                AppLog.logWarning(AppLog.diarization, LogSanitizer.formatEvent(
                    "chunk_order_failed",
                    error: "index=\(entryIndex),status=\(status),failType=\(failType.map(String.init) ?? "nil")"
                ))
            }
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

    /// 恢复队列中仍待处理（pending/failed）的分片数（重开录音展示用）
    var pendingChunkCount: Int {
        queue.filter { $0.status == .pending || $0.status == .failed }.count
    }

    /// 待重试分片的脱敏失败类别摘要（如"转码失败×3"），无待重试时为 nil
    var awaitingUserRetrySummary: String? {
        let entries = queue.filter { $0.status == .awaitingUserRetry }
        guard !entries.isEmpty else { return nil }
        let counts = Dictionary(grouping: entries, by: { entry -> String in
            guard let kind = entry.lastFailureKind else { return DiarizationAPIError.orderFailureKind(nil).displayName }
            return DiarizationAPIError.OrderFailureKind(rawValue: kind)?.displayName
                ?? { switch kind {
                case "auth": return "分人凭证无效"
                case "unconfigured": return "分人未配置"
                case "credential": return "凭证需要重新保存"
                case "too_many_speakers": return "声纹数量超限"
                case "known_speaker_sample": return "声纹样本无效"
                case "matching_unsupported": return "服务不支持声纹匹配"
                case "rate_limited": return "云端限流"
                case "server": return "云端服务失败"
                case "network": return "网络连接失败"
                case "client": return "请求被拒绝"
                case "invalid_response": return "响应无法解析"
                default: return kind.hasPrefix("provider_") ? "服务拒绝（\(kind.dropFirst(9))）" : kind
                } }()
        }).mapValues(\.count)
        return counts
            .sorted { $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: "、")
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

    /// 当前录音真实时长（毫秒）。若录音文件暂时不可读，返回上限值避免阻断分片处理。
    private var recordedAudioMs: Int64 {
        guard let meeting,
              let audioURL = try? fileStore.audioFileURL(for: meeting) else {
            return Int64.max
        }
        return (try? AudioChunkExtractor.durationMs(of: audioURL)) ?? Int64.max
    }

    private var isProviderConfigured: Bool {
        switch configurationSnapshot.selectedProvider {
        case .disabled:
            return false
        case .openAICompatible:
            return configurationSnapshot.isValid && keyStore.hasConfiguredKey
        case .volcengine:
            return configurationSnapshot.isValid && keyStore.hasConfiguredKey
        case .iflytek:
            return configurationSnapshot.isValid && keyStore.hasConfiguredKey
        case .localSherpaOnnx:
            // 本地引擎 v1 只做整场识别（13 号文档 §3.3）；会中分片保持未配置零请求
            return false
        }
    }

    private func updateCloudState() {
        if case .suspended = cloudState { return }
        if case .unconfigured = cloudState { return }
        let outstanding = queue.filter { $0.needsProcessing }.count
        let awaiting = queue.filter { $0.status == .awaitingUserRetry }.count
        if processingTask != nil, outstanding > 0 {
            cloudState = .working(pending: outstanding)
        } else if outstanding > 0 || awaiting > 0 {
            // 有队列工作但没有活跃处理循环：恢复展示态，不谎称"识别中"
            cloudState = .restored(pending: outstanding, awaitingRetry: awaiting)
        } else {
            cloudState = .idle
        }
        onQueueChanged?()
    }

    @discardableResult
    private func persistQueue() -> Bool {
        guard let queueStore else { return true }
        do {
            try queueStore.save(queue)
            queuePersistenceError = nil
            updateCloudState()
            return true
        } catch {
            queuePersistenceError = "分人待处理队列保存失败，原录音仍保留，可重新识别说话人。"
            AppLog.logError(AppLog.diarization, LogSanitizer.formatEvent(
                "chunk_queue_save_failed", error: String(describing: type(of: error))
            ))
            updateCloudState()
            return false
        }
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
