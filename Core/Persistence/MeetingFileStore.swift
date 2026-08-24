import Foundation

final class SecurityScopedStorageAccess {
    let url: URL
    private let didStartAccessing: Bool

    init(url: URL, didStartAccessing: Bool) {
        self.url = url
        self.didStartAccessing = didStartAccessing
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

struct AppStorageResolution {
    let baseDirectory: URL
    let obsidianVaultURL: URL?
    let securityScopedAccess: SecurityScopedStorageAccess?
    let warning: String?
}

enum AppStorageLocationError: Error, Equatable {
    case invalidObsidianVault
    case destinationNotEmpty
    case migrationInventoryMismatch
    case migrationDataUnreadable
}

extension AppStorageLocationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidObsidianVault:
            return "所选文件夹不是 Obsidian Vault，请选择包含 .obsidian 的根目录。"
        case .destinationNotEmpty:
            return "Vault 中的“帮我分析”文件夹已有其他内容，已停止迁移以避免覆盖。"
        case .migrationInventoryMismatch:
            return "迁移副本的文件清单校验失败，旧数据仍保留在原目录。"
        case .migrationDataUnreadable:
            return "迁移副本的数据文件无法复读，旧数据仍保留在原目录。"
        }
    }
}

enum AppStorageLocation {
    static let obsidianStorageDirectoryName = "帮我分析"
    static let bookmarkDefaultsKey = "bwfx.storage.obsidianVaultBookmark"

    static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MeetingStoreError.directoryUnavailable
        }
        return base.appending(path: "BangWoFenXi", directoryHint: .isDirectory)
    }

    static func storageDirectory(inVault vaultURL: URL) -> URL {
        vaultURL.appending(path: obsidianStorageDirectoryName, directoryHint: .isDirectory)
    }

    static func suggestedObsidianVault(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidate = homeDirectory
            .appending(path: "Desktop", directoryHint: .isDirectory)
            .appending(path: "Obsidian Vault", directoryHint: .isDirectory)
        return isObsidianVault(candidate, fileManager: fileManager) ? candidate : nil
    }

    static func isObsidianVault(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        let marker = url.appending(path: ".obsidian", directoryHint: .isDirectory)
        return fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func bookmarkData(for vaultURL: URL) throws -> Data {
        try vaultURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func saveBookmarkData(
        _ data: Data,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(data, forKey: bookmarkDefaultsKey)
    }

    static func resolveDefault(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) throws -> AppStorageResolution {
        let fallback = try applicationSupportDirectory(fileManager: fileManager)
        guard let storedBookmarkData = userDefaults.data(forKey: bookmarkDefaultsKey) else {
            return AppStorageResolution(
                baseDirectory: fallback,
                obsidianVaultURL: nil,
                securityScopedAccess: nil,
                warning: nil
            )
        }

        do {
            var isStale = false
            let vaultURL = try URL(
                resolvingBookmarkData: storedBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let access = SecurityScopedStorageAccess(
                url: vaultURL,
                didStartAccessing: vaultURL.startAccessingSecurityScopedResource()
            )
            guard isObsidianVault(vaultURL, fileManager: fileManager) else {
                throw AppStorageLocationError.invalidObsidianVault
            }
            let directory = storageDirectory(inVault: vaultURL)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if isStale {
                saveBookmarkData(try bookmarkData(for: vaultURL), userDefaults: userDefaults)
            }
            return AppStorageResolution(
                baseDirectory: directory,
                obsidianVaultURL: vaultURL,
                securityScopedAccess: access,
                warning: nil
            )
        } catch {
            return AppStorageResolution(
                baseDirectory: fallback,
                obsidianVaultURL: nil,
                securityScopedAccess: nil,
                warning: "Obsidian 授权已失效，当前暂用本机安全目录，请在设置中重新选择 Vault。"
            )
        }
    }

    static func prepareVault(
        _ vaultURL: URL,
        migratingFrom sourceDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isObsidianVault(vaultURL, fileManager: fileManager) else {
            throw AppStorageLocationError.invalidObsidianVault
        }
        let destination = storageDirectory(inVault: vaultURL)
        try migrateExistingData(
            from: sourceDirectory,
            to: destination,
            fileManager: fileManager
        )
        return destination
    }

    static func migrateExistingData(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let source = sourceDirectory.standardizedFileURL
        let destination = destinationDirectory.standardizedFileURL
        if source == destination {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }

        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }

        var destinationIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) {
            guard destinationIsDirectory.boolValue else {
                throw AppStorageLocationError.destinationNotEmpty
            }
            let existing = try meaningfulContents(
                of: destination,
                fileManager: fileManager
            )
            if !existing.isEmpty {
                guard try containsValidProjectStore(destination, fileManager: fileManager) else {
                    throw AppStorageLocationError.destinationNotEmpty
                }
                let sourceContents = try meaningfulContents(
                    of: source,
                    fileManager: fileManager
                )
                let destinationMatchesSource = sourceContents.isEmpty
                    ? true
                    : try directoryContentsMatch(
                            source,
                            destination,
                            fileManager: fileManager
                        )
                guard destinationMatchesSource else {
                    throw AppStorageLocationError.destinationNotEmpty
                }
                return
            }
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(
            path: ".\(obsidianStorageDirectoryName)-migrating-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) {
            try fileManager.copyItem(
                at: item,
                to: staging.appending(path: item.lastPathComponent)
            )
        }

        guard try fileInventory(at: source, fileManager: fileManager)
            == fileInventory(at: staging, fileManager: fileManager) else {
            throw AppStorageLocationError.migrationInventoryMismatch
        }
        guard try storedJSONIsReadable(in: staging, fileManager: fileManager) else {
            throw AppStorageLocationError.migrationDataUnreadable
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    private static func meaningfulContents(
        of directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent != ".DS_Store" }
    }

    private static func containsValidProjectStore(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let projectsURL = directory.appending(path: "projects.json", directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: projectsURL.path) else {
            return false
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        _ = try decoder.decode([Project].self, from: Data(contentsOf: projectsURL))
        return true
    }

    private static func storedJSONIsReadable(
        in directory: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let projectsURL = directory.appending(path: "projects.json", directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: projectsURL.path) {
            _ = try decoder.decode([Project].self, from: Data(contentsOf: projectsURL))
        }

        let meetingsURL = directory.appending(path: "meetings.json", directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: meetingsURL.path) {
            _ = try decoder.decode([Meeting].self, from: Data(contentsOf: meetingsURL))
        }
        return true
    }

    private static func fileInventory(
        at directory: URL,
        fileManager: FileManager
    ) throws -> [String: Int64] {
        let resolvedDirectoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw AppStorageLocationError.migrationInventoryMismatch
        }

        var inventory: [String: Int64] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let resolvedFilePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedFilePath.hasPrefix(resolvedDirectoryPath + "/") else {
                throw AppStorageLocationError.migrationInventoryMismatch
            }
            let relativePath = String(resolvedFilePath.dropFirst(resolvedDirectoryPath.count + 1))
            inventory[relativePath] = Int64(values.fileSize ?? 0)
        }
        return inventory
    }

    private static func directoryContentsMatch(
        _ source: URL,
        _ destination: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let sourceInventory = try fileInventory(
            at: source,
            fileManager: fileManager
        ).filter { URL(fileURLWithPath: $0.key).lastPathComponent != ".DS_Store" }
        let destinationInventory = try fileInventory(
            at: destination,
            fileManager: fileManager
        ).filter { URL(fileURLWithPath: $0.key).lastPathComponent != ".DS_Store" }
        guard sourceInventory == destinationInventory else {
            return false
        }
        return sourceInventory.keys.allSatisfy { relativePath in
            fileManager.contentsEqual(
                atPath: source.appending(path: relativePath).path,
                andPath: destination.appending(path: relativePath).path
            )
        }
    }
}

/// 会议文件存储布局（实施计划 7.1 / 阶段 1）：
/// 录音等文件放在应用数据根目录下的会议专属目录，数据库只存相对路径。
///
/// 目录约定：
///   <base>/Meetings/<meeting-uuid>/recording.caf   —— 完整录音
///   <base>/meetings.json                           —— 数据库（见 JSONMeetingStore）
struct MeetingFileStore: Sendable {
    /// 录音文件名（PCM .caf，与采集硬件格式一致，避免重采样）
    static let recordingFileName = "recording.caf"
    /// 会议文件根目录名
    static let meetingsDirectoryName = "Meetings"
    /// 上传分片目录名（会议专属目录内）
    static let chunksDirectoryName = "chunks"
    /// 声音样本目录名（会议专属目录内）
    static let samplesDirectoryName = "samples"
    /// 分片队列状态文件名
    static let chunkQueueFileName = "queue.json"

    /// 应用数据根目录（默认使用已授权的 Obsidian Vault/帮我分析，未授权时回退 Application Support）
    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// App Sandbox 内的安全回退实例；生产环境的实际默认位置由 AppStorageLocation 解析。
    static func makeDefault() throws -> MeetingFileStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MeetingStoreError.directoryUnavailable
        }
        return MeetingFileStore(
            baseDirectory: base.appending(path: "BangWoFenXi", directoryHint: .isDirectory)
        )
    }

    /// 会议专属目录（相对根目录）：Meetings/<uuid>
    func meetingDirectory(for meetingID: UUID) -> URL {
        baseDirectory
            .appending(path: Self.meetingsDirectoryName, directoryHint: .isDirectory)
            .appending(path: meetingID.uuidString, directoryHint: .isDirectory)
    }

    /// 创建会议专属目录（含中间层），返回目录 URL
    @discardableResult
    func ensureMeetingDirectory(for meetingID: UUID) throws -> URL {
        let directory = meetingDirectory(for: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 完整录音的数据库相对路径（仅存此值，不存绝对路径）
    func relativeAudioPath(for meetingID: UUID) -> String {
        "\(Self.meetingsDirectoryName)/\(meetingID.uuidString)/\(Self.recordingFileName)"
    }

    /// 相对路径 → 绝对 URL。
    /// 安全约束：拒绝空路径与任何逃逸出根目录的相对路径（如「..」、绝对路径）。
    func absoluteURL(forRelativePath relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MeetingFileStoreError.invalidRelativePath
        }
        let resolvedBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        var resolvedURL = resolvedBase
        for component in components {
            resolvedURL = resolvedURL
                .appending(path: String(component), directoryHint: .inferFromPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard resolvedURL.path.hasPrefix(resolvedBase.path + "/") else {
                throw MeetingFileStoreError.invalidRelativePath
            }
        }
        return resolvedURL
    }

    // MARK: - 阶段 3：声音样本与上传分片

    /// 参会人声音样本的相对路径：Meetings/<会议>/samples/<参会人>.wav
    func relativeVoiceSamplePath(meetingID: UUID, participantID: UUID) -> String {
        "\(Self.meetingsDirectoryName)/\(meetingID.uuidString)/\(Self.samplesDirectoryName)/\(participantID.uuidString).wav"
    }

    /// 分片目录（绝对 URL）
    func chunksDirectory(for meetingID: UUID) -> URL {
        meetingDirectory(for: meetingID)
            .appending(path: Self.chunksDirectoryName, directoryHint: .isDirectory)
    }

    /// 创建分片目录
    @discardableResult
    func ensureChunksDirectory(for meetingID: UUID) throws -> URL {
        let directory = chunksDirectory(for: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 分片文件名（按序号）
    static func chunkFileName(index: Int) -> String {
        String(format: "chunk_%04d.wav", index)
    }

    /// 分片队列状态文件（绝对 URL）
    func chunkQueueFileURL(for meetingID: UUID) -> URL {
        chunksDirectory(for: meetingID)
            .appending(path: Self.chunkQueueFileName, directoryHint: .notDirectory)
    }

    /// 会议录音文件的绝对 URL（若已设置相对路径）
    func audioFileURL(for meeting: Meeting) throws -> URL? {
        guard let relativePath = meeting.audioRelativePath else { return nil }
        return try absoluteURL(forRelativePath: relativePath)
    }

    /// 会议录音文件是否存在
    func audioFileExists(for meeting: Meeting) -> Bool {
        guard let url = try? audioFileURL(for: meeting) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 删除会议专属目录（阶段 5 的整场删除会调用；阶段 1 先提供能力并测试）
    func deleteMeetingFiles(for meetingID: UUID) throws {
        let directory = meetingDirectory(for: meetingID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

/// 会议文件存储错误
enum MeetingFileStoreError: Error, Equatable {
    /// 相对路径为空、为绝对路径或包含「..」逃逸
    case invalidRelativePath
}

extension MeetingFileStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            return "非法的相对路径"
        }
    }
}
