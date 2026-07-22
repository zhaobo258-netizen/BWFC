import Foundation
import Testing
@testable import BangWoFenXi

/// Meeting → Project 迁移测试（产品文档 03 号 §15.1）：
/// 映射完整性、幂等、原子替换与失败零破坏。每个用例独立临时目录，结束即清理。
@Suite("Meeting 到 Project 迁移")
final class ProjectMigrationTests {
    let tempRoot: URL

    init() {
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// 每个用例一个独立临时目录
    private func makeCaseDirectory(_ name: String) -> URL {
        tempRoot.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// 迁移 + 重读 projects.json 的便捷组合
    private func migratedProjects(in directory: URL, now: Date) throws -> (ProjectMigrationCoordinator.ProjectMigrationReport, [Project]) {
        let report = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        let projects = try JSONProjectStore(directory: directory).loadProjects()
        return (report, projects)
    }

    @Test("空数据库迁移：无旧库则生成空 projects.json 与标记，重复执行为 alreadyMigrated")
    func emptyDatabaseMigration() throws {
        let directory = makeCaseDirectory("empty")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let report = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        #expect(report == .init(outcome: .migrated, sourceMeetingCount: 0, projectCount: 0))

        // projects.json 存在且为空数组
        let projectsURL = directory.appending(path: "projects.json")
        #expect(FileManager.default.fileExists(atPath: projectsURL.path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let projects = try decoder.decode([Project].self, from: Data(contentsOf: projectsURL))
        #expect(projects.isEmpty)

        // 标记文件存在
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "projects-migration-v2.json").path))

        // 再次执行为幂等空操作
        let second = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        #expect(second.outcome == .alreadyMigrated)
        #expect(second.projectCount == 0)
    }

    @Test("单项目完整迁移：全部字段与内容逐项保留")
    func singleMeetingFullMigration() throws {
        let directory = makeCaseDirectory("single")
        let now = Date(timeIntervalSince1970: 1_753_100_000)
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)
        let endedAt = Date(timeIntervalSince1970: 1_753_003_600)

        let meetingId = UUID()
        let audioPath = "Meetings/\(meetingId.uuidString)/recording.caf"
        let consentAt = Date(timeIntervalSince1970: 1_752_999_000)

        // 两名参会人：一方 role 非空且带声音样本、一方 role 空串且无样本（验证空串转 nil 与 nil 透传）
        let oursId = UUID()
        let voicePath = "Meetings/\(meetingId.uuidString)/samples/\(oursId.uuidString).wav"
        let ours = Participant(id: oursId, cloudAlias: "p_01", displayName: "我方代表",
                               side: .ours, role: "主谈", colorToken: "green",
                               voiceReferencePath: voicePath, voiceReferenceDurationMs: 4_200)
        let counterpart = Participant(id: UUID(), cloudAlias: "p_02", displayName: "对方采购",
                                      side: .counterpart, role: "", colorToken: "blue")

        let meeting = Meeting(
            id: meetingId,
            title: "年度采购谈判",
            background: "双方就新一年度框架议价",
            ourGoal: "锁定年度量能价格",
            ourBottomLine: "返点不低于 3%",
            counterpartContext: "对方为长期供应商",
            glossary: ["返点"],
            status: .completed,
            startedAt: startedAt,
            endedAt: endedAt,
            audioRelativePath: audioPath,
            audioUploadConsentAt: consentAt,
            lastAnalyzedSegmentEndMs: 12_000,
            preferredInputDeviceID: "device-1",
            pauseIntervals: [PauseInterval(startMs: 60_000, endMs: 90_000)]
        )
        meeting.participants = [ours, counterpart]

        // 三个片段：含星标与人工修订
        let segmentCreatedAt = Date(timeIntervalSince1970: 1_753_000_010)
        let segmentUpdatedAt = Date(timeIntervalSince1970: 1_753_000_020)
        let segments = [
            TranscriptSegment(id: UUID(), startMs: 1_000, endMs: 5_000, text: "第一段",
                              participantId: ours.id, remoteSpeakerLabel: "p_01",
                              source: .cloud, state: .final,
                              createdAt: segmentCreatedAt, updatedAt: segmentUpdatedAt),
            TranscriptSegment(id: UUID(), startMs: 5_000, endMs: 9_000, text: "第二段（星标）",
                              participantId: counterpart.id, remoteSpeakerLabel: "p_02",
                              source: .cloud, state: .final, isStarred: true,
                              createdAt: segmentCreatedAt, updatedAt: segmentUpdatedAt),
            TranscriptSegment(id: UUID(), startMs: 9_000, endMs: 12_000, text: "第三段（已修订）",
                              participantId: nil, remoteSpeakerLabel: nil,
                              source: .manual, state: .edited,
                              createdAt: segmentCreatedAt, updatedAt: segmentUpdatedAt)
        ]
        meeting.segments = segments

        // 两版快照：含议题与分析项
        let snapshotV1 = AnalysisSnapshot(version: 1, createdAt: startedAt, analyzedThroughMs: 5_000)
        snapshotV1.topics.append(
            TopicState(title: "年度量能", status: .discussing,
                       evidenceSegmentIds: [segments[0].id], order: 0)
        )
        let snapshotV2 = AnalysisSnapshot(
            version: 2, createdAt: endedAt, analyzedThroughMs: 12_000,
            currentTopicTitle: "返点",
            confirmedItems: [StructureEntry(text: "年度量能 120 万箱", evidenceSegmentIds: [segments[0].id])]
        )
        snapshotV2.topics.append(
            TopicState(title: "年度量能", status: .confirmed,
                       evidenceSegmentIds: [segments[0].id], order: 0)
        )
        snapshotV2.insights.append(
            Insight(category: .explicitDemand, subjectParticipantId: counterpart.id,
                    statement: "对方要求保证年度量能。", epistemicStatus: .explicit,
                    confidence: .high, evidenceSegmentIds: [segments[1].id],
                    firstObservedAt: segmentCreatedAt, lastUpdatedAt: segmentUpdatedAt)
        )
        meeting.snapshots = [snapshotV1, snapshotV2]

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([meeting])

        let (report, projects) = try migratedProjects(in: directory, now: now)
        #expect(report == .init(outcome: .migrated, sourceMeetingCount: 1, projectCount: 1))
        let project = try #require(projects.first)

        // 顶层字段
        #expect(project.schemaVersion == 2)
        #expect(project.id == meetingId)
        #expect(project.title == "年度采购谈判")
        #expect(project.sourceType == .liveRecording)
        #expect(project.scenario == nil)
        #expect(project.scenarioWasUserSelected == false)
        #expect(project.status == .ready)
        #expect(project.createdAt == startedAt)
        #expect(project.lastActivityAt == endedAt)
        #expect(project.startedAt == startedAt)
        #expect(project.endedAt == endedAt)
        #expect(project.durationMs == 3_600_000)
        #expect(project.runtimeAssetRelativePath == audioPath)
        #expect(project.originalFileName == nil)
        #expect(project.preferredInputDeviceID == "device-1")
        #expect(project.pauseIntervals == [PauseInterval(startMs: 60_000, endMs: 90_000)])

        // 说话人：UUID 保留、legacySide 正确、空 role 转 nil、均为用户确认
        #expect(project.speakers.count == 2)
        #expect(project.speakers[0].id == ours.id)
        #expect(project.speakers[0].displayName == "我方代表")
        #expect(project.speakers[0].role == "主谈")
        #expect(project.speakers[0].colorToken == "green")
        #expect(project.speakers[0].isUserConfirmed == true)
        #expect(project.speakers[0].legacySide == "ours")
        // 旧声音样本路径与时长逐项保留；无样本者为 nil
        #expect(project.speakers[0].legacyVoiceReferencePath == voicePath)
        #expect(project.speakers[0].legacyVoiceReferenceDurationMs == 4_200)
        #expect(project.speakers[1].id == counterpart.id)
        #expect(project.speakers[1].role == nil)
        #expect(project.speakers[1].legacySide == "counterpart")
        #expect(project.speakers[1].isUserConfirmed == true)
        #expect(project.speakers[1].legacyVoiceReferencePath == nil)
        #expect(project.speakers[1].legacyVoiceReferenceDurationMs == nil)

        // legacyMetadata：旧谈判专属字段逐项保留（不得只填输入不验输出）
        let legacy = try #require(project.legacyMetadata)
        #expect(legacy.background == "双方就新一年度框架议价")
        #expect(legacy.ourGoal == "锁定年度量能价格")
        #expect(legacy.ourBottomLine == "返点不低于 3%")
        #expect(legacy.counterpartContext == "对方为长期供应商")
        #expect(legacy.glossary == ["返点"])
        #expect(legacy.audioUploadConsentAt == consentAt)
        #expect(legacy.lastAnalyzedSegmentEndMs == 12_000)

        // 片段：关键字段逐一全等
        #expect(project.segments.count == 3)
        for (migrated, source) in zip(project.segments, segments) {
            #expect(migrated.id == source.id)
            #expect(migrated.startMs == source.startMs)
            #expect(migrated.endMs == source.endMs)
            #expect(migrated.text == source.text)
            #expect(migrated.participantId == source.participantId)
            #expect(migrated.remoteSpeakerLabel == source.remoteSpeakerLabel)
            #expect(migrated.source == source.source)
            #expect(migrated.state == source.state)
            #expect(migrated.isStarred == source.isStarred)
            #expect(migrated.createdAt == source.createdAt)
            #expect(migrated.updatedAt == source.updatedAt)
        }
        #expect(project.segments[1].isStarred == true)
        #expect(project.segments[2].state == .edited)

        // 旧快照：版本与内容数量一致
        #expect(project.legacySnapshots.count == 2)
        #expect(project.legacySnapshots[0].version == 1)
        #expect(project.legacySnapshots[0].topics.count == 1)
        #expect(project.legacySnapshots[1].version == 2)
        #expect(project.legacySnapshots[1].currentTopicTitle == "返点")
        #expect(project.legacySnapshots[1].confirmedItems.count == 1)
        #expect(project.legacySnapshots[1].topics.count == 1)
        #expect(project.legacySnapshots[1].insights.count == 1)
        #expect(project.legacySnapshots[1].insights.first?.statement == "对方要求保证年度量能。")

        // 新结构默认值
        #expect(project.note.markdown == "")
        #expect(project.note.updatedAt == now)
        #expect(project.note.lastSyncedHash == nil)
        #expect(project.processingJobs.isEmpty)
        #expect(project.archive == ArchiveState())
    }

    @Test("多项目一次迁完：数量与 id 集合相等")
    func multipleMeetingsMigration() throws {
        let directory = makeCaseDirectory("multi")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetings = [
            Meeting(title: "草稿会议", status: .draft),
            Meeting(title: "录音中会议", status: .recording,
                    startedAt: Date(timeIntervalSince1970: 1_753_000_000)),
            Meeting(title: "已结束会议", status: .completed,
                    startedAt: Date(timeIntervalSince1970: 1_753_000_000),
                    endedAt: Date(timeIntervalSince1970: 1_753_001_800))
        ]
        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings(meetings)

        let (report, projects) = try migratedProjects(in: directory, now: now)
        #expect(report.sourceMeetingCount == 3)
        #expect(report.projectCount == 3)
        #expect(projects.count == 3)
        #expect(Set(projects.map(\.id)) == Set(meetings.map(\.id)))
        #expect(projects.map(\.status) == [.creating, .recording, .ready])
    }

    @Test("旧字段缺失：最少键 meetings.json 可迁移成功")
    func legacyMinimalJSONMigration() throws {
        let directory = makeCaseDirectory("legacy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meetingId = UUID()
        let json = """
        [
            {
                "id": "\(meetingId.uuidString)",
                "title": "旧版最少字段会议",
                "status": "ready"
            }
        ]
        """
        try Data(json.utf8).write(to: directory.appending(path: "meetings.json"))

        let now = Date(timeIntervalSince1970: 1_753_100_000)
        let (report, projects) = try migratedProjects(in: directory, now: now)
        #expect(report.sourceMeetingCount == 1)
        let project = try #require(projects.first)
        #expect(project.id == meetingId)
        #expect(project.title == "旧版最少字段会议")
        #expect(project.status == .creating) // ready → creating
        #expect(project.createdAt == now)
        #expect(project.lastActivityAt == now)
        #expect(project.durationMs == 0)
        #expect(project.speakers.isEmpty)
        #expect(project.segments.isEmpty)
        #expect(project.legacySnapshots.isEmpty)

        // 最少键旧数据也生成完整 legacyMetadata（旧字段默认值逐项保留）
        let legacy = try #require(project.legacyMetadata)
        #expect(legacy.background == "")
        #expect(legacy.ourGoal == "")
        #expect(legacy.ourBottomLine == "")
        #expect(legacy.counterpartContext == "")
        #expect(legacy.glossary.isEmpty)
        #expect(legacy.audioUploadConsentAt == nil)
        #expect(legacy.lastAnalyzedSegmentEndMs == 0)
    }

    @Test("异常状态映射：recording/paused/finalizing 为可恢复异常，其余为正常")
    func statusMapping() {
        #expect(MeetingToProjectMigrator.projectStatus(for: .draft) == .creating)
        #expect(MeetingToProjectMigrator.projectStatus(for: .ready) == .creating)
        #expect(MeetingToProjectMigrator.projectStatus(for: .recording) == .recording)
        #expect(MeetingToProjectMigrator.projectStatus(for: .paused) == .paused)
        #expect(MeetingToProjectMigrator.projectStatus(for: .finalizing) == .processing)
        #expect(MeetingToProjectMigrator.projectStatus(for: .completed) == .ready)

        // ProjectStatus.isAbnormalIfAppRelaunched 与文档 §7.1 的 Recoverable 一致
        #expect(ProjectStatus.recording.isAbnormalIfAppRelaunched == true)
        #expect(ProjectStatus.paused.isAbnormalIfAppRelaunched == true)
        #expect(ProjectStatus.processing.isAbnormalIfAppRelaunched == true)
        #expect(ProjectStatus.ready.isAbnormalIfAppRelaunched == false)
        #expect(ProjectStatus.creating.isAbnormalIfAppRelaunched == false)
        #expect(ProjectStatus.readyWithWarnings.isAbnormalIfAppRelaunched == false)
        #expect(ProjectStatus.failed.isAbnormalIfAppRelaunched == false)
    }

    @Test("重复执行迁移：第二次 alreadyMigrated 且 projects.json 字节不变")
    func repeatedMigrationIsNoop() throws {
        let directory = makeCaseDirectory("repeat")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([Meeting(title: "会议", status: .completed,
                                               startedAt: Date(timeIntervalSince1970: 1_753_000_000),
                                               endedAt: Date(timeIntervalSince1970: 1_753_000_600))])

        let first = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        #expect(first.outcome == .migrated)
        let projectsURL = directory.appending(path: "projects.json")
        let firstBytes = try Data(contentsOf: projectsURL)

        let second = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        #expect(second.outcome == .alreadyMigrated)
        #expect(second.sourceMeetingCount == 1)
        #expect(second.projectCount == 1)
        let secondBytes = try Data(contentsOf: projectsURL)
        #expect(firstBytes == secondBytes)
    }

    @Test("新文件损坏：标记存在而 projects.json 损坏时抛错，且任何文件不被改动")
    func corruptedNewStoreThrows() throws {
        let directory = makeCaseDirectory("corrupted")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([Meeting(title: "会议", status: .completed)])
        _ = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)

        let meetingsURL = directory.appending(path: "meetings.json")
        let meetingsBytesBefore = try Data(contentsOf: meetingsURL)

        // 覆写 projects.json 为垃圾字节
        let projectsURL = directory.appending(path: "projects.json")
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01])
        try garbage.write(to: projectsURL)

        #expect(throws: ProjectMigrationError.corruptedNewStore) {
            try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        }

        // meetings.json 字节不变；垃圾 projects.json 仍在原位未被删除或覆盖
        #expect(try Data(contentsOf: meetingsURL) == meetingsBytesBefore)
        #expect(try Data(contentsOf: projectsURL) == garbage)
    }

    @Test("标记缺失且 projects.json 不可解码：拒绝覆写，所有文件保持原样")
    func missingMarkerWithCorruptedProjectsRefuses() throws {
        let directory = makeCaseDirectory("corrupted-nomarker")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([Meeting(title: "会议", status: .completed)])

        // 预置垃圾 projects.json，无标记（无法证明其内容安全，不得重建覆盖）
        let projectsURL = directory.appending(path: "projects.json")
        let garbage = Data([0xFF, 0xFE, 0x00])
        try garbage.write(to: projectsURL)

        #expect(throws: ProjectMigrationError.corruptedNewStore) {
            try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        }
        #expect(try Data(contentsOf: projectsURL) == garbage)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "projects-migration-v2.json").path))
    }

    @Test("迁移中断-残留 tmp：垃圾 tmp 被安全替换，projects.json 合法")
    func staleTmpIsReplaced() throws {
        let directory = makeCaseDirectory("stale-tmp")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([Meeting(title: "会议", status: .completed)])
        // 预置垃圾 tmp，无标记（模拟上次迁移在替换前崩溃）
        try Data([0xFF, 0xFE]).write(to: directory.appending(path: "projects.json.tmp"))

        let report = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        #expect(report.outcome == .migrated)

        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "projects.json.tmp").path))
        let projects = try JSONProjectStore(directory: directory).loadProjects()
        #expect(projects.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "projects-migration-v2.json").path))
    }

    @Test("迁移中断-标记未写：删除标记后重跑结果与首次完全一致")
    func missingMarkerRerunsIdentically() throws {
        let directory = makeCaseDirectory("rerun")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([
            Meeting(title: "会议一", status: .completed,
                    startedAt: Date(timeIntervalSince1970: 1_753_000_000),
                    endedAt: Date(timeIntervalSince1970: 1_753_000_600)),
            Meeting(title: "会议二", status: .ready)
        ])

        _ = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        let projectsURL = directory.appending(path: "projects.json")
        let firstBytes = try Data(contentsOf: projectsURL)

        // 模拟标记未写：删除标记后重跑——绝不覆盖 projects.json，验证通过只补标记
        try FileManager.default.removeItem(at: directory.appending(path: "projects-migration-v2.json"))
        let report = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        #expect(report.outcome == .markerRestored)
        #expect(report.projectCount == 2)
        #expect(try Data(contentsOf: projectsURL) == firstBytes)
        // 标记已补写
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "projects-migration-v2.json").path))
    }

    @Test("标记缺失恢复：projects.json 中额外的 V2 新项目在补标记后完整保留")
    func markerRestorePreservesExtraV2Projects() throws {
        let directory = makeCaseDirectory("restore-extra")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([Meeting(title: "旧会议", status: .completed)])
        _ = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)

        // 模拟阶段 B 已向 projects.json 写入新项目
        let store = try JSONProjectStore(directory: directory)
        var projects = try store.loadProjects()
        let extraProject = Project(title: "V2 新项目", sourceType: .liveRecording,
                                   status: .recording, createdAt: now, lastActivityAt: now)
        projects.append(extraProject)
        try store.saveProjects(projects)

        // 删除标记，走恢复分支
        try FileManager.default.removeItem(at: directory.appending(path: "projects-migration-v2.json"))
        let projectsURL = directory.appending(path: "projects.json")
        let bytesBefore = try Data(contentsOf: projectsURL)

        let report = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        #expect(report.outcome == .markerRestored)
        #expect(report.sourceMeetingCount == 1)
        #expect(report.projectCount == 2)

        // projects.json 字节不变，额外 V2 项目仍在
        #expect(try Data(contentsOf: projectsURL) == bytesBefore)
        let reread = try store.loadProjects()
        #expect(reread.count == 2)
        #expect(reread.contains { $0.id == extraProject.id })
    }

    @Test("标记缺失恢复：projects.json 缺少旧会议对应项目时拒绝补标记且不动任何文件")
    func markerRestoreRejectsIncompleteProjects() throws {
        let directory = makeCaseDirectory("restore-incomplete")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([
            Meeting(title: "会议一", status: .completed),
            Meeting(title: "会议二", status: .completed)
        ])
        _ = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)

        // 人为移除一个项目（模拟 projects.json 被改坏但可解码）
        let store = try JSONProjectStore(directory: directory)
        var projects = try store.loadProjects()
        projects.removeFirst()
        try store.saveProjects(projects)

        try FileManager.default.removeItem(at: directory.appending(path: "projects-migration-v2.json"))
        let projectsURL = directory.appending(path: "projects.json")
        let bytesBefore = try Data(contentsOf: projectsURL)

        #expect(throws: ProjectMigrationError.self) {
            try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        }
        // projects.json 保持原样，标记仍未写入
        #expect(try Data(contentsOf: projectsURL) == bytesBefore)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "projects-migration-v2.json").path))
    }

    @Test("补写标记失败：抛错且 projects.json 字节不变；故障排除后恢复成功")
    func markerWriteFailureKeepsProjectsUntouched() throws {
        let directory = makeCaseDirectory("marker-fail")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([Meeting(title: "会议", status: .completed)])
        _ = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        try FileManager.default.removeItem(at: directory.appending(path: "projects-migration-v2.json"))

        // 用同名目录阻塞标记文件写入
        let markerURL = directory.appending(path: "projects-migration-v2.json")
        try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)

        let projectsURL = directory.appending(path: "projects.json")
        let bytesBefore = try Data(contentsOf: projectsURL)
        #expect(throws: (any Error).self) {
            try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        }
        #expect(try Data(contentsOf: projectsURL) == bytesBefore)

        // 故障排除后：恢复分支补标记成功，projects.json 仍不变
        try FileManager.default.removeItem(at: markerURL)
        let report = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        #expect(report.outcome == .markerRestored)
        #expect(try Data(contentsOf: projectsURL) == bytesBefore)
    }

    @Test("恢复后多次重启幂等：alreadyMigrated 重复返回且 projects.json 字节稳定")
    func multipleRestartsStayIdempotent() throws {
        let directory = makeCaseDirectory("restart-idem")
        let now = Date(timeIntervalSince1970: 1_753_100_000)

        let meetingStore = try JSONMeetingStore(directory: directory)
        try meetingStore.saveMeetings([Meeting(title: "会议", status: .completed)])
        _ = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        try FileManager.default.removeItem(at: directory.appending(path: "projects-migration-v2.json"))

        let restored = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
        #expect(restored.outcome == .markerRestored)

        let projectsURL = directory.appending(path: "projects.json")
        let bytesAfterRestore = try Data(contentsOf: projectsURL)
        for _ in 0..<3 {
            let report = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded(now: now)
            #expect(report.outcome == .alreadyMigrated)
            #expect(try Data(contentsOf: projectsURL) == bytesAfterRestore)
        }
    }

    @Test("纯函数确定性：同一输入与 migratedAt 产出完全一致；speaker 与状态映射全分支")
    func migratorDeterminismAndBranches() throws {
        let migratedAt = Date(timeIntervalSince1970: 1_753_100_000)
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)
        let endedAt = Date(timeIntervalSince1970: 1_753_001_800)

        let meeting = Meeting(title: "确定性验证", status: .completed,
                              startedAt: startedAt, endedAt: endedAt,
                              audioRelativePath: "Meetings/x/recording.caf",
                              pauseIntervals: [PauseInterval(startMs: 10, endMs: 20)])
        meeting.participants = [
            Participant(cloudAlias: "p_01", displayName: "甲", side: .ours, role: "主谈"),
            Participant(cloudAlias: "p_02", displayName: "乙", side: .neutral, role: "")
        ]
        meeting.segments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, text: "你好",
                              participantId: meeting.participants[0].id,
                              source: .cloud, state: .final,
                              createdAt: startedAt, updatedAt: startedAt)
        ]
        meeting.snapshots = [AnalysisSnapshot(version: 1, createdAt: startedAt, analyzedThroughMs: 1_000)]

        let first = try MeetingToProjectMigrator.project(from: meeting, migratedAt: migratedAt)
        let second = try MeetingToProjectMigrator.project(from: meeting, migratedAt: migratedAt)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(first) == encoder.encode(second))

        // 时长来自 startedAt/endedAt 区间（半小时）
        #expect(first.durationMs == 1_800_000)

        // speaker(from:) 各分支：role 空串转 nil、legacySide 取 side 原值、id 保留
        let withRole = MeetingToProjectMigrator.speaker(from: meeting.participants[0])
        #expect(withRole.id == meeting.participants[0].id)
        #expect(withRole.role == "主谈")
        #expect(withRole.isUserConfirmed == true)
        #expect(withRole.legacySide == "ours")
        let emptyRole = MeetingToProjectMigrator.speaker(from: meeting.participants[1])
        #expect(emptyRole.role == nil)
        #expect(emptyRole.legacySide == "neutral")
        let counterpartSpeaker = MeetingToProjectMigrator.speaker(
            from: Participant(cloudAlias: "p_03", displayName: "丙", side: .counterpart))
        #expect(counterpartSpeaker.legacySide == "counterpart")

        // 无 startedAt/endedAt 时时长取片段与暂停区间最大结束毫秒
        let undated = Meeting(title: "无时间会议", status: .draft)
        undated.segments = [TranscriptSegment(startMs: 0, endMs: 42_000, text: "片段",
                                              source: .local, state: .provisional)]
        undated.pauseIntervals = [PauseInterval(startMs: 50_000, endMs: 66_000)]
        let undatedProject = try MeetingToProjectMigrator.project(from: undated, migratedAt: migratedAt)
        #expect(undatedProject.durationMs == 66_000)
        #expect(undatedProject.createdAt == migratedAt)
        #expect(undatedProject.lastActivityAt == migratedAt)

        // 完全无时间线索时时长为 0
        let empty = try MeetingToProjectMigrator.project(
            from: Meeting(title: "空会议", status: .draft), migratedAt: migratedAt)
        #expect(empty.durationMs == 0)
    }
}
