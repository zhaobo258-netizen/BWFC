import Foundation

/// V2 项目持久化协议（产品文档 03 号 §9.1）。
/// 与 MeetingStoring 同一隔离思路：JSON 实现先行，后续可替换为 SwiftData 实现。
protocol ProjectStoring: Sendable {
    /// 读取全部项目
    func loadProjects() throws -> [Project]
    /// 覆盖保存全部项目（原子写入）
    func saveProjects(_ projects: [Project]) throws
}

/// 项目持久化错误
enum ProjectStoreError: Error, Equatable {
    case directoryUnavailable
    case dataCorrupted(backupFileName: String?)
}

/// JSON 文件持久化：projects.json 与 meetings.json 同目录（Application Support/BangWoFenXi），
/// 风格完全镜像 JSONMeetingStore——iso8601 日期、prettyPrinted+sortedKeys、原子写入。
final class JSONProjectStore: ProjectStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var writeBlockedByIncompleteBackup = false

    /// - Parameter directory: 存储目录（会自动创建）
    init(directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appending(path: "projects.json", directoryHint: .notDirectory)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 默认存储：~/Library/Application Support/BangWoFenXi/（与 JSONMeetingStore 同目录）
    static func makeDefault() throws -> JSONProjectStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ProjectStoreError.directoryUnavailable
        }
        return try JSONProjectStore(directory: base.appending(path: "BangWoFenXi", directoryHint: .isDirectory))
    }

    func loadProjects() throws -> [Project] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        do {
            return try decoder.decode([Project].self, from: data)
        } catch is DecodingError {
            writeBlockedByIncompleteBackup = true
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let backupFileName = "projects.corrupt-\(formatter.string(from: Date())).json"
            let backupURL = fileURL.deletingLastPathComponent()
                .appending(path: backupFileName, directoryHint: .notDirectory)
            do {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
                writeBlockedByIncompleteBackup = false
                AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent(
                    "project_store_corrupted",
                    error: "backup_completed"
                ))
                throw ProjectStoreError.dataCorrupted(backupFileName: backupFileName)
            } catch let error as ProjectStoreError {
                throw error
            } catch {
                AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent(
                    "project_store_corrupt_backup_failed",
                    error: String(describing: type(of: error))
                ))
                throw ProjectStoreError.dataCorrupted(backupFileName: nil)
            }
        }
    }

    func saveProjects(_ projects: [Project]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !writeBlockedByIncompleteBackup else {
            throw ProjectStoreError.dataCorrupted(backupFileName: nil)
        }
        let data = try encoder.encode(projects)
        // 原子写入：避免中途崩溃留下半个文件
        try data.write(to: fileURL, options: .atomic)
    }
}

/// 内存持久化：单元测试、SwiftUI 预览与磁盘不可用时的降级方案
final class InMemoryProjectStore: ProjectStoring, @unchecked Sendable {
    private var projects: [Project]
    private let lock = NSLock()

    init(seed: [Project] = []) {
        self.projects = seed
    }

    func loadProjects() throws -> [Project] {
        lock.lock()
        defer { lock.unlock() }
        return projects
    }

    func saveProjects(_ projects: [Project]) throws {
        lock.lock()
        defer { lock.unlock() }
        self.projects = projects
    }
}
