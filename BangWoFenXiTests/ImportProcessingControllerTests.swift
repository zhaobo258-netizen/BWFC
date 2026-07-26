import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

/// 导入处理控制器（阶段 C）：流水线编排、持久化、续跑、并发保护、字段级合并
@MainActor
@Suite("导入处理流水线", .serialized)
final class ImportProcessingControllerTests {
    private let tempDirectory: URL
    private let fileStore: MeetingFileStore
    private let store = InMemoryProjectStore()
    private let importMock: MockAudioImportService
    private let analysisMock = MockConversationAnalysisService()
    private var transcriptionMockFactory: @Sendable () -> MockLocalTranscriptionService
    private var analysisConfigured = false

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-importctl-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileStore = MeetingFileStore(baseDirectory: tempDirectory)
        importMock = MockAudioImportService(fileStore: fileStore)
        transcriptionMockFactory = {
            let mock = MockLocalTranscriptionService()
            mock.finishEndsStream = true
            mock.emit(LocalTranscriptResult(startAudioMs: 0, endAudioMs: 2000,
                                            text: "导入音频的第一句。", isFinal: true))
            return mock
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeController() -> ImportProcessingController {
        let factory = transcriptionMockFactory
        return ImportProcessingController(
            importService: importMock,
            makeTranscriptionService: { factory() },
            analysisService: analysisMock,
            fileStore: fileStore,
            isAnalysisConfigured: { [self] in analysisConfigured },
            loadProject: { [store] id in
                try store.loadProjects().first { $0.id == id }
            },
            persistProject: { [store] project, fields in
                var projects = try store.loadProjects()
                ProjectPersistence.upsert(project, into: &projects, fields: fields)
                try store.saveProjects(projects)
            }
        )
    }

    /// 轮询等待条件达成（测试纪律：条件轮询，禁止固定睡眠）
    private func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func storedProject(_ id: UUID) throws -> Project? {
        try store.loadProjects().first { $0.id == id }
    }

    // MARK: - 用例

    @Test("成功全流程（未配置分析）：提取 + 转写完成 → ready，片段与资产路径落库")
    func happyPathWithoutAnalysis() async throws {
        let controller = makeController()
        let projectID = try await controller.beginImport(url: importMock.fakeSourceURL(named: "客户拜访.m4a"))
        await waitFor { !controller.isRunning }

        let project = try #require(try storedProject(projectID))
        #expect(project.status == .ready)
        #expect(project.sourceType == .importedAudio)
        #expect(project.title == "客户拜访")
        #expect(project.originalFileName == "客户拜访.m4a")
        #expect(project.processingJobs.map(\.kind) == [.audioExtraction, .transcription])
        #expect(project.processingJobs.allSatisfy { $0.status == .completed })
        #expect(project.segments.count == 1)
        #expect(project.segments.first?.text == "导入音频的第一句。")
        #expect(project.runtimeAssetRelativePath == fileStore.relativeAudioPath(for: projectID))
        #expect(project.endedAt != nil)
    }

    @Test("已配置分析：分析 Job 完成 → ready，快照落库")
    func happyPathWithAnalysis() async throws {
        analysisConfigured = true
        let controller = makeController()
        let projectID = try await controller.beginImport(url: importMock.fakeSourceURL(named: "带分析.m4a"))
        await waitFor { !controller.isRunning }

        let project = try #require(try storedProject(projectID))
        #expect(project.status == .ready)
        #expect(project.processingJobs.map(\.kind) == [.audioExtraction, .transcription, .analysis])
        #expect(project.processingJobs.allSatisfy { $0.status == .completed })
        #expect(project.analysisSnapshots.count == 1, "最终分析快照必须落库（阶段 D：V2 通用分析容器）")
        #expect(analysisMock.calls.count == 1)
    }

    @Test("检查失败：明确错误抛出，不创建项目")
    func inspectFailureCreatesNothing() async throws {
        importMock.inspectError = .noAudioTrack
        let controller = makeController()
        await #expect(throws: AudioImportError.noAudioTrack) {
            _ = try await controller.beginImport(url: self.importMock.fakeSourceURL(named: "纯画面.mp4"))
        }
        #expect(try store.loadProjects().isEmpty)
    }

    @Test("提取可重试失败 → processing + failedRetryable；修复后 resume 续跑到 ready")
    func retryableExtractionFailureThenResume() async throws {
        importMock.prepareError = .extractionFailed
        let controller = makeController()
        let externalURL = importMock.fakeSourceURL(named: "会失败.m4a")
        let projectID = try await controller.beginImport(url: externalURL)
        await waitFor { !controller.isRunning }

        var project = try #require(try storedProject(projectID))
        #expect(project.status == .processing)
        #expect(project.processingJobs.first { $0.kind == .audioExtraction }?.status == .failedRetryable)
        #expect(project.processingJobs.first { $0.kind == .audioExtraction }?.retryCount == 1)
        #expect(project.processingJobs.first { $0.kind == .transcription }?.status == .pending, "后续阶段不执行")

        // 修复后续跑（不重新提供来源 URL：用项目目录中的原件副本）
        try FileManager.default.removeItem(at: externalURL)
        importMock.prepareError = nil
        controller.resume(projectID: projectID)
        await waitFor { !controller.isRunning }

        project = try #require(try storedProject(projectID))
        #expect(project.status == .ready)
        #expect(project.processingJobs.allSatisfy { $0.status == .completed })
        #expect(importMock.prepareCallsWithoutOriginalURL >= 1,
                "外部原文件删除后，续跑仍必须只依赖 source-original 副本")
    }

    @Test("视频轨损坏（failedFinal）：项目进入 failed，不无限重试")
    func finalFailureMarksProjectFailed() async throws {
        importMock.prepareError = .undecodable
        let controller = makeController()
        let projectID = try await controller.beginImport(url: importMock.fakeSourceURL(named: "损坏.mov", hasVideo: true))
        await waitFor { !controller.isRunning }

        let project = try #require(try storedProject(projectID))
        #expect(project.sourceType == .importedVideo)
        #expect(project.status == .failed)
        #expect(project.processingJobs.first { $0.kind == .audioExtraction }?.status == .failedFinal)
    }

    @Test("分析失败：必需阶段完成 → readyWithWarnings，文稿仍可用（03 §6.2 部分完成）")
    func analysisFailureYieldsPartialSuccess() async throws {
        analysisConfigured = true
        analysisMock.persistentError = AnalysisAPIError.serverError(statusCode: 500)
        let controller = makeController()
        let projectID = try await controller.beginImport(url: importMock.fakeSourceURL(named: "分析挂了.m4a"))
        await waitFor { !controller.isRunning }

        let project = try #require(try storedProject(projectID))
        #expect(project.status == .readyWithWarnings)
        #expect(project.segments.count == 1, "文稿必须可用")
        #expect(project.processingJobs.first { $0.kind == .analysis }?.status == .failedRetryable)
    }

    @Test("并发保护 + 取消 + 字段级合并：处理中第二次导入被拒；中途笔记编辑不被流水线覆盖；取消后 Job 回 pending")
    func busyCancelAndFieldLevelMerge() async throws {
        importMock.prepareGateEnabled = true // prepare 挂起等待放行
        let controller = makeController()
        let projectID = try await controller.beginImport(url: importMock.fakeSourceURL(named: "长任务.m4a"))
        await waitFor { self.importMock.prepareStarted }

        // 处理中：第二次导入被明确拒绝（首版一次一个）
        await #expect(throws: ImportBusyError.self) {
            _ = try await controller.beginImport(url: self.importMock.fakeSourceURL(named: "第二个.m4a"))
        }

        // 模拟工作台并发编辑：直接改存储中的笔记与标题（另一份副本）
        if let stored = try storedProject(projectID) {
            stored.note = NoteDocument(markdown: "用户会中笔记", updatedAt: Date())
            stored.title = "用户改过的标题"
            var projects = try store.loadProjects()
            if let index = projects.firstIndex(where: { $0.id == stored.id }) { projects[index] = stored }
            try store.saveProjects(projects)
        }

        // 放行提取，让转写走完
        importMock.releasePrepareGate()
        await waitFor { !controller.isRunning }

        let project = try #require(try storedProject(projectID))
        #expect(project.note.markdown == "用户会中笔记", "流水线持久化不得覆盖用户笔记")
        #expect(project.title == "用户改过的标题", "流水线持久化不得覆盖用户标题")
        #expect(project.status == .ready)
    }

    @Test("取消：执行中的 Job 回 pending（非失败），项目保持 processing 可续跑")
    func cancelRevertsRunningJobToPending() async throws {
        importMock.prepareGateEnabled = true
        let controller = makeController()
        let projectID = try await controller.beginImport(url: importMock.fakeSourceURL(named: "取消我.m4a"))
        await waitFor { self.importMock.prepareStarted }

        controller.cancel()
        await waitFor { !controller.isRunning }

        let project = try #require(try storedProject(projectID))
        #expect(project.status == .processing)
        #expect(project.processingJobs.first { $0.kind == .audioExtraction }?.status == .pending)
        #expect(project.processingJobs.first { $0.kind == .audioExtraction }?.lastErrorCategory == nil,
                "取消不是失败，不得记错误")
    }
}

/// Mock 导入服务：inspect/prepare 按脚本成败；prepare 成功时真实写出可读的 48kHz caf
/// （转写阶段要读该文件）；支持挂起门控（并发/取消用例）。
final class MockAudioImportService: AudioImportServicing, @unchecked Sendable {
    private let fileStore: MeetingFileStore
    private let lock = NSLock()

    var inspectError: AudioImportError?
    var prepareError: AudioImportError?
    /// prepare 挂起等待放行（测试并发与取消窗口）
    var prepareGateEnabled = false
    private var _prepareStarted = false
    private var _gateReleased = false
    private var _prepareCallsWithoutOriginalURL = 0

    var prepareStarted: Bool { lock.withLock { _prepareStarted } }
    var prepareCallsWithoutOriginalURL: Int { lock.withLock { _prepareCallsWithoutOriginalURL } }

    init(fileStore: MeetingFileStore) {
        self.fileStore = fileStore
    }

    func releasePrepareGate() {
        lock.withLock { _gateReleased = true }
    }

    /// 生成一个占位来源文件 URL（真实存在，供复制路径判定）
    func fakeSourceURL(named name: String, hasVideo: Bool = false) -> URL {
        let url = fileStore.baseDirectory.appending(path: name)
        try? FileManager.default.createDirectory(at: fileStore.baseDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("fake-media".utf8).write(to: url)
        }
        lock.withLock { fakeVideoFlags[name] = hasVideo }
        return url
    }
    private var fakeVideoFlags: [String: Bool] = [:]

    func inspect(url: URL) async throws -> ImportedMediaInfo {
        if let inspectError { throw inspectError }
        let hasVideo = lock.withLock { fakeVideoFlags[url.lastPathComponent] ?? false }
        return ImportedMediaInfo(durationMs: 2_000, hasVideoTrack: hasVideo,
                                 fileName: url.lastPathComponent, fileSizeBytes: 10)
    }

    func prepareAudio(from url: URL, for projectID: UUID,
                      onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lock.withLock { _prepareStarted = true }
        // 续跑时传入的是项目目录中的原件副本（source-original.*）
        if url.lastPathComponent.hasPrefix(AVFoundationAudioImportService.sourceCopyBaseName) {
            lock.withLock { _prepareCallsWithoutOriginalURL += 1 }
        }
        if prepareGateEnabled {
            while !(lock.withLock { _gateReleased }) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        // 与真实服务同序：先留存原件副本（复制成功后提取才可能失败），
        // 续跑用例依赖「失败前副本已在项目目录」这一真实行为
        let directory = try fileStore.ensureMeetingDirectory(for: projectID)
        let copy = directory.appending(path: "\(AVFoundationAudioImportService.sourceCopyBaseName).m4a")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.copyItem(at: url, to: copy)
        }
        if let prepareError { throw prepareError }
        // 写出真实可读的 48kHz caf（转写阶段读取）
        onProgress(0.5)
        let output = try fileStore.absoluteURL(forRelativePath: fileStore.relativeAudioPath(for: projectID))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: output, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600)!
        buffer.frameLength = 9_600
        try file.write(from: buffer)
        onProgress(1.0)
        return output
    }
}
