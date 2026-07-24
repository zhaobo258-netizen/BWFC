import Foundation
import Testing
@testable import BangWoFenXi

/// 录音资产缺失安全恢复测试（Codex 审计补强）：
/// 补写条件、不覆盖既有路径、不动录音文件、幂等。
@Suite("录音资产恢复")
final class ProjectAssetRepairTests {
    let tempDirectory: URL
    let fileStore: MeetingFileStore

    init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileStore = MeetingFileStore(baseDirectory: tempDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// 在标准相对路径造一份录音文件，返回相对路径
    @discardableResult
    private func makeRecordingFile(for projectID: UUID, bytes: Int) throws -> String {
        let relativePath = fileStore.relativeAudioPath(for: projectID)
        let url = try fileStore.absoluteURL(forRelativePath: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: bytes).write(to: url)
        return relativePath
    }

    @Test("空路径 + 录音存在且非空：补写标准相对路径")
    func repairsWhenFileExists() throws {
        let project = Project(title: "缺资产项目", sourceType: .liveRecording, status: .ready)
        let expectedPath = try makeRecordingFile(for: project.id, bytes: 1_024)

        #expect(ProjectAssetRepair.needsRepair(project, fileStore: fileStore) == true)
        #expect(ProjectAssetRepair.repair([project], fileStore: fileStore) == 1)
        #expect(project.runtimeAssetRelativePath == expectedPath)
    }

    @Test("空路径但录音不存在：不补写")
    func skipsWhenFileMissing() {
        let project = Project(title: "无录音项目", sourceType: .liveRecording, status: .creating)
        #expect(ProjectAssetRepair.needsRepair(project, fileStore: fileStore) == false)
        #expect(ProjectAssetRepair.repair([project], fileStore: fileStore) == 0)
        #expect(project.runtimeAssetRelativePath == nil)
    }

    @Test("空路径 + 录音为 0 字节：不补写")
    func skipsWhenFileEmpty() throws {
        let project = Project(title: "空录音项目", sourceType: .liveRecording, status: .ready)
        _ = try makeRecordingFile(for: project.id, bytes: 0)
        #expect(ProjectAssetRepair.needsRepair(project, fileStore: fileStore) == false)
        #expect(project.runtimeAssetRelativePath == nil)
    }

    @Test("已有非空路径：绝不覆盖")
    func neverOverwritesExistingPath() throws {
        let project = Project(title: "已有路径项目", sourceType: .liveRecording,
                              status: .ready, runtimeAssetRelativePath: "Meetings/other/recording.caf")
        _ = try makeRecordingFile(for: project.id, bytes: 1_024)
        #expect(ProjectAssetRepair.repair([project], fileStore: fileStore) == 0)
        #expect(project.runtimeAssetRelativePath == "Meetings/other/recording.caf")
    }

    @Test("非 liveRecording 来源：不补写")
    func skipsNonLiveRecording() throws {
        let project = Project(title: "导入音频项目", sourceType: .importedAudio, status: .ready)
        _ = try makeRecordingFile(for: project.id, bytes: 1_024)
        #expect(ProjectAssetRepair.needsRepair(project, fileStore: fileStore) == false)
    }

    @Test("repairIfNeeded：持久化、录音文件字节不变且幂等")
    func repairIfNeededPersistsIdempotently() throws {
        let store = try JSONProjectStore(directory: tempDirectory)
        let damaged = Project(title: "缺资产", sourceType: .liveRecording, status: .ready)
        let healthy = Project(title: "正常", sourceType: .liveRecording, status: .ready,
                              runtimeAssetRelativePath: "Meetings/x/recording.caf")
        try store.saveProjects([damaged, healthy])
        let recordingPath = try makeRecordingFile(for: damaged.id, bytes: 2_048)
        let recordingURL = try fileStore.absoluteURL(forRelativePath: recordingPath)
        let recordingBytesBefore = try Data(contentsOf: recordingURL)

        let first = try ProjectAssetRepair.repairIfNeeded(store: store, fileStore: fileStore)
        #expect(first == 1)

        // 重新读取验证持久化生效
        let reread = try JSONProjectStore(directory: tempDirectory)
        let projects = try reread.loadProjects()
        #expect(projects.first(where: { $0.id == damaged.id })?.runtimeAssetRelativePath == recordingPath)
        #expect(projects.first(where: { $0.id == healthy.id })?.runtimeAssetRelativePath == "Meetings/x/recording.caf")

        // 录音文件字节不变（不移动、不改写）
        #expect(try Data(contentsOf: recordingURL) == recordingBytesBefore)

        // 幂等：第二次无变化、不再写库
        let second = try ProjectAssetRepair.repairIfNeeded(store: store, fileStore: fileStore)
        #expect(second == 0)
    }
}
