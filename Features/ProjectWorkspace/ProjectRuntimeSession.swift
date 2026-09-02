import Foundation

/// Project ⇄ 运行时 Meeting 桥接（阶段 B）。
///
/// 现有录音 / 转写 / 分人 / 分析链路全部围绕 Meeting 构建且已稳定，
/// 阶段 B 不重写这些底层：工作台在内存中把 Project 水合为同 id 的运行时 Meeting
/// 驱动整套链路，再把运行时状态回写 Project 并经 ProjectStoring 持久化。
/// 运行时 Meeting 不写入旧 meetingStore——新项目的权威存储只有 projects.json。
enum ProjectRuntimeSession {

    // MARK: - 状态映射

    /// ProjectStatus → 运行时 MeetingStatus。
    /// creating → ready（可立即开始录音）；processing → finalizing；
    /// ready/readyWithWarnings/failed → completed（只读回看）。
    static func runtimeStatus(for status: ProjectStatus) -> MeetingStatus {
        switch status {
        case .creating: return .ready
        case .recording: return .recording
        case .paused: return .paused
        case .processing: return .finalizing
        case .ready, .readyWithWarnings, .failed: return .completed
        }
    }

    /// MeetingStatus → ProjectStatus（与阶段 A 迁移器口径一致，避免两套映射漂移）
    static func projectStatus(for status: MeetingStatus) -> ProjectStatus {
        MeetingToProjectMigrator.projectStatus(for: status)
    }

    // MARK: - 底部录音条可见性

    /// 底部录音条只在「本次会话真的持有录音器」时出现。
    ///
    /// 崩溃遗留的项目状态仍是 recording/paused，但进程重启后 recorder 里没有 activeMeeting，
    /// 此时露出录音条会让人按到暂停 —— 状态机必然抛 noActiveMeeting，且「继续」分支永远够不着。
    /// 这类项目该走的是异常横幅的「标记为已结束」，不是录音条。
    /// 修的是显示前提而不是放宽状态机守卫：守卫报错是对的，不能让真实的状态机错误被吞掉。
    static func showsRecordBar(status: MeetingStatus, hasLiveRecorder: Bool) -> Bool {
        guard hasLiveRecorder else { return false }
        return status == .recording || status == .paused
    }

    // MARK: - 时长口径

    /// 墙钟时长（毫秒），口径与迁移器一致：含暂停区间，不等于媒体真实时长。
    ///
    /// - endedAt 已知：直接取 endedAt - startedAt；
    /// - endedAt 缺失（录音中或异常退出未收尾）：用 now - startedAt 与片段/暂停末端取 max，
    ///   避免「无片段无暂停」时归零并在恢复后固化为 0（Bug 2）；
    /// - startedAt 也缺失：退回片段/暂停末端与已有值，不凭空造数。
    static func wallClockDurationMs(
        startedAt: Date?,
        endedAt: Date?,
        segmentEndMs: Int64,
        pauseEndMs: Int64,
        fallbackDurationMs: Int64 = 0,
        now: Date = Date()
    ) -> Int64 {
        let timelineEnd = max(segmentEndMs, pauseEndMs)
        guard let startedAt else {
            return max(timelineEnd, fallbackDurationMs)
        }
        if let endedAt {
            return Int64((endedAt.timeIntervalSince(startedAt) * 1000).rounded())
        }
        let elapsed = max(0, Int64((now.timeIntervalSince(startedAt) * 1000).rounded()))
        return max(elapsed, max(timelineEnd, fallbackDurationMs))
    }

    // MARK: - Project → 运行时 Meeting

    /// 把 Project 水合为同 id 的运行时 Meeting。
    /// 旧谈判字段从 legacyMetadata 还原（供分析上下文）；segments/snapshots 经 JSON 深拷贝，
    /// 运行时对 Meeting 的任何修改都不会反向污染 Project，必须显式 applyRuntime 回写。
    static func makeRuntimeMeeting(from project: Project) throws -> Meeting {
        let legacy = project.legacyMetadata
        let meeting = Meeting(
            id: project.id,
            title: project.title,
            background: legacy?.background ?? "",
            ourGoal: legacy?.ourGoal ?? "",
            ourBottomLine: legacy?.ourBottomLine ?? "",
            counterpartContext: legacy?.counterpartContext ?? "",
            glossary: legacy?.glossary ?? [],
            status: runtimeStatus(for: project.status),
            startedAt: project.startedAt,
            endedAt: project.endedAt,
            audioRelativePath: project.runtimeAssetRelativePath,
            audioUploadConsentAt: legacy?.audioUploadConsentAt,
            lastAnalyzedSegmentEndMs: legacy?.lastAnalyzedSegmentEndMs ?? 0,
            preferredInputDeviceID: project.preferredInputDeviceID,
            pauseIntervals: project.pauseIntervals,
            timelineDurationMs: project.durationMs
        )
        meeting.participants = project.speakers.map { speaker in
            Participant(
                id: speaker.id,
                cloudAlias: speaker.cloudAlias,
                displayName: speaker.displayName,
                side: speaker.legacySide.flatMap { ParticipantSide(rawValue: $0) } ?? .neutral,
                role: speaker.role ?? "",
                colorToken: speaker.colorToken,
                voiceReferencePath: speaker.voiceSamplePath ?? speaker.legacyVoiceReferencePath,
                voiceReferenceDurationMs: speaker.voiceSampleDurationMs ?? speaker.legacyVoiceReferenceDurationMs,
                iflytekFeatureID: speaker.iflytekFeatureID
            )
        }
        // 深拷贝：与迁移器同一 iso8601 配置
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        meeting.segments = try decoder.decode(
            [TranscriptSegment].self, from: encoder.encode(project.segments))
        meeting.snapshots = try decoder.decode(
            [AnalysisSnapshot].self, from: encoder.encode(project.legacySnapshots))
        return meeting
    }

    // MARK: - 运行时 Meeting → Project

    /// 把运行时 Meeting 的状态回写 Project（不写库；调用方负责 persist(project)）。
    /// - 状态映射与迁移器一致；readyWithWarnings/failed 不由运行时反向产生；
    /// - segments/snapshots 深拷贝回写，避免两棵树共享可变引用；
    /// - durationMs 口径与迁移器一致：会议墙钟时间轴（含暂停），非媒体实际时长；
    /// - legacyMetadata 缺失时按默认值补建，并同步增量分析游标。
    static func applyRuntime(_ meeting: Meeting, to project: Project, at now: Date = Date()) throws {
        project.status = projectStatus(for: meeting.status)
        project.startedAt = meeting.startedAt
        project.endedAt = meeting.endedAt
        project.pauseIntervals = meeting.pauseIntervals
        project.preferredInputDeviceID = meeting.preferredInputDeviceID
        // 录音资产关联：运行时为权威（开录时由录音服务写入相对路径），必须回写项目
        project.runtimeAssetRelativePath = meeting.audioRelativePath

        let segmentEndMs = meeting.segments.map(\.endMs).max() ?? 0
        let pauseEndMs = meeting.pauseIntervals.map(\.endMs).max() ?? 0
        if meeting.timelineDurationMs > 0 {
            project.durationMs = max(
                meeting.timelineDurationMs,
                max(segmentEndMs, pauseEndMs)
            )
        } else {
            project.durationMs = wallClockDurationMs(
                startedAt: meeting.startedAt,
                endedAt: meeting.endedAt,
                segmentEndMs: segmentEndMs,
                pauseEndMs: pauseEndMs,
                fallbackDurationMs: project.durationMs,
                now: now
            )
        }

        var legacy = project.legacyMetadata ?? LegacyMeetingMetadata()
        legacy.lastAnalyzedSegmentEndMs = meeting.lastAnalyzedSegmentEndMs
        project.legacyMetadata = legacy

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        project.segments = try decoder.decode(
            [TranscriptSegment].self, from: encoder.encode(meeting.segments))
        project.legacySnapshots = try decoder.decode(
            [AnalysisSnapshot].self, from: encoder.encode(meeting.snapshots))

        project.lastActivityAt = now
    }
}

@MainActor
final class ProjectRuntimePersistenceController {
    private let meeting: Meeting
    private let project: Project
    private let persist: (Project) throws -> Void
    private let debounce: Duration
    private let onFailure: (Error) -> Void
    private var flushTask: Task<Void, Never>?
    /// 单调递增的落盘任务代号：只有当前代号的任务有权清空 flushTask，
    /// 避免 await 边界后 cancel() 作用在已被替换的引用上导致重复写盘。
    private var flushGeneration = 0
    /// 连续写失败次数（决定退避时长，达上限后停止自动重试）
    private var consecutiveFailures = 0

    /// 写失败后的自动重试上限；超过后保留 saveError 等用户显式操作，不静默丢数据
    static let maxRetryAttempts = 3

    private(set) var hasPendingChanges = false
    private(set) var saveError: String?
    /// 已执行的落盘次数（供测试断言不重复写盘）
    private(set) var writeAttemptCount = 0
    /// 因写失败排入的重试次数
    private(set) var retryCount = 0

    init(
        meeting: Meeting,
        project: Project,
        persist: @escaping (Project) throws -> Void,
        debounce: Duration = .seconds(2),
        onFailure: @escaping (Error) -> Void = { _ in }
    ) {
        self.meeting = meeting
        self.project = project
        self.persist = persist
        self.debounce = debounce
        self.onFailure = onFailure
    }

    func schedule() {
        hasPendingChanges = true
        // 窗口从第一条未保存片段起算，持续转写时也能保证最多约 2 秒未落盘。
        guard flushTask == nil else { return }
        scheduleFlush(after: debounce)
    }

    private func scheduleFlush(after delay: Duration) {
        flushGeneration += 1
        let generation = flushGeneration
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.writeThrough(generation: generation)
        }
    }

    @discardableResult
    func flush(force: Bool = false) -> Bool {
        flushTask?.cancel()
        flushTask = nil
        // 提升代号使在途任务失去写盘资格，重复 flush() 不会各写一次
        flushGeneration += 1
        guard hasPendingChanges || force else { return saveError == nil }
        writeThrough(generation: flushGeneration)
        return saveError == nil
    }

    /// generation 不是当前代号时说明该任务已被取代，直接放弃。
    /// 写盘完成后才清 flushTask，避免与 flush() 的 cancel() 竞态。
    private func writeThrough(generation: Int) {
        guard generation == flushGeneration else { return }
        writeAttemptCount += 1
        do {
            try ProjectRuntimeSession.applyRuntime(meeting, to: project)
            try persist(project)
            hasPendingChanges = false
            saveError = nil
            consecutiveFailures = 0
            flushTask = nil
        } catch {
            saveError = String(describing: type(of: error))
            onFailure(error)
            flushTask = nil
            scheduleRetryIfPossible()
        }
    }

    /// 写失败时 hasPendingChanges 仍为 true；这里按次数退避重排，
    /// 否则没有新 schedule() 时这批变更会一直躺着不重试。
    private func scheduleRetryIfPossible() {
        consecutiveFailures += 1
        guard consecutiveFailures <= Self.maxRetryAttempts else { return }
        retryCount += 1
        scheduleFlush(after: retryBackoff(attempt: consecutiveFailures))
    }

    private func retryBackoff(attempt: Int) -> Duration {
        // 1s / 2s / 4s，上限在 maxRetryAttempts 处收敛
        .seconds(1 << min(attempt - 1, 2))
    }
}
