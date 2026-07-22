import Foundation

// V1（Meeting）→ V2（Project）数据迁移（产品文档 03 号 §15.1）。
// 分两层：MeetingToProjectMigrator 为纯函数映射器（确定性、可单测）；
// ProjectMigrationCoordinator 为文件级协调器（幂等、原子替换、失败零破坏）。

/// 纯函数迁移器：Meeting → Project 字段映射。
/// 对同一输入与同一 migratedAt 必须产出完全一致的结果（支撑幂等）。
enum MeetingToProjectMigrator {
    /// 状态映射：draft/ready→creating，recording→recording，paused→paused，
    /// finalizing→processing，completed→ready
    static func projectStatus(for status: MeetingStatus) -> ProjectStatus {
        switch status {
        case .draft, .ready: return .creating
        case .recording: return .recording
        case .paused: return .paused
        case .finalizing: return .processing
        case .completed: return .ready
        }
    }

    /// Participant → Speaker：id 原样保留；role 空串转 nil；
    /// 旧参与者均为用户手工录入，isUserConfirmed=true；side 原值进 legacySide；
    /// 旧声音样本路径与时长完整保留（样本文件留在原目录，不移动不删除）
    static func speaker(from participant: Participant) -> Speaker {
        Speaker(
            id: participant.id,
            cloudAlias: participant.cloudAlias,
            displayName: participant.displayName,
            role: participant.role.isEmpty ? nil : participant.role,
            colorToken: participant.colorToken,
            isUserConfirmed: true,
            legacySide: participant.side.rawValue,
            legacyVoiceReferencePath: participant.voiceReferencePath,
            legacyVoiceReferenceDurationMs: participant.voiceReferenceDurationMs
        )
    }

    /// Meeting → Project 完整映射。
    /// segments 与 legacySnapshots 经 JSON 往返深拷贝，避免新旧两棵树共享可变引用。
    /// 旧谈判专属字段（背景/目标/底线/词汇等）完整存入 legacyMetadata，不丢失。
    static func project(from meeting: Meeting, migratedAt: Date) throws -> Project {
        // 时长口径：会议墙钟时间轴（包含暂停区间），非媒体实际时长。
        // 优先 startedAt/endedAt 区间；否则取片段与暂停区间的最大结束毫秒
        let durationMs: Int64
        if let startedAt = meeting.startedAt, let endedAt = meeting.endedAt {
            durationMs = Int64((endedAt.timeIntervalSince(startedAt) * 1000).rounded())
        } else {
            let segmentEnd = meeting.segments.map(\.endMs).max() ?? 0
            let pauseEnd = meeting.pauseIntervals.map(\.endMs).max() ?? 0
            durationMs = max(segmentEnd, pauseEnd)
        }

        // 深拷贝：iso8601 配置与持久化层一致
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let segments = try decoder.decode([TranscriptSegment].self, from: encoder.encode(meeting.segments))
        let snapshots = try decoder.decode([AnalysisSnapshot].self, from: encoder.encode(meeting.snapshots))

        return Project(
            schemaVersion: 2,
            id: meeting.id,
            title: meeting.title,
            sourceType: .liveRecording,
            scenario: nil,
            scenarioWasUserSelected: false,
            status: projectStatus(for: meeting.status),
            createdAt: meeting.startedAt ?? meeting.endedAt ?? migratedAt,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            lastActivityAt: meeting.endedAt ?? meeting.startedAt ?? migratedAt,
            runtimeAssetRelativePath: meeting.audioRelativePath,
            originalFileName: nil,
            durationMs: durationMs,
            preferredInputDeviceID: meeting.preferredInputDeviceID,
            pauseIntervals: meeting.pauseIntervals,
            speakers: meeting.participants.map(speaker(from:)),
            segments: segments,
            legacySnapshots: snapshots,
            legacyMetadata: LegacyMeetingMetadata(
                background: meeting.background,
                ourGoal: meeting.ourGoal,
                ourBottomLine: meeting.ourBottomLine,
                counterpartContext: meeting.counterpartContext,
                glossary: meeting.glossary,
                audioUploadConsentAt: meeting.audioUploadConsentAt,
                lastAnalyzedSegmentEndMs: meeting.lastAnalyzedSegmentEndMs
            ),
            note: NoteDocument(markdown: "", updatedAt: migratedAt),
            processingJobs: [],
            archive: ArchiveState()
        )
    }
}

/// 迁移错误
enum ProjectMigrationError: Error, Equatable {
    /// 标记文件存在但 projects.json 缺失或损坏：旧库与新库状态不一致，拒绝任何写操作
    case corruptedNewStore
    /// 写后校验失败：迁移结果与源数据不一致
    case validationFailed(String)
}

/// 文件级迁移协调器（产品文档 03 号 §15.1）。
/// 安全不变量：全程绝不写 meetings.json；绝不触碰录音目录；
/// 任何中途失败都不会破坏 meetings.json、旧录音或已存在的有效 projects.json。
final class ProjectMigrationCoordinator {
    /// 迁移报告
    struct ProjectMigrationReport: Equatable, Sendable {
        /// 本次执行结果
        var outcome: Outcome
        /// 源会议数
        var sourceMeetingCount: Int
        /// 迁移出的项目数
        var projectCount: Int
    }

    enum Outcome: Equatable, Sendable {
        case migrated
        case alreadyMigrated
        /// 标记缺失但 projects.json 已存在且校验通过：只补写标记，未改动 projects.json
        case markerRestored
    }

    /// 迁移完成标记文件内容
    private struct MigrationMarker: Codable {
        var completedAt: Date
        var sourceMeetingCount: Int
        var projectCount: Int
        var schemaVersion: Int
    }

    private let directory: URL
    private let projectsURL: URL
    private let projectsTmpURL: URL
    private let markerURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: 同时含 meetings.json / projects.json 的目录
    init(directory: URL) {
        self.directory = directory
        self.projectsURL = directory.appending(path: "projects.json", directoryHint: .notDirectory)
        self.projectsTmpURL = directory.appending(path: "projects.json.tmp", directoryHint: .notDirectory)
        self.markerURL = directory.appending(path: "projects-migration-v2.json", directoryHint: .notDirectory)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 幂等迁移入口。
    /// 1. 标记存在：projects.json 可完整解码 → alreadyMigrated 空操作；缺失或解码失败 → 抛 corruptedNewStore，不动任何文件。
    /// 2. 标记缺失但 projects.json 已存在（上次在替换成功后、写标记前中断，或后续版本已写入新项目）：
    ///    绝不覆盖现有 projects.json；逐个验证旧 Meeting 均有对应 Project 后只补写标记；
    ///    验证不通过则抛错并保持所有文件原样。
    /// 3. 两者都不存在：执行首次迁移：tmp 写入 → 复读校验 → 原子替换 → 写标记。
    func migrateIfNeeded(now: Date = Date()) throws -> ProjectMigrationReport {
        let fileManager = FileManager.default

        // 1. 已完成迁移：只做健康检查，绝不写任何文件
        if fileManager.fileExists(atPath: markerURL.path) {
            let marker = try decoder.decode(MigrationMarker.self, from: Data(contentsOf: markerURL))
            guard fileManager.fileExists(atPath: projectsURL.path),
                  let projects = try? decoder.decode([Project].self, from: Data(contentsOf: projectsURL)) else {
                throw ProjectMigrationError.corruptedNewStore
            }
            return ProjectMigrationReport(
                outcome: .alreadyMigrated,
                sourceMeetingCount: marker.sourceMeetingCount,
                projectCount: projects.count
            )
        }

        // 2. 标记缺失但 projects.json 已存在：只读加载旧会议并验证对应关系，
        //    通过则仅补写标记（保留全部现有项目，含 V2 新项目），绝不重建或覆盖 projects.json
        if fileManager.fileExists(atPath: projectsURL.path) {
            guard let existingProjects = try? decoder.decode([Project].self, from: Data(contentsOf: projectsURL)) else {
                // 无法解码即无法证明其内容安全，拒绝覆写，交人工核查
                throw ProjectMigrationError.corruptedNewStore
            }
            let meetings = try JSONMeetingStore(directory: directory).loadMeetings()
            try validateRecovery(projects: existingProjects, against: meetings)
            let marker = MigrationMarker(
                completedAt: now,
                sourceMeetingCount: meetings.count,
                projectCount: existingProjects.count,
                schemaVersion: 2
            )
            // 补写标记失败会向上抛错；projects.json 在本分支从未被写入，字节必然不变
            try encoder.encode(marker).write(to: markerURL, options: .atomic)
            return ProjectMigrationReport(
                outcome: .markerRestored,
                sourceMeetingCount: meetings.count,
                projectCount: existingProjects.count
            )
        }

        // 3. 首次迁移。只读加载旧会议（文件不存在即空数组；JSONMeetingStore 只创建目录、不写文件）
        let meetingStore = try JSONMeetingStore(directory: directory)
        let meetings = try meetingStore.loadMeetings()
        let projects = try meetings.map { try MeetingToProjectMigrator.project(from: $0, migratedAt: now) }

        // 3. 先写 tmp（普通写入），重新读取完整解码并逐项校验
        let data = try encoder.encode(projects)
        try data.write(to: projectsTmpURL)
        let redecoded: [Project]
        do {
            redecoded = try decoder.decode([Project].self, from: Data(contentsOf: projectsTmpURL))
        } catch {
            try? fileManager.removeItem(at: projectsTmpURL)
            throw ProjectMigrationError.validationFailed("tmp 复读解码失败")
        }
        do {
            try validate(redecoded, against: meetings)
        } catch {
            try? fileManager.removeItem(at: projectsTmpURL)
            throw error
        }

        // 4. 原子替换为 projects.json：已存在用 replaceItemAt，否则同目录 rename（原子）；
        //    失败时旧 projects.json（若存在）保持原样，best-effort 清理 tmp
        do {
            if fileManager.fileExists(atPath: projectsURL.path) {
                _ = try fileManager.replaceItemAt(projectsURL, withItemAt: projectsTmpURL)
            } else {
                try fileManager.moveItem(at: projectsTmpURL, to: projectsURL)
            }
        } catch {
            try? fileManager.removeItem(at: projectsTmpURL)
            throw error
        }

        // 5. 写完成标记（原子写）
        let marker = MigrationMarker(
            completedAt: now,
            sourceMeetingCount: meetings.count,
            projectCount: projects.count,
            schemaVersion: 2
        )
        try encoder.encode(marker).write(to: markerURL, options: .atomic)

        return ProjectMigrationReport(
            outcome: .migrated,
            sourceMeetingCount: meetings.count,
            projectCount: projects.count
        )
    }

    /// 写后校验：数量、id、录音路径、暂停区间、片段关键序列、快照数量逐项一致
    private func validate(_ projects: [Project], against meetings: [Meeting]) throws {
        guard projects.count == meetings.count else {
            throw ProjectMigrationError.validationFailed("项目数 \(projects.count) 与会议数 \(meetings.count) 不等")
        }
        for (project, meeting) in zip(projects, meetings) {
            guard project.id == meeting.id else {
                throw ProjectMigrationError.validationFailed("项目 id 与源会议 id 不符")
            }
            guard project.runtimeAssetRelativePath == meeting.audioRelativePath else {
                throw ProjectMigrationError.validationFailed("会议 \(meeting.id) 录音路径不符")
            }
            guard project.pauseIntervals == meeting.pauseIntervals else {
                throw ProjectMigrationError.validationFailed("会议 \(meeting.id) 暂停区间不符")
            }
            guard project.segments.count == meeting.segments.count else {
                throw ProjectMigrationError.validationFailed("会议 \(meeting.id) 片段数不符")
            }
            for (segment, source) in zip(project.segments, meeting.segments) {
                guard segment.id == source.id, segment.startMs == source.startMs, segment.endMs == source.endMs else {
                    throw ProjectMigrationError.validationFailed("会议 \(meeting.id) 片段序列不符")
                }
            }
            guard project.legacySnapshots.count == meeting.snapshots.count else {
                throw ProjectMigrationError.validationFailed("会议 \(meeting.id) 快照数不符")
            }
        }
    }

    /// 无标记恢复校验：旧 Meeting 必须个个存在对应 Project（按 id）。
    /// 缺一即拒绝补标记，避免下次启动把含 V2 新项目的 projects.json 误当旧迁移产物。
    private func validateRecovery(projects: [Project], against meetings: [Meeting]) throws {
        let projectIds = Set(projects.map(\.id))
        let missingCount = meetings.filter { !projectIds.contains($0.id) }.count
        guard missingCount == 0 else {
            throw ProjectMigrationError.validationFailed(
                "projects.json 缺少 \(missingCount) 个旧会议对应的项目，拒绝补写标记，需人工核查")
        }
    }
}
