import Foundation
import Testing
@testable import BangWoFenXi

@Suite("业务记忆读取与升级备份", .serialized)
@MainActor
struct AppEnvironmentMemoryTests {
    private func environment() throws -> AppEnvironment {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-人物 业务 100%-\(UUID())", directoryHint: .isDirectory)
        return AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: directory),
            projectStore: try JSONProjectStore(directory: directory),
            credentialServiceName: "bwfx-memory-tests-\(UUID())"
        )
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
