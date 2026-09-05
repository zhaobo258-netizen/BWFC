import Foundation
import Testing
@testable import BangWoFenXi

/// 导入流水线纯逻辑（阶段 C）：Job 编排、续跑起点、最终状态判定
@Suite("导入流水线规划")
struct ImportPlannerTests {

    // MARK: - Job 计划

    @Test("未配置分析 Key：只创建提取与转写 Job，不伪造分析 Job")
    func planWithoutAnalysis() {
        let jobs = ImportPlanner.planJobs(analysisConfigured: false)
        #expect(jobs.map(\.kind) == [.audioExtraction, .transcription])
        #expect(jobs.allSatisfy { $0.status == .pending })
    }

    @Test("已配置分析 Key：追加分析 Job")
    func planWithAnalysis() {
        let jobs = ImportPlanner.planJobs(analysisConfigured: true)
        #expect(jobs.map(\.kind) == [.audioExtraction, .transcription, .analysis])
    }

    @Test("分析模型可用且启用完整总结：完整总结排在分析之后")
    func planWithFinalReport() {
        let jobs = ImportPlanner.planJobs(
            analysisConfigured: true,
            finalReportConfigured: true
        )
        #expect(
            jobs.map(\.kind)
                == [.audioExtraction, .transcription, .analysis, .finalReport]
        )
    }

    @Test("导入分人位于转写之后，晚补分人会重建受影响分析")
    func diarizationRunsBeforeAnalysis() {
        let jobs = ImportPlanner.planJobs(
            analysisConfigured: true, finalReportConfigured: true, diarizationConfigured: true
        )
        #expect(jobs.map(\.kind) == [.audioExtraction, .transcription, .diarization, .analysis, .finalReport])
        var previous = ImportPlanner.planJobs(analysisConfigured: true, finalReportConfigured: true)
        for index in previous.indices { previous[index].status = .completed }
        let resumed = ImportPlanner.jobsForResume(
            previous, analysisConfigured: true, finalReportConfigured: true, diarizationConfigured: true
        )
        #expect(resumed.first { $0.kind == .transcription }?.status == .completed)
        #expect(resumed.first { $0.kind == .diarization }?.status == .pending)
        #expect(resumed.first { $0.kind == .analysis }?.status == .pending)
        #expect(resumed.first { $0.kind == .finalReport }?.status == .pending)
    }

    // MARK: - 续跑

    @Test("续跑：running（崩溃遗留）与 failedRetryable 回 pending，completed 不动")
    func resumeResetsInterruptedJobs() {
        let existing = [
            ProcessingJob(kind: .audioExtraction, status: .completed),
            ProcessingJob(kind: .transcription, status: .running, progress: 0.4),
            ProcessingJob(kind: .analysis, status: .failedRetryable)
        ]
        let jobs = ImportPlanner.jobsForResume(existing, analysisConfigured: true)
        #expect(jobs.first { $0.kind == .audioExtraction }?.status == .completed)
        #expect(jobs.first { $0.kind == .transcription }?.status == .pending)
        #expect(jobs.first { $0.kind == .transcription }?.progress == nil)
        #expect(jobs.first { $0.kind == .analysis }?.status == .pending)
    }

    @Test("续跑：分析 Key 中途配置好则补建分析 Job；已存在不重复")
    func resumeAddsAnalysisJobWhenConfigured() {
        let existing = [
            ProcessingJob(kind: .audioExtraction, status: .completed),
            ProcessingJob(kind: .transcription, status: .completed)
        ]
        let jobs = ImportPlanner.jobsForResume(existing, analysisConfigured: true)
        #expect(jobs.filter { $0.kind == .analysis }.count == 1)
        let again = ImportPlanner.jobsForResume(jobs, analysisConfigured: true)
        #expect(again.filter { $0.kind == .analysis }.count == 1)
    }

    @Test("续跑补建完整总结且不重复")
    func resumeAddsFinalReportOnce() {
        let existing = [
            ProcessingJob(kind: .audioExtraction, status: .completed),
            ProcessingJob(kind: .transcription, status: .completed),
            ProcessingJob(kind: .analysis, status: .completed)
        ]
        let jobs = ImportPlanner.jobsForResume(
            existing,
            analysisConfigured: true,
            finalReportConfigured: true
        )
        #expect(jobs.filter { $0.kind == .finalReport }.count == 1)
        let again = ImportPlanner.jobsForResume(
            jobs,
            analysisConfigured: true,
            finalReportConfigured: true
        )
        #expect(again.filter { $0.kind == .finalReport }.count == 1)
    }

    @Test("续跑：failedFinal 保持不动，不复活")
    func resumeKeepsFinalFailure() {
        let existing = [ProcessingJob(kind: .audioExtraction, status: .failedFinal)]
        let jobs = ImportPlanner.jobsForResume(existing, analysisConfigured: false)
        #expect(jobs.first?.status == .failedFinal)
    }

    // MARK: - 执行顺序

    @Test("下一个待执行：按规范顺序取第一个 pending")
    func nextPendingFollowsCanonicalOrder() {
        let jobs = [
            ProcessingJob(kind: .analysis, status: .pending),
            ProcessingJob(kind: .audioExtraction, status: .completed),
            ProcessingJob(kind: .transcription, status: .pending)
        ]
        #expect(ImportPlanner.nextPendingJob(jobs)?.kind == .transcription)
    }

    @Test("前序 failedFinal 阻断流水线：不跳过继续后面的阶段")
    func finalFailureBlocksPipeline() {
        let jobs = [
            ProcessingJob(kind: .audioExtraction, status: .failedFinal),
            ProcessingJob(kind: .transcription, status: .pending)
        ]
        #expect(ImportPlanner.nextPendingJob(jobs) == nil)
    }

    @Test("全部完成或失败可重试：没有待执行 Job")
    func noPendingWhenDoneOrRetryable() {
        #expect(ImportPlanner.nextPendingJob([
            ProcessingJob(kind: .audioExtraction, status: .completed),
            ProcessingJob(kind: .transcription, status: .failedRetryable)
        ]) == nil)
    }

    // MARK: - 最终状态

    @Test("必需阶段全完成、无可选阶段 → ready")
    func statusReadyWhenRequiredDone() {
        let jobs = [
            ProcessingJob(kind: .audioExtraction, status: .completed),
            ProcessingJob(kind: .transcription, status: .completed)
        ]
        #expect(ImportPlanner.projectStatus(after: jobs) == .ready)
    }

    @Test("可选分析失败 → readyWithWarnings（部分完成，文稿仍可用）")
    func statusWarningsWhenOptionalFailed() {
        let jobs = [
            ProcessingJob(kind: .audioExtraction, status: .completed),
            ProcessingJob(kind: .transcription, status: .completed),
            ProcessingJob(kind: .analysis, status: .failedRetryable)
        ]
        #expect(ImportPlanner.projectStatus(after: jobs) == .readyWithWarnings)
    }

    @Test("必需阶段 failedFinal → failed")
    func statusFailedWhenRequiredFinalFailure() {
        let jobs = [
            ProcessingJob(kind: .audioExtraction, status: .failedFinal),
            ProcessingJob(kind: .transcription, status: .pending)
        ]
        #expect(ImportPlanner.projectStatus(after: jobs) == .failed)
    }

    @Test("必需阶段可重试失败 → 保持 processing（可续跑）")
    func statusProcessingWhenRequiredRetryable() {
        let jobs = [
            ProcessingJob(kind: .audioExtraction, status: .completed),
            ProcessingJob(kind: .transcription, status: .failedRetryable)
        ]
        #expect(ImportPlanner.projectStatus(after: jobs) == .processing)
    }

    // MARK: - 辅助判定

    @Test("来源类型：有视频轨为导入视频，否则导入音频")
    func sourceTypeFromVideoTrack() {
        #expect(ImportPlanner.sourceType(hasVideoTrack: true) == .importedVideo)
        #expect(ImportPlanner.sourceType(hasVideoTrack: false) == .importedAudio)
    }

    @Test("默认标题：文件名去扩展名；空名兜底")
    func defaultTitleFromFileName() {
        #expect(ImportPlanner.defaultTitle(forFileName: "客户拜访 0722.m4a") == "客户拜访 0722")
        #expect(ImportPlanner.defaultTitle(forFileName: ".m4a") == "导入的音视频")
        #expect(ImportPlanner.defaultTitle(forFileName: "  ") == "导入的音视频")
    }
}
