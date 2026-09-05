import Foundation

enum BusinessProjectStoreError: Error, Equatable {
    case projectNotFound
    case duplicateName
}

/// 轻 CRM 业务项目存储（12 号 §7）：business-projects.json。
/// 模式与 PersonLibraryStore/JSONProjectStore 一致：JSON 原子写、ISO8601、sortedKeys。
final class BusinessProjectStore: @unchecked Sendable {
    private let baseDirectory: URL
    private let fileURL: URL
    private let fileManager: FileManager
    private let indexWriter: (Data, URL) throws -> Void
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
            path: "business-projects.json",
            directoryHint: .notDirectory
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

    func load() throws -> [BusinessProject] {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        do {
            return try decoder.decode([BusinessProject].self, from: data)
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let corruptURL = fileURL.deletingLastPathComponent().appending(
                path: "business-projects.corrupt-\(stamp).json",
                directoryHint: .notDirectory
            )
            try? data.write(to: corruptURL, options: .atomic)
            throw error
        }
    }

    @discardableResult
    func create(
        name: String,
        goalStatement: String? = nil,
        backgroundContext: String? = nil,
        participantPersonIDs: [UUID] = [],
        linkedProjectIDs: [UUID] = [],
        now: Date = Date()
    ) throws -> BusinessProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BusinessProjectStoreError.projectNotFound }
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var projects = try loadUnlocked()
        guard !projects.contains(where: { $0.name == trimmed }) else {
            throw BusinessProjectStoreError.duplicateName
        }
        let project = BusinessProject(
            name: trimmed,
            goalStatement: goalStatement,
            participantPersonIDs: participantPersonIDs,
            linkedProjectIDs: linkedProjectIDs,
            backgroundContext: backgroundContext,
            createdAt: now,
            updatedAt: now,
            lastActivityAt: now
        )
        projects.append(project)
        try persistUnlocked(projects)
        return project
    }

    @discardableResult
    func update(_ updated: BusinessProject, now: Date = Date()) throws -> BusinessProject {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var projects = try loadUnlocked()
        guard let index = projects.firstIndex(where: { $0.id == updated.id }) else {
            throw BusinessProjectStoreError.projectNotFound
        }
        var next = updated
        next.updatedAt = now
        next.lastActivityAt = now
        projects[index] = next
        try persistUnlocked(projects)
        return next
    }

    /// 只更新跟进事项（避免整对象覆盖并发编辑中的其他字段）。
    @discardableResult
    func replaceFollowUps(
        businessProjectID: UUID,
        followUps: [FollowUp],
        now: Date = Date()
    ) throws -> BusinessProject {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var projects = try loadUnlocked()
        guard let index = projects.firstIndex(where: { $0.id == businessProjectID }) else {
            throw BusinessProjectStoreError.projectNotFound
        }
        projects[index].followUps = followUps
        projects[index].updatedAt = now
        projects[index].lastActivityAt = now
        try persistUnlocked(projects)
        return projects[index]
    }

    /// 关联/解除录音（不复制录音，只保存引用）。
    @discardableResult
    func setLinkedProjects(
        businessProjectID: UUID,
        projectIDs: [UUID],
        now: Date = Date()
    ) throws -> BusinessProject {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var projects = try loadUnlocked()
        guard let index = projects.firstIndex(where: { $0.id == businessProjectID }) else {
            throw BusinessProjectStoreError.projectNotFound
        }
        projects[index].linkedProjectIDs = Array(Set(projectIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        projects[index].updatedAt = now
        try persistUnlocked(projects)
        return projects[index]
    }

    /// 关联/解除参与人物。
    @discardableResult
    func setParticipants(
        businessProjectID: UUID,
        personIDs: [UUID],
        now: Date = Date()
    ) throws -> BusinessProject {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var projects = try loadUnlocked()
        guard let index = projects.firstIndex(where: { $0.id == businessProjectID }) else {
            throw BusinessProjectStoreError.projectNotFound
        }
        projects[index].participantPersonIDs = Array(Set(personIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        projects[index].updatedAt = now
        try persistUnlocked(projects)
        return projects[index]
    }

    func delete(businessProjectID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        var projects = try loadUnlocked()
        let originalCount = projects.count
        projects.removeAll { $0.id == businessProjectID }
        guard projects.count == originalCount - 1 else {
            throw BusinessProjectStoreError.projectNotFound
        }
        try persistUnlocked(projects)
    }

    func replaceAll(_ projects: [BusinessProject]) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureBaseDirectoryUnlocked()
        try persistUnlocked(projects)
    }

    // MARK: - 归组建议（12 号 §7.2：迁移时同名仅提出归组建议，不自动认定同一项目）

    struct GroupingSuggestion: Equatable, Sendable, Identifiable {
        var name: String
        var projectIDs: [UUID]
        var id: String { name }
    }

    /// 从现有录音的业务分类字符串生成归组建议（排除已关联到业务项目的录音）。
    static func groupingSuggestions(
        recordings: [Project],
        existingBusinessProjects: [BusinessProject]
    ) -> [GroupingSuggestion] {
        let linkedIDs = Set(existingBusinessProjects.flatMap(\.linkedProjectIDs))
        var byName: [String: [UUID]] = [:]
        for recording in recordings {
            guard let category = recording.businessCategory?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !category.isEmpty,
                recording.sourceType != .combinedRecordings,
                !linkedIDs.contains(recording.id) else { continue }
            byName[category, default: []].append(recording.id)
        }
        return byName
            .map { GroupingSuggestion(name: $0.key, projectIDs: $0.value) }
            .sorted { $0.projectIDs.count > $1.projectIDs.count }
    }

    // MARK: - 私有

    private func loadUnlocked() throws -> [BusinessProject] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([BusinessProject].self, from: data)
    }

    private func ensureBaseDirectoryUnlocked() throws {
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
    }

    private func persistUnlocked(_ projects: [BusinessProject]) throws {
        let data = try encoder.encode(projects)
        try indexWriter(data, fileURL)
    }
}
