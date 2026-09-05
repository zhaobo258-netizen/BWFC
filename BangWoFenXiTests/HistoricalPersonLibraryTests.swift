import Foundation
import Testing
@testable import BangWoFenXi

@Suite("历史人物库")
struct HistoricalPersonLibraryTests {
    @Test("人物档案聚合跨会议发言和证据")
    func summariesAndEvidence() {
        let profileID = UUID()
        let speakerOne = Speaker(
            cloudAlias: "p_01",
            displayName: "张三",
            voiceProfileId: profileID
        )
        let speakerTwo = Speaker(
            cloudAlias: "p_02",
            displayName: "张三",
            voiceProfileId: profileID
        )
        let first = TranscriptSegment(
            startMs: 0,
            endMs: 2_000,
            text: "先讲结论。",
            participantId: speakerOne.id,
            source: .cloud,
            state: .final
        )
        first.speakerWasUserConfirmed = true
        let second = TranscriptSegment(
            startMs: 3_000,
            endMs: 5_000,
            text: "再说三个依据。",
            participantId: speakerTwo.id,
            source: .cloud,
            state: .edited
        )
        second.speakerWasUserConfirmed = true
        let projects = [
            Project(
                title: "第一次会议",
                sourceType: .liveRecording,
                lastActivityAt: Date(timeIntervalSince1970: 10),
                speakers: [speakerOne],
                segments: [first]
            ),
            Project(
                title: "第二次会议",
                sourceType: .liveRecording,
                lastActivityAt: Date(timeIntervalSince1970: 20),
                speakers: [speakerTwo],
                segments: [second]
            )
        ]
        let profile = SpeakerVoiceProfile(
            id: profileID,
            displayName: "张三",
            role: "区域负责人",
            colorToken: "blue",
            sampleRelativePath: "VoiceProfiles/\(profileID.uuidString)/reference.wav",
            sampleDurationMs: 3_000,
            isAutoEnabled: true,
            createdAt: .distantPast,
            updatedAt: .now
        )

        let summary = HistoricalPersonLibrary.summaries(
            profiles: [profile],
            projects: projects
        )[0]
        let evidence = HistoricalPersonLibrary.communicationEvidence(
            profileID: profileID,
            projects: projects
        )

        #expect(summary.projects.map(\.title) == ["第二次会议", "第一次会议"])
        #expect(summary.attributedSegmentCount == 2)
        #expect(summary.userConfirmedSegmentCount == 2)
        #expect(evidence.map(\.segmentID) == [first.id, second.id])
    }

    @Test("表达画像不把云端自动归属冒充人工确认证据")
    func communicationEvidenceRequiresUserConfirmation() {
        let profileID = UUID()
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "张三",
            voiceProfileId: profileID
        )
        let automatic = TranscriptSegment(
            startMs: 0,
            endMs: 2_000,
            text: "云端自动归属。",
            participantId: speaker.id,
            source: .cloud,
            state: .final
        )
        let confirmed = TranscriptSegment(
            startMs: 3_000,
            endMs: 5_000,
            text: "用户已确认。",
            participantId: speaker.id,
            source: .cloud,
            state: .final
        )
        confirmed.speakerWasUserConfirmed = true
        let project = Project(
            title: "会议",
            sourceType: .liveRecording,
            speakers: [speaker],
            segments: [automatic, confirmed]
        )

        let evidence = HistoricalPersonLibrary.communicationEvidence(
            profileID: profileID,
            projects: [project]
        )

        #expect(evidence.map(\.segmentID) == [confirmed.id])
    }

    @Test("合并分析副本不重复计入人物发言、画像证据和声纹素材")
    func derivedProjectsDoNotDuplicateLearning() throws {
        let profileID = UUID()
        let firstSpeaker = Speaker(cloudAlias: "p_01", displayName: "甲", voiceProfileId: profileID)
        let secondSpeaker = Speaker(cloudAlias: "p_01", displayName: "甲", voiceProfileId: profileID)
        let firstSegment = TranscriptSegment(
            startMs: 0, endMs: 3_000, text: "第一段。", participantId: firstSpeaker.id,
            source: .local, state: .final, speakerWasUserConfirmed: true
        )
        let secondSegment = TranscriptSegment(
            startMs: 0, endMs: 3_000, text: "第二段。", participantId: secondSpeaker.id,
            source: .local, state: .final, speakerWasUserConfirmed: true
        )
        let first = Project(
            title: "一", sourceType: .liveRecording, status: .ready,
            lastActivityAt: Date(timeIntervalSince1970: 1),
            runtimeAssetRelativePath: "Meetings/one/recording.caf",
            speakers: [firstSpeaker], segments: [firstSegment]
        )
        let second = Project(
            title: "二", sourceType: .liveRecording, status: .ready,
            lastActivityAt: Date(timeIntervalSince1970: 2),
            runtimeAssetRelativePath: "Meetings/two/recording.caf",
            speakers: [secondSpeaker], segments: [secondSegment]
        )
        let combined = try ProjectHomeSupport.makeCombinedAnalysisProject(from: [first, second])
        combined.runtimeAssetRelativePath = "Meetings/derived/recording.caf"
        let profile = personProfile(id: profileID)
        let projects = [combined, first, second]

        let summary = try #require(HistoricalPersonLibrary.summaries(profiles: [profile], projects: projects).first)
        #expect(summary.projects.count == 2)
        #expect(summary.userConfirmedSegmentCount == 2)
        #expect(HistoricalPersonLibrary.communicationEvidence(profileID: profileID, projects: projects)
            .map(\.segmentID) == [firstSegment.id, secondSegment.id])
        #expect(HistoricalPersonLibrary.voiceprintSampleClips(
            profileID: profileID, projects: projects, targetDurationMs: 10_000
        ).isEmpty)
    }

    @MainActor
    @Test("画像等待期间新增、删除与编辑项目不会被旧库覆盖")
    func profileUpdatePreservesChangesDuringGeneration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = personProfile()
        profile.isCurrentUser = true
        let nextCurrentUser = personProfile()
        try saveProfiles([profile, nextCurrentUser], in: root)
        let profileStore = SpeakerVoiceProfileStore(baseDirectory: root)
        let projectStore = try JSONProjectStore(directory: root)
        let source = confirmedProject(profileID: profile.id)
        source.speakers[0].isCurrentUser = true
        let deleted = Project(title: "待删录音", sourceType: .liveRecording)
        try projectStore.saveProjects([source, deleted])
        let generation = HistoricalPersonDelayedGeneration()
        let update = Task {
            try await HistoricalPersonLibrary.updateCommunicationProfile(
                profileID: profile.id, profileStore: profileStore,
                projectStore: projectStore, generationService: generation
            )
        }
        await generation.waitUntilRequested()
        let latestSource = try #require(projectStore.loadProjects().first { $0.id == source.id })
        latestSource.title = "用户最新标题"
        latestSource.note.markdown = "模型等待期间的新笔记"
        latestSource.segments.append(TranscriptSegment(
            startMs: 7_000, endMs: 8_000, text: "新转写", source: .local, state: .final
        ))
        let added = Project(title: "新录音", sourceType: .liveRecording)
        try projectStore.saveProjects([latestSource, added])
        try profileStore.updateContext(
            profileID: profile.id, backgroundContext: "用户最新背景", communicationProfile: nil
        )
        try HistoricalPersonLibrary.setCurrentUser(
            profileID: nextCurrentUser.id, profileStore: profileStore, projectStore: projectStore
        )
        await generation.finish(evidenceID: source.segments[0].id)
        #expect(try await update.value == 2)

        let stored = try projectStore.loadProjects()
        #expect(Set(stored.map(\.id)) == [source.id, added.id])
        let refreshed = try #require(stored.first { $0.id == source.id })
        #expect(refreshed.title == "用户最新标题")
        #expect(refreshed.note.markdown == "模型等待期间的新笔记")
        #expect(refreshed.segments.count == 3)
        #expect(refreshed.speakers.first?.communicationProfile?.summary == "可观察的沟通方式")
        #expect(try profileStore.loadForManagement().first?.backgroundContext == "用户最新背景")
        #expect(try profileStore.loadForManagement().filter { $0.isCurrentUser == true }.map(\.id) == [nextCurrentUser.id])
        #expect(refreshed.speakers.first?.isCurrentUser == false)
    }

    @MainActor
    @Test("画像等待期间删除人物后不重新创建档案")
    func profileDeletedDuringGenerationIsNotRecreated() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = personProfile()
        try saveProfiles([profile], in: root)
        let profileStore = SpeakerVoiceProfileStore(baseDirectory: root)
        let projectStore = try JSONProjectStore(directory: root)
        let source = confirmedProject(profileID: profile.id)
        try projectStore.saveProjects([source])
        let generation = HistoricalPersonDelayedGeneration()
        let update = Task {
            try await HistoricalPersonLibrary.updateCommunicationProfile(
                profileID: profile.id, profileStore: profileStore,
                projectStore: projectStore, generationService: generation
            )
        }
        await generation.waitUntilRequested()
        try profileStore.delete(profileID: profile.id)
        await generation.finish(evidenceID: source.segments[0].id)
        await #expect(throws: SpeakerVoiceProfileStoreError.profileNotFound) {
            _ = try await update.value
        }
        #expect(try profileStore.loadForManagement().isEmpty)
        #expect(try projectStore.loadProjects().first?.speakers.first?.communicationProfile == nil)
    }

    @MainActor
    @Test("设为我同步所有历史录音并保留各场笔记")
    func currentUserSelectionUpdatesEveryRecording() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var old = personProfile()
        old.isCurrentUser = true
        let selected = personProfile()
        try saveProfiles([old, selected], in: root)
        let profileStore = SpeakerVoiceProfileStore(baseDirectory: root)
        let projectStore = try JSONProjectStore(directory: root)
        let first = confirmedProject(profileID: old.id)
        first.speakers[0].isCurrentUser = true
        let second = confirmedProject(profileID: selected.id)
        second.note.markdown = "保留原笔记"
        let unlinked = Speaker(cloudAlias: "p_02", displayName: "临时人物", isCurrentUser: true)
        second.speakers.append(unlinked)
        try projectStore.saveProjects([first, second])

        try HistoricalPersonLibrary.setCurrentUser(
            profileID: selected.id, profileStore: profileStore, projectStore: projectStore
        )

        #expect(try profileStore.loadForManagement().filter { $0.isCurrentUser == true }.map(\.id) == [selected.id])
        let stored = try projectStore.loadProjects()
        #expect(stored.flatMap(\.speakers).filter { $0.isCurrentUser == true }.map(\.voiceProfileId) == [selected.id])
        #expect(stored.first { $0.id == second.id }?.note.markdown == "保留原笔记")
    }

    @MainActor
    @Test("画像写项目失败时恢复人物画像并保留等待期间修改")
    func profileWriteFailureRollsBackOnlyFreshState() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = personProfile()
        try saveProfiles([profile], in: root)
        let profileStore = SpeakerVoiceProfileStore(baseDirectory: root)
        let projectStore = HistoricalPersonFailingProjectStore(base: try JSONProjectStore(directory: root))
        let source = confirmedProject(profileID: profile.id)
        try projectStore.saveProjects([source])
        let generation = HistoricalPersonDelayedGeneration()
        let update = Task {
            try await HistoricalPersonLibrary.updateCommunicationProfile(
                profileID: profile.id, profileStore: profileStore,
                projectStore: projectStore, generationService: generation
            )
        }
        await generation.waitUntilRequested()
        let latest = try #require(projectStore.loadProjects().first)
        latest.note.markdown = "必须保留的新笔记"
        try projectStore.saveProjects([latest])
        try profileStore.updateContext(
            profileID: profile.id, backgroundContext: "必须保留的新背景", communicationProfile: nil
        )
        projectStore.failNextSave = true
        await generation.finish(evidenceID: source.segments[0].id)
        await #expect(throws: HistoricalPersonFailingProjectStore.Failure.save) {
            _ = try await update.value
        }

        let restored = try #require(projectStore.loadProjects().first)
        #expect(restored.note.markdown == "必须保留的新笔记")
        #expect(restored.speakers.first?.communicationProfile == nil)
        #expect(try profileStore.loadForManagement().first?.communicationProfile == nil)
        #expect(try profileStore.loadForManagement().first?.backgroundContext == "必须保留的新背景")
    }

    @MainActor
    @Test("设为我项目保存失败时全局和项目身份一起恢复")
    func failedCurrentUserSelectionRestoresIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var original = personProfile()
        original.isCurrentUser = true
        let selected = personProfile()
        try saveProfiles([original, selected], in: root)
        let profileStore = SpeakerVoiceProfileStore(baseDirectory: root)
        let projectStore = HistoricalPersonFailingProjectStore(base: try JSONProjectStore(directory: root))
        let source = confirmedProject(profileID: original.id)
        source.speakers[0].isCurrentUser = true
        try projectStore.saveProjects([source])
        projectStore.failNextSave = true

        #expect(throws: HistoricalPersonFailingProjectStore.Failure.save) {
            try HistoricalPersonLibrary.setCurrentUser(
                profileID: selected.id, profileStore: profileStore, projectStore: projectStore
            )
        }
        #expect(try profileStore.loadForManagement().filter { $0.isCurrentUser == true }.map(\.id) == [original.id])
        #expect(try projectStore.loadProjects().first?.speakers.first?.isCurrentUser == true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "bwfx-person-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func personProfile(id: UUID = UUID()) -> SpeakerVoiceProfile {
        SpeakerVoiceProfile(
            id: id, displayName: "测试人物", colorToken: "blue",
            sampleRelativePath: "VoiceProfiles/\(id.uuidString)/reference.wav",
            sampleDurationMs: 3_000, isAutoEnabled: true,
            createdAt: .distantPast, updatedAt: .distantPast
        )
    }

    private func saveProfiles(_ profiles: [SpeakerVoiceProfile], in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profiles).write(to: directory.appending(path: "speaker-profiles.json"), options: .atomic)
    }

    private func confirmedProject(profileID: UUID) -> Project {
        let speaker = Speaker(cloudAlias: "p_01", displayName: "测试人物", voiceProfileId: profileID)
        return Project(
            title: "历史录音", sourceType: .liveRecording, speakers: [speaker],
            segments: [0, 1].map { index in
                TranscriptSegment(
                    startMs: Int64(index * 3_000), endMs: Int64(index * 3_000 + 2_000),
                    text: "人工确认发言\(index)", participantId: speaker.id,
                    source: .local, state: .final, speakerWasUserConfirmed: true
                )
            }
        )
    }

    @Test("档案更新会同步所有关联会议，删除时解除关联")
    func applyAndUnlink() {
        let profileID = UUID()
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "旧名",
            voiceSamplePath: "VoiceProfiles/\(profileID.uuidString)/reference.wav",
            voiceSampleDurationMs: 3_000,
            voiceProfileId: profileID
        )
        let project = Project(
            title: "会议",
            sourceType: .liveRecording,
            speakers: [speaker]
        )
        let profile = SpeakerVoiceProfile(
            id: profileID,
            displayName: "新名",
            role: "总经理",
            colorToken: "orange",
            sampleRelativePath: "VoiceProfiles/\(profileID.uuidString)/reference.wav",
            sampleDurationMs: 3_000,
            isAutoEnabled: true,
            createdAt: .distantPast,
            updatedAt: .now,
            backgroundContext: "关注渠道效率",
            iflytekFeatureID: "feature-123"
        )

        #expect(HistoricalPersonLibrary.applyProfile(profile, to: [project]) == 1)
        #expect(speaker.displayName == "新名")
        #expect(speaker.backgroundContext == "关注渠道效率")
        #expect(speaker.iflytekFeatureID == "feature-123")
        #expect(speaker.voiceSamplePath == profile.sampleRelativePath)
        #expect(speaker.voiceSampleDurationMs == 3_000)

        #expect(HistoricalPersonLibrary.unlinkProfile(profile, from: [project]) == 1)
        #expect(speaker.voiceProfileId == nil)
        #expect(speaker.voiceSamplePath == nil)
        #expect(speaker.backgroundContext == nil)
        #expect(speaker.iflytekFeatureID == nil)
    }

    @Test("讯飞声纹样本只拼接人工确认发言并精确补足十秒")
    func voiceprintClipsUseConfirmedSpeechOnly() {
        let profileID = UUID()
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "张三",
            voiceProfileId: profileID
        )
        let first = TranscriptSegment(
            startMs: 1_000,
            endMs: 7_000,
            text: "第一段。",
            participantId: speaker.id,
            source: .cloud,
            state: .final
        )
        first.speakerWasUserConfirmed = true
        let automatic = TranscriptSegment(
            startMs: 8_000,
            endMs: 18_000,
            text: "仅云端自动归属。",
            participantId: speaker.id,
            source: .cloud,
            state: .final
        )
        let second = TranscriptSegment(
            startMs: 20_000,
            endMs: 26_000,
            text: "第二段。",
            participantId: speaker.id,
            source: .cloud,
            state: .edited
        )
        second.speakerWasUserConfirmed = true
        let project = Project(
            title: "会议",
            sourceType: .liveRecording,
            runtimeAssetRelativePath: "Meetings/test/recording.caf",
            pauseIntervals: [PauseInterval(startMs: 3_000, endMs: 4_000)],
            speakers: [speaker],
            segments: [first, automatic, second]
        )

        let clips = HistoricalPersonLibrary.voiceprintSampleClips(
            profileID: profileID,
            projects: [project],
            targetDurationMs: 10_000
        )

        #expect(clips.map(\.sourceAudioRelativePath) == [
            "Meetings/test/recording.caf",
            "Meetings/test/recording.caf"
        ])
        #expect(clips.map { $0.audioEndMs - $0.audioStartMs } == [6_000, 4_000])
        #expect(clips.reduce(0) { $0 + $1.audioEndMs - $1.audioStartMs } == 10_000)
    }

    @Test("人工确认语音不足十秒时不伪造讯飞声纹样本")
    func voiceprintClipsRejectInsufficientSpeech() {
        let profileID = UUID()
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "张三",
            voiceProfileId: profileID
        )
        let segment = TranscriptSegment(
            startMs: 0,
            endMs: 6_000,
            text: "只有六秒。",
            participantId: speaker.id,
            source: .cloud,
            state: .final
        )
        segment.speakerWasUserConfirmed = true
        let project = Project(
            title: "会议",
            sourceType: .liveRecording,
            runtimeAssetRelativePath: "Meetings/test/recording.caf",
            speakers: [speaker],
            segments: [segment]
        )

        #expect(
            HistoricalPersonLibrary.voiceprintSampleClips(
                profileID: profileID,
                projects: [project],
                targetDurationMs: 10_000
            ).isEmpty
        )
    }
}

private actor HistoricalPersonDelayedGeneration: AITextGenerationServing {
    private var response: CheckedContinuation<AITextGenerationResponse, any Error>?
    private var requestStarted: CheckedContinuation<Void, Never>?
    private var hasRequested = false

    func generate(_ request: AITextGenerationRequest) async throws -> AITextGenerationResponse {
        hasRequested = true
        requestStarted?.resume()
        requestStarted = nil
        return try await withCheckedThrowingContinuation { response = $0 }
    }

    func waitUntilRequested() async {
        if hasRequested { return }
        await withCheckedContinuation { requestStarted = $0 }
    }

    func finish(evidenceID: UUID) {
        response?.resume(returning: AITextGenerationResponse(
            text: """
            {"summary":"可观察的沟通方式","observations":[{"title":"明确依据","observation":"用事实解释决定","evidence_segment_ids":["\(evidenceID.uuidString)"]}]}
            """,
            provider: .init(id: "fixture", displayName: "本地测试", modelID: "fixture")
        ))
        response = nil
    }

    func testActiveConnection() async throws -> AIProviderDescriptor {
        .init(id: "fixture", displayName: "本地测试", modelID: "fixture")
    }
}

private final class HistoricalPersonFailingProjectStore: ProjectStoring, @unchecked Sendable {
    enum Failure: Error { case save }
    let base: any ProjectStoring
    var failNextSave = false

    init(base: any ProjectStoring) { self.base = base }

    func loadProjects() throws -> [Project] { try base.loadProjects() }

    func saveProjects(_ projects: [Project]) throws {
        if failNextSave {
            failNextSave = false
            throw Failure.save
        }
        try base.saveProjects(projects)
    }
}
