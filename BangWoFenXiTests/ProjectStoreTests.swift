import Foundation
import Testing
@testable import BangWoFenXi

/// V2 项目持久化测试（产品文档 03 号 §8 / §9.1：模型完整性与存储往返）。
/// 使用临时目录与内存实现，测试结束后清理，不产生任何残留数据。
@Suite("V2 项目持久化")
final class ProjectStoreTests {
    let tempDirectory: URL

    init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// 每个用例一个独立临时目录（套件内并行执行，共享目录会互相覆盖 projects.json）
    private func makeCaseDirectory(_ name: String) -> URL {
        tempDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// 完整模型树：写入 → 换一个 store 实例重新读取 → 字段逐一校验
    @Test("完整模型读写")
    func fullModelRoundTrip() throws {
        let directory = makeCaseDirectory("roundtrip")
        let store = try JSONProjectStore(directory: directory)

        let createdAt = Date(timeIntervalSince1970: 1_753_000_000)
        let startedAt = Date(timeIntervalSince1970: 1_753_000_100)
        let endedAt = Date(timeIntervalSince1970: 1_753_003_700)
        let assetId = UUID()

        // 说话人（含 legacySide 与旧声音样本字段）
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "测试对方",
            role: "采购负责人",
            colorToken: "blue",
            isUserConfirmed: true,
            legacySide: "counterpart",
            legacyVoiceReferencePath: "Meetings/x/samples/y.wav",
            legacyVoiceReferenceDurationMs: 4_200
        )

        // 片段（设置三个 V2 新可选字段）
        let segment = TranscriptSegment(
            startMs: 125_000,
            endMs: 131_500,
            text: "测试用转写文本",
            participantId: speaker.id,
            remoteSpeakerLabel: "p_01",
            source: .cloud,
            state: .edited,
            isStarred: true,
            createdAt: startedAt,
            updatedAt: startedAt,
            speakerConfidence: .high,
            languageCode: "zh-CN",
            sourceAssetId: assetId
        )

        // 旧分析快照（含议题与分析项）
        let snapshot = AnalysisSnapshot(
            version: 2,
            createdAt: endedAt,
            analyzedThroughMs: 131_500,
            currentTopicTitle: "年度量能",
            counterpartPositions: [
                StructureEntry(text: "对方要求保证年度量能", evidenceSegmentIds: [segment.id])
            ]
        )
        snapshot.topics.append(
            TopicState(title: "年度量能", status: .discussing,
                       evidenceSegmentIds: [segment.id], order: 0)
        )
        snapshot.insights.append(
            Insight(
                category: .explicitDemand,
                subjectParticipantId: speaker.id,
                statement: "对方明确提出年度量能保证要求。",
                epistemicStatus: .explicit,
                confidence: .high,
                evidenceSegmentIds: [segment.id],
                firstObservedAt: startedAt,
                lastUpdatedAt: endedAt
            )
        )

        let project = Project(
            title: "年度采购谈判",
            sourceType: .liveRecording,
            scenario: .clientVisit,
            scenarioWasUserSelected: true,
            status: .ready,
            createdAt: createdAt,
            startedAt: startedAt,
            endedAt: endedAt,
            lastActivityAt: endedAt,
            runtimeAssetRelativePath: "Meetings/\(UUID().uuidString)/recording.caf",
            originalFileName: nil,
            durationMs: 3_600_000,
            preferredInputDeviceID: "device-1",
            pauseIntervals: [PauseInterval(startMs: 60_000, endMs: 90_000)],
            speakers: [speaker],
            segments: [segment],
            legacySnapshots: [snapshot],
            legacyMetadata: LegacyMeetingMetadata(
                background: "背景", ourGoal: "目标", ourBottomLine: "底线",
                counterpartContext: "对方背景", glossary: ["返点"],
                audioUploadConsentAt: startedAt, lastAnalyzedSegmentEndMs: 131_500
            ),
            note: NoteDocument(markdown: "# 笔记\n\n要点。", updatedAt: endedAt, lastSyncedHash: "abc123"),
            processingJobs: [
                ProcessingJob(kind: .transcription, status: .completed, progress: 1.0,
                              retryCount: 1, lastErrorCategory: "timeout", updatedAt: endedAt)
            ],
            archive: ArchiveState(vaultBookmarkId: "bookmark-1", projectRelativePath: "Projects/谈判",
                                  lastSyncedAt: endedAt, lastManifestHash: "hash-1", hasPendingChanges: true)
        )

        try store.saveProjects([project])

        // 换一个 store 实例重新读取
        let reloadedStore = try JSONProjectStore(directory: directory)
        let loaded = try reloadedStore.loadProjects()
        #expect(loaded.count == 1)
        let restored = try #require(loaded.first)

        #expect(restored.schemaVersion == 2)
        #expect(restored.id == project.id)
        #expect(restored.title == "年度采购谈判")
        #expect(restored.sourceType == .liveRecording)
        #expect(restored.scenario == .clientVisit)
        #expect(restored.scenarioWasUserSelected == true)
        #expect(restored.status == .ready)
        #expect(restored.createdAt == createdAt)
        #expect(restored.startedAt == startedAt)
        #expect(restored.endedAt == endedAt)
        #expect(restored.lastActivityAt == endedAt)
        #expect(restored.runtimeAssetRelativePath == project.runtimeAssetRelativePath)
        #expect(restored.originalFileName == nil)
        #expect(restored.durationMs == 3_600_000)
        #expect(restored.preferredInputDeviceID == "device-1")
        #expect(restored.pauseIntervals == [PauseInterval(startMs: 60_000, endMs: 90_000)])

        // 说话人逐字段
        #expect(restored.speakers.count == 1)
        let restoredSpeaker = try #require(restored.speakers.first)
        #expect(restoredSpeaker.id == speaker.id)
        #expect(restoredSpeaker.cloudAlias == "p_01")
        #expect(restoredSpeaker.displayName == "测试对方")
        #expect(restoredSpeaker.role == "采购负责人")
        #expect(restoredSpeaker.colorToken == "blue")
        #expect(restoredSpeaker.isUserConfirmed == true)
        #expect(restoredSpeaker.legacySide == "counterpart")
        #expect(restoredSpeaker.legacyVoiceReferencePath == "Meetings/x/samples/y.wav")
        #expect(restoredSpeaker.legacyVoiceReferenceDurationMs == 4_200)

        // 片段逐字段（含 V2 新可选字段）
        #expect(restored.segments.count == 1)
        let restoredSegment = try #require(restored.segments.first)
        #expect(restoredSegment.id == segment.id)
        #expect(restoredSegment.startMs == 125_000)
        #expect(restoredSegment.endMs == 131_500)
        #expect(restoredSegment.text == "测试用转写文本")
        #expect(restoredSegment.participantId == speaker.id)
        #expect(restoredSegment.remoteSpeakerLabel == "p_01")
        #expect(restoredSegment.source == .cloud)
        #expect(restoredSegment.state == .edited)
        #expect(restoredSegment.isStarred == true)
        #expect(restoredSegment.createdAt == startedAt)
        #expect(restoredSegment.updatedAt == startedAt)
        #expect(restoredSegment.speakerConfidence == .high)
        #expect(restoredSegment.languageCode == "zh-CN")
        #expect(restoredSegment.sourceAssetId == assetId)

        // 旧快照：版本与内容数量一致
        #expect(restored.legacySnapshots.count == 1)
        let restoredSnapshot = try #require(restored.legacySnapshots.first)
        #expect(restoredSnapshot.version == 2)
        #expect(restoredSnapshot.analyzedThroughMs == 131_500)
        #expect(restoredSnapshot.currentTopicTitle == "年度量能")
        #expect(restoredSnapshot.counterpartPositions.count == 1)
        #expect(restoredSnapshot.topics.count == 1)
        #expect(restoredSnapshot.insights.count == 1)

        // legacyMetadata 逐字段
        let restoredLegacy = try #require(restored.legacyMetadata)
        #expect(restoredLegacy.background == "背景")
        #expect(restoredLegacy.ourGoal == "目标")
        #expect(restoredLegacy.ourBottomLine == "底线")
        #expect(restoredLegacy.counterpartContext == "对方背景")
        #expect(restoredLegacy.glossary == ["返点"])
        #expect(restoredLegacy.audioUploadConsentAt == startedAt)
        #expect(restoredLegacy.lastAnalyzedSegmentEndMs == 131_500)

        // 笔记 / 任务 / 归档
        #expect(restored.note.markdown == "# 笔记\n\n要点。")
        #expect(restored.note.updatedAt == endedAt)
        #expect(restored.note.lastSyncedHash == "abc123")
        #expect(restored.processingJobs.count == 1)
        let restoredJob = try #require(restored.processingJobs.first)
        #expect(restoredJob.kind == .transcription)
        #expect(restoredJob.status == .completed)
        #expect(restoredJob.progress == 1.0)
        #expect(restoredJob.retryCount == 1)
        #expect(restoredJob.lastErrorCategory == "timeout")
        #expect(restored.archive.vaultBookmarkId == "bookmark-1")
        #expect(restored.archive.projectRelativePath == "Projects/谈判")
        #expect(restored.archive.lastSyncedAt == endedAt)
        #expect(restored.archive.lastManifestHash == "hash-1")
        #expect(restored.archive.hasPendingChanges == true)
    }

    @Test("空库返回空数组")
    func emptyStoreReturnsEmpty() throws {
        let store = try JSONProjectStore(directory: makeCaseDirectory("empty"))
        #expect(try store.loadProjects().isEmpty)
    }

    @Test("覆盖保存反映删除")
    func overwriteReflectsDeletion() throws {
        let directory = makeCaseDirectory("overwrite")
        let store = try JSONProjectStore(directory: directory)
        let first = Project(title: "项目一", sourceType: .liveRecording)
        let second = Project(title: "项目二", sourceType: .importedAudio)
        try store.saveProjects([first, second])
        try store.saveProjects([second])

        let reloadedStore = try JSONProjectStore(directory: directory)
        let loaded = try reloadedStore.loadProjects()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == second.id)
    }

    @Test("内存存储读写一致")
    func inMemoryRoundTrip() throws {
        let project = Project(title: "内存项目", sourceType: .importedVideo, status: .processing)
        let store = InMemoryProjectStore(seed: [project])
        let loaded = try store.loadProjects()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == project.id)

        try store.saveProjects([])
        #expect(try store.loadProjects().isEmpty)
    }

    @Test("缺失可选字段的 JSON 可解码回退默认")
    func legacyJSONDecodesWithDefaults() throws {
        let projectId = UUID()
        let json = """
        {
            "id": "\(projectId.uuidString)",
            "title": "最小项目",
            "sourceType": "liveRecording",
            "status": "creating",
            "createdAt": "2026-07-22T00:00:00Z",
            "lastActivityAt": "2026-07-22T00:00:00Z",
            "durationMs": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(json.utf8))

        #expect(project.schemaVersion == 2)
        #expect(project.id == projectId)
        #expect(project.title == "最小项目")
        #expect(project.sourceType == .liveRecording)
        #expect(project.scenario == nil)
        #expect(project.scenarioWasUserSelected == false)
        #expect(project.status == .creating)
        #expect(project.startedAt == nil)
        #expect(project.endedAt == nil)
        #expect(project.runtimeAssetRelativePath == nil)
        #expect(project.originalFileName == nil)
        #expect(project.durationMs == 0)
        #expect(project.preferredInputDeviceID == nil)
        #expect(project.pauseIntervals.isEmpty)
        #expect(project.speakers.isEmpty)
        #expect(project.segments.isEmpty)
        #expect(project.legacySnapshots.isEmpty)
        // 补强前生成的 Project JSON 无 legacyMetadata 键：解码为 nil，不报错
        #expect(project.legacyMetadata == nil)
        #expect(project.note.markdown == "")
        #expect(project.note.lastSyncedHash == nil)
        #expect(project.processingJobs.isEmpty)
        #expect(project.archive == ArchiveState())
    }

    @Test("AppEnvironment 注入项目存储：默认内存实现可读写往返")
    @MainActor
    func environmentProjectStoreRoundTrip() throws {
        let fileStore = MeetingFileStore(baseDirectory: tempDirectory)
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: fileStore,
            // 独立 Keychain service：不触碰生产条目，避免授权弹窗（与 Key 分家测试同一模式）
            keychainServiceName: "com.zhaobo.BangWoFenXi.tests.project-store"
        )

        #expect(try environment.allProjects().isEmpty)

        let project = Project(title: "环境注入项目", sourceType: .liveRecording)
        try environment.persist(project)
        #expect(try environment.allProjects().count == 1)

        // 按 id 覆盖语义：同 id 再存不重复
        try environment.persist(project)
        let projects = try environment.allProjects()
        #expect(projects.count == 1)
        #expect(projects.first?.id == project.id)
    }

    @Test("字段所有权表覆盖 Project 全部存储属性")
    func fieldOwnershipCoversEveryProjectProperty() {
        let project = Project(title: "字段守护", sourceType: .importedAudio)
        let modelFields = Set(
            Mirror(reflecting: project).children.compactMap(\.label)
        )
        let registeredFields = Set(ProjectPersistence.fieldOwnership.keys)

        #expect(modelFields == registeredFields)
    }

    @Test("流水线先写片段后，工作台旧副本只合并笔记且不冲掉片段")
    @MainActor
    func staleWorkspaceNoteDoesNotOverwritePipelineSegments() throws {
        let directory = makeCaseDirectory("field-merge")
        let store = try JSONProjectStore(directory: directory)
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: directory.appending(path: "files")),
            projectStore: store,
            keychainServiceName: "com.zhaobo.BangWoFenXi.tests.field-merge.\(UUID().uuidString)"
        )
        let initial = Project(
            title: "并发导入",
            sourceType: .importedAudio,
            status: .processing
        )
        try environment.persist(initial)

        let staleWorkspace = try #require(environment.allProjects().first)
        let pipelineCopy = try #require(environment.allProjects().first)
        pipelineCopy.segments = [
            TranscriptSegment(
                startMs: 0,
                endMs: 2_000,
                text: "流水线新片段",
                source: .local,
                state: .final
            )
        ]
        try environment.persist(pipelineCopy, fields: .importPipeline)

        let noteController = NoteController(
            project: staleWorkspace,
            persist: { try environment.persist($0, fields: .note) },
            debounce: .seconds(60)
        )
        noteController.update(markdown: "工作台旧副本里的新笔记")
        #expect(noteController.saveNow())

        let saved = try #require(environment.allProjects().first)
        #expect(saved.note.markdown == "工作台旧副本里的新笔记")
        #expect(saved.segments.count == 1)
        #expect(saved.segments.first?.text == "流水线新片段")
    }

    @Test("流水线合并保留人工片段修订与用户手选场景")
    func pipelineMergePreservesWorkspaceOverrides() {
        let projectID = UUID()
        let segmentID = UUID()
        let edited = TranscriptSegment(
            id: segmentID,
            startMs: 0,
            endMs: 1_000,
            text: "人工修订",
            source: .manual,
            state: .edited,
            isStarred: true
        )
        let stored = Project(
            id: projectID,
            title: "存储项目",
            sourceType: .importedAudio,
            scenario: .clientVisit,
            scenarioWasUserSelected: true,
            segments: [edited]
        )
        let pipeline = Project(
            id: projectID,
            title: "流水线旧副本",
            sourceType: .importedAudio,
            scenario: .classLearning,
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    startMs: 0,
                    endMs: 1_000,
                    text: "机器旧文本",
                    source: .local,
                    state: .final
                ),
                TranscriptSegment(
                    startMs: 1_000,
                    endMs: 2_000,
                    text: "流水线新增",
                    source: .local,
                    state: .final
                )
            ]
        )
        var projects = [stored]

        ProjectPersistence.upsert(pipeline, into: &projects, fields: .importPipeline)

        let merged = projects[0]
        #expect(merged.scenario == .clientVisit)
        #expect(merged.scenarioWasUserSelected)
        #expect(merged.segments.count == 2)
        #expect(merged.segments.first?.text == "人工修订")
        #expect(merged.segments.first?.state == .edited)
        #expect(merged.segments.first?.isStarred == true)
    }

    @Test("导入项目刷新清单包含后台场景建议与选择来源")
    @MainActor
    func importedRefreshIncludesScenarioSuggestion() {
        let id = UUID()
        let workspace = Project(
            id: id,
            title: "打开中的工作台",
            sourceType: .importedAudio
        )
        let fresh = Project(
            id: id,
            title: "存储副本",
            sourceType: .importedAudio,
            scenario: .journalistInterview,
            scenarioWasUserSelected: false,
            status: .ready
        )

        ProjectWorkspaceView.applyImportedStorageRefresh(from: fresh, to: workspace)

        #expect(workspace.scenario == .journalistInterview)
        #expect(workspace.scenarioWasUserSelected == false)
    }
}
