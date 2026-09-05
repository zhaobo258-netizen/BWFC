import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

@Suite("业务记忆读取与升级备份", .serialized)
@MainActor
struct AppEnvironmentMemoryTests {
    private func environment(projectStore: (any ProjectStoring)? = nil) throws -> AppEnvironment {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-人物 业务 100%-\(UUID())", directoryHint: .isDirectory)
        return AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: directory),
            projectStore: try projectStore ?? JSONProjectStore(directory: directory),
            credentialServiceName: "bwfx-memory-tests-\(UUID())"
        )
    }

    private func enrollSyntheticPerson(
        in env: AppEnvironment, name: String = "合成自动人物", frequency: Float = 220
    ) throws -> (profile: SpeakerVoiceProfile, person: Person) {
        let directory = env.fileStore.baseDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "synthetic-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<48_000 {
            channel[frame] = sin(2 * Float.pi * frequency * Float(frame) / 16_000) * 0.2
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: AudioRecordingSettings.fileSettings(for: format))
            try file.write(from: buffer)
        }
        let profile = try env.speakerVoiceProfileStore.enroll(
            displayName: name, role: "合成采购", colorToken: "blue", sourceSampleURL: url, durationMs: 3_000
        )
        let person = try env.personLibraryStore.ensurePerson(for: profile)
        return (profile, person)
    }

    @Test("刷新声纹保留说话人 ID 和代号，更新样本与特征并补人物链接")
    func refreshReferencesKeepsSpeakerIdentity() throws {
        let env = try environment()
        defer { try? FileManager.default.removeItem(at: env.fileStore.baseDirectory) }
        let fixture = try enrollSyntheticPerson(in: env)
        let speaker = Speaker(
            cloudAlias: "p_07", displayName: "本场旧称谓",
            voiceSamplePath: "legacy/stale.wav", voiceSampleDurationMs: 2_000,
            voiceProfileId: fixture.profile.id, iflytekFeatureID: "old-feature"
        )
        let project = Project(title: "合成旧录音", sourceType: .liveRecording)
        project.speakers = [speaker]
        try env.persist(project)
        try env.speakerVoiceProfileStore.setIFlytekVoiceprint(
            profileID: fixture.profile.id, featureID: "new-feature", sampleSHA256: "synthetic-hash"
        )

        let speakers = try env.refreshAutomaticSpeakerReferences(for: project.id)
        let refreshed = try #require(speakers.first)
        #expect(speakers.count == 1)
        #expect(refreshed.id == speaker.id)
        #expect(refreshed.cloudAlias == "p_07")
        #expect(refreshed.voiceProfileId == fixture.profile.id)
        #expect(refreshed.personId == fixture.person.id)
        #expect(refreshed.voiceSamplePath == fixture.profile.sampleRelativePath)
        #expect(refreshed.voiceSampleDurationMs == 3_000)
        #expect(refreshed.iflytekFeatureID == "new-feature")
        let stored = try #require(env.allProjects().first)
        #expect(stored.speakers.first?.id == speaker.id)
        #expect(stored.speakers.first?.iflytekFeatureID == "new-feature")
        let person = try #require(try env.personLibraryStore.person(id: fixture.person.id))
        #expect(person.speakerLinks.contains { $0.projectID == project.id && $0.speakerID == speaker.id })
    }

    @Test("空说话人的导入录音带入自动人物，重复刷新不增人且保留人物链接")
    func refreshReferencesSeedsImportedRecording() throws {
        let env = try environment()
        defer { try? FileManager.default.removeItem(at: env.fileStore.baseDirectory) }
        let fixture = try enrollSyntheticPerson(in: env)
        let project = Project(title: "合成导入音频", sourceType: .importedAudio)
        try env.persist(project)
        let first = try env.refreshAutomaticSpeakerReferences(for: project.id)
        let second = try env.refreshAutomaticSpeakerReferences(for: project.id)
        let speaker = try #require(first.first)
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(speaker.personId == fixture.person.id)
        #expect(speaker.voiceProfileId == fixture.profile.id)
        #expect(speaker.cloudAlias == "p_01")
        #expect(second.first?.id == speaker.id)
        #expect(second.first?.cloudAlias == speaker.cloudAlias)
        let person = try #require(try env.personLibraryStore.person(id: fixture.person.id))
        #expect(person.speakerLinks.filter { $0.projectID == project.id }.map(\.speakerID) == [speaker.id])
    }

    @Test("本场停用声纹后保留档案 ID，自动刷新不能重新启用")
    func refreshReferencesRespectsManualDisable() throws {
        let env = try environment()
        defer { try? FileManager.default.removeItem(at: env.fileStore.baseDirectory) }
        let fixture = try enrollSyntheticPerson(in: env)
        let project = Project(title: "合成停用声纹", sourceType: .importedAudio)
        let speaker = Speaker(cloudAlias: "p_04", displayName: fixture.person.displayName,
                              voiceProfileId: fixture.profile.id, personId: fixture.person.id)
        project.speakers = [speaker]
        try env.persist(project)
        try env.speakerVoiceProfileStore.setIFlytekVoiceprint(
            profileID: fixture.profile.id, featureID: "available-feature", sampleSHA256: "synthetic-hash"
        )
        let speakers = try env.refreshAutomaticSpeakerReferences(for: project.id)
        let stored = try #require(env.allProjects().first?.speakers.first)
        #expect(speakers.count == 1)
        #expect(stored.id == speaker.id)
        #expect(stored.cloudAlias == "p_04")
        #expect(stored.voiceProfileId == fixture.profile.id)
        #expect(stored.personId == fixture.person.id)
        #expect(stored.voiceSamplePath == nil)
        #expect(stored.legacyVoiceReferencePath == nil)
        #expect(stored.iflytekFeatureID == nil)
        #expect(SpeakerPanelLogic.activeVoiceReferenceCount(in: speakers) == 0)
    }

    @Test("同名说话人与同名人物不自动合并，各声纹只连接自己的 Person")
    func refreshReferencesNeverMatchesByName() throws {
        let env = try environment()
        defer { try? FileManager.default.removeItem(at: env.fileStore.baseDirectory) }
        let first = try enrollSyntheticPerson(in: env, name: "同名", frequency: 220)
        let second = try enrollSyntheticPerson(in: env, name: "同名", frequency: 330)
        let unlinked = Speaker(cloudAlias: "p_01", displayName: "同名")
        let project = Project(title: "合成同名录音", sourceType: .importedAudio)
        project.speakers = [unlinked]
        try env.persist(project)
        let speakers = try env.refreshAutomaticSpeakerReferences(for: project.id)
        #expect(speakers.count == 3)
        #expect(Set(speakers.map(\.id)).count == 3)
        #expect(Set(speakers.map(\.cloudAlias)).count == 3)
        let untouched = try #require(speakers.first { $0.id == unlinked.id })
        #expect(untouched.personId == nil)
        #expect(untouched.voiceProfileId == nil)
        #expect(untouched.cloudAlias == "p_01")
        #expect(speakers.first { $0.voiceProfileId == first.profile.id }?.personId == first.person.id)
        #expect(speakers.first { $0.voiceProfileId == second.profile.id }?.personId == second.person.id)
        for fixture in [first, second] {
            let person = try #require(try env.personLibraryStore.person(id: fixture.person.id))
            let links = person.speakerLinks.filter { $0.projectID == project.id }
            #expect(links.count == 1)
            #expect(links.first?.speakerID != unlinked.id)
        }
    }

    @Test("读取旧项目后出现新文稿和笔记，声纹刷新事务仍保留最新内容")
    func refreshReferencesPreservesConcurrentContent() throws {
        let store = InterleavingSpeakerRefreshProjectStore()
        let env = try environment(projectStore: store)
        defer { try? FileManager.default.removeItem(at: env.fileStore.baseDirectory) }
        _ = try enrollSyntheticPerson(in: env)
        let project = Project(title: "合成并发刷新", sourceType: .importedAudio)
        try env.persist(project)
        let laterSegment = TranscriptSegment(startMs: 0, endMs: 1_000, text: "后来确认的验收条件。",
                                             source: .manual, state: .edited)
        store.afterNextLoad = {
            let latest = try #require(store.loadProjects().first)
            latest.segments = [laterSegment]
            latest.note.markdown = "后来保存的业务笔记。"
            try store.saveProjects([latest])
        }
        _ = try env.refreshAutomaticSpeakerReferences(for: project.id)
        let latest = try #require(env.allProjects().first)
        #expect(latest.speakers.count == 1)
        #expect(latest.segments.map(\.id) == [laterSegment.id])
        #expect(latest.segments.first?.text == laterSegment.text)
        #expect(latest.note.markdown == "后来保存的业务笔记。")
    }

    @Test("业务项目作用域只进入已关联录音，不按录音 ID 匹配")
    func scopedMemories() throws {
        let env = try environment()
        let person = try env.personLibraryStore.createPerson(displayName: "合成人物")
        let project = Project(title: "合成录音", sourceType: .liveRecording)
        project.speakers = [Speaker(cloudAlias: "p_01", displayName: person.displayName, personId: person.id)]
        try env.persist(project)
        let business = try env.businessProjectStore.create(name: "合成业务", linkedProjectIDs: [project.id])
        let memory = MemoryEntry(content: "本项目按月统计", kind: .terminology,
            scope: MemoryScope(personID: person.id, businessProjectID: business.id, displayText: "本业务"),
            isManuallyAuthored: true, status: .active)
        _ = try env.personLibraryStore.replaceMemoryEntries(personID: person.id, entries: [memory])
        #expect(try env.applicableMemories(for: project).map(\.id) == [memory.id])
        let unrelated = Project(title: "另一场录音", sourceType: .liveRecording)
        unrelated.speakers = project.speakers
        #expect(try env.applicableMemories(for: unrelated).isEmpty)
        #expect(try env.applicableMemories(for: project, maximumCount: -1).isEmpty)
    }

    @Test("原文或人物变化及删除后，旧有效记忆立即退出问答上下文")
    func invalidatedSourceCannotLeak() throws {
        let env = try environment()
        let person = try env.personLibraryStore.createPerson(displayName: "合成来源人物")
        let source = Project(title: "合成来源", sourceType: .liveRecording)
        let speaker = Speaker(cloudAlias: "p_01", displayName: person.displayName, personId: person.id)
        source.speakers = [speaker]
        let segment = TranscriptSegment(startMs: 0, endMs: 2000, text: "按月统计有效客户",
            participantId: speaker.id, source: .local, state: .final, speakerWasUserConfirmed: true)
        source.segments = [segment]
        try env.persist(source)
        let memory = MemoryEntry(content: "按月统计", kind: .terminology,
            scope: MemoryScope(personID: person.id, businessProjectID: nil, displayText: "人物"),
            source: MemorySourceReference(recordingID: source.id, segmentID: segment.id, snippet: segment.text,
                sourceVersion: BusinessMemoryCandidateBuilder.sourceVersion(project: source, segment: segment)),
            status: .active)
        _ = try env.personLibraryStore.replaceMemoryEntries(personID: person.id, entries: [memory])
        #expect(try env.applicableMemories(for: source).count == 1)
        segment.text = "改成按周统计"
        try env.persist(source)
        #expect(try env.applicableMemories(for: source).isEmpty)
        segment.text = "按月统计有效客户"
        source.speakers[0].personId = UUID()
        try env.persist(source)
        let context = Project(title: "后续录音", sourceType: .liveRecording)
        context.speakers = [Speaker(cloudAlias: "p_01", displayName: person.displayName, personId: person.id)]
        #expect(try env.applicableMemories(for: context).isEmpty)
        try env.projectStore.saveProjects([])
        #expect(try env.applicableMemories(for: context).isEmpty)
    }

    @Test("未到生效时间的记忆不进入上下文，同名责任人不自动选第一人")
    func futureAndAmbiguousIdentity() throws {
        let env = try environment()
        let person = try env.personLibraryStore.createPerson(displayName: "同名")
        _ = try env.personLibraryStore.createPerson(displayName: "同名")
        let project = Project(title: "合成录音", sourceType: .liveRecording)
        project.speakers = [Speaker(cloudAlias: "p_01", displayName: person.displayName, personId: person.id)]
        let memory = MemoryEntry(content: "下月启用", kind: .confirmedConstraint,
            scope: MemoryScope(personID: person.id, businessProjectID: nil, displayText: "人物"),
            isManuallyAuthored: true, status: .active, effectiveFrom: .distantFuture)
        _ = try env.personLibraryStore.replaceMemoryEntries(personID: person.id, entries: [memory])
        #expect(try env.applicableMemories(for: project).isEmpty)
        #expect(env.personByExactDisplayName("同名") == nil)
    }

    @Test("损坏人物库显式失败，不伪装无可用记忆")
    func corruptStoreThrows() throws {
        let env = try environment()
        _ = try env.personLibraryStore.createPerson(displayName: "合成人物")
        let path = env.fileStore.baseDirectory.appending(path: "persons.json")
        try Data("broken".utf8).write(to: path)
        let project = Project(title: "合成录音", sourceType: .liveRecording)
        #expect(throws: (any Error).self) { try env.applicableMemories(for: project) }
    }

    @Test("人物改名与背景同步到录音，撤销保留之后的文稿")
    func metadataAndUndo() throws {
        let env = try environment()
        let person = try env.personLibraryStore.createPerson(displayName: "旧名")
        let project = Project(title: "合成录音", sourceType: .liveRecording)
        project.speakers = [Speaker(cloudAlias: "p_01", displayName: "旧名", personId: person.id)]
        try env.persist(project)
        try env.updateLibraryPersonMetadata(personID: person.id, displayName: "新名", role: "负责人", backgroundContext: "按月核对")
        #expect(try env.personLibraryStore.person(id: person.id)?.displayName == "新名")
        let stored = try #require(env.allProjects().first)
        #expect(stored.speakers[0].backgroundContext == "按月核对")
        stored.segments = [TranscriptSegment(startMs: 0, endMs: 10, text: "之后的文字", source: .manual, state: .edited)]
        try env.persist(stored)
        try env.undoPersonChange()
        let restored = try #require(env.allProjects().first)
        #expect(restored.speakers[0].displayName == "旧名")
        #expect(restored.segments.first?.text == "之后的文字")
    }

    @Test("来源导航请求只能被目标录音消费，离开时清除")
    func evidenceNavigation() {
        let router = AppRouter()
        let projectID = UUID(), segmentID = UUID()
        router.showProjectWorkspace(projectID, autoStart: false, evidenceSegmentID: segmentID)
        #expect(router.consumeEvidenceRequest(for: UUID()) == nil)
        #expect(router.consumeEvidenceRequest(for: projectID) == segmentID)
        #expect(router.consumeEvidenceRequest(for: projectID) == nil)
        router.showProjectWorkspace(projectID, autoStart: false, evidenceSegmentID: segmentID)
        router.showBusinessProjects()
        #expect(router.consumeEvidenceRequest(for: projectID) == nil)
    }

    @Test("迁移备份保留权威原文，可连续执行且复制失败时抛错", arguments: ["ascii", "中文 空格 100%"])
    func migrationBackup(directoryName: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bwfx-backup-\(directoryName)-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("synthetic-source".utf8)
        try data.write(to: directory.appending(path: "projects.json"))
        try AppEnvironment.backupAuthorityFilesBeforeMigration(in: directory, fileManager: .default)
        try AppEnvironment.backupAuthorityFilesBeforeMigration(in: directory, fileManager: .default)
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appending(path: "MigrationBackups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 2)
        for backup in backups { #expect(try Data(contentsOf: backup.appending(path: "projects.json")) == data) }
        #expect(throws: (any Error).self) {
            try AppEnvironment.backupAuthorityFilesBeforeMigration(in: directory, fileManager: FailingBackupFileManager())
        }
    }
}

private final class FailingBackupFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class InterleavingSpeakerRefreshProjectStore: ProjectStoring, @unchecked Sendable {
    private var data = Data("[]".utf8)
    var afterNextLoad: (() throws -> Void)?

    func loadProjects() throws -> [Project] {
        let projects = try JSONDecoder().decode([Project].self, from: data)
        let action = afterNextLoad
        afterNextLoad = nil
        try action?()
        return projects
    }

    func saveProjects(_ projects: [Project]) throws {
        data = try JSONEncoder().encode(projects)
    }
}
