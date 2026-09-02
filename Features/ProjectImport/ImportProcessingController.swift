import Foundation

/// 导入处理控制器（阶段 C，03 §9.2）：导入任务状态与续跑；不负责 UI 文稿展示。
///
/// 生命周期：挂在 AppEnvironment（App 级），离开工作台页面后后台继续处理；
/// 首版一次只处理一个导入（03 §6.2）。
/// 每个阶段的状态变化都立即持久化到 project.processingJobs——
/// App 重启后从最后完成阶段续跑（03 §7.2），不重新复制原文件。
@MainActor
@Observable
final class ImportProcessingController {

    // MARK: - 依赖（协议注入，可测试替换）

    private let importService: any AudioImportServicing
    /// 转写服务工厂：每次导入用独立实例，不与实时录音会话争抢
    private let makeTranscriptionService: () -> any LocalTranscriptionServicing
    private let analysisService: any ConversationAnalysisServicing
    private let finalReportGenerator: (any FinalReportGenerating)?
    private let fileStore: MeetingFileStore
    private let loadProject: (UUID) throws -> Project?
    private let persistProject: (Project, ProjectFieldOwnership) throws -> Void
    private let isAnalysisConfigured: () -> Bool
    /// 全局词库（导入转写的识别上下文；纠错规则由环境注入）
    var lexiconProvider: () -> [String] = { [] }
    var correctionRulesProvider: () -> [CorrectionRule] = { [] }

    // MARK: - 可观察状态

    /// 当前处理中的项目（nil = 空闲）
    private(set) var activeProjectID: UUID?
    /// 当前项目的 Job 流水镜像（UI 展示进度）
    private(set) var jobs: [ProcessingJob] = []
    /// 面向用户的脱敏错误提示（导入被拒绝 / 阶段失败）
    private(set) var lastErrorMessage: String?
    /// 是否正在执行流水线
    var isRunning: Bool { pipelineTask != nil }
    private(set) var finalReportNotificationRevision = 0
    private(set) var latestFinalReportCompletion: FinalReportCoordinator.Completion?
    private var pendingFinalReportCompletion: FinalReportCoordinator.Completion?

    private var pipelineTask: Task<Void, Never>?
    /// 流水线当前操作的项目对象（MainActor 持有；进度回调经 self 访问，避免跨并发域传递非 Sendable 的 Project）
    private var activeProject: Project?

    init(
        importService: any AudioImportServicing,
        makeTranscriptionService: @escaping () -> any LocalTranscriptionServicing,
        analysisService: any ConversationAnalysisServicing,
        finalReportGenerator: (any FinalReportGenerating)? = nil,
        fileStore: MeetingFileStore,
        isAnalysisConfigured: @escaping () -> Bool,
        loadProject: @escaping (UUID) throws -> Project?,
        persistProject: @escaping (Project, ProjectFieldOwnership) throws -> Void
    ) {
        self.importService = importService
        self.makeTranscriptionService = makeTranscriptionService
        self.analysisService = analysisService
        self.finalReportGenerator = finalReportGenerator
        self.fileStore = fileStore
        self.isAnalysisConfigured = isAnalysisConfigured
        self.loadProject = loadProject
        self.persistProject = persistProject
    }

    // MARK: - 入口

    /// 开始导入：检查文件 → 创建项目并立即持久化 → 启动流水线。
    /// 返回新项目 id 供导航直达工作台；检查失败抛出明确错误（不创建项目）。
    func beginImport(url: URL) async throws -> UUID {
        guard pipelineTask == nil else {
            throw ImportBusyError()
        }
        lastErrorMessage = nil
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let info = try await importService.inspect(url: url)

        let project = Project(
            title: ImportPlanner.defaultTitle(forFileName: info.fileName),
            sourceType: ImportPlanner.sourceType(hasVideoTrack: info.hasVideoTrack),
            status: .processing,
            startedAt: Date(),
            originalFileName: info.fileName,
            durationMs: info.durationMs,
            processingJobs: ImportPlanner.planJobs(
                analysisConfigured: isAnalysisConfigured(),
                finalReportConfigured: finalReportGenerator != nil
            )
        )
        try persistProject(project, .importPipeline)

        startPipeline(projectID: project.id, sourceURL: url)
        return project.id
    }

    /// 续跑（App 重启后 / 用户点重试）：从第一个未完成阶段继续。
    /// 原件副本已在项目目录内，不需要重新提供来源 URL。
    func resume(projectID: UUID) {
        guard pipelineTask == nil else { return }
        lastErrorMessage = nil
        startPipeline(projectID: projectID, sourceURL: nil)
    }

    /// 取消当前流水线：执行中的 Job 回退为 pending（非失败，可续跑），项目保持 processing
    func cancel() {
        pipelineTask?.cancel()
    }

    // MARK: - 流水线

    private func startPipeline(projectID: UUID, sourceURL: URL?) {
        pendingFinalReportCompletion = nil
        activeProjectID = projectID
        pipelineTask = Task { [weak self] in
            await self?.runPipeline(projectID: projectID, sourceURL: sourceURL)
            self?.pipelineTask = nil
        }
    }

    private func runPipeline(projectID: UUID, sourceURL: URL?) async {
        guard let project = (try? loadProject(projectID)) ?? nil else {
            lastErrorMessage = "项目读取失败，无法继续处理"
            activeProjectID = nil
            return
        }
        activeProject = project
        defer { activeProject = nil }
        // 续跑准备：running/failedRetryable 回 pending；分析 Key 补配置则补建分析 Job
        project.processingJobs = ImportPlanner.jobsForResume(
            project.processingJobs,
            analysisConfigured: isAnalysisConfigured(),
            finalReportConfigured: finalReportGenerator != nil
        )
        project.status = .processing
        persistQuietly(project)

        while let job = ImportPlanner.nextPendingJob(project.processingJobs) {
            if Task.isCancelled { break }
            setJob(job.kind, status: .running, progress: 0, in: project)
            let outcome = await run(job.kind, for: project, sourceURL: sourceURL)
            switch outcome {
            case .completed:
                setJob(job.kind, status: .completed, progress: 1, in: project)
                if job.kind == .finalReport,
                   let completion = pendingFinalReportCompletion {
                    latestFinalReportCompletion = completion
                    pendingFinalReportCompletion = nil
                    finalReportNotificationRevision += 1
                }
            case .failed(let category, let retryable, let message):
                if job.kind == .finalReport {
                    pendingFinalReportCompletion = nil
                }
                setJob(job.kind, status: retryable ? .failedRetryable : .failedFinal,
                       errorCategory: category, in: project)
                lastErrorMessage = message
                AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent(
                    "import_job_failed_\(job.kind.rawValue)", error: category))
            case .cancelled:
                if job.kind == .finalReport {
                    pendingFinalReportCompletion = nil
                }
                setJob(job.kind, status: .pending, progress: nil, in: project)
                persistQuietly(project)
                activeProjectID = nil
                return
            }
        }

        project.status = ImportPlanner.projectStatus(after: project.processingJobs)
        if project.status == .ready || project.status == .readyWithWarnings {
            project.endedAt = project.endedAt ?? Date()
        }
        project.lastActivityAt = Date()
        persistQuietly(project)
        activeProjectID = nil
    }

    private enum JobOutcome {
        case completed
        case failed(category: String, retryable: Bool, message: String)
        case cancelled
    }

    private func run(_ kind: ProcessingJobKind, for project: Project, sourceURL: URL?) async -> JobOutcome {
        switch kind {
        case .audioExtraction:
            return await runExtraction(for: project, sourceURL: sourceURL)
        case .transcription:
            return await runTranscription(for: project)
        case .analysis:
            return await runAnalysis(for: project)
        case .finalReport:
            return await runFinalReport(for: project)
        case .diarization, .knowledgeExpansion, .obsidianArchive:
            // 阶段 C 不创建这些 Job；出现即为编排错误，如实失败而非静默跳过
            return .failed(category: "unsupported_stage", retryable: false, message: "该处理阶段尚未支持")
        }
    }

    /// 提取：复制原件 + 音轨 → recording.caf。
    /// sourceURL 为 nil（续跑）时使用项目目录中留存的原件副本。
    private func runExtraction(for project: Project, sourceURL: URL?) async -> JobOutcome {
        do {
            let url: URL
            if let sourceURL {
                url = sourceURL
            } else if let existing = existingSourceCopyURL(for: project.id) {
                url = existing
            } else {
                return .failed(category: "source_copy_missing", retryable: false,
                               message: "找不到导入时留存的原件副本，无法继续提取")
            }
            // 外部 URL 只在首轮提取存在；false 也可能表示 Powerbox 当前已授权，
            // 不应视为错误。prepareAudio 先复制 source-original，再只读项目目录副本。
            let accessedSecurityScope = sourceURL != nil
                ? url.startAccessingSecurityScopedResource()
                : false
            defer {
                if accessedSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            _ = try await importService.prepareAudio(from: url, for: project.id) { [weak self] progress in
                Task { @MainActor in
                    self?.updateJobProgress(.audioExtraction, progress: progress)
                }
            }
            project.runtimeAssetRelativePath = fileStore.relativeAudioPath(for: project.id)
            persistQuietly(project)
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch let error as AudioImportError {
            let retryable: Bool
            switch error {
            case .extractionFailed, .fileNotReadable: retryable = true
            case .noAudioTrack, .zeroDuration, .undecodable: retryable = false
            }
            return .failed(category: String(describing: error), retryable: retryable,
                           message: error.userMessage)
        } catch {
            return .failed(category: String(describing: type(of: error)), retryable: true,
                           message: "音轨提取失败，可重试")
        }
    }

    private func runTranscription(for project: Project) async -> JobOutcome {
        let service = makeTranscriptionService()
        let availability = await service.checkMandarinAvailability()
        guard availability.isReady else {
            return .failed(category: "transcription_unavailable", retryable: true,
                           message: availability.issueSummary ?? "本地转写暂不可用")
        }
        guard let relativePath = project.runtimeAssetRelativePath,
              let audioURL = try? fileStore.absoluteURL(forRelativePath: relativePath) else {
            return .failed(category: "audio_missing", retryable: false,
                           message: "提取音频缺失，请从提取阶段重试")
        }
        do {
            let runner = FileTranscriptionRunner(service: service)
            let rules = correctionRulesProvider()
            let segments = try await runner.run(
                audioURL: audioURL,
                contextualStrings: lexiconProvider() // 全局词库改善识别
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.updateJobProgress(.transcription, progress: progress)
                }
            }
            for segment in segments {
                segment.text = TranscriptCorrector.autoCorrect(segment.text, rules: rules)
            }
            project.segments = segments
            persistQuietly(project)
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch let error as AudioImportError {
            return .failed(category: String(describing: error), retryable: true,
                           message: error.userMessage)
        } catch {
            return .failed(category: String(describing: type(of: error)), retryable: true,
                           message: "转写失败，可重试")
        }
    }

    /// 分析（阶段 D：V2 通用分析，语义分析师）：整篇一次性生成，快照直接写在 Project 上
    private func runAnalysis(for project: Project) async -> JobOutcome {
        guard !project.segments.isEmpty else {
            // 空转写没有可分析内容：如实完成（分析结果为空），不伪造洞察
            return .completed
        }
        let controller = ConversationAnalysisController(service: analysisService)
        controller.knownTermsProvider = lexiconProvider
        controller.relatedProjectsProvider = { [loadProject] in
            project.relatedProjectIDs.compactMap {
                (try? loadProject($0)) ?? nil
            }
        }
        controller.attach(to: project)
        await controller.generateFinalAnalysis()
        if Task.isCancelled { return .cancelled }
        if let failure = controller.lastFailureKind {
            return .failed(category: "analysis_failed", retryable: true,
                           message: "分析失败（\(failure)），可重试")
        }
        persistQuietly(project)
        return .completed
    }

    private func runFinalReport(for project: Project) async -> JobOutcome {
        guard let finalReportGenerator,
              let analysis = project.analysisSnapshots.max(by: {
                  $0.version < $1.version
              }) else {
            return .failed(
                category: "final_report_evidence_missing",
                retryable: true,
                message: "缺少完整分析证据，无法生成完整总结"
            )
        }
        let fileWriter = FinalReportFileWriter(fileStore: fileStore)
        let previousReports = project.finalReportSnapshots
        let latestReport = previousReports.max {
            $0.version < $1.version
        }
        var fileSnapshot: FinalReportFileWriter.Snapshot?
        do {
            var report = try await finalReportGenerator.generate(
                project: project,
                analysis: analysis,
                knownTerms: lexiconProvider(),
                relatedProjects: project.relatedProjectIDs.compactMap {
                    (try? loadProject($0)) ?? nil
                },
                version: (latestReport?.version ?? 0) + 1
            )
            let markdown = FinalReportMarkdownRenderer.makeMarkdown(
                report: report,
                project: project
            )
            fileSnapshot = try fileWriter.snapshot(projectID: project.id)
            report.markdownHash = try fileWriter.write(
                markdown: markdown,
                projectID: project.id,
                expectedExistingHash: latestReport?.markdownHash
            )
            project.finalReportSnapshots.append(report)
            project.finalReportSnapshots = FinalReportSnapshotRetention.keepingMostRecent(
                project.finalReportSnapshots
            )
            try persistProject(project, .importPipeline)
            pendingFinalReportCompletion = FinalReportCoordinator.Completion(
                projectID: project.id,
                version: report.version
            )
            return .completed
        } catch is CancellationError {
            rollbackFinalReport(
                project: project,
                previousReports: previousReports,
                fileWriter: fileWriter,
                fileSnapshot: fileSnapshot
            )
            return .cancelled
        } catch let error as AnalysisAPIError {
            rollbackFinalReport(
                project: project,
                previousReports: previousReports,
                fileWriter: fileWriter,
                fileSnapshot: fileSnapshot
            )
            return .failed(
                category: String(describing: error),
                retryable: true,
                message: "完整总结生成失败，可重试"
            )
        } catch {
            rollbackFinalReport(
                project: project,
                previousReports: previousReports,
                fileWriter: fileWriter,
                fileSnapshot: fileSnapshot
            )
            return .failed(
                category: String(describing: type(of: error)),
                retryable: true,
                message: "完整总结保存失败，可重试"
            )
        }
    }

    private func rollbackFinalReport(
        project: Project,
        previousReports: [FinalReportSnapshot],
        fileWriter: FinalReportFileWriter,
        fileSnapshot: FinalReportFileWriter.Snapshot?
    ) {
        project.finalReportSnapshots = previousReports
        guard let fileSnapshot else { return }
        do {
            try fileWriter.restore(fileSnapshot, projectID: project.id)
        } catch {
            AppLog.logError(
                AppLog.persistence,
                LogSanitizer.formatEvent(
                    "import_final_report_file_rollback_failed",
                    error: String(describing: type(of: error))
                )
            )
        }
    }

    // MARK: - Job 状态与持久化

    private func setJob(_ kind: ProcessingJobKind, status: ProcessingJobStatus,
                        progress: Double? = nil, errorCategory: String? = nil,
                        in project: Project) {
        guard let index = project.processingJobs.firstIndex(where: { $0.kind == kind }) else { return }
        project.processingJobs[index].status = status
        project.processingJobs[index].progress = progress
        if let errorCategory {
            project.processingJobs[index].lastErrorCategory = errorCategory
            project.processingJobs[index].retryCount += 1
        }
        project.processingJobs[index].updatedAt = Date()
        project.lastActivityAt = Date()
        persistQuietly(project)
    }

    /// 进度只更新内存镜像（高频回调不落盘；阶段完成时才持久化）
    private func updateJobProgress(_ kind: ProcessingJobKind, progress: Double) {
        guard let project = activeProject,
              let index = project.processingJobs.firstIndex(where: { $0.kind == kind }) else { return }
        project.processingJobs[index].progress = progress
        jobs = project.processingJobs
    }

    /// 流水线只提交自己拥有的字段，合并规则由统一持久层维护。
    private func persistQuietly(_ project: Project) {
        do {
            try persistProject(project, .importPipeline)
        } catch {
            AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent(
                "import_persist_failed", error: String(describing: type(of: error))))
            lastErrorMessage = "处理进度保存失败：\(error.localizedDescription)"
        }
        jobs = project.processingJobs
    }

    /// 项目目录中留存的原件副本（续跑用）
    private func existingSourceCopyURL(for projectID: UUID) -> URL? {
        let directory = fileStore.meetingDirectory(for: projectID)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.first {
            $0.lastPathComponent.hasPrefix(AVFoundationAudioImportService.sourceCopyBaseName + ".")
        }
    }
}

/// 已有导入在处理中（首版一次只处理一个导入）
struct ImportBusyError: Error, Equatable {
    var userMessage: String { "已有一个导入正在处理，请等它完成后再导入下一个文件。" }
}
