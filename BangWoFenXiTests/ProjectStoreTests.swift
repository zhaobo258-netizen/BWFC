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

        let reviewCandidate = TranscriptReviewCandidate(
            segmentId: segment.id,
            wrong: "测试用转写",
            right: "测试转写",
            sourceTextAtReview: segment.text
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
            transcriptReviewCandidates: [reviewCandidate],
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
        #expect(restored.transcriptReviewCandidates == [reviewCandidate])

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

    @Test("非法 JSON 读取时备份原始字节并抛出明确损坏错误")
    func corruptedJSONIsBackedUp() throws {
        let directory = makeCaseDirectory("corrupt-backup")
        let store = try JSONProjectStore(directory: directory)
        let projectsURL = directory.appending(path: "projects.json")
        let corruptedData = Data(#"{"projects":"unterminated""#.utf8)
        try corruptedData.write(to: projectsURL)
        var backupFileName: String?

        do {
            _ = try store.loadProjects()
            Issue.record("非法 JSON 必须抛出 dataCorrupted")
        } catch let ProjectStoreError.dataCorrupted(name) {
            backupFileName = name
        }

        let name = try #require(backupFileName)
        #expect(name.hasPrefix("projects.corrupt-"))
        #expect(name.hasSuffix(".json"))
        let backupURL = directory.appending(path: name)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try Data(contentsOf: backupURL) == corruptedData)
        #expect(!FileManager.default.fileExists(atPath: projectsURL.path))
    }

    @Test("损坏备份完成后可重建空库且备份不被吞掉")
    func saveAfterCorruptionPreservesBackup() throws {
        let directory = makeCaseDirectory("corrupt-rebuild")
        let store = try JSONProjectStore(directory: directory)
        let projectsURL = directory.appending(path: "projects.json")
        let corruptedData = Data([0xFF, 0xFE, 0x00, 0x7B])
        try corruptedData.write(to: projectsURL)
        var backupFileName: String?

        do {
            _ = try store.loadProjects()
        } catch let ProjectStoreError.dataCorrupted(name) {
            backupFileName = name
        }

        let name = try #require(backupFileName)
        let backupURL = directory.appending(path: name)
        let rebuilt = Project(title: "重建项目", sourceType: .liveRecording)
        try store.saveProjects([rebuilt])

        #expect(try Data(contentsOf: backupURL) == corruptedData)
        let reloaded = try JSONProjectStore(directory: directory).loadProjects()
        #expect(reloaded.map(\.id) == [rebuilt.id])
    }

    @Test("首页对损坏库显示备份成功的真实文案")
    func corruptedStoreLoadMessageIsTruthful() {
        let message = ProjectHomeView.loadErrorMessage(
            for: ProjectStoreError.dataCorrupted(
                backupFileName: "projects.corrupt-2026-07-26T10:00:00Z.json"
            )
        )

        #expect(message.contains("数据文件损坏"))
        #expect(message.contains("已备份为 projects.corrupt-"))
        #expect(message.contains("原始数据未丢失"))
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
        #expect(project.finalReportSnapshots.isEmpty)
        #expect(project.knowledgeSeeds.isEmpty)
        #expect(project.aiChatMessages.isEmpty)
        #expect(project.aiChatDraft.isEmpty)
        #expect(!project.noteAIContextEnabled)
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
            // 独立凭证 service：不触碰生产条目，避免授权弹窗（与 Key 分家测试同一模式）
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.project-store"
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

    @Test("关联项目上下文独立合并，不覆盖笔记与录音数据")
    func relatedContextOwnership() {
        let stored = Project(
            title: "存储副本",
            sourceType: .liveRecording,
            segments: [TranscriptSegment(
                startMs: 0,
                endMs: 500,
                text: "保留原文",
                source: .local,
                state: .final
            )],
            note: NoteDocument(markdown: "保留笔记")
        )
        let incoming = Project(
            id: stored.id,
            title: "旧标题",
            businessCategory: "经销商增长",
            projectBackgroundContext: "这是人工确认的项目背景。",
            relatedProjectIDs: [UUID(), UUID()],
            sourceType: .liveRecording,
            segments: [],
            note: NoteDocument(markdown: "旧笔记")
        )
        var projects = [stored]

        ProjectPersistence.upsert(
            incoming,
            into: &projects,
            fields: .relatedContext
        )

        #expect(projects[0].businessCategory == "经销商增长")
        #expect(projects[0].projectBackgroundContext == "这是人工确认的项目背景。")
        #expect(projects[0].relatedProjectIDs == incoming.relatedProjectIDs)
        #expect(projects[0].segments.count == 1)
        #expect(projects[0].note.markdown == "保留笔记")
        #expect(projects[0].title == "存储副本")
    }

    @Test("转写复查候选只更新自己的字段")
    func transcriptReviewOwnershipDoesNotOverwriteSegments() {
        let segment = TranscriptSegment(
            startMs: 0,
            endMs: 1_000,
            text: "存储中的原文",
            source: .local,
            state: .final
        )
        let stored = Project(
            title: "持久化",
            sourceType: .liveRecording,
            segments: [segment]
        )
        let stale = Project(
            id: stored.id,
            title: stored.title,
            sourceType: .liveRecording,
            segments: []
        )
        stale.transcriptReviewCandidates = [TranscriptReviewCandidate(
            segmentId: segment.id,
            wrong: "原文",
            right: "正文",
            sourceTextAtReview: segment.text
        )]
        var projects = [stored]

        ProjectPersistence.upsert(stale, into: &projects, fields: .transcriptReview)

        #expect(projects[0].segments.count == 1)
        #expect(projects[0].segments[0].text == "存储中的原文")
        #expect(projects[0].transcriptReviewCandidates.count == 1)
    }

    @Test("旧 AI 推断卡片的说话人确认可单独持久化")
    func legacyAnalysisOwnershipPersistsSpeakerOnly() throws {
        let evidenceID = UUID()
        let speakerID = UUID()
        let stored = Project(
            title: "旧快照",
            sourceType: .liveRecording,
            segments: [TranscriptSegment(
                id: evidenceID,
                startMs: 0,
                endMs: 1_000,
                text: "原话",
                source: .cloud,
                state: .final
            )]
        )
        let snapshot = AnalysisSnapshot(version: 1, analyzedThroughMs: 1_000)
        snapshot.insights = [Insight(
            category: .possibleMotive,
            subjectParticipantId: speakerID,
            statement: "需要推进",
            epistemicStatus: .inference,
            confidence: .medium,
            evidenceSegmentIds: [evidenceID]
        )]
        let incoming = Project(
            id: stored.id,
            title: stored.title,
            sourceType: .liveRecording,
            legacySnapshots: [snapshot]
        )
        var projects = [stored]

        ProjectPersistence.upsert(incoming, into: &projects, fields: .legacyAnalysis)

        #expect(projects[0].legacySnapshots.first?.insights.first?.subjectParticipantId == speakerID)
        #expect(projects[0].segments.first?.text == "原话")
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
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.field-merge.\(UUID().uuidString)"
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

    @Test("流水线旧副本不覆盖用户只确认过的说话人")
    func pipelineMergePreservesSpeakerOnlyConfirmation() {
        let projectID = UUID()
        let segmentID = UUID()
        let confirmedSpeakerID = UUID()
        let confirmed = TranscriptSegment(
            id: segmentID,
            startMs: 0,
            endMs: 1_000,
            text: "原始文字",
            participantId: confirmedSpeakerID,
            source: .cloud,
            state: .final,
            speakerWasUserConfirmed: true
        )
        let stored = Project(
            id: projectID,
            title: "存储项目",
            sourceType: .importedAudio,
            segments: [confirmed]
        )
        let pipeline = Project(
            id: projectID,
            title: "流水线旧副本",
            sourceType: .importedAudio,
            segments: [TranscriptSegment(
                id: segmentID,
                startMs: 0,
                endMs: 1_000,
                text: "原始文字",
                participantId: nil,
                source: .cloud,
                state: .final
            )]
        )
        var projects = [stored]

        ProjectPersistence.upsert(pipeline, into: &projects, fields: .importPipeline)

        #expect(projects[0].segments.first?.participantId == confirmedSpeakerID)
        #expect(projects[0].segments.first?.speakerWasUserConfirmed == true)
        #expect(projects[0].segments.first?.state == .final)
    }

    @Test("首页重命名只改标题：不冲掉磁盘上的片段、状态与分析（Bug 7）")
    func homeRenameOnlyTouchesTitle() {
        let id = UUID()
        let stored = Project(
            id: id,
            title: "旧标题",
            sourceType: .liveRecording,
            status: .ready,
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1_000, text: "已有文稿", source: .local, state: .final)
            ]
        )
        stored.durationMs = 60_000
        // 首页只拿到列表里的副本，改完标题就写库；其余字段必须保持磁盘上的值
        let renamed = Project(id: id, title: "客户走访 · 张总", sourceType: .liveRecording, status: .creating)
        renamed.lastActivityAt = stored.lastActivityAt.addingTimeInterval(60)
        var projects = [stored]

        ProjectPersistence.upsert(renamed, into: &projects, fields: .title)

        let merged = projects[0]
        #expect(merged.title == "客户走访 · 张总")
        #expect(merged.lastActivityAt == renamed.lastActivityAt)
        #expect(merged.status == .ready)
        #expect(merged.durationMs == 60_000)
        #expect(merged.segments.count == 1)
        #expect(merged.segments.first?.text == "已有文稿")
    }

    @Test("用户可从人工场景切回自动判断")
    func userScenarioCanReturnToAutomatic() {
        let id = UUID()
        let stored = Project(
            id: id,
            title: "场景",
            sourceType: .liveRecording,
            scenario: .clientVisit,
            scenarioWasUserSelected: true
        )
        let incoming = Project(
            id: id,
            title: "场景",
            sourceType: .liveRecording,
            scenario: nil,
            scenarioWasUserSelected: false
        )
        var projects = [stored]
        ProjectPersistence.upsert(
            incoming,
            into: &projects,
            fields: .userScenario
        )
        #expect(projects[0].scenario == nil)
        #expect(!projects[0].scenarioWasUserSelected)
    }

    @Test("导入项目刷新清单包含后台场景建议与选择来源")
    @MainActor
    func importedRefreshIncludesScenarioSuggestion() {
        let id = UUID()
        let workspace = Project(
            id: id,
            title: "打开中的工作台",
            sourceType: .importedAudio,
            aiChatMessages: [
                ProjectAIChatMessage(role: .user, text: "工作台里的背景")
            ],
            noteAIContextEnabled: true
        )
        let fresh = Project(
            id: id,
            title: "存储副本",
            sourceType: .importedAudio,
            scenario: .journalistInterview,
            scenarioWasUserSelected: false,
            status: .ready,
            finalReportSnapshots: [
                FinalReportSnapshot(
                    version: 1,
                    providerID: "p",
                    providerName: "P",
                    modelID: "m",
                    promptVersion: "v",
                    inputFingerprint: "f",
                    headline: "完整总结",
                    overview: "后台完整总结",
                    items: []
                )
            ],
            knowledgeSeeds: [
                KnowledgeSeed(
                    seedText: "后台生成的知识种子",
                    whyItMatters: "测试刷新",
                    evidenceSegmentIds: [UUID()]
                )
            ],
            aiChatMessages: [
                ProjectAIChatMessage(role: .assistant, text: "后台旧副本")
            ],
            noteAIContextEnabled: false
        )

        ProjectWorkspaceView.applyImportedStorageRefresh(from: fresh, to: workspace)

        #expect(workspace.scenario == .journalistInterview)
        #expect(workspace.scenarioWasUserSelected == false)
        #expect(workspace.finalReportSnapshots.count == 1)
        #expect(workspace.knowledgeSeeds.count == 1)
        #expect(workspace.aiChatMessages.first?.text == "工作台里的背景")
        #expect(workspace.noteAIContextEnabled)
    }

    @Test("实时保存只更新录音字段，保留后台报告、人物和笔记")
    func recordingRuntimePreservesConcurrentFields() throws {
        let stored = Project(title: "新标题", sourceType: .liveRecording, status: .recording,
                             speakers: [Speaker(cloudAlias: "p_01", displayName: "已更新姓名", colorToken: "blue")],
                             note: NoteDocument(markdown: "新笔记"),
                             processingJobs: [ProcessingJob(kind: .finalReport, status: .completed)])
        let segment = TranscriptSegment(startMs: 0, endMs: 1_000, text: "新文稿", source: .local, state: .final)
        let incoming = Project(id: stored.id, title: "旧标题", sourceType: .liveRecording, status: .ready,
                               runtimeAssetRelativePath: "Meetings/test/recording.caf", durationMs: 1_000,
                               segments: [segment])
        var projects = [stored]
        ProjectPersistence.upsert(incoming, into: &projects, fields: .recordingRuntime)
        #expect(stored.title == "新标题")
        #expect(stored.speakers.first?.displayName == "已更新姓名")
        #expect(stored.note.markdown == "新笔记")
        #expect(stored.processingJobs.first?.status == .completed)
        #expect(stored.status == .ready)
        #expect(stored.segments.first?.id == segment.id)
        #expect(stored.runtimeAssetRelativePath == incoming.runtimeAssetRelativePath)
    }

    @Test("报告保存保留同时更新的转写失败状态")
    func finalReportOnlyOwnsReportJob() {
        let stored = Project(title: "记录", sourceType: .liveRecording,
                             processingJobs: [ProcessingJob(kind: .transcription, status: .failedRetryable)])
        let incoming = Project(id: stored.id, title: "记录", sourceType: .liveRecording,
                               processingJobs: [ProcessingJob(kind: .transcription, status: .completed),
                                                ProcessingJob(kind: .finalReport, status: .completed)])
        var projects = [stored]
        ProjectPersistence.upsert(incoming, into: &projects, fields: .finalReport)
        #expect(stored.processingJobs.first(where: { $0.kind == .transcription })?.status == .failedRetryable)
        #expect(stored.processingJobs.first(where: { $0.kind == .finalReport })?.status == .completed)
    }

    @Test("结束空录音与失败任务不得显示成就绪")
    func processingStatusReflectsEvidence() {
        let project = Project(title: "记录", sourceType: .liveRecording, status: .ready)
        #expect(!project.hasUsableTranscript)
        #expect(project.processingStatusText == "录音已结束 · 无可用文稿")
        project.segments = [TranscriptSegment(startMs: 0, endMs: 1_000, text: "   ", source: .local, state: .final)]
        #expect(!project.hasUsableTranscript)
        project.segments[0].text = "有内容"
        #expect(project.processingStatusText == "文稿可用 · 未生成总结")
        project.processingJobs = [ProcessingJob(kind: .finalReport, status: .failedRetryable)]
        #expect(project.processingStatusText == "文稿可用 · 部分处理失败")
        project.status = .processing
        #expect(project.processingStatusText == "处理失败 · 可重试")
        #expect(project.hasFailedProcessingJobs)
    }

    @Test("存储不可用拒绝临时写入，删除后拒绝后台旧副本")
    @MainActor
    func unavailableAndDeletedProjectRejectWrites() throws {
        let directory = makeCaseDirectory("write-guard")
        let store = InMemoryProjectStore()
        let environment = AppEnvironment(meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: directory), projectStore: store,
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.unavailable-\(UUID())",
            isPersistentStorageUnavailable: true)
        let project = Project(title: "测试", sourceType: .liveRecording)
        #expect(throws: ProjectWriteError.self) { try environment.persist(project) }
        #expect(try store.loadProjects().isEmpty)
        let active = AppEnvironment(meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: directory), projectStore: store,
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.deleted-\(UUID())")
        try active.persist(project)
        try active.deleteProject(project)
        #expect(throws: ProjectWriteError.self) { try active.persist(project, fields: .finalReport) }
        #expect(try store.loadProjects().isEmpty)
    }

    @Test("删除项目：记录与项目目录一起消失，其他项目和其他目录不受影响")
    @MainActor
    func deleteProjectRemovesRecordAndDirectory() throws {
        let base = makeCaseDirectory("delete-project")
        let fileStore = MeetingFileStore(baseDirectory: base)
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: fileStore,
            projectStore: try JSONProjectStore(directory: base),
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.delete-project-\(UUID().uuidString)"
        )

        let doomed = Project(title: "待删", sourceType: .liveRecording, status: .ready)
        let keeper = Project(title: "保留", sourceType: .liveRecording, status: .ready)
        try environment.persist(doomed)
        try environment.persist(keeper)

        let doomedDirectory = try fileStore.ensureMeetingDirectory(for: doomed.id)
        let keeperDirectory = try fileStore.ensureMeetingDirectory(for: keeper.id)
        try Data("假录音".utf8).write(
            to: doomedDirectory.appending(path: "recording.caf", directoryHint: .notDirectory)
        )

        try environment.deleteProject(doomed)

        let remaining = try environment.allProjects()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == keeper.id)
        #expect(!FileManager.default.fileExists(atPath: doomedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: keeperDirectory.path))
    }

    @Test("删除没有落盘目录的项目不报错（创建中就被删）")
    @MainActor
    func deleteProjectWithoutDirectorySucceeds() throws {
        let base = makeCaseDirectory("delete-project-no-dir")
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: base),
            projectStore: try JSONProjectStore(directory: base),
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.delete-project-\(UUID().uuidString)"
        )
        let project = Project(title: "刚建就删", sourceType: .liveRecording, status: .creating)
        try environment.persist(project)

        try environment.deleteProject(project)

        #expect(try environment.allProjects().isEmpty)
    }

    @Test("识别人保留人工文字、星标和已确认归属")
    @MainActor
    func speakerRecognitionPreservesUserEditsAndConfirmedIdentity() {
        let confirmedSpeakerID = UUID()
        let segment = TranscriptSegment(startMs: 1_000, endMs: 3_000, text: "人工修正的交付范围",
            participantId: confirmedSpeakerID, remoteSpeakerLabel: "旧分组", source: .manual,
            state: .edited, isStarred: true, speakerConfidence: .medium,
            textWasUserEdited: true, speakerWasUserConfirmed: true)
        let snapshot = HistoricalSpeakerRelabeler.SegmentSnapshot(id: segment.id,
            startMs: segment.startMs, endMs: segment.endMs, text: segment.text,
            participantId: segment.participantId, speakerWasUserConfirmed: true)
        let result = HistoricalSpeakerRelabeler.Result(assignments: [segment.id: UUID()],
            processedChunkCount: 1, remoteLabels: [segment.id: "chunk:0:speaker_2"])

        let changed = ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: [snapshot], to: [segment])

        #expect(changed == [segment.id])
        #expect(segment.remoteSpeakerLabel == "chunk:0:speaker_2")
        #expect(segment.text == "人工修正的交付范围")
        #expect(segment.startMs == 1_000 && segment.endMs == 3_000)
        #expect(segment.isStarred)
        #expect(segment.source == .manual && segment.state == .edited)
        #expect(segment.textWasUserEdited == true)
        #expect(segment.participantId == confirmedSpeakerID)
        #expect(segment.speakerWasUserConfirmed == true)
        #expect(segment.speakerConfidence == .medium)
    }

    @Test("识别人为未改变片段写入匿名分组和匹配人物")
    @MainActor
    func speakerRecognitionAppliesLabelsAndKnownAssignments() {
        let known = TranscriptSegment(startMs: 0, endMs: 2_000, text: "先核对费用口径", source: .local, state: .final)
        let anonymous = TranscriptSegment(startMs: 2_000, endMs: 4_000, text: "再确认验收范围", source: .local, state: .final)
        let segments = [known, anonymous]
        let snapshots = segments.map {
            HistoricalSpeakerRelabeler.SegmentSnapshot(id: $0.id, startMs: $0.startMs, endMs: $0.endMs,
                text: $0.text, participantId: $0.participantId, speakerWasUserConfirmed: false)
        }
        let matchedSpeakerID = UUID()
        let result = HistoricalSpeakerRelabeler.Result(assignments: [known.id: matchedSpeakerID],
            processedChunkCount: 1, remoteLabels: [known.id: "chunk:0:speaker_1", anonymous.id: "chunk:0:speaker_2"])

        let changed = ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: snapshots, to: segments)

        #expect(changed == [known.id, anonymous.id])
        #expect(known.participantId == matchedSpeakerID)
        #expect(known.speakerConfidence == .high)
        #expect(known.remoteSpeakerLabel == "chunk:0:speaker_1")
        #expect(anonymous.remoteSpeakerLabel == "chunk:0:speaker_2")
        #expect(anonymous.participantId == nil && anonymous.speakerConfidence == nil)
        #expect(known.speakerWasUserConfirmed != true && anonymous.speakerWasUserConfirmed != true)
        #expect(segments.map(\.text) == ["先核对费用口径", "再确认验收范围"])
        #expect(ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: snapshots, to: segments).isEmpty)
    }

    @Test("识别人晚到结果不覆盖请求期间的文字、时间和归属修改")
    @MainActor
    func speakerRecognitionRejectsChangedOrNewSegments() throws {
        var segments = (0..<5).map { index in
            TranscriptSegment(startMs: Int64(index * 2_000), endMs: Int64(index * 2_000 + 1_000),
                text: "合成片段 \(index)", source: .local, state: .final)
        }
        let snapshots = segments.map {
            HistoricalSpeakerRelabeler.SegmentSnapshot(id: $0.id, startMs: $0.startMs, endMs: $0.endMs,
                text: $0.text, participantId: $0.participantId, speakerWasUserConfirmed: false)
        }
        segments[0].text = "请求期间人工更正"
        segments[0].textWasUserEdited = true
        segments[1].startMs += 100
        segments[2].endMs += 100
        segments[3].participantId = UUID()
        segments[4].speakerWasUserConfirmed = true
        segments.append(TranscriptSegment(startMs: 10_000, endMs: 11_000, text: "请求后新增",
            source: .manual, state: .edited))
        let result = HistoricalSpeakerRelabeler.Result(
            assignments: Dictionary(uniqueKeysWithValues: segments.map { ($0.id, UUID()) }),
            processedChunkCount: 1,
            remoteLabels: Dictionary(uniqueKeysWithValues: segments.map { ($0.id, "旧请求分组") }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(segments)

        let changed = ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: snapshots, to: segments)

        #expect(changed.isEmpty)
        #expect(try encoder.encode(segments) == before)
    }

    @Test("识别人拒绝失效人工锚点和已删除人物，保留其他组匹配", arguments: [false, true])
    @MainActor
    func speakerRecognitionRejectsInvalidAnchorsAndDeletedSpeakers(deleteAnchor: Bool) {
        let originalSpeakerID = UUID()
        let correctedSpeakerID = UUID()
        let deletedSpeakerID = UUID()
        let anchor = TranscriptSegment(startMs: 0, endMs: 1_000, text: "人工确认锚点",
            participantId: originalSpeakerID, source: .local, state: .final, speakerWasUserConfirmed: true)
        let sameGroup = TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "同组未确认片段", source: .local, state: .final)
        let deletedPerson = TranscriptSegment(startMs: 2_000, endMs: 3_000, text: "已删除人物的旧匹配", source: .local, state: .final)
        let unaffected = TranscriptSegment(startMs: 3_000, endMs: 4_000, text: "其他组仍可匹配", source: .local, state: .final)
        var segments = [anchor, sameGroup, deletedPerson, unaffected]
        let snapshots = segments.map {
            HistoricalSpeakerRelabeler.SegmentSnapshot(id: $0.id, startMs: $0.startMs, endMs: $0.endMs,
                text: $0.text, participantId: $0.participantId, speakerWasUserConfirmed: $0.speakerWasUserConfirmed == true)
        }
        let result = HistoricalSpeakerRelabeler.Result(assignments: [sameGroup.id: originalSpeakerID,
            deletedPerson.id: deletedSpeakerID, unaffected.id: originalSpeakerID], processedChunkCount: 1,
            remoteLabels: [anchor.id: "chunk:0:speaker_1", sameGroup.id: "chunk:0:speaker_1",
                deletedPerson.id: "chunk:0:speaker_2", unaffected.id: "chunk:0:speaker_3"])
        if deleteAnchor {
            segments.removeAll { $0.id == anchor.id }
        } else {
            anchor.participantId = correctedSpeakerID
        }

        let changed = ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: snapshots, to: segments,
            validSpeakerIDs: Set([originalSpeakerID, correctedSpeakerID]))

        #expect(changed == [sameGroup.id, deletedPerson.id, unaffected.id])
        #expect(sameGroup.remoteSpeakerLabel == "chunk:0:speaker_1")
        #expect(sameGroup.participantId == nil && sameGroup.speakerConfidence == nil)
        #expect(deletedPerson.remoteSpeakerLabel == "chunk:0:speaker_2")
        #expect(deletedPerson.participantId == nil && deletedPerson.speakerConfidence == nil)
        #expect(unaffected.remoteSpeakerLabel == "chunk:0:speaker_3")
        #expect(unaffected.participantId == originalSpeakerID && unaffected.speakerConfidence == .high)
        #expect(!changed.contains(anchor.id))
        if deleteAnchor {
            #expect(!segments.contains { $0.id == anchor.id })
        } else {
            #expect(anchor.participantId == correctedSpeakerID && anchor.speakerWasUserConfirmed == true)
            #expect(anchor.remoteSpeakerLabel == nil)
        }
    }

    @Test("回填矛盾不静默改写旧自动归属：标冲突待确认（15 号计划 F02）")
    @MainActor
    func speakerRecognitionFlagsConflictOnContradictingAssignment() {
        let oldSpeakerID = UUID()
        let newSpeakerID = UUID()
        let segment = TranscriptSegment(startMs: 0, endMs: 2_000, text: "自动归属片段",
            participantId: oldSpeakerID, remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerConfidence: .high)
        let snapshot = HistoricalSpeakerRelabeler.SegmentSnapshot(id: segment.id,
            startMs: 0, endMs: 2_000, text: "自动归属片段",
            participantId: oldSpeakerID, speakerWasUserConfirmed: false)
        let result = HistoricalSpeakerRelabeler.Result(
            assignments: [segment.id: newSpeakerID],
            processedChunkCount: 1,
            remoteLabels: [segment.id: "chunk:0:speaker_1"])

        let changed = ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: [snapshot], to: [segment])

        #expect(changed == [segment.id])
        #expect(segment.participantId == oldSpeakerID, "旧自动归属保留，不静默改写")
        #expect(segment.speakerAttributionConflict == true, "矛盾必须显式标记")
        #expect(segment.speakerConfidence == .low, "冲突态不宣称高置信")
        #expect(segment.speakerWasUserConfirmed != true)

        // 人工指认后解除冲突
        MeetingTranscriptEditor.assignSpeaker(
            segment, to: Participant(id: newSpeakerID, cloudAlias: "p_02",
                                     displayName: "李总", side: .counterpart))
        #expect(segment.speakerAttributionConflict == false)
        #expect(segment.speakerWasUserConfirmed == true)
        #expect(segment.participantId == newSpeakerID)
    }

    @Test("标签更换但解析不出人物：旧归属标待确认，不表现为新识别通过")
    @MainActor
    func speakerRecognitionFlagsConflictWhenLabelChangesWithoutAssignment() {
        let oldSpeakerID = UUID()
        let segment = TranscriptSegment(startMs: 0, endMs: 2_000, text: "标签更换片段",
            participantId: oldSpeakerID, remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerConfidence: .high)
        let snapshot = HistoricalSpeakerRelabeler.SegmentSnapshot(id: segment.id,
            startMs: 0, endMs: 2_000, text: "标签更换片段",
            participantId: oldSpeakerID, speakerWasUserConfirmed: false)
        // 新一轮结果只有新标签，没有 assignment
        let result = HistoricalSpeakerRelabeler.Result(
            assignments: [:], processedChunkCount: 1,
            remoteLabels: [segment.id: "chunk:0:speaker_2"])

        let changed = ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: [snapshot], to: [segment])

        #expect(changed == [segment.id])
        #expect(segment.remoteSpeakerLabel == "chunk:0:speaker_2")
        #expect(segment.participantId == oldSpeakerID)
        #expect(segment.speakerAttributionConflict == true)
        #expect(segment.speakerConfidence == .low)
    }

    @Test("回填幂等与冲突解除：相同结果清除待确认标记且二次运行零改动")
    @MainActor
    func speakerRecognitionClearsStaleConflictIdempotently() {
        let speakerID = UUID()
        let segment = TranscriptSegment(startMs: 0, endMs: 2_000, text: "幂等片段",
            participantId: speakerID, remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerConfidence: .low,
            speakerAttributionConflict: true)
        let snapshot = HistoricalSpeakerRelabeler.SegmentSnapshot(id: segment.id,
            startMs: 0, endMs: 2_000, text: "幂等片段",
            participantId: speakerID, speakerWasUserConfirmed: false)
        let result = HistoricalSpeakerRelabeler.Result(
            assignments: [segment.id: speakerID], processedChunkCount: 1,
            remoteLabels: [segment.id: "chunk:0:speaker_1"])

        let changed = ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: [snapshot], to: [segment])
        #expect(changed == [segment.id])
        #expect(segment.speakerAttributionConflict == false)
        #expect(segment.participantId == speakerID)

        #expect(ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: [snapshot], to: [segment]).isEmpty)
    }

    @Test("未被整场回填覆盖的片段保持原状（缺少覆盖不等于反证）")
    @MainActor
    func speakerRecognitionLeavesUncoveredSegmentsUntouched() {
        let speakerID = UUID()
        let segment = TranscriptSegment(startMs: 0, endMs: 2_000, text: "未覆盖片段",
            participantId: speakerID, remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerConfidence: .high,
            speakerAttributionConflict: true)
        let snapshot = HistoricalSpeakerRelabeler.SegmentSnapshot(id: segment.id,
            startMs: 0, endMs: 2_000, text: "未覆盖片段",
            participantId: speakerID, speakerWasUserConfirmed: false)
        let result = HistoricalSpeakerRelabeler.Result(assignments: [:], processedChunkCount: 1, remoteLabels: [:])

        let changed = ProjectWorkspaceView.applySpeakerRecognition(result, snapshots: [snapshot], to: [segment])

        #expect(changed.isEmpty)
        #expect(segment.participantId == speakerID)
        #expect(segment.speakerAttributionConflict == true, "未覆盖不清冲突也不清归属")
        #expect(segment.speakerConfidence == .high)
    }

    @Test("撤销归属经真实 persist 落盘：确认→撤销回同一人后重读为未确认（审查修复 1）")
    @MainActor
    func undoAttributionPersistsThroughManualSegmentsMerge() throws {
        let base = makeCaseDirectory("undo-attribution-persist")
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: base),
            projectStore: try JSONProjectStore(directory: base),
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.undo-attr-\(UUID().uuidString)"
        )
        let speakerID = UUID()
        let project = Project(title: "撤销落盘", sourceType: .liveRecording)
        project.speakers = [Speaker(id: speakerID, cloudAlias: "p_01", displayName: "甲")]
        let segment = TranscriptSegment(startMs: 0, endMs: 1_000, text: "自动归属",
            participantId: speakerID, source: .cloud, state: .final)
        project.segments = [segment]
        try environment.persist(project)

        // 手工句级确认（自动 A → 确认 A，人物没变但 confirmed/scope 变化）
        segment.speakerWasUserConfirmed = true
        segment.speakerConfirmationScope = .segment
        try environment.persist(project, fields: .manualSegments)
        var stored = try #require(try environment.allProjects().first)
        var storedSegment = try #require(stored.segments.first { $0.id == segment.id })
        #expect(storedSegment.speakerWasUserConfirmed == true)
        #expect(storedSegment.speakerConfirmationScope == .segment)

        // 撤销：回到同一人物但未确认、无作用域——四项旧条件全不成立
        segment.speakerWasUserConfirmed = nil
        segment.speakerConfirmationScope = nil
        try environment.persist(project, fields: .manualSegments)
        stored = try #require(try environment.allProjects().first)
        storedSegment = try #require(stored.segments.first { $0.id == segment.id })
        #expect(storedSegment.speakerWasUserConfirmed == nil, "撤销必须落盘")
        #expect(storedSegment.speakerConfirmationScope == nil, "作用域撤销必须落盘")

        // 冲突标记变化同样落盘
        segment.speakerAttributionConflict = true
        try environment.persist(project, fields: .manualSegments)
        stored = try #require(try environment.allProjects().first)
        storedSegment = try #require(stored.segments.first { $0.id == segment.id })
        #expect(storedSegment.speakerAttributionConflict == true)
    }

    @Test("合并录音复制句级作用域与冲突标记，重开不退回组级兼容语义（审查修复 5）")
    @MainActor
    func mergedRecordingCarriesScopeThroughCopyAndReload() throws {
        let base = makeCaseDirectory("merge-scope-copy")
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: base),
            projectStore: try JSONProjectStore(directory: base),
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.merge-scope-\(UUID().uuidString)"
        )
        let source = Project(title: "来源录音", sourceType: .liveRecording)
        let speaker = Speaker(cloudAlias: "p_01", displayName: "甲")
        source.speakers = [speaker]
        let segment = TranscriptSegment(startMs: 0, endMs: 1_000, text: "句级确认的片段",
            participantId: speaker.id, source: .cloud, state: .final,
            speakerWasUserConfirmed: true, speakerAttributionConflict: false,
            speakerConfirmationScope: .segment)
        source.segments = [segment]
        source.status = .ready
        try environment.persist(source)
        // 合并入口要求至少两场录音且都有可用文稿；第二场给一条最终片段
        let filler = Project(title: "第二场", sourceType: .liveRecording)
        filler.status = .ready
        filler.segments = [TranscriptSegment(startMs: 0, endMs: 1_000, text: "第二场的一句话",
            source: .local, state: .final)]
        try environment.persist(filler)
        let combined = try ProjectHomeSupport.makeCombinedAnalysisProject(from: [source, filler])
        try environment.persist(combined)
        let stored = try #require(try environment.allProjects().first { $0.id == combined.id })
        let copied = try #require(stored.segments.first { $0.text == "句级确认的片段" })
        #expect(copied.speakerConfirmationScope == .segment, "合并复制不得退回组级兼容语义")
        #expect(copied.speakerWasUserConfirmed == true)
        #expect(copied.speakerAttributionConflict == false)
        #expect(copied.participantId == copiedSpeakerID(in: stored, named: "甲"),
                "复制后指向合并项目内的人物副本")
        // 不反写来源录音
        let sourceReloaded = try #require(try environment.allProjects().first { $0.id == source.id })
        #expect(sourceReloaded.segments.first?.sourceAssetId == nil)
    }

    /// 合并项目里按姓名找人物副本 ID
    private func copiedSpeakerID(in project: Project, named name: String) -> UUID? {
        project.speakers.first { $0.displayName == name }?.id
    }

    @Test("生产回滚函数还原两棵模型全部归属字段与 updatedAt（审查修复 2）")
    @MainActor
    func rollbackAttributionStateRestoresBothModels() {
        let speakerA = UUID()
        let originalConflict = true
        let originalScope = SpeakerConfirmationScope.group
        let originalUpdatedAt = Date(timeIntervalSince1970: 700_000_000)
        // 两棵模型用同一片段实例语义：相同 UUID 才能按 entries 索引回滚
        let fixedSegmentID = UUID()
        let makeOriginal = { [TranscriptSegment(
            id: fixedSegmentID,
            startMs: 0, endMs: 1_000, text: "归属片段",
            participantId: speakerA, source: .cloud, state: .final,
            speakerAttributionConflict: originalConflict,
            speakerConfirmationScope: originalScope
        )] }
        // 操作前的 updatedAt 单独覆盖（init 里默认 Date()）
        func stamp(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
            segments.forEach { $0.updatedAt = originalUpdatedAt }
            return segments
        }
        let before = stamp(makeOriginal())
        let entry = ProjectWorkspaceView.SpeakerAttributionUndo.Entry(
            startMs: before[0].startMs, endMs: before[0].endMs,
            sourceAssetId: before[0].sourceAssetId,
            participantId: before[0].participantId,
            speakerWasUserConfirmed: before[0].speakerWasUserConfirmed,
            speakerAttributionConflict: before[0].speakerAttributionConflict,
            speakerConfirmationScope: before[0].speakerConfirmationScope,
            updatedAt: before[0].updatedAt
        )
        let entries: [UUID: ProjectWorkspaceView.SpeakerAttributionUndo.Entry] = [before[0].id: entry]

        // 模拟已应用的指认（meeting 与 project 两棵模型都被改写）
        let meetingSegments = makeOriginal()
        let projectSegments = makeOriginal()
        for segment in meetingSegments + projectSegments {
            segment.participantId = UUID()
            segment.speakerWasUserConfirmed = true
            segment.speakerAttributionConflict = false
            segment.speakerConfirmationScope = .segment
            segment.updatedAt = Date(timeIntervalSince1970: 800_000_000)
        }

        ProjectWorkspaceView.rollbackAttributionState(
            entries: entries,
            meetingSegments: meetingSegments,
            projectSegments: projectSegments
        )

        for segment in meetingSegments + projectSegments {
            #expect(segment.participantId == speakerA)
            #expect(segment.speakerWasUserConfirmed == nil)
            #expect(segment.speakerAttributionConflict == originalConflict)
            #expect(segment.speakerConfirmationScope == originalScope)
            #expect(segment.updatedAt == originalUpdatedAt, "updatedAt 必须一并还原")
        }
    }

    @Test("Shift 连续范围双向选择：锚点在上/在下都覆盖完整区间（第四轮复核 UI 逻辑）")
    @MainActor
    func shiftRangeCoversBothDirections() {
        let ids = (0..<8).map { _ in UUID() }
        // 锚点在上（3），当前在下（6）：3–6
        #expect(Set(ProjectWorkspaceView.shiftRange(
            anchorIndex: 3, currentIndex: 6, ordered: ids)) == Set(ids[3...6]))
        // 锚点在下（6），当前在上（3）：3–6（双向）
        #expect(Set(ProjectWorkspaceView.shiftRange(
            anchorIndex: 6, currentIndex: 3, ordered: ids)) == Set(ids[3...6]))
        // 同点：只含自身
        #expect(ProjectWorkspaceView.shiftRange(
            anchorIndex: 4, currentIndex: 4, ordered: ids) == [ids[4]])
        // 越界防御：空结果不 trap
        #expect(ProjectWorkspaceView.shiftRange(
            anchorIndex: 0, currentIndex: 99, ordered: ids).isEmpty)
    }

    @Test("组级生产事务：保存失败还原两棵独立活模型树（第四轮复核）")
    @MainActor
    func groupAssignSaveFailureRestoresTwoLiveModelTrees() throws {
        let base = makeCaseDirectory("group-txn-failure")
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: base),
            projectStore: try JSONProjectStore(directory: base),
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.group-txn-\(UUID().uuidString)"
        )
        let speakerA = UUID()
        let speakerB = UUID()
        let project = Project(title: "组级事务", sourceType: .liveRecording)
        project.speakers = [
            Speaker(id: speakerA, cloudAlias: "p_01", displayName: "甲"),
            Speaker(id: speakerB, cloudAlias: "p_02", displayName: "乙"),
        ]
        let label = "chunk:0:speaker_1"
        let anchor = TranscriptSegment(startMs: 0, endMs: 1_000, text: "锚点",
            remoteSpeakerLabel: label, source: .cloud, state: .final)
        let sameGroup = TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "同组",
            remoteSpeakerLabel: label, source: .cloud, state: .final)
        // meeting 树与 project 树是两棵独立实例（生产中 applyRuntime 会拷贝）
        project.segments = [
            TranscriptSegment(id: anchor.id, startMs: anchor.startMs, endMs: anchor.endMs,
                text: anchor.text, remoteSpeakerLabel: label, source: .cloud, state: .final),
            TranscriptSegment(id: sameGroup.id, startMs: sameGroup.startMs, endMs: sameGroup.endMs,
                text: sameGroup.text, remoteSpeakerLabel: label, source: .cloud, state: .final),
        ]
        let meetingTree: [TranscriptSegment] = [anchor, sameGroup]
        try environment.persist(project)

        // Workspace 事务顺序（mutation 前拍 before → assign → 模拟 applyRuntime 拷贝 → persist 失败）
        var before: [UUID: ProjectWorkspaceView.SpeakerAttributionUndo.Entry] = [:]
        for segment in meetingTree {
            before[segment.id] = ProjectWorkspaceView.attributionEntry(of: segment)
        }
        let outcome = SpeakerBackfill.assign(
            anchorSegmentId: anchor.id, to: speakerB, segments: meetingTree)
        #expect(outcome.changedSegmentIds.count == 2)
        // applyRuntime 等价拷贝：project 树同步为新值
        for segment in project.segments {
            segment.participantId = speakerB
            segment.speakerWasUserConfirmed = true
            segment.speakerConfirmationScope = .group
            segment.speakerAttributionConflict = false
        }

        environment.markPersistentStorageUnavailableForTesting()
        #expect(throws: ProjectWriteError.self) {
            try environment.persist(project, fields: .manualSegments)
        }
        // 磁盘保持旧值
        let stored = try #require(try environment.allProjects().first)
        for segment in stored.segments {
            #expect(segment.participantId == nil)
            #expect(segment.speakerConfirmationScope == nil)
        }
        // 生产共享回滚：两棵活模型树全部还原
        ProjectWorkspaceView.rollbackAttributionState(
            entries: before,
            meetingSegments: meetingTree,
            projectSegments: project.segments
        )
        for segment in meetingTree + project.segments {
            #expect(segment.participantId == nil, "两棵树都必须还原，不能残留新值")
            #expect(segment.speakerWasUserConfirmed == nil)
            #expect(segment.speakerConfirmationScope == nil)
        }
        // 解除注入重新提交成功
        environment.clearPersistentStorageUnavailableForTesting()
        for segment in meetingTree + project.segments {
            segment.participantId = speakerB
            segment.speakerWasUserConfirmed = true
            segment.speakerConfirmationScope = .group
            segment.speakerAttributionConflict = false
        }
        try environment.persist(project, fields: .manualSegments)
        let retried = try #require(try environment.allProjects().first)
        #expect(retried.segments.allSatisfy { $0.participantId == speakerB })
    }

    // MARK: - 录音持久化管线（.recordingRuntime + explicitSegmentIDs）回归（最终复核 P1）

    /// 生产录音持久化事务的最小复刻：
    /// makeRuntimeMeeting → mutate runtime → applyRuntime → persist(.recordingRuntime, explicitIDs)。
    /// 磁盘预置一条「其他来源已确认」行（模拟并行写入），验证保护不吞显式变更、并行内容不丢。
    @MainActor
    private func makeRecordingPersistenceFixture(
        directoryName: String,
        credentialTag: String
    ) throws -> (AppEnvironment, Project, Meeting, UUID, UUID) {
        let base = makeCaseDirectory(directoryName)
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: base),
            projectStore: try JSONProjectStore(directory: base),
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.\(credentialTag)-\(UUID().uuidString)"
        )
        let speakerA = UUID()
        let speakerB = UUID()
        let project = Project(title: "录音管线", sourceType: .liveRecording)
        project.speakers = [
            Speaker(id: speakerA, cloudAlias: "p_01", displayName: "甲"),
            Speaker(id: speakerB, cloudAlias: "p_02", displayName: "乙"),
        ]
        project.segments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, text: "目标行",
                remoteSpeakerLabel: "chunk:0:speaker_1", source: .cloud, state: .final),
            TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "并行确认行",
                participantId: speakerA, source: .cloud, state: .final,
                speakerWasUserConfirmed: true),
        ]
        project.note = NoteDocument(markdown: "手写笔记。")
        try environment.persist(project)
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        return (environment, project, meeting, speakerA, speakerB)
    }

    @Test("录音管线撤销落盘：confirmed 行撤销不再被合并保护吞掉（最终复核 P1）")
    @MainActor
    func recordingUndoPersistsThroughRuntimePipeline() throws {
        let (environment, project, meeting, speakerA, speakerB) = try makeRecordingPersistenceFixture(
            directoryName: "rec-undo", credentialTag: "rec-undo")
        // 磁盘预置：目标行已确认给乙（此前某次指认落盘）
        _ = SpeakerBackfill.assign(
            anchorSegmentId: meeting.segments[0].id, to: speakerB, segments: meeting.segments)
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(project, fields: .recordingRuntime)
        let afterAssign = try #require(try environment.allProjects().first)
        #expect(try #require(afterAssign.segments.first).participantId == speakerB,
                "前置：磁盘含 B")

        // 录音中撤销：before/after → undoDecision → 恢复 runtime 树 → persist(.recordingRuntime, IDs)
        let before = ProjectWorkspaceView.attributionEntry(of: meeting.segments[0])
        let after = ProjectWorkspaceView.attributionEntry(of: meeting.segments[0])
        let record = ProjectWorkspaceView.SpeakerAttributionUndo(
            kind: .group, speakerID: speakerB,
            entries: [meeting.segments[0].id: before],
            afterEntries: [meeting.segments[0].id: after],
            occurredAt: Date())
        switch ProjectWorkspaceView.undoDecision(
            for: meeting.segments[0], before: before, after: after,
            speakers: project.speakers) {
        case .apply:
            meeting.segments[0].participantId = nil
            meeting.segments[0].speakerWasUserConfirmed = nil
            meeting.segments[0].speakerAttributionConflict = nil
            meeting.segments[0].speakerConfirmationScope = nil
        case .skip(let reason):
            Issue.record("撤销不得跳过：\(reason)")
        }
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        // 关键：录音字段 + 显式 IDs（生产 syncAndPersist 链路）
        try environment.persist(
            project, fields: .recordingRuntime,
            explicitSegmentIDs: [meeting.segments[0].id])
        let stored = try #require(try environment.allProjects().first)
        let undone = try #require(stored.segments.first { $0.id == meeting.segments[0].id })
        #expect(undone.participantId == nil, "撤销必须落盘，不得被 confirmed 保护吞掉")
        #expect(undone.speakerWasUserConfirmed == nil)
        #expect(undone.speakerConfirmationScope == nil)
        // 并行确认行与笔记不受影响
        let untouched = try #require(stored.segments.first { $0.text == "并行确认行" })
        #expect(untouched.participantId == speakerA && untouched.speakerWasUserConfirmed == true)
        #expect(stored.note.markdown == "手写笔记。")
    }

    @Test("显式归属只应用归属字段：磁盘较新的文字/星标不被 runtime 旧副本覆盖（最终验收缺陷 1）")
    @MainActor
    func explicitAssignPreservesNewerNonAttributionContent() throws {
        let (environment, project, meeting, _, speakerB) = try makeRecordingPersistenceFixture(
            directoryName: "attr-only", credentialTag: "attr-only")
        let targetID = meeting.segments[0].id
        // 磁盘初始：旧文字、无星标
        try environment.persist(project, fields: .recordingRuntime)

        // 磁盘上同一句后来被人工编辑：新文字 + 星标（runtime 副本未知）
        let stored = try #require(try environment.allProjects().first)
        let storedSegment = try #require(stored.segments.first { $0.id == targetID })
        let newerText = "磁盘上人工编辑过的新文字"
        storedSegment.text = newerText
        storedSegment.isStarred = true
        storedSegment.updatedAt = Date()
        try environment.persist(stored, fields: .manualSegments)

        // runtime 树仍是旧文字副本（stale）；现在只改归属（撤销到未指认）
        meeting.segments[0].participantId = nil
        meeting.segments[0].speakerWasUserConfirmed = nil
        meeting.segments[0].speakerAttributionConflict = nil
        meeting.segments[0].speakerConfirmationScope = nil
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(
            project, fields: .recordingRuntime,
            explicitSegmentIDs: [targetID])

        // 磁盘：归属已撤销，但较新的文字与星标保留
        let after = try #require(try environment.allProjects().first)
        let merged = try #require(after.segments.first { $0.id == targetID })
        #expect(merged.participantId == nil, "归属变更必须落盘")
        #expect(merged.speakerWasUserConfirmed == nil)
        #expect(merged.speakerConfirmationScope == nil)
        #expect(merged.text == newerText, "较新的人工文字不得被 runtime 旧副本覆盖")
        #expect(merged.isStarred == true, "星标不得被 runtime 旧副本覆盖")

        // 反向：改判给乙同样只动归属
        meeting.segments[0].participantId = speakerB
        meeting.segments[0].speakerWasUserConfirmed = true
        meeting.segments[0].speakerConfirmationScope = .segment
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(
            project, fields: .recordingRuntime,
            explicitSegmentIDs: [targetID])
        let afterAssign = try #require(try environment.allProjects().first)
        let reassigned = try #require(afterAssign.segments.first { $0.id == targetID })
        #expect(reassigned.participantId == speakerB)
        #expect(reassigned.text == newerText, "改判同样只动归属")
        #expect(reassigned.isStarred == true)
    }

    @Test("写失败回滚后撤销强制意图：自动重试不得覆盖磁盘后来的人工归属（最终验收缺陷 2）")
    @MainActor
    func failedFlushRevokesExplicitIntentForAutomaticRetry() async throws {
        let base = makeCaseDirectory("revoke-intent")
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: base),
            projectStore: try JSONProjectStore(directory: base),
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.revoke-intent-\(UUID().uuidString)"
        )
        let speakerB = UUID()
        let project = Project(title: "意图撤销", sourceType: .liveRecording)
        project.speakers = [Speaker(id: speakerB, cloudAlias: "p_02", displayName: "乙")]
        project.segments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, text: "目标行",
                remoteSpeakerLabel: "chunk:0:speaker_1", source: .cloud, state: .final),
        ]
        try environment.persist(project)
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)

        var writeCalls = 0
        var shouldFail = false
        let controller = ProjectRuntimePersistenceController(
            meeting: meeting, project: project,
            persist: { [environment] project, explicitIDs in
                writeCalls += 1
                if shouldFail { throw ProjectWriteError.storageUnavailable }
                try environment.persist(
                    project, fields: .recordingRuntime, explicitSegmentIDs: explicitIDs)
            },
            debounce: .seconds(60),
            onFailure: { _ in }
        )
        // 生产事务：指认 → applyRuntime → 显式 flush 失败 → 调用方回滚并撤销意图
        _ = SpeakerBackfill.assign(
            anchorSegmentId: meeting.segments[0].id, to: speakerB, segments: meeting.segments)
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        controller.markExplicitSegmentIDs([meeting.segments[0].id])
        shouldFail = true
        #expect(!controller.flush(force: true), "前置：注入失败")
        // 调用方回滚 runtime 树 + 撤销强制意图（生产失败路径）
        meeting.segments[0].participantId = nil
        meeting.segments[0].speakerWasUserConfirmed = nil
        meeting.segments[0].speakerConfirmationScope = nil
        controller.clearPendingExplicitSegmentIDs()

        // 磁盘后来收到人工归属变更（另一工作台路径直接落盘）
        let storedMid = try #require(try environment.allProjects().first)
        let midSegment = try #require(storedMid.segments.first)
        midSegment.participantId = speakerB
        midSegment.speakerWasUserConfirmed = true
        midSegment.speakerConfirmationScope = .segment
        try environment.persist(storedMid, fields: .manualSegments)

        // 自动重试（转写 final 片段触发 schedule，无显式意图）不得覆盖磁盘人工归属
        shouldFail = false
        controller.schedule()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline, controller.writeAttemptCount < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let afterRetry = try #require(try environment.allProjects().first)
        let finalSegment = try #require(afterRetry.segments.first)
        #expect(finalSegment.participantId == speakerB,
                "回滚后撤销的强制意图不得在自动重试时覆盖磁盘后来的人工归属")
        #expect(finalSegment.speakerConfirmationScope == .segment)
        #expect(finalSegment.speakerWasUserConfirmed == true)
    }

    @Test("录音管线撤销失败重试：磁盘保持 B，解除注入后重试成功（最终复核 P1）")
    @MainActor
    func recordingUndoFailureRetry() throws {
        let (environment, project, meeting, _, speakerB) = try makeRecordingPersistenceFixture(
            directoryName: "rec-undo-retry", credentialTag: "rec-undo-retry")
        _ = SpeakerBackfill.assign(
            anchorSegmentId: meeting.segments[0].id, to: speakerB, segments: meeting.segments)
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(project, fields: .recordingRuntime)

        // 撤销 runtime 树
        meeting.segments[0].participantId = nil
        meeting.segments[0].speakerWasUserConfirmed = nil
        meeting.segments[0].speakerConfirmationScope = nil
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)

        environment.markPersistentStorageUnavailableForTesting()
        #expect(throws: ProjectWriteError.self) {
            try environment.persist(
                project, fields: .recordingRuntime,
                explicitSegmentIDs: [meeting.segments[0].id])
        }
        // 失败：磁盘保持 B（可重试状态）
        let duringFailure = try #require(try environment.allProjects().first)
        #expect(duringFailure.segments.first?.participantId == speakerB)

        environment.clearPersistentStorageUnavailableForTesting()
        try environment.persist(
            project, fields: .recordingRuntime,
            explicitSegmentIDs: [meeting.segments[0].id])
        let retried = try #require(try environment.allProjects().first)
        #expect(retried.segments.first?.participantId == nil)
        #expect(retried.segments.first?.speakerConfirmationScope == nil)
    }

    @Test("录音管线改判与清除：confirmed 行 A→B 改判、清除均落盘（最终复核 P1）")
    @MainActor
    func recordingReassignAndClearPersist() throws {
        let (environment, project, meeting, speakerA, speakerB) = try makeRecordingPersistenceFixture(
            directoryName: "rec-reassign-clear", credentialTag: "rec-reassign")
        // 预置：目标行已确认给甲
        meeting.segments[0].participantId = speakerA
        meeting.segments[0].speakerWasUserConfirmed = true
        meeting.segments[0].speakerConfirmationScope = .segment
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(project, fields: .recordingRuntime)

        // 改判 A→B（单条显式改判语义）经录音管线落盘
        meeting.segments[0].participantId = speakerB
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(
            project, fields: .recordingRuntime,
            explicitSegmentIDs: [meeting.segments[0].id])
        let afterReassign = try #require(try environment.allProjects().first)
        #expect(try #require(afterReassign.segments.first).participantId == speakerB,
                "confirmed 行改判必须落盘")

        // 清除归属经录音管线落盘
        MeetingTranscriptEditor.clearSpeaker(meeting.segments[0])
        meeting.segments[0].speakerConfirmationScope = .segment
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(
            project, fields: .recordingRuntime,
            explicitSegmentIDs: [meeting.segments[0].id])
        let afterClear = try #require(try environment.allProjects().first)
        let cleared = try #require(afterClear.segments.first)
        #expect(cleared.participantId == nil)
        #expect(cleared.speakerWasUserConfirmed == true, "清除是明确人工决定")
        #expect(cleared.speakerConfirmationScope == .segment)
    }

    @Test("组级生产事务：指认落盘→重读含 B+group→撤销落盘→重读旧值（第四轮复核）")
    @MainActor
    func groupAssignUndoReloadRoundTrip() throws {
        let base = makeCaseDirectory("group-undo-roundtrip")
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: base),
            projectStore: try JSONProjectStore(directory: base),
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.group-undo-\(UUID().uuidString)"
        )
        let speakerA = UUID()
        let speakerB = UUID()
        let project = Project(title: "组级撤销", sourceType: .liveRecording)
        project.speakers = [
            Speaker(id: speakerA, cloudAlias: "p_01", displayName: "甲"),
            Speaker(id: speakerB, cloudAlias: "p_02", displayName: "乙"),
        ]
        project.segments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, text: "锚点",
                remoteSpeakerLabel: "chunk:0:speaker_1", source: .cloud, state: .final),
        ]
        project.note = NoteDocument(markdown: "撤销后仍须保留的笔记。")
        try environment.persist(project)
        // 生产桥接：runtime 树与权威树分离
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)

        // ① 组级指认：before → assign → after → applyRuntime → persist
        let before = ProjectWorkspaceView.attributionEntry(of: meeting.segments[0])
        _ = SpeakerBackfill.assign(
            anchorSegmentId: meeting.segments[0].id, to: speakerB, segments: meeting.segments)
        let after = ProjectWorkspaceView.attributionEntry(of: meeting.segments[0])
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(project, fields: .manualSegments)
        // 重读磁盘：B + group 作用域确实落盘（此前的空转版本缺这一步）
        let afterAssign = try #require(try environment.allProjects().first)
        let assigned = try #require(afterAssign.segments.first { $0.id == meeting.segments[0].id })
        #expect(assigned.participantId == speakerB)
        #expect(assigned.speakerWasUserConfirmed == true)
        #expect(assigned.speakerConfirmationScope == .group)

        // ② 撤销：共享 undoDecision 按操作后状态匹配（kind=group 成立）→ 恢复 runtime 树 → 落盘
        let record = ProjectWorkspaceView.SpeakerAttributionUndo(
            kind: .group, speakerID: speakerB,
            entries: [meeting.segments[0].id: before],
            afterEntries: [meeting.segments[0].id: after],
            occurredAt: Date())
        // 撤销前 runtime 树仍持新值（生产中 attach 后由工作台持有）；undoDecision 以磁盘一致状态核对
        let appliedSegment = try #require(afterAssign.segments.first { $0.id == meeting.segments[0].id })
        switch ProjectWorkspaceView.undoDecision(
            for: appliedSegment, before: before, after: after,
            speakers: project.speakers) {
        case .apply:
            meeting.segments[0].participantId = before.participantId
            meeting.segments[0].speakerWasUserConfirmed = before.speakerWasUserConfirmed
            meeting.segments[0].speakerAttributionConflict = before.speakerAttributionConflict
            meeting.segments[0].speakerConfirmationScope = before.speakerConfirmationScope
        case .skip(let reason):
            Issue.record("组级撤销不得跳过：\(reason)")
        }
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(project, fields: .manualSegments)

        // ③ 重读磁盘：恢复到指认前（人物未指认），笔记保留
        let stored = try #require(try environment.allProjects().first)
        let storedSegment = try #require(stored.segments.first { $0.id == meeting.segments[0].id })
        #expect(storedSegment.participantId == nil)
        #expect(storedSegment.speakerWasUserConfirmed == nil)
        #expect(storedSegment.speakerConfirmationScope == nil)
        #expect(stored.note.markdown == "撤销后仍须保留的笔记。")
    }

    @Test("组级过期预览：新增同标签语句后重算资格集不一致即拒绝（第四轮复核）")
    @MainActor
    func staleGroupPreviewRejectedAfterNewSameLabelSegment() {
        let target = UUID()
        let label = "chunk:0:speaker_1"
        let anchor = TranscriptSegment(startMs: 0, endMs: 1_000, text: "锚点",
            remoteSpeakerLabel: label, source: .cloud, state: .final)
        let frozenSegments: [TranscriptSegment] = [anchor]
        guard let frozenPlan = SpeakerBackfill.groupAssignmentPlan(
            anchorSegmentId: anchor.id, to: target,
            segments: frozenSegments, includeAllUnconfirmed: false) else {
            Issue.record("冻结计划必须生成")
            return
        }
        #expect(frozenPlan.applicableSegmentIds == [anchor.id])

        // 预览后录音追加了一条同标签可修改句
        let appended = TranscriptSegment(startMs: 5_000, endMs: 6_000, text: "新到的同组句",
            remoteSpeakerLabel: label, source: .cloud, state: .final)
        let currentSegments: [TranscriptSegment] = [anchor, appended]
        let freshPlan = SpeakerBackfill.groupAssignmentPlan(
            anchorSegmentId: anchor.id, to: target,
            segments: currentSegments, includeAllUnconfirmed: false)
        #expect(freshPlan != nil)
        #expect(ProjectWorkspaceView.groupPlanDrifted(fresh: freshPlan!, frozen: frozenPlan),
                "新增同标签语句必须判定为计划漂移")

        // 无漂移时（同集合）不误报
        let unchanged = SpeakerBackfill.groupAssignmentPlan(
            anchorSegmentId: anchor.id, to: target,
            segments: frozenSegments, includeAllUnconfirmed: false)
        #expect(!ProjectWorkspaceView.groupPlanDrifted(fresh: unchanged!, frozen: frozenPlan))
    }

    @Test("保存失败注入：生产事务路径下两棵模型树与磁盘均回滚，撤销基线可重试（第四轮复核）")
    @MainActor
    func persistFailureKeepsDiskAndModelsUntouched() throws {
        let base = makeCaseDirectory("assign-persist-failure")
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: base),
            projectStore: try JSONProjectStore(directory: base),
            credentialServiceName: "com.zhaobo.BangWoFenXi.tests.assign-fail-\(UUID().uuidString)"
        )
        let speakerA = UUID()
        let speakerB = UUID()
        let project = Project(title: "保存失败注入", sourceType: .liveRecording)
        project.speakers = [
            Speaker(id: speakerA, cloudAlias: "p_01", displayName: "甲"),
            Speaker(id: speakerB, cloudAlias: "p_02", displayName: "乙"),
        ]
        let label = "chunk:0:speaker_1"
        project.segments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, text: "同组一",
                remoteSpeakerLabel: label, source: .cloud, state: .final),
            TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "同组二",
                remoteSpeakerLabel: label, source: .cloud, state: .final),
        ]
        project.note = NoteDocument(markdown: "用户手写笔记，全程不得被指认事务触碰。")
        try environment.persist(project)

        // 生产桥接：runtime 树（工作台持有）与权威树（project.segments）从此分离
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        // 指认事务：mutation 前拍 before（runtime 树）→ 组级 assign → applyRuntime 同步权威树
        var before: [UUID: ProjectWorkspaceView.SpeakerAttributionUndo.Entry] = [:]
        for segment in meeting.segments {
            before[segment.id] = ProjectWorkspaceView.attributionEntry(of: segment)
        }
        let outcome = SpeakerBackfill.assign(
            anchorSegmentId: meeting.segments[0].id, to: speakerB, segments: meeting.segments)
        #expect(outcome.changedSegmentIds.count == 2)
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        // 注入持久层失败：生产同一 persist 入口必须抛错，不静默
        environment.markPersistentStorageUnavailableForTesting()
        #expect(throws: ProjectWriteError.self) {
            try environment.persist(project, fields: .manualSegments)
        }
        // 磁盘保持旧值
        let stored = try #require(try environment.allProjects().first)
        #expect(stored.segments.allSatisfy { $0.participantId == nil && $0.speakerConfirmationScope == nil })
        #expect(stored.note.markdown.contains("手写笔记"))
        // 生产共享回滚：两棵活模型树全部还原（runtime 树 + 权威树）
        ProjectWorkspaceView.rollbackAttributionState(
            entries: before,
            meetingSegments: meeting.segments,
            projectSegments: project.segments
        )
        for segment in meeting.segments + project.segments {
            #expect(segment.participantId == nil, "两棵树都必须还原，不能残留新值")
            #expect(segment.speakerWasUserConfirmed == nil)
            #expect(segment.speakerConfirmationScope == nil)
        }
        // 可重试基线：before 快照与磁盘旧值逐条一致（失败后撤销记录仍指向可恢复状态）
        for segment in stored.segments {
            let baseline = try #require(before[segment.id])
            #expect(baseline.participantId == segment.participantId)
            #expect(baseline.speakerWasUserConfirmed == segment.speakerWasUserConfirmed)
            #expect(baseline.speakerConfirmationScope == segment.speakerConfirmationScope)
        }
        // 解除注入：同一变更集重试成功（重新 assign + applyRuntime + persist）
        environment.clearPersistentStorageUnavailableForTesting()
        _ = SpeakerBackfill.assign(
            anchorSegmentId: meeting.segments[0].id, to: speakerB, segments: meeting.segments)
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        try environment.persist(project, fields: .manualSegments)
        let retried = try #require(try environment.allProjects().first)
        #expect(retried.segments.allSatisfy {
            $0.participantId == speakerB && $0.speakerConfirmationScope == .group
        })
        #expect(retried.note.markdown.contains("手写笔记"), "笔记不被指认事务触碰")
    }

    @Test("冻结边界核对拒绝 UUID 保留但时间/来源/归属变化的重切片段（审查修复 3）")
    @MainActor
    func frozenBoundariesRejectResegmentedCarriedUUID() {
        let segmentID = UUID()
        let frozenEntry = ProjectWorkspaceView.SpeakerAttributionUndo.Entry(
            startMs: 0, endMs: 2_000, sourceAssetId: nil,
            participantId: nil, speakerWasUserConfirmed: nil,
            speakerAttributionConflict: nil, speakerConfirmationScope: nil,
            updatedAt: Date(timeIntervalSince1970: 700_000_000)
        )
        let frozen: [UUID: ProjectWorkspaceView.SpeakerAttributionUndo.Entry] = [segmentID: frozenEntry]

        func currentSegment(startMs: Int64, endMs: Int64, source: UUID?) -> TranscriptSegment {
            let segment = TranscriptSegment(id: segmentID, startMs: startMs, endMs: endMs,
                text: "重切后保留 UUID", source: .cloud, state: .final)
            segment.sourceAssetId = source
            return segment
        }

        // 完全一致 → 通过
        #expect(ProjectWorkspaceView.frozenBoundariesStillValid(
            frozen: frozen, applicable: [segmentID],
            segments: [currentSegment(startMs: 0, endMs: 2_000, source: nil)]))
        // 云端重切保留 UUID 但边界变化 → 拒绝
        #expect(!ProjectWorkspaceView.frozenBoundariesStillValid(
            frozen: frozen, applicable: [segmentID],
            segments: [currentSegment(startMs: 0, endMs: 1_200, source: nil)]))
        // 来源资产变化（合并录音语境）→ 拒绝
        #expect(!ProjectWorkspaceView.frozenBoundariesStillValid(
            frozen: frozen, applicable: [segmentID],
            segments: [currentSegment(startMs: 0, endMs: 2_000, source: UUID())]))
        // 预览清单与当前可修改清单不一致 → 拒绝
        #expect(!ProjectWorkspaceView.frozenBoundariesStillValid(
            frozen: frozen, applicable: [UUID()],
            segments: [currentSegment(startMs: 0, endMs: 2_000, source: nil)]))
    }

    @Test("批量指认幂等解除冲突标记；原话行冲突显示后缀")
    @MainActor
    func speakerBackfillAndRowDisplayHandleConflict() {
        let speakerID = UUID()
        let anchor = TranscriptSegment(startMs: 0, endMs: 1_000, text: "锚点",
            remoteSpeakerLabel: "chunk:0:speaker_1", source: .cloud, state: .final)
        let conflict = TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "冲突片段",
            participantId: UUID(), remoteSpeakerLabel: "chunk:0:speaker_1",
            source: .cloud, state: .final, speakerAttributionConflict: true)
        let outcome = SpeakerBackfill.assign(
            anchorSegmentId: anchor.id, to: speakerID, segments: [anchor, conflict])
        #expect(outcome.changedSegmentIds.count == 2)
        #expect(conflict.speakerAttributionConflict == false)
        #expect(conflict.speakerWasUserConfirmed == true)
        #expect(conflict.participantId == speakerID)

        // 已指认但冲突标记残留的场景：再次批量指认幂等解除
        conflict.speakerAttributionConflict = true
        let second = SpeakerBackfill.assign(
            anchorSegmentId: anchor.id, to: speakerID, segments: [anchor, conflict])
        #expect(second.changedSegmentIds == [conflict.id])
        #expect(conflict.speakerAttributionConflict == false)

        // 原话行显示冲突后缀，且不影响正常行的名字
        let participant = Participant(cloudAlias: "p_01", displayName: "张总", side: .counterpart)
        conflict.participantId = participant.id
        conflict.speakerAttributionConflict = true
        let conflictRow = TranscriptRowData.make(
            from: conflict, participants: [participant], unknownDisplay: nil, highlightedID: nil)
        #expect(conflictRow.speakerName == "张总（归属待确认）")
        conflict.speakerAttributionConflict = false
        let normalRow = TranscriptRowData.make(
            from: conflict, participants: [participant], unknownDisplay: nil, highlightedID: nil)
        #expect(normalRow.speakerName == "张总")
    }

}
