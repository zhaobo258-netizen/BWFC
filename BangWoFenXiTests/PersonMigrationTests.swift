import Foundation
import Testing
@testable import BangWoFenXi

@Suite("人物迁移（声纹档案 → Person）", .serialized)
struct PersonMigrationTests {
    @Test("迁移标记存在但人物文件丢失时显式失败，不当作空库")
    func missingMigratedStoreFailsClosed() throws {
        let directory = try temporaryDirectory()
        let persons = PersonLibraryStore(baseDirectory: directory)
        let profiles = SpeakerVoiceProfileStore(baseDirectory: directory)
        let projects = try JSONProjectStore(directory: directory)
        _ = try PersonMigrationCoordinator.migrateIfNeeded(personStore: persons, profileStore: profiles,
            projectStore: projects, baseDirectory: directory)
        try FileManager.default.removeItem(at: directory.appending(path: "persons.json"))
        #expect(throws: PersonLibraryStoreError.personNotFound) {
            try PersonMigrationCoordinator.migrateIfNeeded(personStore: persons, profileStore: profiles,
                projectStore: projects, baseDirectory: directory)
        }
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-person-mig-tests-中文 100%-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("首次迁移：为档案建人并回填 Speaker.personId，可重复运行不重复建人")
    func migrateAndRerun() throws {
        let directory = try temporaryDirectory()
        let profileStore = SpeakerVoiceProfileStore(baseDirectory: directory)
        let personStore = PersonLibraryStore(baseDirectory: directory)

        // 两个档案（其中一个设为“我”）
        let profileA = try profileStore.enroll(
            displayName: "张三", role: nil, colorToken: "blue",
            sourceSampleURL: try Self.sampleWav(in: directory, name: "a"),
            durationMs: 3_000
        )
        try profileStore.setCurrentUser(profileID: profileA.id)
        let profileB = try profileStore.enroll(
            displayName: "李四", role: "采购", colorToken: "green",
            sourceSampleURL: try Self.sampleWav(in: directory, name: "b"),
            durationMs: 3_000
        )

        // 两个项目，各有一个说话人挂到 profileA / profileB
        var project1 = Project(title: "会议一", sourceType: .liveRecording)
        let speaker1 = Speaker(cloudAlias: "p_01", displayName: "说话人 1", voiceProfileId: profileA.id)
        project1.speakers.append(speaker1)
        var project2 = Project(title: "会议二", sourceType: .liveRecording)
        let speaker2 = Speaker(cloudAlias: "p_01", displayName: "说话人 1", voiceProfileId: profileB.id)
        project2.speakers.append(speaker2)

        let store = InMemoryProjectStore(seed: [project1, project2])
        let outcome = try PersonMigrationCoordinator.migrateIfNeeded(
            personStore: personStore,
            profileStore: profileStore,
            projectStore: store,
            baseDirectory: directory
        )
        let projects = try store.loadProjects()
        #expect(outcome.createdPersonCount == 2)
        #expect(outcome.backfilledSpeakers.count == 2)
        #expect(!outcome.markerExisted)
        // personId 回填 == profile.id（复用为稳定 personId）
        #expect(projects[0].speakers[0].personId == profileA.id)
        #expect(projects[1].speakers[0].personId == profileB.id)

        let persons = try personStore.load()
        #expect(persons.count == 2)
        #expect(persons.filter(\.isCurrentUser).count == 1)
        #expect(persons.first { $0.id == profileA.id }?.isCurrentUser == true)
        #expect(persons.first { $0.id == profileA.id }?.linkedVoiceProfileID == profileA.id)
        // 账本记录了关联
        #expect(persons.first { $0.id == profileA.id }?.speakerLinks.count == 1)

        // 完成标记存在后不再迁移；新身份须由显式创建路径写入。
        let outcome2 = try PersonMigrationCoordinator.migrateIfNeeded(
            personStore: personStore,
            profileStore: profileStore,
            projectStore: store,
            baseDirectory: directory
        )
        #expect(outcome2.createdPersonCount == 0)
        #expect(outcome2.backfilledSpeakers.isEmpty)
        #expect(try personStore.load().count == 2)
        #expect(FileManager.default.fileExists(
            atPath: PersonMigrationCoordinator.markerURL(in: directory).path
        ))

        // 新项目即使携带旧 voiceProfileId，也不能借重启重建用户已删除的身份。
        var project3 = Project(title: "会议三", sourceType: .liveRecording)
        project3.speakers.append(Speaker(
            cloudAlias: "p_01", displayName: "说话人 1", voiceProfileId: profileA.id
        ))
        try store.saveProjects(projects + [project3])
        let outcome3 = try PersonMigrationCoordinator.migrateIfNeeded(
            personStore: personStore,
            profileStore: profileStore,
            projectStore: store,
            baseDirectory: directory
        )
        #expect(outcome3.createdPersonCount == 0)
        #expect(outcome3.backfilledSpeakers.isEmpty)
        #expect(try store.loadProjects()[2].speakers[0].personId == nil)
    }

    @Test("无档案说话人不被强行关联")
    func noProfileNoBackfill() throws {
        let directory = try temporaryDirectory()
        let personStore = PersonLibraryStore(baseDirectory: directory)
        var project = Project(title: "无档案", sourceType: .liveRecording)
        project.speakers.append(Speaker(cloudAlias: "p_01", displayName: "无名"))
        let store = InMemoryProjectStore(seed: [project])
        let outcome = try PersonMigrationCoordinator.migrateIfNeeded(
            personStore: personStore,
            profileStore: SpeakerVoiceProfileStore(baseDirectory: directory),
            projectStore: store,
            baseDirectory: directory
        )
        #expect(outcome.createdPersonCount == 0)
        #expect(outcome.backfilledSpeakers.isEmpty)
        #expect(try store.loadProjects()[0].speakers[0].personId == nil)
    }

    @Test("中文、空格与百分号目录识别迁移标记，重开不复活已删除人物")
    func completedMigrationDoesNotResurrectDeletedPerson() throws {
        let directory = try temporaryDirectory()
        let people = PersonLibraryStore(baseDirectory: directory)
        let profiles = SpeakerVoiceProfileStore(baseDirectory: directory)
        let profile = try profiles.enroll(
            displayName: "合成甲", role: nil, colorToken: "blue",
            sourceSampleURL: try Self.sampleWav(in: directory, name: "deleted"), durationMs: 3_000
        )
        let projects = InMemoryProjectStore()
        _ = try PersonMigrationCoordinator.migrateIfNeeded(
            personStore: people, profileStore: profiles, projectStore: projects, baseDirectory: directory
        )
        try people.deletePerson(personID: profile.id)
        _ = try PersonMigrationCoordinator.migrateIfNeeded(
            personStore: people, profileStore: profiles, projectStore: projects, baseDirectory: directory
        )
        #expect(try people.load().isEmpty)
        #expect(try profiles.loadForManagement().count == 1)
    }

    @Test("坏人物或声纹索引阻断迁移且不落完成标记")
    func corruptedSourceFailsClosed() throws {
        for file in ["persons.json", "speaker-profiles.json"] {
            let directory = try temporaryDirectory()
            let url = directory.appending(path: file)
            let original = Data("broken-json".utf8)
            try original.write(to: url)
            #expect(throws: Error.self) {
                _ = try PersonMigrationCoordinator.migrateIfNeeded(
                    personStore: PersonLibraryStore(baseDirectory: directory),
                    profileStore: SpeakerVoiceProfileStore(baseDirectory: directory),
                    projectStore: InMemoryProjectStore(), baseDirectory: directory
                )
            }
            #expect(try Data(contentsOf: url) == original)
            #expect(!FileManager.default.fileExists(atPath: PersonMigrationCoordinator.markerURL(in: directory).path))
        }
    }

    @Test("中文、空格与百分号目录中标记写失败回滚新人物与项目")
    func markerFailureRollsBackBothStores() throws {
        let directory = try temporaryDirectory()
        let people = PersonLibraryStore(baseDirectory: directory)
        let profiles = SpeakerVoiceProfileStore(baseDirectory: directory)
        let profile = try profiles.enroll(
            displayName: "合成甲", role: nil, colorToken: "blue",
            sourceSampleURL: try Self.sampleWav(in: directory, name: "rollback"), durationMs: 3_000
        )
        let project = Project(title: "合成会议", sourceType: .liveRecording)
        project.speakers = [Speaker(cloudAlias: "p_01", displayName: "甲", voiceProfileId: profile.id)]
        let store = InMemoryProjectStore(seed: [project])
        #expect(throws: Error.self) {
            _ = try PersonMigrationCoordinator.migrateIfNeeded(
                personStore: people, profileStore: profiles, projectStore: store, baseDirectory: directory,
                markerWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        }
        #expect(try people.load().isEmpty)
        #expect(try store.loadProjects().first?.speakers.first?.personId == nil)
        #expect(!FileManager.default.fileExists(atPath: PersonMigrationCoordinator.markerURL(in: directory).path))
    }

    @Test("不同Person ID已有声纹映射时回填真实Person ID")
    func usesExplicitVoiceMapping() throws {
        let directory = try temporaryDirectory()
        let people = PersonLibraryStore(baseDirectory: directory)
        let profiles = SpeakerVoiceProfileStore(baseDirectory: directory)
        let profile = try profiles.enroll(
            displayName: "声音甲", role: nil, colorToken: "blue",
            sourceSampleURL: try Self.sampleWav(in: directory, name: "mapping"), durationMs: 3_000
        )
        let person = try people.createPerson(displayName: "人物甲", linkedVoiceProfileID: profile.id)
        let project = Project(title: "会议", sourceType: .liveRecording)
        project.speakers = [Speaker(cloudAlias: "p_01", displayName: "甲", voiceProfileId: profile.id)]
        let store = InMemoryProjectStore(seed: [project])
        _ = try PersonMigrationCoordinator.migrateIfNeeded(
            personStore: people, profileStore: profiles, projectStore: store, baseDirectory: directory
        )
        #expect(try store.loadProjects().first?.speakers.first?.personId == person.id)
        #expect(try people.load().count == 1)
    }

    @Test("中文、空格与百分号目录回滚保留旧人物文件原字节并清理失败标记")
    func encodedDirectoryRollbackPreservesOriginalBytes() throws {
        let directory = try temporaryDirectory()
        let people = PersonLibraryStore(baseDirectory: directory)
        let existing = try people.createPerson(displayName: "原有人物", backgroundContext: "原有背景")
        let personFile = directory.appending(path: "persons.json")
        let originalBytes = try Data(contentsOf: personFile)
        let profiles = SpeakerVoiceProfileStore(baseDirectory: directory)
        let profile = try profiles.enroll(
            displayName: "待迁移人物", role: nil, colorToken: "blue",
            sourceSampleURL: try Self.sampleWav(in: directory, name: "rollback-original"), durationMs: 3_000
        )
        let project = Project(title: "合成录音", sourceType: .liveRecording)
        project.speakers = [Speaker(cloudAlias: "p_01", displayName: "待迁移人物", voiceProfileId: profile.id)]
        let projects = InMemoryProjectStore(seed: [project])
        #expect(throws: Error.self) {
            _ = try PersonMigrationCoordinator.migrateIfNeeded(
                personStore: people, profileStore: profiles, projectStore: projects, baseDirectory: directory,
                markerWriter: { data, url in
                    try data.write(to: url, options: .atomic)
                    throw CocoaError(.fileWriteNoPermission)
                }
            )
        }
        #expect(try Data(contentsOf: personFile) == originalBytes)
        #expect(try PersonLibraryStore(baseDirectory: directory).load().map(\.id) == [existing.id])
        #expect(try projects.loadProjects()[0].speakers[0].personId == nil)
        #expect(!FileManager.default.fileExists(atPath: PersonMigrationCoordinator.markerURL(in: directory).path))
    }

    private static func sampleWav(in directory: URL, name: String) throws -> URL {
        let url = directory.appending(path: "\(name)-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        try WAVFixture.writeTone(to: url, durationMs: 3_000)
        return url
    }
}

/// 测试共用：正弦波 wav 夹具
enum WAVFixture {
    static func writeTone(to url: URL, durationMs: Int64, sampleRate: Double = 16_000) throws {
        let bytesPerSample: Int = 2
        let frameCount = Int(Double(durationMs) / 1_000 * sampleRate)
        var pcm = [Int16]()
        for frame in 0..<frameCount {
            let value = sin(2 * Double.pi * 220 * Double(frame) / sampleRate) * 0.2 * Double(Int16.max)
            pcm.append(Int16(value))
        }
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append("RIFF")
        appendUInt32(UInt32(36 + pcm.count * bytesPerSample))
        append("WAVE")
        append("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate) * UInt32(bytesPerSample))
        appendUInt16(UInt16(bytesPerSample))
        appendUInt16(16)
        append("data")
        appendUInt32(UInt32(pcm.count * bytesPerSample))
        for sample in pcm {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url, options: .atomic)
    }
}
