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

    @Test("删除项目：记录与项目目录一起消失，其他项目和其他目录不受影响")
    @MainActor
    func deleteProjectRemovesRecordAndDirectory() throws {
        let base = makeCaseDirectory("delete-project")
        let fileStore = MeetingFileStore(baseDirectory: base)
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: fileStore,
            projectStore: try JSONProjectStore(directory: base),
            keychainServiceName: "com.zhaobo.BangWoFenXi.tests.delete-project-\(UUID().uuidString)"
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
            keychainServiceName: "com.zhaobo.BangWoFenXi.tests.delete-project-\(UUID().uuidString)"
        )
        let project = Project(title: "刚建就删", sourceType: .liveRecording, status: .creating)
        try environment.persist(project)

        try environment.deleteProject(project)

        #expect(try environment.allProjects().isEmpty)
    }
}
