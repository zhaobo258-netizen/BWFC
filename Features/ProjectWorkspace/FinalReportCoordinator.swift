import Foundation

@MainActor
@Observable
final class FinalReportCoordinator {
    struct Completion: Equatable {
        var projectID: UUID
        var version: Int
    }

    enum State: Equatable {
        case idle
        case generating
        case completed(version: Int)
        case failed(message: String)
    }

    private let analysisService: any ConversationAnalysisServicing
    private let finalReportGenerator: any FinalReportGenerating
    private let fileWriter: FinalReportFileWriter
    private let loadProject: (UUID) throws -> Project?
    private let persistProject: (Project, ProjectFieldOwnership) throws -> Void
    private let knownTermsProvider: () -> [String]
    /// 可注入的延迟（测试避免真实等待）
    private let sleep: (Duration) async -> Void

    /// 瞬时错误自动重试上限（10 号计划需求 2：长录音生成一次超时就静默失败太脆）
    static let maxTransientRetries = 2

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var refreshRequestedWhileRunning: Set<UUID> = []
    private(set) var states: [UUID: State] = [:]
    private(set) var revision = 0
    private(set) var latestCompletion: Completion?

    var hasActiveTasks: Bool {
        !tasks.isEmpty
    }

    init(
        analysisService: any ConversationAnalysisServicing,
        finalReportGenerator: any FinalReportGenerating,
        fileWriter: FinalReportFileWriter,
        loadProject: @escaping (UUID) throws -> Project?,
        persistProject: @escaping (Project, ProjectFieldOwnership) throws -> Void,
        knownTermsProvider: @escaping () -> [String],
        sleep: @escaping (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.analysisService = analysisService
        self.finalReportGenerator = finalReportGenerator
        self.fileWriter = fileWriter
        self.loadProject = loadProject
        self.persistProject = persistProject
        self.knownTermsProvider = knownTermsProvider
        self.sleep = sleep
    }

    func state(for projectID: UUID) -> State {
        states[projectID] ?? .idle
    }

    func start(
        projectID: UUID,
        refreshIfRunning: Bool = false
    ) {
        guard tasks[projectID] == nil else {
            if refreshIfRunning {
                refreshRequestedWhileRunning.insert(projectID)
            }
            return
        }
        latestCompletion = nil
        states[projectID] = .generating
        let task = Task { [weak self] in
            await self?.run(projectID: projectID)
            self?.tasks[projectID] = nil
            if self?.refreshRequestedWhileRunning.remove(projectID) != nil {
                self?.start(projectID: projectID)
            }
        }
        tasks[projectID] = task
    }

    private func run(projectID: UUID) async {
        guard let project = (try? loadProject(projectID)) ?? nil else {
            states[projectID] = .failed(message: "项目读取失败，无法生成完整总结")
            return
        }
        setJob(.running, in: project)
        persistQuietly(project, fields: .finalReport)

        let analysisController = ConversationAnalysisController(service: analysisService)
        analysisController.knownTermsProvider = knownTermsProvider
        analysisController.attach(to: project)
        await analysisController.generateFinalAnalysis()
        guard !Task.isCancelled else {
            setJob(.pending, in: project)
            persistQuietly(project, fields: .finalReport)
            states[projectID] = .idle
            return
        }
        let snapshot: ConversationAnalysisSnapshot
        if analysisController.lastFailureKind == nil,
           let generatedSnapshot = analysisController.currentSnapshot {
            do {
                try persistProject(project, .analysis)
            } catch {
                fail(
                    project: project,
                    projectID: projectID,
                    message: "全量分析保存失败，可重试"
                )
                return
            }
            snapshot = generatedSnapshot
        } else if let latestSnapshot = project.analysisSnapshots.max(by: {
            $0.version < $1.version
        }) {
            snapshot = latestSnapshot
            AppLog.logWarning(
                AppLog.analysis,
                LogSanitizer.formatEvent(
                    "final_report_using_existing_analysis_after_refresh_failure"
                )
            )
        } else {
            snapshot = ConversationAnalysisSnapshot(
                version: 0,
                analyzedThroughMs: project.segments.map(\.endMs).max() ?? 0,
                items: []
            )
            AppLog.logWarning(
                AppLog.analysis,
                LogSanitizer.formatEvent(
                    "final_report_using_full_transcript_without_analysis"
                )
            )
        }

        let previousReports = project.finalReportSnapshots
        let latestReport = previousReports.max {
            $0.version < $1.version
        }
        var fileSnapshot: FinalReportFileWriter.Snapshot?
        do {
            var report = try await generateWithTransientRetry(
                project: project,
                analysis: snapshot,
                version: (latestReport?.version ?? 0) + 1
            )
            let markdown = FinalReportMarkdownRenderer.makeMarkdown(
                report: report,
                project: project
            )
            fileSnapshot = try fileWriter.snapshot(projectID: projectID)
            report.markdownHash = try fileWriter.write(
                markdown: markdown,
                projectID: projectID,
                expectedExistingHash: latestReport?.markdownHash
            )
            project.finalReportSnapshots.append(report)
            project.finalReportSnapshots = FinalReportSnapshotRetention.keepingMostRecent(
                project.finalReportSnapshots
            )
            project.lastActivityAt = Date()
            setJob(.completed, in: project)
            try persistProject(project, .finalReport)
            states[projectID] = .completed(version: report.version)
            latestCompletion = Completion(
                projectID: projectID,
                version: report.version
            )
            revision += 1
        } catch {
            project.finalReportSnapshots = previousReports
            if let fileSnapshot {
                do {
                    try fileWriter.restore(fileSnapshot, projectID: projectID)
                } catch {
                    AppLog.logError(
                        AppLog.persistence,
                        LogSanitizer.formatEvent(
                            "final_report_file_rollback_failed",
                            error: String(describing: type(of: error))
                        )
                    )
                }
            }
            fail(
                project: project,
                projectID: projectID,
                message: Self.userMessage(error)
            )
        }
    }

    /// 生成 + 瞬时错误重试：超时/断网/限流/服务繁忙自动退避重试，
    /// 其他错误（凭证、结果不合规）立刻抛出交给统一失败路径。
    private func generateWithTransientRetry(
        project: Project,
        analysis: ConversationAnalysisSnapshot,
        version: Int
    ) async throws -> FinalReportSnapshot {
        var attempt = 0
        while true {
            do {
                return try await finalReportGenerator.generate(
                    project: project,
                    analysis: analysis,
                    knownTerms: knownTermsProvider(),
                    version: version
                )
            } catch let error as AnalysisAPIError
                where attempt < Self.maxTransientRetries
                    && Self.isTransient(error)
                    && !Task.isCancelled {
                attempt += 1
                AppLog.logWarning(AppLog.analysis, LogSanitizer.formatEvent(
                    "final_report_transient_retry",
                    error: "attempt=\(attempt) \(String(describing: error))"
                ))
                await sleep(.seconds(15 * attempt))
            }
        }
    }

    private static func isTransient(_ error: AnalysisAPIError) -> Bool {
        switch error {
        case .timeout, .network, .rateLimited, .serverError:
            return true
        case .unauthorized, .missingAPIKey, .credentialAccessRequired,
             .truncated, .invalidResponse, .clientError:
            return false
        }
    }

    private func fail(project: Project, projectID: UUID, message: String) {
        setJob(.failedRetryable, in: project)
        persistQuietly(project, fields: .finalReport)
        states[projectID] = .failed(message: message)
        revision += 1
    }

    private func setJob(_ status: ProcessingJobStatus, in project: Project) {
        if let index = project.processingJobs.firstIndex(where: { $0.kind == .finalReport }) {
            project.processingJobs[index].status = status
            project.processingJobs[index].progress = status == .completed ? 1 : nil
            if status == .failedRetryable || status == .failedFinal {
                project.processingJobs[index].retryCount += 1
                project.processingJobs[index].lastErrorCategory = "final_report_failed"
            } else {
                project.processingJobs[index].lastErrorCategory = nil
            }
            project.processingJobs[index].updatedAt = Date()
        } else {
            project.processingJobs.append(ProcessingJob(
                kind: .finalReport,
                status: status,
                retryCount: status == .failedRetryable || status == .failedFinal ? 1 : 0,
                lastErrorCategory: status == .failedRetryable || status == .failedFinal
                    ? "final_report_failed"
                    : nil
            ))
        }
    }

    private func persistQuietly(
        _ project: Project,
        fields: ProjectFieldOwnership
    ) {
        do {
            try persistProject(project, fields)
        } catch {
            AppLog.logError(
                AppLog.persistence,
                LogSanitizer.formatEvent(
                    "final_report_persist_failed",
                    error: String(describing: type(of: error))
                )
            )
        }
    }

    private static func userMessage(_ error: Error) -> String {
        if let apiError = error as? AnalysisAPIError {
            switch apiError {
            case .missingAPIKey: return "AI 模型未连接，请前往设置"
            case .credentialAccessRequired:
                return "App 更新后需要重新连接 AI，请前往设置"
            case .unauthorized:
                return "AI 凭证无效或模型未开通，请前往设置检查连接与模型"
            case .timeout: return "完整总结生成超时，可重试"
            default: return "完整总结暂时生成失败，可重试"
            }
        }
        return "完整总结暂时生成失败，可重试"
    }
}
