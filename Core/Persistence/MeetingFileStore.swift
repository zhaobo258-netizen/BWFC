import Foundation

/// 会议文件存储布局（实施计划 7.1 / 阶段 1）：
/// 录音等文件放在 Application Support 下的会议专属目录，数据库只存相对路径。
///
/// 目录约定：
///   <base>/Meetings/<meeting-uuid>/recording.caf   —— 完整录音
///   <base>/meetings.json                           —— 数据库（见 JSONMeetingStore）
struct MeetingFileStore: Sendable {
    /// 录音文件名（PCM .caf，与采集硬件格式一致，避免重采样）
    static let recordingFileName = "recording.caf"
    /// 会议文件根目录名
    static let meetingsDirectoryName = "Meetings"

    /// 应用数据根目录（通常为 ~/Library/Application Support/BangWoFenXi）
    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// 默认实例：与 JSONMeetingStore 共用同一 Application Support 根目录
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
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw MeetingFileStoreError.invalidRelativePath
        }
        return baseDirectory.appending(path: relativePath, directoryHint: .notDirectory)
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
