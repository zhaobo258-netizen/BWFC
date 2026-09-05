import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

@MainActor
private final class ImportFinalReportGenerator:
    FinalReportGenerating,
    @unchecked Sendable
{
    var error: AnalysisAPIError?
    private(set) var callCount = 0
    var suspendGeneration = false
    private(set) var generationSuspended = false
    private var generationContinuation: CheckedContinuation<Void, Never>?

    func resumeGeneration() {
        generationContinuation?.resume()
        generationContinuation = nil
    }

    func generate(
        project: Project,
        analysis: ConversationAnalysisSnapshot,
        knownTerms: [String],
        relatedProjects: [Project],
        version: Int
    ) async throws -> FinalReportSnapshot {
        callCount += 1
        if suspendGeneration {
            await withCheckedContinuation { continuation in
                generationContinuation = continuation
                generationSuspended = true
            }
        }
        if let error {
            throw error
        }
        guard let segment = project.segments.first else {
            throw AnalysisAPIError.invalidResponse
        }
        return FinalReportSnapshot(
            version: version,
            providerID: "import-mock",
            providerName: "Import Mock",
            modelID: "import-model",
            promptVersion: PromptRegistry.version,
            inputFingerprint: FinalReportFingerprint.make(for: project),
            headline: "导入完整总结",
            overview: "导入完成后自动生成。",
            items: [
                FinalReportItem(
                    category: .fact,
                    text: "导入文稿事实",
                    epistemicStatus: .explicit,
                    confidence: .high,
                    evidenceSegmentIds: [segment.id]
                )
            ]
        )
    }
}

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

    private func makeController(
        finalReportGenerator: (any FinalReportGenerating)? = nil,
        diarizationService: (any DiarizationServicing)? = nil
    ) -> ImportProcessingController {
        let factory = transcriptionMockFactory
        return ImportProcessingController(
            importService: importMock,
            makeTranscriptionService: { factory() },
            analysisService: analysisMock,
            finalReportGenerator: finalReportGenerator,
            makeDiarizationService: { diarizationService },
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

    @Test("导入完成后自动生成一次完整总结并写入 Markdown")
    func importGeneratesFinalReportOnce() async throws {
        analysisConfigured = true
        let generator = ImportFinalReportGenerator()
        let controller = makeController(finalReportGenerator: generator)
        let projectID = try await controller.beginImport(
            url: importMock.fakeSourceURL(named: "带完整总结.m4a")
        )
        await waitFor { !controller.isRunning }

        let project = try #require(try storedProject(projectID))
        #expect(
            project.processingJobs.map(\.kind)
                == [.audioExtraction, .transcription, .analysis, .finalReport]
        )
        #expect(project.processingJobs.allSatisfy { $0.status == .completed })
        #expect(project.finalReportSnapshots.count == 1)
        #expect(generator.callCount == 1)
        #expect(controller.finalReportNotificationRevision == 1)
        #expect(FileManager.default.fileExists(
            atPath: fileStore.meetingDirectory(for: projectID)
                .appending(path: "完整总结.md").path
        ))
    }

    @Test("完整总结失败只产生可重试告警，录音文稿仍可用")
    func finalReportFailureDoesNotLoseTranscript() async throws {
        analysisConfigured = true
        let generator = ImportFinalReportGenerator()
        generator.error = .network
        let controller = makeController(finalReportGenerator: generator)
        let projectID = try await controller.beginImport(
            url: importMock.fakeSourceURL(named: "总结失败.m4a")
        )
        await waitFor { !controller.isRunning }

        let project = try #require(try storedProject(projectID))
        #expect(project.status == .readyWithWarnings)
        #expect(project.segments.count == 1)
        #expect(project.finalReportSnapshots.isEmpty)
        #expect(
            project.processingJobs.first { $0.kind == .finalReport }?.status
                == .failedRetryable
        )
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
    @Test("项目删除后晚返回的完整总结不得重建目录或通知成功")
    func deletedProjectRejectsLateFinalReport() async throws {
        analysisConfigured = true
        for requestCancellation in [false, true] {
            let generator = ImportFinalReportGenerator()
            generator.suspendGeneration = true
            let controller = makeController(finalReportGenerator: generator)
            let id = try await controller.beginImport(
                url: importMock.fakeSourceURL(named: "晚返回-\(requestCancellation).m4a")
            )
            await waitFor { generator.generationSuspended }
            #expect(generator.generationSuspended)
            if requestCancellation { controller.cancel() }
            var projects = try store.loadProjects()
            projects.removeAll { $0.id == id }
            try store.saveProjects(projects)
            let directory = fileStore.meetingDirectory(for: id)
            try FileManager.default.removeItem(at: directory)
            generator.resumeGeneration()
            await waitFor { !controller.isRunning }
            #expect(!controller.isRunning)
            #expect(controller.activeProjectID == nil)
            #expect(try storedProject(id) == nil)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            #expect(controller.latestFinalReportCompletion == nil)
            #expect(controller.finalReportNotificationRevision == 0)
        }
    }

    @Test("导入配置分人后执行匿名分人，失败仅重试该阶段")
    func importedDiarizationRetriesWithoutRepeatingTranscription() async throws {
        let transcription = MockLocalTranscriptionService()
        transcription.finishEndsStream = true
        transcription.emit(.init(startAudioMs: 0, endAudioMs: 150,
                                 text: "导入语音", isFinal: true))
        transcriptionMockFactory = { transcription }
        let cloud = MockDiarizationService()
        cloud.persistentError = DiarizationAPIError.network
        let controller = makeController(diarizationService: cloud)
        let id = try await controller.beginImport(url: importMock.fakeSourceURL(named: "分人.m4a"))
        await waitFor { !controller.isRunning }
        let failed = try #require(try storedProject(id))
        #expect(failed.processingJobs.first { $0.kind == .diarization }?.status == .failedRetryable)
        #expect(failed.segments.map(\.text) == ["导入语音"])
        #expect(failed.status == .readyWithWarnings)
        #expect(cloud.calls.count == 1)
        cloud.persistentError = nil
        cloud.resultQueue = [.init(durationMs: 200, segments: [
            .init(startMs: 0, endMs: 150, text: "导入语音", speakerLabel: "speaker_0")
        ])]
        controller.resume(projectID: id)
        await waitFor { !controller.isRunning }
        let completed = try #require(try storedProject(id))
        #expect(completed.status == .ready)
        #expect(completed.processingJobs.first { $0.kind == .diarization }?.status == .completed)
        #expect(completed.segments.first?.source == .cloud)
        #expect(completed.segments.first?.remoteSpeakerLabel == "chunk:0:speaker_0")
        #expect(transcription.startSessionCalls.count == 1)
        #expect(cloud.calls.count == 2)
        #expect(cloud.calls.allSatisfy { $0.speakers.isEmpty })
    }

    @Test("导入准备声纹后只发一次整场请求，已知人物和跨20秒匿名标签保持一致")
    func recordingDiarizationUsesPreparedReferencesOnce() async throws {
        importMock.audioDurationMs = 45_000
        let transcription = MockLocalTranscriptionService()
        transcription.finishEndsStream = true
        transcription.emit(.init(startAudioMs: 0, endAudioMs: 45_000,
                                 text: "本地整段粗略文字，等待按不同说话人细分。", isFinal: true))
        transcriptionMockFactory = { transcription }
        let response = DiarizationChunkResult(durationMs: 45_000, segments: [
            .init(startMs: 0, endMs: 1_000, text: "已登记人物先确认验收。", speakerLabel: "p_07"),
            .init(startMs: 21_000, endMs: 22_000, text: "另一人提出付款条件。", speakerLabel: "speaker_0"),
            .init(startMs: 41_000, endMs: 42_000, text: "同一个人补充交货条件。", speakerLabel: "speaker_0")
        ])
        let cloud = ImportRecordingDiarizationMock(response: response)
        let controller = makeController(diarizationService: cloud)
        let sampleURL = tempDirectory.appending(path: "synthetic-reference.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<48_000 {
            channel[frame] = sin(2 * Float.pi * 220 * Float(frame) / 16_000) * 0.2
        }
        do {
            let file = try AVAudioFile(forWriting: sampleURL, settings: AudioRecordingSettings.fileSettings(for: format))
            try file.write(from: buffer)
        }
        let known = Speaker(cloudAlias: "p_07", displayName: "合成已登记人物",
                            voiceSamplePath: "synthetic-reference.wav", voiceSampleDurationMs: 3_000,
                            iflytekFeatureID: "synthetic-feature")
        var prepared = 0
        controller.prepareSpeakerReferences = { [store] project in
            prepared += 1
            project.speakers = [known]
            try store.saveProjects([project])
        }
        let id = try await controller.beginImport(url: importMock.fakeSourceURL(named: "整场分人.m4a"))
        await waitFor { !controller.isRunning }
        let project = try #require(try storedProject(id))
        #expect(prepared == 1)
        #expect(cloud.recordingCalls.count == 1)
        #expect(cloud.chunkCallCount == 0)
        #expect(cloud.recordingCalls.first?.map(\.alias) == ["p_07"])
        #expect(cloud.recordingCalls.first?.first?.iflytekFeatureID == "synthetic-feature")
        #expect(project.processingJobs.first { $0.kind == .diarization }?.status == .completed)
        #expect(project.segments.map(\.text) == response.segments.map(\.text))
        #expect(project.segments.first?.participantId == known.id)
        let anonymous = project.segments.filter { $0.participantId == nil }
        #expect(anonymous.count == 2)
        #expect(anonymous.first?.remoteSpeakerLabel == anonymous.last?.remoteSpeakerLabel)
        #expect(anonymous.first?.remoteSpeakerLabel?.hasPrefix("recording:") == true)
        #expect(anonymous.first?.remoteSpeakerLabel?.hasSuffix(":speaker_0") == true)
    }

    @Test("整场分人保护人工文字和身份，也不覆盖请求期间后来保存的段落与笔记")
    func recordingDiarizationPreservesManualAndLatestSegments() async throws {
        let manualSpeaker = Speaker(cloudAlias: "p_01", displayName: "合成人工人物")
        let manualText = TranscriptSegment(startMs: 0, endMs: 50, text: "人工更正文稿。",
                                          source: .manual, state: .edited, textWasUserEdited: true)
        let manualIdentity = TranscriptSegment(startMs: 50, endMs: 100, text: "人工指定人物。",
            participantId: manualSpeaker.id, source: .local, state: .final, speakerWasUserConfirmed: true)
        let changing = TranscriptSegment(startMs: 100, endMs: 150, text: "请求前的文字。", source: .local, state: .final)
        let cloud = ImportRecordingDiarizationMock(response: .init(durationMs: 200, segments: [
            .init(startMs: 0, endMs: 50, text: "云端误写一。", speakerLabel: "speaker_0"),
            .init(startMs: 50, endMs: 100, text: "云端误写二。", speakerLabel: "speaker_0"),
            .init(startMs: 100, endMs: 150, text: "迟到的云端原文。", speakerLabel: "speaker_0")
        ]))
        cloud.suspendRecording = true
        let controller = makeController(diarizationService: cloud)
        controller.prepareSpeakerReferences = { [store] project in
            project.speakers = [manualSpeaker]
            project.segments = [manualText, manualIdentity, changing]
            try store.saveProjects([project])
        }
        let id = try await controller.beginImport(url: importMock.fakeSourceURL(named: "整场保护.m4a"))
        await waitFor { cloud.recordingSuspended }
        #expect(cloud.recordingSuspended)
        let current = try #require(try storedProject(id))
        changing.text = "请求期间后来保存的文字。"
        let added = TranscriptSegment(startMs: 150, endMs: 200, text: "新增的段落。", source: .local, state: .final)
        current.segments.append(added)
        current.note.markdown = "后来保存的笔记。"
        try store.saveProjects([current])
        cloud.resumeRecording()
        await waitFor { !controller.isRunning }
        let saved = try #require(try storedProject(id))
        #expect(saved.segments.map(\.id) == [manualText.id, manualIdentity.id, changing.id, added.id])
        #expect(saved.segments.map(\.text) == ["人工更正文稿。", "人工指定人物。", "请求期间后来保存的文字。", "新增的段落。"])
        #expect(saved.segments.first { $0.id == manualIdentity.id }?.participantId == manualSpeaker.id)
        #expect(saved.segments.first { $0.id == manualIdentity.id }?.speakerWasUserConfirmed == true)
        #expect(saved.note.markdown == "后来保存的笔记。")
    }

    @Test("整场识别响应晚于取消或删除时，不写回识别结果", arguments: [false, true])
    func recordingDiarizationDropsLateResponse(deleteProject: Bool) async throws {
        let cloud = ImportRecordingDiarizationMock(response: .init(durationMs: 200, segments: [
            .init(startMs: 0, endMs: 150, text: "迟到结果不得落盘。", speakerLabel: "speaker_0")
        ]))
        cloud.suspendRecording = true
        let controller = makeController(diarizationService: cloud)
        let id = try await controller.beginImport(url: importMock.fakeSourceURL(named: "取消整场.m4a"))
        await waitFor { cloud.recordingSuspended }
        #expect(cloud.recordingSuspended)
        if deleteProject {
            try store.saveProjects([])
        } else {
            controller.cancel()
        }
        cloud.resumeRecording()
        await waitFor { !controller.isRunning }
        #expect(!controller.isRunning)
        if deleteProject {
            #expect(try storedProject(id) == nil)
        } else {
            let saved = try #require(try storedProject(id))
            #expect(saved.segments.map(\.text) == ["导入音频的第一句。"])
            #expect(saved.processingJobs.first { $0.kind == .diarization }?.status == .pending)
            #expect(saved.segments.allSatisfy { $0.remoteSpeakerLabel == nil })
        }
    }

    @Test("无语音或收尾失败不触发分析，部分原话保存可重试")
    func emptyOrFailedTranscriptionDoesNotAnalyze() async throws {
        analysisConfigured = true
        let empty = MockLocalTranscriptionService()
        empty.finishEndsStream = true
        transcriptionMockFactory = { empty }
        let controller = makeController()
        let emptyID = try await controller.beginImport(url: importMock.fakeSourceURL(named: "无语音.m4a"))
        await waitFor { !controller.isRunning }
        let emptyProject = try #require(try storedProject(emptyID))
        #expect(emptyProject.processingJobs.first { $0.kind == .transcription }?.status == .failedRetryable)
        #expect(analysisMock.calls.isEmpty)

        let partial = MockLocalTranscriptionService()
        partial.finishEndsStream = true
        partial.finishError = .finalizationFailed
        partial.finalResultsOnFinish = [
            .init(startAudioMs: 0, endAudioMs: 150, text: "中断前的原话", isFinal: true)
        ]
        transcriptionMockFactory = { partial }
        let retryController = makeController()
        let partialID = try await retryController.beginImport(url: importMock.fakeSourceURL(named: "中断.m4a"))
        await waitFor { !retryController.isRunning }
        let partialProject = try #require(try storedProject(partialID))
        #expect(partialProject.segments.map(\.text) == ["中断前的原话"])
        #expect(partialProject.processingJobs.first { $0.kind == .transcription }?.status == .failedRetryable)
        #expect(analysisMock.calls.isEmpty)
    }

    @Test("历史现场录音重转写保留原音和人工标注，并映射暂停时间")
    func retranscribeLiveRecordingPreservesAudioAndManualWork() async throws {
        let project = Project(title: "历史录音", sourceType: .liveRecording, status: .ready)
        let audio = try await importMock.prepareAudio(
            from: importMock.fakeSourceURL(named: "原录音.m4a"), for: project.id,
            onProgress: { _ in }
        )
        project.runtimeAssetRelativePath = fileStore.relativeAudioPath(for: project.id)
        project.pauseIntervals = [PauseInterval(startMs: 50, endMs: 150)]
        let manual = TranscriptSegment(startMs: 0, endMs: 40, text: "人工纠正",
                                       participantId: UUID(), source: .manual, state: .edited,
                                       isStarred: true, speakerWasUserConfirmed: true)
        project.segments = [manual]
        try store.saveProjects([project])
        let original = try Data(contentsOf: audio)
        let mock = MockLocalTranscriptionService()
        mock.finishEndsStream = true
        mock.emit(.init(startAudioMs: 0, endAudioMs: 40, text: "自动文字", isFinal: true))
        mock.emit(.init(startAudioMs: 60, endAudioMs: 180, text: "暂停后的话", isFinal: true))
        transcriptionMockFactory = { mock }
        let controller = makeController()
        try controller.retranscribe(projectID: project.id)
        await waitFor { !controller.isRunning }
        let saved = try #require(try storedProject(project.id))
        #expect(saved.sourceType == .liveRecording)
        #expect(saved.status == .ready)
        #expect(saved.segments.first?.id == manual.id)
        #expect(saved.segments.first?.text == "人工纠正")
        #expect(saved.segments.first?.isStarred == true)
        #expect(saved.segments.first?.speakerWasUserConfirmed == true)
        #expect(saved.segments.last?.startMs == 160)
        #expect(saved.segments.last?.endMs == 280)
        #expect(try Data(contentsOf: audio) == original)
    }

}

/// Mock 导入服务：inspect/prepare 按脚本成败；prepare 成功时真实写出可读的 48kHz caf
/// （转写阶段要读该文件）；支持挂起门控（并发/取消用例）。
final class MockAudioImportService: AudioImportServicing, @unchecked Sendable {
    private let fileStore: MeetingFileStore
    private let lock = NSLock()

    var inspectError: AudioImportError?
    var audioDurationMs: Int64 = 200
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
        let frameCount = AVAudioFrameCount(audioDurationMs * 48)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        onProgress(1.0)
        return output
    }
}

private final class ImportRecordingDiarizationMock: DiarizationServicing, @unchecked Sendable {
    let recordingLimits: DiarizationRecordingLimits? = .init(maximumBytes: 25_000_000, maximumDurationMs: nil)
    let knownSpeakerMatchingCapability: KnownSpeakerMatchingCapability = .supported(maximumSpeakers: 4)
    let response: DiarizationChunkResult
    var suspendRecording = false
    private let lock = NSLock()
    private var recordedReferences: [[KnownSpeakerReference]] = []
    private var chunks = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspended = false

    init(response: DiarizationChunkResult) { self.response = response }
    var recordingCalls: [[KnownSpeakerReference]] { lock.withLock { recordedReferences } }
    var chunkCallCount: Int { lock.withLock { chunks } }
    var recordingSuspended: Bool { lock.withLock { suspended } }

    func resumeRecording() {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }

    func transcribeRecording(at audioURL: URL, knownSpeakers: [KnownSpeakerReference]) async throws -> DiarizationChunkResult {
        lock.withLock { recordedReferences.append(knownSpeakers) }
        if suspendRecording {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    suspended = true
                }
            }
        }
        return response
    }

    func transcribeChunk(at chunkURL: URL, knownSpeakers: [KnownSpeakerReference]) async throws -> DiarizationChunkResult {
        lock.withLock { chunks += 1 }
        return response
    }

    func testConnection() async throws -> Bool { true }
}
