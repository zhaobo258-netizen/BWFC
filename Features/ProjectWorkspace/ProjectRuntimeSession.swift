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
            pauseIntervals: project.pauseIntervals
        )
        meeting.participants = project.speakers.map { speaker in
            Participant(
                id: speaker.id,
                cloudAlias: speaker.cloudAlias,
                displayName: speaker.displayName,
                side: speaker.legacySide.flatMap { ParticipantSide(rawValue: $0) } ?? .neutral,
                role: speaker.role ?? "",
                colorToken: speaker.colorToken,
                voiceReferencePath: speaker.legacyVoiceReferencePath,
                voiceReferenceDurationMs: speaker.legacyVoiceReferenceDurationMs
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

        if let startedAt = meeting.startedAt, let endedAt = meeting.endedAt {
            project.durationMs = Int64((endedAt.timeIntervalSince(startedAt) * 1000).rounded())
        } else {
            let segmentEnd = meeting.segments.map(\.endMs).max() ?? 0
            let pauseEnd = meeting.pauseIntervals.map(\.endMs).max() ?? 0
            project.durationMs = max(segmentEnd, pauseEnd)
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
