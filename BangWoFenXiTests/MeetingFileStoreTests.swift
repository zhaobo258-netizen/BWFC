import Foundation
import Testing
@testable import BangWoFenXi

/// 会议文件存储测试：相对路径约定、目录创建、路径安全（阶段 1 验收：录音文件路径/相对路径逻辑）
@Suite("会议文件存储")
final class MeetingFileStoreTests {
    let tempDirectory: URL
    let store: MeetingFileStore

    init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = MeetingFileStore(baseDirectory: tempDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    @Test("会议专属目录符合约定")
    func meetingDirectoryLayout() {
        let id = UUID()
        let directory = store.meetingDirectory(for: id)
        #expect(directory.path.hasPrefix(tempDirectory.path))
        #expect(directory.lastPathComponent == id.uuidString)
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Meetings")
    }

    @Test("相对路径只含约定结构，不含绝对路径")
    func relativeAudioPathConvention() {
        let id = UUID()
        let relative = store.relativeAudioPath(for: id)
        #expect(relative == "Meetings/\(id.uuidString)/recording.caf")
        #expect(!relative.hasPrefix("/"))
        #expect(!relative.contains(tempDirectory.path), "数据库只存相对路径，不得泄露机器绝对路径")
    }

    @Test("相对路径与绝对 URL 往返一致")
    func relativeToAbsoluteRoundTrip() throws {
        let id = UUID()
        let relative = store.relativeAudioPath(for: id)
        let absolute = try store.absoluteURL(forRelativePath: relative)
        #expect(absolute.path == store.meetingDirectory(for: id)
            .appending(path: MeetingFileStore.recordingFileName).path)
    }

    @Test("创建会议专属目录（含中间层）")
    func ensureDirectoryCreatesHierarchy() throws {
        let id = UUID()
        let directory = try store.ensureMeetingDirectory(for: id)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("非法相对路径被拒绝：空、绝对路径、上级逃逸")
    func invalidRelativePathsRejected() {
        #expect(throws: MeetingFileStoreError.self) { _ = try store.absoluteURL(forRelativePath: "") }
        #expect(throws: MeetingFileStoreError.self) { _ = try store.absoluteURL(forRelativePath: "/etc/passwd") }
        #expect(throws: MeetingFileStoreError.self) { _ = try store.absoluteURL(forRelativePath: "../outside.json") }
        #expect(throws: MeetingFileStoreError.self) { _ = try store.absoluteURL(forRelativePath: "Meetings/../../escape") }
    }

    @Test("会议录音 URL 与存在性检查")
    func audioFileURLAndExistence() throws {
        let meeting = Meeting(title: "路径测试")
        // 未设置相对路径时为 nil
        #expect(try store.audioFileURL(for: meeting) == nil)
        #expect(!store.audioFileExists(for: meeting))

        meeting.audioRelativePath = store.relativeAudioPath(for: meeting.id)
        let url = try #require(try store.audioFileURL(for: meeting))
        #expect(!store.audioFileExists(for: meeting))

        // 写入文件后存在性为 true
        try store.ensureMeetingDirectory(for: meeting.id)
        try Data([0x01]).write(to: url)
        #expect(store.audioFileExists(for: meeting))
    }

    @Test("删除会议专属目录")
    func deleteMeetingFiles() throws {
        let id = UUID()
        let directory = try store.ensureMeetingDirectory(for: id)
        try Data([0x01]).write(to: directory.appending(path: "recording.caf"))
        #expect(FileManager.default.fileExists(atPath: directory.path))

        try store.deleteMeetingFiles(for: id)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        // 重复删除幂等
        #expect(throws: Never.self) { try store.deleteMeetingFiles(for: id) }
    }
}
