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
        /// 云端暂停：401 或未配置 Key（本地录音与转写继续，修复后可重试）
        case suspended(reason: String)
    }

    private let diarization: any DiarizationServicing
    private let fileStore: MeetingFileStore
    private let transcriptController: LocalTranscriptionController
    private let retryPolicy: RetryPolicy
    private let planner: ChunkPlanner
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

    /// 队列变化回调（视图层刷新）
    var onQueueChanged: (() -> Void)?

    init(
        diarization: any DiarizationServicing,
        fileStore: MeetingFileStore,
        transcriptController: LocalTranscriptionController,
        retryPolicy: RetryPolicy = RetryPolicy(),
        planner: ChunkPlanner = ChunkPlanner(),
        sleep: @escaping (Int64) async -> Void = { ms in
            try? await Task.sleep(for: .milliseconds(ms))
        }
    ) {
        self.diarization = diarization
        self.fileStore = fileStore
        self.transcriptController = transcriptController
        self.retryPolicy = retryPolicy
        self.planner = planner
        self.sleep = sleep
    }

    // MARK: - 会话

    /// 启动云端识别编排（录音已开始）。
    /// 恢复既有队列（App 重启后补传）；云端未配置时进入 suspended 并仅保留本地能力。
    func start(for meeting: Meeting, timelineProvider: @escaping () -> RecordingTimeline?) {
        self.meeting = meeting
        self.timelineProvider = timelineProvider
        self.mapper = SpeakerMapper(participants: meeting.participants)

        let store = ChunkQueueStore(fileURL: fileStore.chunkQueueFileURL(for: meeting.id))
        queueStore = store
        if let restored = try? store.load(), !restored.isEmpty {
            // 崩溃时处于 uploading 的条目按失败处理，允许重试
            queue = restored.map { entry in
                var entry = entry
                if entry.status == .uploading { entry.status = .failed }
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

        cloudState = .idle
        kickProcessing()
    }

    /// 停止编排（不等待队列完成；结束会议请用 finishAndDrain）
    func cancel() {
        processingTask?.cancel()
        processingTask = nil
    }

    // MARK: - 分片产出

    /// 按当前音频进度产出新分片（录音中由界面定时器周期调用）
    func pollProgress() {
        guard let meeting, meeting.status == .recording,
              let timeline = timelineProvider?() else { return }
        let uptoAudioMs = timeline.effectiveAudioMs(at: Date())
        produceChunks(uptoAudioMs: uptoAudioMs)
    }

    /// 按给定音频进度产出新分片（纯逻辑入口，测试可直接驱动）
    func produceChunks(uptoAudioMs: Int64) {
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
                status: .pending,
                attemptCount: 0
            )
            queue.append(entry)
            nextChunkIndex = window.index + 1
            persistQueue()
        } catch {
            // 提取失败：只记录脱敏错误，不阻断录音
            AppLog.diarization.error("\(LogSanitizer.formatEvent("chunk_extract_failed", error: String(describing: type(of: error))))")
        }
    }

    // MARK: - 上传处理

    /// 触发处理循环（幂等）
    private func kickProcessing() {
        guard processingTask == nil else { return }
        if case .suspended = cloudState { return }
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
                let result = try await upload(entry: entry)
                try applyResult(result, for: entry)
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
                handleUploadError(error, entryIndex: entryIndex)
                if case .suspended = cloudState { return }
                if queue[entryIndex].status == .awaitingUserRetry { continue }
            } catch {
                handleUploadError(.network, entryIndex: entryIndex)
            }
            persistQueue()
        }
    }

    /// 调用云端识别
    private func upload(entry: ChunkQueueEntry) async throws -> DiarizationChunkResult {
        guard let meeting else { throw DiarizationAPIError.network }
        let chunkURL = fileStore.chunksDirectory(for: meeting.id)
            .appending(path: entry.fileName)
        let speakers: [KnownSpeakerReference] = meeting.participants.compactMap { participant in
            guard let relativePath = participant.voiceReferencePath,
                  let url = try? fileStore.absoluteURL(forRelativePath: relativePath),
                  FileManager.default.fileExists(atPath: url.path),
                  !participant.cloudAlias.isEmpty else { return nil }
            return KnownSpeakerReference(alias: participant.cloudAlias, sampleURL: url)
        }
        return try await diarization.transcribeChunk(at: chunkURL, knownSpeakers: speakers)
    }

    /// 云端相对时间 → 会议时间轴 → 交给合并点
    private func applyResult(_ result: DiarizationChunkResult, for entry: ChunkQueueEntry) throws {
        for segment in result.segments {
            let resolution = mapper.resolve(remoteLabel: segment.speakerLabel)
            let participantId: UUID?
            if case .known(let id) = resolution {
                participantId = id
            } else {
                participantId = nil
            }
            transcriptController.applyCloudSegment(
                wallStartMs: entry.wallStartMs + segment.startMs,
                wallEndMs: entry.wallStartMs + segment.endMs,
                text: segment.text,
                participantId: participantId,
                remoteSpeakerLabel: segment.speakerLabel
            )
        }
    }

    /// 上传失败分类处理（实施计划 11.2）
    private func handleUploadError(_ error: DiarizationAPIError, entryIndex: Int) {
        switch error {
        case .unauthorized, .missingAPIKey:
            // Key 无效：云端模块暂停，本地录音继续；不消耗重试次数
            queue[entryIndex].status = .pending
            cloudState = .suspended(reason: error.localizedDescription)
            AppLog.diarization.error("\(LogSanitizer.formatEvent("cloud_suspended", statusCode: 401))")
        case .rateLimited, .serverError, .network:
            queue[entryIndex].attemptCount += 1
            if retryPolicy.shouldRetry(afterFailures: queue[entryIndex].attemptCount) {
                queue[entryIndex].status = .failed
                AppLog.diarization.warning("\(LogSanitizer.formatEvent("chunk_retry_scheduled", statusCode: nil, error: String(describing: error)))")
            } else {
                // 超过上限：待用户重试，不得无限循环
                queue[entryIndex].status = .awaitingUserRetry
                AppLog.diarization.error("\(LogSanitizer.formatEvent("chunk_awaiting_user_retry"))")
            }
        case .clientError, .invalidResponse:
            // 请求/响应问题：不重试，直接待用户处理
            queue[entryIndex].status = .awaitingUserRetry
        }
    }

    // MARK: - 用户操作

    /// 用户手动重试「待重试」分片（重置失败计数）
    func retryAwaitingUserChunks() {
        for index in queue.indices where queue[index].status == .awaitingUserRetry {
            queue[index].status = .pending
            queue[index].attemptCount = 0
        }
        if case .suspended = cloudState { cloudState = .idle }
        persistQueue()
        kickProcessing()
    }

    /// API Key 修复后恢复云端处理
    func resumeAfterKeyFix() {
        if case .suspended = cloudState { cloudState = .idle }
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

    private func updateCloudState() {
        if case .suspended = cloudState { return }
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
