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

    private func makeCaseDirectory(_ name: String) -> URL {
        tempDirectory.appending(
            path: "\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
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

    @Test("Obsidian 默认在 Vault 根目录建立“帮我分析”子文件夹")
    func obsidianStorageDirectoryConvention() throws {
        let vault = makeCaseDirectory("vault")
        try FileManager.default.createDirectory(
            at: vault.appending(path: ".obsidian", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        #expect(AppStorageLocation.isObsidianVault(vault))
        #expect(AppStorageLocation.storageDirectory(inVault: vault)
            == vault.appending(path: "帮我分析", directoryHint: .isDirectory))
    }

    @Test("迁移到 Obsidian 会复制并校验全部数据，原目录保持不变")
    func obsidianMigrationCopiesWithoutDeletingSource() throws {
        let caseDirectory = makeCaseDirectory("migration")
        let source = caseDirectory.appending(path: "source", directoryHint: .isDirectory)
        let project = Project(
            title: "迁移项目",
            sourceType: .liveRecording,
            status: .ready
        )
        let meeting = Meeting(title: "迁移会议", status: .completed)
        try JSONProjectStore(directory: source).saveProjects([project])
        try JSONMeetingStore(directory: source).saveMeetings([meeting])

        let sourceFiles = MeetingFileStore(baseDirectory: source)
        let meetingDirectory = try sourceFiles.ensureMeetingDirectory(for: project.id)
        let audio = Data([0x01, 0x02, 0x03, 0x04])
        try audio.write(to: meetingDirectory.appending(path: MeetingFileStore.recordingFileName))

        let vault = caseDirectory.appending(path: "vault", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: vault.appending(path: ".obsidian", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let destination = try AppStorageLocation.prepareVault(
            vault,
            migratingFrom: source
        )
        let migratedProjects = try JSONProjectStore(directory: destination).loadProjects()
        let migratedAudio = try Data(contentsOf: MeetingFileStore(baseDirectory: destination)
            .meetingDirectory(for: project.id)
            .appending(path: MeetingFileStore.recordingFileName))

        #expect(destination.lastPathComponent == "帮我分析")
        #expect(migratedProjects.first?.id == project.id)
        #expect(migratedAudio == audio)
        #expect(FileManager.default.fileExists(
            atPath: source.appending(path: "projects.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: meetingDirectory.appending(path: MeetingFileStore.recordingFileName).path
        ))

        let repeatedDestination = try AppStorageLocation.prepareVault(
            vault,
            migratingFrom: source
        )
        #expect(repeatedDestination == destination)
        #expect(try JSONProjectStore(directory: repeatedDestination)
            .loadProjects().first?.id == project.id)
    }

    @Test("目标子文件夹已有未知内容时拒绝覆盖")
    func obsidianMigrationRejectsUnknownDestination() throws {
        let caseDirectory = makeCaseDirectory("conflict")
        let source = caseDirectory.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.appending(path: "data.txt"))

        let vault = caseDirectory.appending(path: "vault", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: vault.appending(path: ".obsidian", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let destination = AppStorageLocation.storageDirectory(inVault: vault)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appending(path: "existing.txt"))

        #expect(throws: AppStorageLocationError.self) {
            try AppStorageLocation.prepareVault(vault, migratingFrom: source)
        }
        #expect(try String(
            contentsOf: destination.appending(path: "existing.txt"),
            encoding: .utf8
        ) == "keep")
    }

    @Test("目标已有另一份有效项目数据时拒绝静默切换")
    func obsidianMigrationRejectsDifferentValidDestination() throws {
        let caseDirectory = makeCaseDirectory("valid-conflict")
        let source = caseDirectory.appending(path: "source", directoryHint: .isDirectory)
        let sourceProject = Project(
            title: "当前项目",
            sourceType: .liveRecording
        )
        try JSONProjectStore(directory: source).saveProjects([sourceProject])

        let vault = caseDirectory.appending(path: "vault", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: vault.appending(path: ".obsidian", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let destination = AppStorageLocation.storageDirectory(inVault: vault)
        let destinationProject = Project(
            title: "Vault 中的另一份项目",
            sourceType: .importedAudio
        )
        try JSONProjectStore(directory: destination).saveProjects([destinationProject])

        #expect(throws: AppStorageLocationError.self) {
            _ = try AppStorageLocation.prepareVault(
                vault,
                migratingFrom: source
            )
        }

        #expect(try JSONProjectStore(directory: source)
            .loadProjects().first?.id == sourceProject.id)
        #expect(try JSONProjectStore(directory: destination)
            .loadProjects().first?.id == destinationProject.id)
    }
}
