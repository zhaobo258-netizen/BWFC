import Foundation
import Testing
@testable import BangWoFenXi

@Suite("独立人物库存储", .serialized)
struct PersonLibraryStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-person-tests-中文 100%-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("无声纹也能建人")
    func createPersonWithoutVoiceProfile() throws {
        let store = PersonLibraryStore(baseDirectory: try temporaryDirectory())
        let person = try store.createPerson(
            displayName: "张三",
            role: "经销商老板",
            backgroundContext: "负责华东区域"
        )
        #expect(person.linkedVoiceProfileID == nil)
        #expect(person.speakerLinks.isEmpty)
        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].displayName == "张三")
        #expect(loaded[0].activeMemories.isEmpty)
    }

    @Test("中文、空格与百分号目录中新建第二个人物及重开均保留首条")
    func encodedDirectoryPreservesExistingPeople() throws {
        let directory = try temporaryDirectory()
        let store = PersonLibraryStore(baseDirectory: directory)
        let first = try store.createPerson(displayName: "合成甲", backgroundContext: "保留背景")
        #expect(try store.person(id: first.id)?.backgroundContext == "保留背景")
        let second = try store.createPerson(displayName: "合成乙")
        let reopened = PersonLibraryStore(baseDirectory: directory)
        let people = try reopened.load()
        #expect(Set(people.map(\.id)) == [first.id, second.id])
        #expect(people.first { $0.id == first.id }?.backgroundContext == "保留背景")
        try reopened.deletePerson(personID: second.id)
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory.appending(path: "PersonsBackups"), includingPropertiesForKeys: nil
        )
        #expect(backups.contains { $0.lastPathComponent.hasPrefix("pre-delete-") })
        #expect(try reopened.load().map(\.id) == [first.id])
    }

    @Test("同名不自动合并")
    func sameNameDoesNotMerge() throws {
        let store = PersonLibraryStore(baseDirectory: try temporaryDirectory())
        _ = try store.createPerson(displayName: "李四")
        _ = try store.createPerson(displayName: "李四")
        #expect(try store.load().count == 2)
    }

    @Test("说话人关联与解除：一次槽位只指一个人")
    func linkAndUnlinkSpeaker() throws {
        let store = PersonLibraryStore(baseDirectory: try temporaryDirectory())
        let a = try store.createPerson(displayName: "A")
        let b = try store.createPerson(displayName: "B")
        let projectID = UUID()
        let speakerID = UUID()
        _ = try store.linkSpeaker(
            personID: a.id, projectID: projectID, speakerID: speakerID, speakerDisplayName: "说话人 1"
        )
        // 关联到 B 后，A 的账本自动移除该槽位
        _ = try store.linkSpeaker(
            personID: b.id, projectID: projectID, speakerID: speakerID, speakerDisplayName: "说话人 1"
        )
        let loaded = try store.load()
        let personA = loaded.first { $0.id == a.id }
        let personB = loaded.first { $0.id == b.id }
        #expect(personA?.speakerLinks.isEmpty == true)
        #expect(personB?.speakerLinks.count == 1)
        // 解除
        _ = try store.unlinkSpeaker(personID: b.id, projectID: projectID, speakerID: speakerID)
        #expect(try store.person(id: b.id)?.speakerLinks.isEmpty == true)
    }

    @Test("误指认可撤销")
    func undoLastChange() throws {
        let store = PersonLibraryStore(baseDirectory: try temporaryDirectory())
        _ = try store.createPerson(displayName: "保留")
        let target = try store.createPerson(displayName: "误指")
        let before = try store.load()
        _ = try store.linkSpeaker(
            personID: target.id, projectID: UUID(), speakerID: UUID(), speakerDisplayName: "s"
        )
        #expect(try store.person(id: target.id)?.speakerLinks.count == 1)
        let restored = try store.undoLastChange()
        #expect(restored.map(\.id) == before.map(\.id))
        #expect(try store.person(id: target.id)?.speakerLinks.isEmpty == true)
    }

    @Test("这是我唯一：置真时清除其他人物")
    func currentUserUniqueness() throws {
        let store = PersonLibraryStore(baseDirectory: try temporaryDirectory())
        let a = try store.createPerson(displayName: "A")
        let b = try store.createPerson(displayName: "B")
        try store.setCurrentUser(personID: a.id)
        try store.setCurrentUser(personID: b.id)
        let loaded = try store.load()
        #expect(loaded.filter(\.isCurrentUser).count == 1)
        #expect(loaded.first { $0.id == b.id }?.isCurrentUser == true)
        try store.setCurrentUser(personID: nil)
        #expect(try store.load().filter(\.isCurrentUser).isEmpty)
    }

    @Test("合并：关联与记忆并入，作用域改指保留人物")
    func mergePersons() throws {
        let store = PersonLibraryStore(baseDirectory: try temporaryDirectory())
        let keeping = try store.createPerson(displayName: "保留者", backgroundContext: nil)
        let absorbing = try store.createPerson(
            displayName: "被并者",
            backgroundContext: "被并者背景"
        )
        _ = try store.linkSpeaker(
            personID: absorbing.id, projectID: UUID(), speakerID: UUID(), speakerDisplayName: "s1"
        )
        var entries = absorbing.memoryEntries
        entries.append(MemoryEntry(
            content: "口径：有效客户指月活门店",
            kind: .terminology,
            scope: MemoryScope(
                personID: absorbing.id, businessProjectID: nil, displayText: "人物"
            ),
            status: .active,
            confirmedAt: Date()
        ))
        _ = try store.replaceMemoryEntries(personID: absorbing.id, entries: entries)

        let preview = try store.mergePreview(keepingID: keeping.id, absorbingID: absorbing.id)
        #expect(preview.combinedRecordingCount == 1)
        #expect(preview.combinedMemoryCount == 1)
        #expect(preview.backgroundConflict == false) // 只有被并者有背景

        let merged = try store.merge(keepingID: keeping.id, absorbingID: absorbing.id)
        #expect(merged.speakerLinks.count == 1)
        #expect(merged.memoryEntries.count == 1)
        #expect(merged.memoryEntries[0].scope.personID == keeping.id)
        #expect(merged.backgroundContext == "被并者背景")
        #expect(try store.load().count == 1)
        // 撤销合并
        _ = try store.undoLastChange()
        #expect(try store.load().count == 2)
    }

    @Test("来源片段变化把相关记忆标记需复核")
    func markMemoriesNeedingReview() throws {
        let store = PersonLibraryStore(baseDirectory: try temporaryDirectory())
        let person = try store.createPerson(displayName: "A")
        let segmentID = UUID()
        var entries: [MemoryEntry] = [
            MemoryEntry(
                content: "约束：预算 50 万",
                kind: .confirmedConstraint,
                scope: MemoryScope(personID: person.id, businessProjectID: nil, displayText: "人物"),
                source: MemorySourceReference(recordingID: UUID(), segmentID: segmentID, snippet: "原话"),
                status: .active,
                confirmedAt: Date()
            ),
            MemoryEntry(
                content: "无关记忆",
                kind: .ongoingTopic,
                scope: MemoryScope(personID: person.id, businessProjectID: nil, displayText: "人物"),
                source: MemorySourceReference(recordingID: UUID(), segmentID: UUID(), snippet: "x"),
                status: .active,
                confirmedAt: Date()
            ),
        ]
        _ = try store.replaceMemoryEntries(personID: person.id, entries: entries)
        let affected = try store.markMemoriesNeedingReview(
            segmentIDs: [segmentID],
            reason: "原文已修改"
        )
        #expect(affected.count == 1)
        let updated = try store.person(id: person.id)
        let reviewEntry = updated?.memoryEntries.first { $0.content.contains("预算") }
        #expect(reviewEntry?.status == .needsReview)
        #expect(reviewEntry?.reviewReason == "原文已修改")
        #expect(updated?.activeMemories.count == 1) // 只剩无关记忆仍有效
        _ = entries // silence unused
    }

    @Test("坏索引文件不静默重建")
    func corruptFilePreserved() throws {
        let directory = try temporaryDirectory()
        let store = PersonLibraryStore(baseDirectory: directory)
        try Data("not-json".utf8).write(
            to: directory.appending(path: "persons.json")
        )
        #expect(throws: Error.self) {
            _ = try store.load()
        }
    }

    @Test("删除人物与版本去重")
    func deleteAndVersionResolution() throws {
        let store = PersonLibraryStore(baseDirectory: try temporaryDirectory())
        let person = try store.createPerson(displayName: "A")
        let scope = MemoryScope(personID: person.id, businessProjectID: nil, displayText: "人物")
        var entries: [MemoryEntry] = []
        for version in 1...3 {
            entries.append(MemoryEntry(
                content: "同一口径",
                kind: .terminology,
                scope: scope,
                status: .active,
                confirmedAt: Date(),
                version: version
            ))
        }
        _ = try store.replaceMemoryEntries(personID: person.id, entries: entries)
        let stored = try store.person(id: person.id)
        #expect(stored?.memoryEntries.filter { $0.status == .active }.count == 1)
        #expect(stored?.memoryEntries.filter { $0.status == .superseded }.count == 2)
        try store.deletePerson(personID: person.id)
        #expect(try store.load().isEmpty)
        // 删除也可撤销恢复
        _ = try store.undoLastChange()
        #expect(try store.load().count == 1)
    }
}

@Suite("人物关系事务", .serialized)
struct PersonRelationshipTransactionTests {
    @MainActor
    private func environment() throws -> AppEnvironment {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-person-relations-\(UUID().uuidString)")
        return AppEnvironment(
            meetingStore: InMemoryMeetingStore(), fileStore: MeetingFileStore(baseDirectory: directory),
            projectStore: try JSONProjectStore(directory: directory),
            audioCapture: MockAudioCaptureService(), localTranscription: MockLocalTranscriptionService(),
            credentialServiceName: "bwfx-person-relations-\(UUID().uuidString)"
        )
    }

    @Test("合并与撤销同步说话人、候选、CRM责任人并保留后续工作")
    @MainActor
    func mergeUndoPreservesLaterWork() throws {
        let env = try environment()
        let a = try env.personLibraryStore.createPerson(displayName: "合成甲")
        let b = try env.personLibraryStore.createPerson(displayName: "合成乙")
        let project = Project(title: "合成会议", sourceType: .liveRecording)
        let speaker = Speaker(cloudAlias: "p_01", displayName: "乙", personId: b.id)
        project.speakers = [speaker]
        project.businessMemoryCandidates = [BusinessMemoryCandidate(
            targetPersonID: b.id, targetPersonDisplayName: "合成乙", kind: .ongoingTopic,
            statement: "继续评估", scopeDescription: "人物", reason: "测试",
            evidenceSegmentID: UUID(), evidenceSnippet: "合成证据"
        )]
        try env.persist(project)
        try env.linkPerson(personID: b.id, projectID: project.id, speakerID: speaker.id)
        try env.setCurrentPerson(personID: b.id)
        var business = try env.businessProjectStore.create(name: "合成业务", participantPersonIDs: [b.id])
        business.followUps = [FollowUp(title: "合成跟进", ownerPersonID: b.id, ownerDisplayText: "乙")]
        business.memoryEntries = [MemoryEntry(
            content: "合成约束", kind: .confirmedConstraint,
            scope: MemoryScope(personID: b.id, businessProjectID: business.id, displayText: "业务"), status: .active
        )]
        _ = try env.businessProjectStore.update(business)
        try env.mergePeople(keepingID: a.id, absorbingID: b.id, keepBackground: false, keepVoice: false)
        #expect(try env.personLibraryStore.person(id: b.id) == nil)
        #expect(try env.allProjects().first?.speakers.first?.personId == a.id)
        #expect(try env.businessProjectStore.load().first?.followUps.first?.ownerPersonID == a.id)
        #expect(try env.businessProjectStore.load().first?.memoryEntries.first?.scope.personID == a.id)

        let edited = try #require(env.allProjects().first)
        edited.title = "稍后编辑的标题"
        edited.note.markdown = "稍后写的笔记"
        try env.persist(edited)
        let another = Project(title: "稍后新建", sourceType: .liveRecording)
        try env.persist(another)
        var currentBusiness = try #require(env.businessProjectStore.load().first)
        currentBusiness.followUps[0].handlingStatus = .completed
        currentBusiness.followUps[0].resultNote = "后续真实结果"
        _ = try env.businessProjectStore.replaceFollowUps(businessProjectID: business.id, followUps: currentBusiness.followUps)
        try env.undoPersonChange()

        let restored = try #require(env.allProjects().first(where: { $0.id == project.id }))
        #expect(restored.title == "稍后编辑的标题")
        #expect(restored.note.markdown == "稍后写的笔记")
        #expect(restored.speakers[0].personId == b.id)
        #expect(restored.speakers[0].isCurrentUser == true)
        #expect(restored.businessMemoryCandidates[0].targetPersonID == b.id)
        #expect(try env.allProjects().contains { $0.id == another.id })
        let restoredBusiness = try #require(env.businessProjectStore.load().first)
        #expect(restoredBusiness.participantPersonIDs == [b.id])
        #expect(restoredBusiness.followUps[0].ownerPersonID == b.id)
        #expect(restoredBusiness.followUps[0].resultNote == "后续真实结果")
        #expect(restoredBusiness.followUps[0].handlingStatus == .completed)
        #expect(restoredBusiness.memoryEntries[0].scope.personID == b.id)
    }

    @Test("人物元数据撤销只恢复本次字段并保留后续颜色与文稿")
    @MainActor
    func metadataUndoPreservesUnchangedFields() throws {
        let env = try environment()
        let person = try env.personLibraryStore.createPerson(displayName: "旧名")
        let project = Project(title: "合成录音", sourceType: .liveRecording)
        project.speakers = [Speaker(
            cloudAlias: "p_01", displayName: "旧名", role: "旧角色", colorToken: "blue",
            personId: person.id, backgroundContext: "旧背景"
        )]
        try env.persist(project)
        try env.updateLibraryPersonMetadata(
            personID: person.id, displayName: "新名", role: "新角色", backgroundContext: "新背景"
        )
        let edited = try #require(env.allProjects().first)
        edited.speakers[0].colorToken = "green"
        edited.segments = [TranscriptSegment(
            startMs: 0, endMs: 1_000, text: "后来增加的原文", source: .manual, state: .edited
        )]
        try env.persist(edited)
        try env.undoPersonChange()
        let restored = try #require(env.allProjects().first)
        #expect(restored.speakers[0].displayName == "旧名")
        #expect(restored.speakers[0].role == "旧角色")
        #expect(restored.speakers[0].backgroundContext == "旧背景")
        #expect(restored.speakers[0].colorToken == "green")
        #expect(restored.segments.first?.text == "后来增加的原文")
    }

    @Test("合并保留两侧声音附件且重复附件不会让迁移崩溃")
    func voiceAliasesAndUniqueness() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bwfx-person-alias-\(UUID().uuidString)")
        let store = PersonLibraryStore(baseDirectory: directory)
        let firstVoice = UUID()
        let secondVoice = UUID()
        let a = try store.createPerson(displayName: "甲", linkedVoiceProfileID: firstVoice)
        let b = try store.createPerson(displayName: "乙", linkedVoiceProfileID: secondVoice)
        let merged = try store.merge(keepingID: a.id, absorbingID: b.id, keepVoiceProfileFromAbsorbing: true)
        #expect(merged.linkedVoiceProfileID == secondVoice)
        #expect(merged.voiceProfileIDs == [firstVoice, secondVoice])
        #expect(throws: PersonLibraryStoreError.conflictingVoiceProfile) {
            _ = try store.createPerson(displayName: "重复", linkedVoiceProfileID: firstVoice)
        }
        #expect(try store.load().count == 1)
        _ = try store.undoLastChange()
        #expect(try store.load().count == 2)
    }

    @Test("落盘失败不污染撤销栈，失败撤销可重试")
    func failedUndoRetainsHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bwfx-person-write-\(UUID().uuidString)")
        var failNextWrite = false
        let store = PersonLibraryStore(baseDirectory: directory, indexWriter: { data, url in
            if failNextWrite {
                failNextWrite = false
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        })
        _ = try store.createPerson(displayName: "甲")
        failNextWrite = true
        #expect(throws: Error.self) { _ = try store.createPerson(displayName: "失败的乙") }
        failNextWrite = true
        #expect(throws: Error.self) { _ = try store.undoLastChange() }
        #expect(store.canUndo)
        _ = try store.undoLastChange()
        #expect(try store.load().isEmpty)
    }

    @Test("未来生效的人工记忆不提前进入上下文")
    func effectiveFromRespected() {
        let entry = MemoryEntry(
            content: "未来口径", kind: .terminology,
            scope: MemoryScope(personID: nil, businessProjectID: nil, displayText: "全部"),
            status: .active, effectiveFrom: Date().addingTimeInterval(3_600)
        )
        let person = Person(displayName: "合成人物", memoryEntries: [entry])
        #expect(person.activeMemories.isEmpty)
    }

    @Test("CRM写失败回滚人物和录音的已提交关系")
    @MainActor
    func secondStoreFailureRollsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bwfx-person-transaction-\(UUID().uuidString)")
        let people = PersonLibraryStore(baseDirectory: directory)
        let a = try people.createPerson(displayName: "甲")
        let b = try people.createPerson(displayName: "乙")
        let project = Project(title: "合成录音", sourceType: .liveRecording)
        project.speakers = [Speaker(cloudAlias: "p_01", displayName: "乙", personId: b.id)]
        let projects = InMemoryProjectStore(seed: [project])
        var failNextWrite = false
        let business = BusinessProjectStore(baseDirectory: directory, indexWriter: { data, url in
            if failNextWrite {
                failNextWrite = false
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        })
        _ = try business.create(name: "合成业务", participantPersonIDs: [b.id])
        failNextWrite = true
        #expect(throws: Error.self) {
            try people.changeIdentity(
                projectStore: projects, businessProjectStore: business,
                profileStore: SpeakerVoiceProfileStore(baseDirectory: directory)
            ) { persons, recordings, businesses in
                persons.removeAll { $0.id == b.id }
                recordings[0].speakers[0].personId = a.id
                businesses[0].participantPersonIDs = [a.id]
            }
        }
        #expect(try people.load().count == 2)
        #expect(try projects.loadProjects()[0].speakers[0].personId == b.id)
        #expect(try business.load()[0].participantPersonIDs == [b.id])
        _ = try people.undoLastChange()
        #expect(try people.person(id: b.id) == nil)
    }
}
