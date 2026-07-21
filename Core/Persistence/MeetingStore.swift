import Foundation

/// 会议持久化协议（实施计划 7.1 要求 SwiftData；当前工具链限制见下）。
///
/// 本机 Command Line Tools 不含 SwiftDataMacros 编译器插件（仅随 Xcode 分发），
/// @Model 宏无法展开。阶段 0 先以协议隔离持久化层：
/// - JSONMeetingStore：当前实现，会议树整体以 JSON 原子写入 Application Support；
/// - InMemoryMeetingStore：测试 / 预览 / 降级使用。
/// 安装 Xcode 后将提供 SwiftData 实现替换本协议，模型字段无需变动。
protocol MeetingStoring: Sendable {
    /// 读取全部会议
    func loadMeetings() throws -> [Meeting]
    /// 覆盖保存全部会议（原子写入）
    func saveMeetings(_ meetings: [Meeting]) throws
}

/// 持久化错误
enum MeetingStoreError: Error, Equatable {
    case directoryUnavailable
}

/// JSON 文件持久化：数据库文件放在 Application Support（App Sandbox 内），
/// 与实施计划 7.1「录音文件放 Application Support、数据库仅存相对路径」的目录约定一致。
final class JSONMeetingStore: MeetingStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: 存储目录（会自动创建）
    init(directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appending(path: "meetings.json", directoryHint: .notDirectory)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 默认存储：~/Library/Application Support/BangWoFenXi/
    static func makeDefault() throws -> JSONMeetingStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MeetingStoreError.directoryUnavailable
        }
        return try JSONMeetingStore(directory: base.appending(path: "BangWoFenXi", directoryHint: .isDirectory))
    }

    func loadMeetings() throws -> [Meeting] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Meeting].self, from: data)
    }

    func saveMeetings(_ meetings: [Meeting]) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try encoder.encode(meetings)
        // 原子写入：避免中途崩溃留下半个文件
        try data.write(to: fileURL, options: .atomic)
    }
}

/// 内存持久化：单元测试、SwiftUI 预览与磁盘不可用时的降级方案
final class InMemoryMeetingStore: MeetingStoring, @unchecked Sendable {
    private var meetings: [Meeting]
    private let lock = NSLock()

    init(seed: [Meeting] = []) {
        self.meetings = seed
    }

    func loadMeetings() throws -> [Meeting] {
        lock.lock()
        defer { lock.unlock() }
        return meetings
    }

    func saveMeetings(_ meetings: [Meeting]) throws {
        lock.lock()
        defer { lock.unlock() }
        self.meetings = meetings
    }
}
