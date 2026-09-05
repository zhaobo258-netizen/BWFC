import Foundation
import OSLog

enum PersonLibraryStoreError: Error, Equatable {
    case personNotFound
    case duplicateCurrentUser
    case cannotUndo
    case conflictingVoiceProfile
    case coordinatedUndoRequired
    case undoConflict
    case rollbackFailed
}

/// 独立人物库（产品文档 12 号 §5）：Person 的持久化与人物级操作。
/// 存储：baseDirectory/persons.json（JSON 原子写、ISO8601、sortedKeys）。
/// 撤回：每次变更前保存索引快照（内存撤销栈 + 破坏性操作前的落盘备份），
/// 误指认与合并可通过 `undoLastChange` 恢复。
final class PersonLibraryStore: @unchecked Sendable {
    static let maximumUndoDepth = 20

    private let baseDirectory: URL
    private let fileURL: URL
    private let backupDirectory: URL
    private let fileManager: FileManager
    private let indexWriter: (Data, URL) throws -> Void
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private struct UndoEntry {
        var persons: [Person]
        var relationships: PersonRelationshipChange?
    }
    private var undoStack: [UndoEntry] = []
    /// 已撤销的内容（支持重做一次）；再次变更时清空。
    private var redoStack: [UndoEntry] = []

    init(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        indexWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        let baseDirectory = baseDirectory.standardizedFileURL
        self.baseDirectory = baseDirectory
        self.fileURL = baseDirectory.appending(
            path: "persons.json",
            directoryHint: .notDirectory
        )
        self.backupDirectory = baseDirectory.appending(
            path: "PersonsBackups",
            directoryHint: .isDirectory
        )
        self.fileManager = fileManager
        self.indexWriter = indexWriter
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - 读取

    func load() throws -> [Person] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func person(id: UUID) throws -> Person? {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked().first { $0.id == id }
    }

    func currentUser() throws -> Person? {
        try load().first { $0.isCurrentUser }
    }

    private func loadUnlocked() throws -> [Person] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        do {
            let persons = try decoder.decode([Person].self, from: data)
                .sorted { $0.createdAt < $1.createdAt }
            try Self.validate(persons)
            return persons
        } catch {
            // 坏文件改名保留，不静默重建（沿用 projects.json 的处理约定）
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let corruptURL = fileURL.deletingLastPathComponent().appending(
                path: "persons.corrupt-\(stamp).json",
                directoryHint: .notDirectory
            )
            try? data.write(to: corruptURL, options: .atomic)
            throw error
        }
    }

    // MARK: - 创建与基础修改

    @discardableResult
    func createPerson(
        displayName: String,
        role: String? = nil,
        backgroundContext: String? = nil,
        colorToken: String = "gray",
        linkedVoiceProfileID: UUID? = nil,
        now: Date = Date()
    ) throws -> Person {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PersonLibraryStoreError.personNotFound }
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        let person = Person(
            displayName: trimmed,
            role: role,
            colorToken: colorToken,
            backgroundContext: backgroundContext,
            isCurrentUser: false,
            linkedVoiceProfileID: linkedVoiceProfileID,
            speakerLinks: [],
            memoryEntries: [],
            createdAt: now,
            updatedAt: now
        )
        persons.append(person)
        try persistUnlocked(persons, now: now, pushUndo: true)
        return person
    }

    @discardableResult
    func updatePerson(_ updated: Person, now: Date = Date()) throws -> Person {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        guard let index = persons.firstIndex(where: { $0.id == updated.id }) else {
            throw PersonLibraryStoreError.personNotFound
        }
        var next = updated
        next.updatedAt = now
        // “这是我”唯一性：置真时清掉其他人物
        if next.isCurrentUser {
            for i in persons.indices where persons[i].id != next.id {
                persons[i].isCurrentUser = false
            }
        }
        persons[index] = next
        try persistUnlocked(persons, now: now, pushUndo: true)
        return next
    }

    /// 按指定内容插入人物（迁移/导入用）；已存在同 ID 人物时抛错，不覆盖。
    @discardableResult
    func insert(_ person: Person, now: Date = Date()) throws -> Person {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        guard !persons.contains(where: { $0.id == person.id }) else {
            throw PersonLibraryStoreError.personNotFound
        }
        var next = person
        next.updatedAt = now
        persons.append(next)
        try persistUnlocked(persons, now: now, pushUndo: true)
        return next
    }

    /// 修改人物档案（姓名/角色/背景），不动关联与记忆。
    @discardableResult
    func updateMetadata(
        personID: UUID,
        displayName: String? = nil,
        role: String? = nil,
        backgroundContext: String? = nil,
        now: Date = Date()
    ) throws -> Person {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        guard let index = persons.firstIndex(where: { $0.id == personID }) else {
            throw PersonLibraryStoreError.personNotFound
        }
        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            persons[index].displayName = trimmed.isEmpty ? persons[index].displayName : trimmed
        }
        if let role {
            persons[index].role = role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : role
        }
        if let backgroundContext {
            persons[index].backgroundContext = backgroundContext
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : backgroundContext
        }
        persons[index].updatedAt = now
        try persistUnlocked(persons, now: now, pushUndo: true)
        return persons[index]
    }

    /// 设置/取消“这是我”（12 号 §5.1：同一份本地用户资料只允许一个当前用户身份）
    func setCurrentUser(personID: UUID?, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        if let personID, !persons.contains(where: { $0.id == personID }) {
            throw PersonLibraryStoreError.personNotFound
        }
        for index in persons.indices {
            persons[index].isCurrentUser = persons[index].id == personID
        }
        try persistUnlocked(persons, now: now, pushUndo: true)
    }

    // MARK: - 说话人关联（跨录音人物关联）

    /// 把某场录音的某个说话人槽位关联到人物（Speaker.personId -> Person.id 的账本侧）。
    /// 调用方负责同步写回 Project.speakers[i].personId；失败时可用 undoLastChange 回滚账本。
    @discardableResult
    func linkSpeaker(
        personID: UUID,
        projectID: UUID,
        speakerID: UUID,
        speakerDisplayName: String,
        now: Date = Date()
    ) throws -> Person {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        guard let index = persons.firstIndex(where: { $0.id == personID }) else {
            throw PersonLibraryStoreError.personNotFound
        }
        // 若该说话人已关联到别的人物，先从旧人物移除（一次槽位只指一个人）
        for other in persons.indices where persons[other].id != personID {
            persons[other].speakerLinks.removeAll {
                $0.projectID == projectID && $0.speakerID == speakerID
            }
        }
        let link = PersonSpeakerLink(
            projectID: projectID,
            speakerID: speakerID,
            speakerDisplayName: speakerDisplayName,
            linkedAt: now
        )
        if !persons[index].speakerLinks.contains(where: {
            $0.projectID == projectID && $0.speakerID == speakerID
        }) {
            persons[index].speakerLinks.append(link)
        }
        persons[index].updatedAt = now
        try persistUnlocked(persons, now: now, pushUndo: true)
        return persons[index]
    }

    /// 解除一次关联（误关联可撤回：先解除 + 必要时 undoLastChange）
    @discardableResult
    func unlinkSpeaker(
        personID: UUID,
        projectID: UUID,
        speakerID: UUID,
        now: Date = Date()
    ) throws -> Person {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        guard let index = persons.firstIndex(where: { $0.id == personID }) else {
            throw PersonLibraryStoreError.personNotFound
        }
        persons[index].speakerLinks.removeAll {
            $0.projectID == projectID && $0.speakerID == speakerID
        }
        persons[index].updatedAt = now
        try persistUnlocked(persons, now: now, pushUndo: true)
        return persons[index]
    }

    // MARK: - 合并

    struct MergePlan: Equatable, Sendable {
        var keepingPerson: Person
        var absorbingPerson: Person
        /// 两侧人工背景是否都非空（非空时需老板选择保留值）
        var backgroundConflict: Bool
        /// 两侧是否各有声纹附件
        var voiceProfileConflict: Bool
        var combinedRecordingCount: Int
        var combinedMemoryCount: Int
    }

    /// 合并预览（12 号 §5.3：先展示关联录音、背景冲突和样本来源）
    func mergePreview(keepingID: UUID, absorbingID: UUID) throws -> MergePlan {
        lock.lock()
        defer { lock.unlock() }
        let persons = try loadUnlocked()
        guard let keeping = persons.first(where: { $0.id == keepingID }),
              let absorbing = persons.first(where: { $0.id == absorbingID }) else {
            throw PersonLibraryStoreError.personNotFound
        }
        return MergePlan(
            keepingPerson: keeping,
            absorbingPerson: absorbing,
            backgroundConflict:
                !(keeping.backgroundContext ?? "").isEmpty
                    && !(absorbing.backgroundContext ?? "").isEmpty,
            voiceProfileConflict:
                keeping.linkedVoiceProfileID != nil && absorbing.linkedVoiceProfileID != nil,
            combinedRecordingCount: Set(
                keeping.speakerLinks.map(\.projectID) + absorbing.speakerLinks.map(\.projectID)
            ).count,
            combinedMemoryCount: keeping.memoryEntries.count + absorbing.memoryEntries.count
        )
    }

    /// 执行合并：absorbing 并入 keeping 后删除。
    /// keepBackground/keepVoiceProfile 指定保留哪一侧（nil 表示无冲突侧自动取非空）。
    @discardableResult
    func merge(
        keepingID: UUID,
        absorbingID: UUID,
        keepBackgroundFromAbsorbing: Bool = false,
        keepVoiceProfileFromAbsorbing: Bool = false,
        now: Date = Date()
    ) throws -> Person {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        try writeRollingBackupUnlocked(label: "pre-merge")
        var persons = try loadUnlocked()
        let keeping = try Self.mergePersons(
            &persons, keepingID: keepingID, absorbingID: absorbingID,
            keepBackgroundFromAbsorbing: keepBackgroundFromAbsorbing,
            keepVoiceProfileFromAbsorbing: keepVoiceProfileFromAbsorbing, now: now
        )
        try persistUnlocked(persons, now: now, pushUndo: true)
        return keeping
    }

    static func mergePersons(
        _ persons: inout [Person], keepingID: UUID, absorbingID: UUID,
        keepBackgroundFromAbsorbing: Bool, keepVoiceProfileFromAbsorbing: Bool, now: Date
    ) throws -> Person {
        guard let keepingIndex = persons.firstIndex(where: { $0.id == keepingID }),
              let absorbingIndex = persons.firstIndex(where: { $0.id == absorbingID }) else {
            throw PersonLibraryStoreError.personNotFound
        }
        var keeping = persons[keepingIndex]
        let absorbing = persons[absorbingIndex]
        guard keepingIndex != absorbingIndex else {
            throw PersonLibraryStoreError.personNotFound
        }

        // 关联合并（按 projectID+speakerID 去重）
        var seenLinks = Set(keeping.speakerLinks.map(\.id))
        for link in absorbing.speakerLinks where !seenLinks.contains(link.id) {
            seenLinks.insert(link.id)
            keeping.speakerLinks.append(link)
        }
        // 记忆合并：absorbing 的条目作用域改指向 keeping，状态保留
        var memories = keeping.memoryEntries
        for var entry in absorbing.memoryEntries {
            if entry.scope.personID == absorbingID { entry.scope.personID = keepingID }
            memories.append(entry)
        }
        keeping.memoryEntries = Self.resolveMemoryVersions(memories)
        let allVoiceIDs = keeping.voiceProfileIDs.union(absorbing.voiceProfileIDs)
        // 背景与声纹：冲突时按选择，否则取非空侧
        if keepBackgroundFromAbsorbing || (keeping.backgroundContext ?? "").isEmpty {
            if let absorbingBackground = absorbing.backgroundContext,
               !absorbingBackground.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                keeping.backgroundContext = absorbingBackground
            }
        }
        if keepVoiceProfileFromAbsorbing || keeping.linkedVoiceProfileID == nil {
            keeping.linkedVoiceProfileID = absorbing.linkedVoiceProfileID
        }
        if absorbing.isCurrentUser && !keeping.isCurrentUser {
            keeping.isCurrentUser = true
        }
        keeping.additionalVoiceProfileIDs = allVoiceIDs
            .filter { $0 != keeping.linkedVoiceProfileID }
            .sorted { $0.uuidString < $1.uuidString }
        keeping.updatedAt = now

        persons.remove(at: absorbingIndex)
        if let newIndex = persons.firstIndex(where: { $0.id == keepingID }) {
            persons[newIndex] = keeping
        } else {
            persons.append(keeping)
        }
        return keeping
    }

    /// 同一作用域内“内容相同仅版本不同”的记忆保留 version 最高者，其余标 superseded。
    static func resolveMemoryVersions(_ entries: [MemoryEntry]) -> [MemoryEntry] {
        var byKey: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            let personKey = entry.scope.personID.map(\.uuidString) ?? "nil"
            let projectKey = entry.scope.businessProjectID.map(\.uuidString) ?? "nil"
            let key = "\(entry.kind.rawValue)|\(entry.content)|\(personKey)|\(projectKey)"
            byKey[key, default: []].append(index)
        }
        var result = entries
        for (_, indices) in byKey where indices.count > 1 {
            let sorted = indices.sorted { result[$0].version > result[$1].version }
            for index in sorted.dropFirst() {
                result[index].status = .superseded
            }
        }
        return result
    }

    // MARK: - 记忆操作

    /// 整体替换某人物的记忆列表（确认候选/修改/撤回的落点）。
    @discardableResult
    func replaceMemoryEntries(personID: UUID, entries: [MemoryEntry], now: Date = Date()) throws -> Person {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        guard let index = persons.firstIndex(where: { $0.id == personID }) else {
            throw PersonLibraryStoreError.personNotFound
        }
        persons[index].memoryEntries = Self.resolveMemoryVersions(entries)
        persons[index].updatedAt = now
        try persistUnlocked(persons, now: now, pushUndo: true)
        return persons[index]
    }

    /// 把若干记忆标记为需复核（来源变化传播，12 号 §6.5）。
    /// 返回受影响的 (personID, entryID) 列表。
    func markMemoriesNeedingReview(
        segmentIDs: Set<UUID>,
        reason: String,
        now: Date = Date()
    ) throws -> [(personID: UUID, entryID: UUID)] {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        var affected: [(UUID, UUID)] = []
        for personIndex in persons.indices {
            var changed = false
            for entryIndex in persons[personIndex].memoryEntries.indices {
                let entry = persons[personIndex].memoryEntries[entryIndex]
                guard entry.status == .active || entry.status == .candidate,
                      let source = entry.source,
                      segmentIDs.contains(source.segmentID) else { continue }
                persons[personIndex].memoryEntries[entryIndex].status = .needsReview
                persons[personIndex].memoryEntries[entryIndex].reviewReason = reason
                persons[personIndex].memoryEntries[entryIndex].updatedAt = now
                affected.append((persons[personIndex].id, entry.id))
                changed = true
            }
            if changed { persons[personIndex].updatedAt = now }
        }
        if !affected.isEmpty {
            try persistUnlocked(persons, now: now, pushUndo: true)
        }
        return affected
    }

    // MARK: - 删除

    /// 删除人物记录（12 号 §5.3：仅解除关联；声音样本由调用方决定是否另删）。
    func deletePerson(personID: UUID, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        try writeRollingBackupUnlocked(label: "pre-delete")
        var persons = try loadUnlocked()
        let originalCount = persons.count
        persons.removeAll { $0.id == personID }
        guard persons.count == originalCount - 1 else {
            throw PersonLibraryStoreError.personNotFound
        }
        try persistUnlocked(persons, now: now, pushUndo: true)
    }

    // MARK: - 撤销 / 重做

    /// 是否存在可撤销的变更（UI 提示用）
    var canUndo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !undoStack.isEmpty
    }

    /// 撤销最近一次人物库变更（误指认、合并、误删）。
    @discardableResult
    func undoLastChange(
        projectStore: (any ProjectStoring)? = nil,
        businessProjectStore: BusinessProjectStore? = nil,
        profileStore: SpeakerVoiceProfileStore? = nil,
        now: Date = Date()
    ) throws -> [Person] {
        try restoreLastChange(
            isRedo: false, projectStore: projectStore,
            businessProjectStore: businessProjectStore, profileStore: profileStore, now: now
        )
    }

    var canRedo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !redoStack.isEmpty
    }

    @discardableResult
    func redoLastChange(
        projectStore: (any ProjectStoring)? = nil,
        businessProjectStore: BusinessProjectStore? = nil,
        profileStore: SpeakerVoiceProfileStore? = nil,
        now: Date = Date()
    ) throws -> [Person] {
        try restoreLastChange(
            isRedo: true, projectStore: projectStore,
            businessProjectStore: businessProjectStore, profileStore: profileStore, now: now
        )
    }

    // MARK: - 私有

    private func ensureBaseDirectoryUnlocked() throws {
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
    }

    private func writeRollingBackupUnlocked(label: String) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDirectory.appending(
            path: "\(label)-\(stamp).json",
            directoryHint: .notDirectory
        )
        // 备份失败不阻断主流程，但记录脱敏日志
        try? fileManager.copyItem(at: fileURL, to: backupURL)
        trimBackupsUnlocked()
    }

    private func trimBackupsUnlocked(keeping: Int = 10) {
        guard let items = try? fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        let backups = items
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for item in backups.dropFirst(keeping) {
            try? fileManager.removeItem(at: item)
        }
    }

    private func persistUnlocked(_ persons: [Person], now: Date, pushUndo: Bool) throws {
        try Self.validate(persons)
        let current = pushUndo ? try loadUnlocked() : []
        let data = try encoder.encode(persons)
        try indexWriter(data, fileURL)
        if pushUndo { recordUndo(persons: current, relationships: nil) }
    }

    private func recordUndo(persons: [Person], relationships: PersonRelationshipChange?) {
        undoStack.append(UndoEntry(persons: persons, relationships: relationships))
        if undoStack.count > Self.maximumUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    static func validate(_ persons: [Person]) throws {
        guard Set(persons.map(\.id)).count == persons.count,
              persons.filter(\.isCurrentUser).count <= 1 else {
            throw PersonLibraryStoreError.duplicateCurrentUser
        }
        var voiceIDs = Set<UUID>()
        for person in persons {
            for id in person.voiceProfileIDs {
                guard voiceIDs.insert(id).inserted else {
                    throw PersonLibraryStoreError.conflictingVoiceProfile
                }
            }
        }
    }

    func replaceAll(_ persons: [Person]) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        try persistUnlocked(persons, now: Date(), pushUndo: false)
    }

    @discardableResult
    func ensurePerson(
        for profile: SpeakerVoiceProfile,
        preferredPersonID: UUID? = nil,
        now: Date = Date()
    ) throws -> Person {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var persons = try loadUnlocked()
        if let existing = persons.first(where: { $0.voiceProfileIDs.contains(profile.id) }) {
            if let preferredPersonID, preferredPersonID != existing.id {
                throw PersonLibraryStoreError.conflictingVoiceProfile
            }
            return existing
        }
        let person: Person
        if let preferredPersonID {
            guard let index = persons.firstIndex(where: { $0.id == preferredPersonID }) else {
                throw PersonLibraryStoreError.personNotFound
            }
            if persons[index].linkedVoiceProfileID == nil {
                persons[index].linkedVoiceProfileID = profile.id
            } else {
                persons[index].additionalVoiceProfileIDs =
                    (persons[index].additionalVoiceProfileIDs ?? []) + [profile.id]
            }
            persons[index].updatedAt = now
            person = persons[index]
        } else {
            guard !persons.contains(where: { $0.id == profile.id }) else {
                throw PersonLibraryStoreError.conflictingVoiceProfile
            }
            person = Person(
                id: profile.id, displayName: profile.displayName, role: profile.role,
                colorToken: profile.colorToken, backgroundContext: profile.backgroundContext,
                isCurrentUser: profile.isCurrentUser == true && !persons.contains(where: \.isCurrentUser),
                linkedVoiceProfileID: profile.id, createdAt: profile.createdAt, updatedAt: now
            )
            persons.append(person)
        }
        try persistUnlocked(persons, now: now, pushUndo: true)
        return person
    }
}

private struct PersonRelationshipSnapshot: Equatable {
    struct SpeakerIdentity: Equatable {
        var displayName: String
        var role: String?
        var backgroundContext: String?
        var colorToken: String
        var personID: UUID?
        var isCurrentUser: Bool?
        var voiceProfileID: UUID?
        var voiceSamplePath: String?
        var voiceSampleDurationMs: Int64?
        var featureID: String?
        var legacyVoicePath: String?
        var legacyVoiceDurationMs: Int64?

        func undoingChanges(from before: Self, to after: Self) throws -> Self {
            var result = self
            func restore<Value: Equatable>(_ field: WritableKeyPath<Self, Value>) throws {
                guard before[keyPath: field] != after[keyPath: field] else { return }
                guard result[keyPath: field] == after[keyPath: field] else {
                    throw PersonLibraryStoreError.undoConflict
                }
                result[keyPath: field] = before[keyPath: field]
            }
            try restore(\.displayName)
            try restore(\.role)
            try restore(\.backgroundContext)
            try restore(\.colorToken)
            try restore(\.personID)
            try restore(\.isCurrentUser)
            try restore(\.voiceProfileID)
            try restore(\.voiceSamplePath)
            try restore(\.voiceSampleDurationMs)
            try restore(\.featureID)
            try restore(\.legacyVoicePath)
            try restore(\.legacyVoiceDurationMs)
            return result
        }
    }
    struct CandidateIdentity: Equatable {
        var personID: UUID?
        var displayName: String?
    }
    struct Recording: Equatable {
        var speakers: [UUID: SpeakerIdentity]
        var candidates: [UUID: CandidateIdentity]
    }
    var recordings: [UUID: Recording]
    var businessProjects: [BusinessProject]
    var currentVoiceProfileID: UUID?
    var voiceProfiles: [SpeakerVoiceProfile]

    init(projects: [Project], businessProjects: [BusinessProject], currentVoiceProfileID: UUID?, voiceProfiles: [SpeakerVoiceProfile]) {
        recordings = [:]
        for project in projects {
            var speakers: [UUID: SpeakerIdentity] = [:]
            for speaker in project.speakers {
                speakers[speaker.id] = SpeakerIdentity(
                    displayName: speaker.displayName, role: speaker.role,
                    backgroundContext: speaker.backgroundContext, colorToken: speaker.colorToken,
                    personID: speaker.personId, isCurrentUser: speaker.isCurrentUser,
                    voiceProfileID: speaker.voiceProfileId, voiceSamplePath: speaker.voiceSamplePath,
                    voiceSampleDurationMs: speaker.voiceSampleDurationMs, featureID: speaker.iflytekFeatureID,
                    legacyVoicePath: speaker.legacyVoiceReferencePath,
                    legacyVoiceDurationMs: speaker.legacyVoiceReferenceDurationMs
                )
            }
            var candidates: [UUID: CandidateIdentity] = [:]
            for candidate in project.businessMemoryCandidates {
                candidates[candidate.id] = CandidateIdentity(
                    personID: candidate.targetPersonID, displayName: candidate.targetPersonDisplayName
                )
            }
            recordings[project.id] = Recording(speakers: speakers, candidates: candidates)
        }
        self.businessProjects = businessProjects
        self.currentVoiceProfileID = currentVoiceProfileID
        self.voiceProfiles = voiceProfiles
    }
}

private struct VoiceIdentityMetadata: Equatable {
    var name: String
    var role: String?
    var color: String
    var background: String?
    var isCurrentUser: Bool?
    var isAutoEnabled: Bool

    init(_ profile: SpeakerVoiceProfile) {
        name = profile.displayName
        role = profile.role
        color = profile.colorToken
        background = profile.backgroundContext
        isCurrentUser = profile.isCurrentUser
        isAutoEnabled = profile.isAutoEnabled
    }

    func apply(to profile: inout SpeakerVoiceProfile) {
        profile.displayName = name
        profile.role = role
        profile.colorToken = color
        profile.backgroundContext = background
        profile.isCurrentUser = isCurrentUser
        profile.isAutoEnabled = isAutoEnabled
    }
}

private struct PersonRelationshipChange {
    var before: PersonRelationshipSnapshot
    var after: PersonRelationshipSnapshot
}

extension PersonLibraryStore {
    private func copyProjects(_ projects: [Project]) throws -> [Project] {
        try decoder.decode([Project].self, from: encoder.encode(projects))
    }

    @MainActor
    func changeIdentity(
        projectStore: any ProjectStoring,
        businessProjectStore: BusinessProjectStore,
        profileStore: SpeakerVoiceProfileStore,
        now: Date = Date(),
        mutate: (inout [Person], [Project], inout [BusinessProject]) throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let originalPersons = try loadUnlocked()
        let projects = try copyProjects(projectStore.loadProjects())
        var businesses = try businessProjectStore.load()
        let profiles = try profileStore.loadForManagement()
        let previous = PersonRelationshipSnapshot(
            projects: projects, businessProjects: businesses,
            currentVoiceProfileID: profiles.first { $0.isCurrentUser == true }?.id, voiceProfiles: profiles
        )
        var persons = originalPersons
        try mutate(&persons, projects, &businesses)
        try Self.validate(persons)
        let currentUser = persons.first(where: \.isCurrentUser)
        for project in projects {
            for speaker in project.speakers {
                speaker.isCurrentUser = speaker.personId != nil && speaker.personId == currentUser?.id
            }
        }
        Self.reconcileLinks(&persons, projects: projects, now: now)
        let availableProfileIDs = Set(profiles.map(\.id))
        let currentVoiceID = currentUser.flatMap { person in
            ([person.linkedVoiceProfileID].compactMap { $0 } + (person.additionalVoiceProfileIDs ?? []))
                .first { availableProfileIDs.contains($0) }
        }
        var updatedProfiles = profiles
        for index in updatedProfiles.indices {
            let profileID = updatedProfiles[index].id
            if let owner = persons.first(where: { $0.voiceProfileIDs.contains(profileID) }) {
                updatedProfiles[index].displayName = owner.displayName
                updatedProfiles[index].role = owner.role
                updatedProfiles[index].colorToken = owner.colorToken
                updatedProfiles[index].backgroundContext = owner.backgroundContext
            } else if originalPersons.contains(where: { $0.voiceProfileIDs.contains(profileID) }) {
                updatedProfiles[index].isAutoEnabled = false
            }
            updatedProfiles[index].isCurrentUser = profileID == currentVoiceID
        }
        let next = PersonRelationshipSnapshot(
            projects: projects, businessProjects: businesses, currentVoiceProfileID: currentVoiceID,
            voiceProfiles: updatedProfiles
        )
        try writeIdentityChange(
            persons: persons, originalPersons: originalPersons,
            projects: projects, businessProjects: businesses,
            previous: previous, next: next,
            projectStore: projectStore, businessProjectStore: businessProjectStore, profileStore: profileStore
        )
        recordUndo(persons: originalPersons, relationships: PersonRelationshipChange(before: previous, after: next))
    }

    private static func reconcileLinks(_ persons: inout [Person], projects: [Project], now: Date) {
        for index in persons.indices {
            let existing = persons[index].speakerLinks
            let personID = persons[index].id
            persons[index].speakerLinks = projects.flatMap { project in
                project.speakers.compactMap { speaker in
                    guard speaker.personId == personID else { return nil }
                    return PersonSpeakerLink(
                        projectID: project.id, speakerID: speaker.id, speakerDisplayName: speaker.displayName,
                        linkedAt: existing.first { $0.projectID == project.id && $0.speakerID == speaker.id }?.linkedAt ?? now
                    )
                }
            }
        }
    }

    private func writeIdentityChange(
        persons: [Person], originalPersons: [Person], projects: [Project], businessProjects: [BusinessProject],
        previous: PersonRelationshipSnapshot, next: PersonRelationshipSnapshot,
        projectStore: any ProjectStoring, businessProjectStore: BusinessProjectStore,
        profileStore: SpeakerVoiceProfileStore
    ) throws {
        var projectAttempted = false
        var businessAttempted = false
        var profileAttempted = false
        var personAttempted = false
        do {
            if previous.recordings != next.recordings {
                projectAttempted = true
                try projectStore.saveProjects(projects)
            }
            if previous.businessProjects != next.businessProjects {
                businessAttempted = true
                try businessProjectStore.replaceAll(businessProjects)
            }
            if previous.voiceProfiles != next.voiceProfiles {
                profileAttempted = true
                try profileStore.replacePersonLinkedMetadata(next.voiceProfiles)
            }
            personAttempted = true
            try ensureBaseDirectoryUnlocked()
            try persistUnlocked(persons, now: Date(), pushUndo: false)
        } catch {
            let originalError = error
            var rollbackFailed = false
            if personAttempted {
                do { try persistUnlocked(originalPersons, now: Date(), pushUndo: false) }
                catch { rollbackFailed = true }
            }
            if profileAttempted {
                do { try profileStore.replacePersonLinkedMetadata(previous.voiceProfiles) }
                catch { rollbackFailed = true }
            }
            if businessAttempted {
                do { try businessProjectStore.replaceAll(previous.businessProjects) }
                catch { rollbackFailed = true }
            }
            if projectAttempted {
                do {
                    Self.applyRecordingIdentities(previous.recordings, to: projects)
                    for project in projects {
                        if let record = previous.recordings[project.id] {
                            project.speakers.removeAll { record.speakers[$0.id] == nil }
                        }
                    }
                    try projectStore.saveProjects(projects)
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw PersonLibraryStoreError.rollbackFailed }
            throw originalError
        }
    }

    private static func applyRecordingIdentities(
        _ identities: [UUID: PersonRelationshipSnapshot.Recording], to projects: [Project]
    ) {
        for project in projects {
            guard let record = identities[project.id] else { continue }
            for speaker in project.speakers {
                guard let state = record.speakers[speaker.id] else { continue }
                speaker.displayName = state.displayName
                speaker.role = state.role
                speaker.backgroundContext = state.backgroundContext
                speaker.colorToken = state.colorToken
                speaker.personId = state.personID
                speaker.isCurrentUser = state.isCurrentUser
                speaker.voiceProfileId = state.voiceProfileID
                speaker.voiceSamplePath = state.voiceSamplePath
                speaker.voiceSampleDurationMs = state.voiceSampleDurationMs
                speaker.iflytekFeatureID = state.featureID
                speaker.legacyVoiceReferencePath = state.legacyVoicePath
                speaker.legacyVoiceReferenceDurationMs = state.legacyVoiceDurationMs
            }
            for index in project.businessMemoryCandidates.indices {
                guard let state = record.candidates[project.businessMemoryCandidates[index].id] else { continue }
                project.businessMemoryCandidates[index].targetPersonID = state.personID
                project.businessMemoryCandidates[index].targetPersonDisplayName = state.displayName
            }
        }
    }

    private func restoreLastChange(
        isRedo: Bool, projectStore: (any ProjectStoring)?, businessProjectStore: BusinessProjectStore?,
        profileStore: SpeakerVoiceProfileStore?, now: Date
    ) throws -> [Person] {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = isRedo ? redoStack.last : undoStack.last else {
            throw PersonLibraryStoreError.cannotUndo
        }
        let currentPersons = try loadUnlocked()
        var restoredPersons = entry.persons
        var reverseRelationships: PersonRelationshipChange?
        if let change = entry.relationships {
            guard let projectStore, let businessProjectStore, let profileStore else {
                throw PersonLibraryStoreError.coordinatedUndoRequired
            }
            let projects = try copyProjects(projectStore.loadProjects())
            var businesses = try businessProjectStore.load()
            let profiles = try profileStore.loadForManagement()
            let current = PersonRelationshipSnapshot(
                projects: projects, businessProjects: businesses,
                currentVoiceProfileID: profiles.first { $0.isCurrentUser == true }?.id, voiceProfiles: profiles
            )
            let restored = try Self.restoredRelationships(change: change, current: current)
            Self.applyRecordingIdentities(restored.recordings, to: projects)
            let existingVoiceIDs = Set(profiles.map(\.id))
            for index in restoredPersons.indices {
                let remaining = restoredPersons[index].voiceProfileIDs.intersection(existingVoiceIDs)
                    .sorted { $0.uuidString < $1.uuidString }
                if let primary = restoredPersons[index].linkedVoiceProfileID, !existingVoiceIDs.contains(primary) {
                    restoredPersons[index].linkedVoiceProfileID = remaining.first
                }
                restoredPersons[index].additionalVoiceProfileIDs = remaining.filter { $0 != restoredPersons[index].linkedVoiceProfileID }
            }
            for project in projects {
                for speaker in project.speakers {
                    if let voiceID = speaker.voiceProfileId, !existingVoiceIDs.contains(voiceID) {
                        speaker.voiceProfileId = nil
                        speaker.voiceSamplePath = nil
                        speaker.voiceSampleDurationMs = nil
                        speaker.iflytekFeatureID = nil
                    speaker.legacyVoiceReferencePath = nil
                    speaker.legacyVoiceReferenceDurationMs = nil
                    }
                }
            }
            businesses = restored.businessProjects
            Self.reconcileLinks(&restoredPersons, projects: projects, now: now)
            let projectIDs = Set(projects.map(\.id))
            for personIndex in restoredPersons.indices {
                for memoryIndex in restoredPersons[personIndex].memoryEntries.indices {
                    let memory = restoredPersons[personIndex].memoryEntries[memoryIndex]
                    if let source = memory.source, !projectIDs.contains(source.recordingID),
                       memory.status == .active || memory.status == .candidate {
                        restoredPersons[personIndex].memoryEntries[memoryIndex].status = .needsReview
                        restoredPersons[personIndex].memoryEntries[memoryIndex].reviewReason = "来源录音已删除"
                    }
                }
            }
            let sanitized = PersonRelationshipSnapshot(
                projects: projects, businessProjects: businesses,
                currentVoiceProfileID: restored.currentVoiceProfileID, voiceProfiles: restored.voiceProfiles
            )
            try writeIdentityChange(
                persons: restoredPersons, originalPersons: currentPersons,
                projects: projects, businessProjects: businesses, previous: current, next: sanitized,
                projectStore: projectStore, businessProjectStore: businessProjectStore, profileStore: profileStore
            )
            reverseRelationships = PersonRelationshipChange(before: current, after: sanitized)
        } else {
            try ensureBaseDirectoryUnlocked()
            try persistUnlocked(restoredPersons, now: now, pushUndo: false)
        }
        let reverse = UndoEntry(persons: currentPersons, relationships: reverseRelationships)
        if isRedo {
            redoStack.removeLast()
            undoStack.append(reverse)
        } else {
            undoStack.removeLast()
            redoStack.append(reverse)
        }
        return restoredPersons
    }

    private static func restoredRelationships(
        change: PersonRelationshipChange, current: PersonRelationshipSnapshot
    ) throws -> PersonRelationshipSnapshot {
        var result = current
        for (projectID, after) in change.after.recordings {
            guard let before = change.before.recordings[projectID], var live = result.recordings[projectID] else { continue }
            for (speakerID, afterValue) in after.speakers {
                let beforeValue = before.speakers[speakerID] ?? PersonRelationshipSnapshot.SpeakerIdentity(
                    displayName: afterValue.displayName, role: afterValue.role,
                    backgroundContext: afterValue.backgroundContext, colorToken: afterValue.colorToken,
                    personID: nil, isCurrentUser: false, voiceProfileID: nil,
                    voiceSamplePath: nil, voiceSampleDurationMs: nil, featureID: nil,
                    legacyVoicePath: nil, legacyVoiceDurationMs: nil
                )
                guard beforeValue != afterValue, let liveValue = live.speakers[speakerID] else { continue }
                live.speakers[speakerID] = try liveValue.undoingChanges(from: beforeValue, to: afterValue)
            }
            for (candidateID, afterValue) in after.candidates {
                guard let beforeValue = before.candidates[candidateID], beforeValue != afterValue,
                      let liveValue = live.candidates[candidateID] else { continue }
                guard liveValue == afterValue else { throw PersonLibraryStoreError.undoConflict }
                live.candidates[candidateID] = beforeValue
            }
            result.recordings[projectID] = live
        }
        for after in change.after.businessProjects {
            guard let before = change.before.businessProjects.first(where: { $0.id == after.id }),
                  let index = result.businessProjects.firstIndex(where: { $0.id == after.id }) else { continue }
            let removed = Set(before.participantPersonIDs).subtracting(after.participantPersonIDs)
            let added = Set(after.participantPersonIDs).subtracting(before.participantPersonIDs)
            result.businessProjects[index].participantPersonIDs = Array(
                Set(result.businessProjects[index].participantPersonIDs).subtracting(added).union(removed)
            ).sorted { $0.uuidString < $1.uuidString }
            for afterFollowUp in after.followUps {
                guard let beforeFollowUp = before.followUps.first(where: { $0.id == afterFollowUp.id }),
                      beforeFollowUp.ownerPersonID != afterFollowUp.ownerPersonID,
                      let followUpIndex = result.businessProjects[index].followUps.firstIndex(where: { $0.id == afterFollowUp.id }) else { continue }
                guard result.businessProjects[index].followUps[followUpIndex].ownerPersonID == afterFollowUp.ownerPersonID else {
                    throw PersonLibraryStoreError.undoConflict
                }
                result.businessProjects[index].followUps[followUpIndex].ownerPersonID = beforeFollowUp.ownerPersonID
                result.businessProjects[index].followUps[followUpIndex].ownerDisplayText = beforeFollowUp.ownerDisplayText
            }
            for afterMemory in after.memoryEntries {
                guard let beforeMemory = before.memoryEntries.first(where: { $0.id == afterMemory.id }),
                      beforeMemory.scope != afterMemory.scope || beforeMemory.status != afterMemory.status,
                      let memoryIndex = result.businessProjects[index].memoryEntries.firstIndex(where: { $0.id == afterMemory.id }) else { continue }
                let live = result.businessProjects[index].memoryEntries[memoryIndex]
                guard live.scope == afterMemory.scope, live.status == afterMemory.status else {
                    throw PersonLibraryStoreError.undoConflict
                }
                result.businessProjects[index].memoryEntries[memoryIndex].scope = beforeMemory.scope
                result.businessProjects[index].memoryEntries[memoryIndex].status = beforeMemory.status
                result.businessProjects[index].memoryEntries[memoryIndex].reviewReason = beforeMemory.reviewReason
            }
        }
        for after in change.after.voiceProfiles {
            guard let before = change.before.voiceProfiles.first(where: { $0.id == after.id }),
                  let index = result.voiceProfiles.firstIndex(where: { $0.id == after.id }) else { continue }
            let beforeMetadata = VoiceIdentityMetadata(before)
            let afterMetadata = VoiceIdentityMetadata(after)
            guard beforeMetadata != afterMetadata else { continue }
            guard VoiceIdentityMetadata(result.voiceProfiles[index]) == afterMetadata else {
                throw PersonLibraryStoreError.undoConflict
            }
            beforeMetadata.apply(to: &result.voiceProfiles[index])
        }
        result.currentVoiceProfileID = result.voiceProfiles.first { $0.isCurrentUser == true }?.id
        return result
    }
}

@MainActor
extension AppEnvironment {
    func linkPerson(personID: UUID?, projectID: UUID, speakerID: UUID, currentProject: Project? = nil) throws {
        try requirePersonStorage()
        try personLibraryStore.changeIdentity(
            projectStore: projectStore, businessProjectStore: businessProjectStore,
            profileStore: speakerVoiceProfileStore
        ) { persons, projects, _ in
            guard let project = projects.first(where: { $0.id == projectID }) else {
                throw PersonLibraryStoreError.personNotFound
            }
            if !project.speakers.contains(where: { $0.id == speakerID }),
               currentProject?.id == projectID,
               let added = currentProject?.speakers.first(where: { $0.id == speakerID }) {
                let data = try JSONEncoder().encode(added)
                project.speakers.append(try JSONDecoder().decode(Speaker.self, from: data))
            }
            guard let speaker = project.speakers.first(where: { $0.id == speakerID }) else {
                throw PersonLibraryStoreError.personNotFound
            }
            if let personID, !persons.contains(where: { $0.id == personID }) {
                throw PersonLibraryStoreError.personNotFound
            }
            let oldPersonID = speaker.personId
            speaker.personId = personID
            if let voiceID = speaker.voiceProfileId,
               let owner = persons.first(where: { $0.voiceProfileIDs.contains(voiceID) }),
               owner.id != personID {
                speaker.voiceProfileId = nil
                speaker.voiceSamplePath = nil
                speaker.voiceSampleDurationMs = nil
                speaker.iflytekFeatureID = nil
                    speaker.legacyVoiceReferencePath = nil
                    speaker.legacyVoiceReferenceDurationMs = nil
            }
            if oldPersonID != personID {
                let changedSegments = Set(project.segments.filter { $0.participantId == speakerID }.map(\.id))
                for personIndex in persons.indices {
                    for memoryIndex in persons[personIndex].memoryEntries.indices {
                        let memory = persons[personIndex].memoryEntries[memoryIndex]
                        if let source = memory.source, source.recordingID == projectID,
                           changedSegments.contains(source.segmentID),
                           memory.status == .active || memory.status == .candidate {
                            persons[personIndex].memoryEntries[memoryIndex].status = .needsReview
                            persons[personIndex].memoryEntries[memoryIndex].reviewReason = "来源说话人的人物归属已修改"
                        }
                    }
                }
                for index in project.businessMemoryCandidates.indices
                where changedSegments.contains(project.businessMemoryCandidates[index].evidenceSegmentID) {
                    project.businessMemoryCandidates[index].targetPersonID = personID
                    project.businessMemoryCandidates[index].targetPersonDisplayName = persons.first { $0.id == personID }?.displayName
                }
            }
        }
    }

    func setCurrentPerson(personID: UUID?) throws {
        try requirePersonStorage()
        try personLibraryStore.changeIdentity(
            projectStore: projectStore, businessProjectStore: businessProjectStore,
            profileStore: speakerVoiceProfileStore
        ) { persons, _, _ in
            if let personID, !persons.contains(where: { $0.id == personID }) {
                throw PersonLibraryStoreError.personNotFound
            }
            for index in persons.indices { persons[index].isCurrentUser = persons[index].id == personID }
        }
    }

    func detachPersonVoiceProfile(profileID: UUID) throws {
        try requirePersonStorage()
        try personLibraryStore.changeIdentity(
            projectStore: projectStore, businessProjectStore: businessProjectStore,
            profileStore: speakerVoiceProfileStore
        ) { persons, projects, _ in
            for index in persons.indices where persons[index].voiceProfileIDs.contains(profileID) {
                let remaining = persons[index].voiceProfileIDs.subtracting([profileID])
                    .sorted { $0.uuidString < $1.uuidString }
                if persons[index].linkedVoiceProfileID == profileID {
                    persons[index].linkedVoiceProfileID = remaining.first
                }
                persons[index].additionalVoiceProfileIDs = remaining.filter { $0 != persons[index].linkedVoiceProfileID }
            }
            for project in projects {
                for speaker in project.speakers where speaker.voiceProfileId == profileID {
                    speaker.voiceProfileId = nil
                    speaker.voiceSamplePath = nil
                    speaker.voiceSampleDurationMs = nil
                    speaker.iflytekFeatureID = nil
                    speaker.legacyVoiceReferencePath = nil
                    speaker.legacyVoiceReferenceDurationMs = nil
                }
            }
        }
    }

    func mergePeople(keepingID: UUID, absorbingID: UUID, keepBackground: Bool, keepVoice: Bool) throws {
        try requirePersonStorage()
        try personLibraryStore.changeIdentity(
            projectStore: projectStore, businessProjectStore: businessProjectStore,
            profileStore: speakerVoiceProfileStore
        ) { persons, projects, businesses in
            let keeping = try PersonLibraryStore.mergePersons(
                &persons, keepingID: keepingID, absorbingID: absorbingID,
                keepBackgroundFromAbsorbing: keepBackground,
                keepVoiceProfileFromAbsorbing: keepVoice, now: Date()
            )
            Self.remapPerson(absorbingID, to: keeping.id, displayName: keeping.displayName,
                             persons: &persons, projects: projects, businesses: &businesses)
        }
    }

    func deleteLibraryPerson(personID: UUID) throws {
        try requirePersonStorage()
        try personLibraryStore.changeIdentity(
            projectStore: projectStore, businessProjectStore: businessProjectStore,
            profileStore: speakerVoiceProfileStore
        ) { persons, projects, businesses in
            guard persons.contains(where: { $0.id == personID }) else { throw PersonLibraryStoreError.personNotFound }
            persons.removeAll { $0.id == personID }
            Self.remapPerson(personID, to: nil, displayName: nil,
                             persons: &persons, projects: projects, businesses: &businesses)
        }
    }

    func undoPersonChange() throws {
        try requirePersonStorage()
        _ = try personLibraryStore.undoLastChange(
            projectStore: projectStore, businessProjectStore: businessProjectStore,
            profileStore: speakerVoiceProfileStore
        )
    }

    private func requirePersonStorage() throws {
        guard !isPersistentStorageUnavailable else { throw ProjectWriteError.storageUnavailable }
    }

    private static func remapPerson(
        _ oldID: UUID, to newID: UUID?, displayName: String?,
        persons: inout [Person], projects: [Project], businesses: inout [BusinessProject]
    ) {
        for project in projects {
            for speaker in project.speakers where speaker.personId == oldID { speaker.personId = newID }
            for index in project.businessMemoryCandidates.indices
            where project.businessMemoryCandidates[index].targetPersonID == oldID {
                project.businessMemoryCandidates[index].targetPersonID = newID
                project.businessMemoryCandidates[index].targetPersonDisplayName = displayName
            }
        }
        for index in persons.indices {
            for memoryIndex in persons[index].memoryEntries.indices
            where persons[index].memoryEntries[memoryIndex].scope.personID == oldID {
                persons[index].memoryEntries[memoryIndex].scope.personID = newID
                if newID == nil {
                    persons[index].memoryEntries[memoryIndex].status = .needsReview
                    persons[index].memoryEntries[memoryIndex].reviewReason = "关联人物已删除"
                }
            }
        }
        for index in businesses.indices {
            businesses[index].participantPersonIDs = Array(Set(businesses[index].participantPersonIDs.compactMap {
                $0 == oldID ? newID : $0
            })).sorted { $0.uuidString < $1.uuidString }
            for followUpIndex in businesses[index].followUps.indices
            where businesses[index].followUps[followUpIndex].ownerPersonID == oldID {
                businesses[index].followUps[followUpIndex].ownerPersonID = newID
                if let displayName { businesses[index].followUps[followUpIndex].ownerDisplayText = displayName }
            }
            for memoryIndex in businesses[index].memoryEntries.indices
            where businesses[index].memoryEntries[memoryIndex].scope.personID == oldID {
                businesses[index].memoryEntries[memoryIndex].scope.personID = newID
                if newID == nil {
                    businesses[index].memoryEntries[memoryIndex].status = .needsReview
                    businesses[index].memoryEntries[memoryIndex].reviewReason = "关联人物已删除"
                }
            }
        }
    }
}
