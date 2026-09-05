import Foundation

/// 导入流水线的纯逻辑规划（阶段 C，可单测）：
/// Job 编排、续跑起点、最终项目状态判定。
/// 纪律：Job 只在真实会执行时创建——分析未配置 Key 时不创建分析 Job，
/// 不伪造「等待中」状态（分人 Provider 同理，阶段 C 不创建分人 Job）。
enum ImportPlanner {

    /// 阶段 C 流水线的规范执行顺序
    static let canonicalOrder: [ProcessingJobKind] = [
        .audioExtraction, .transcription, .diarization, .analysis, .finalReport,
        .knowledgeExpansion, .obsidianArchive
    ]

    /// 新导入项目的 Job 计划
    static func planJobs(
        analysisConfigured: Bool,
        finalReportConfigured: Bool = false,
        diarizationConfigured: Bool = false,
        now: Date = Date()
    ) -> [ProcessingJob] {
        var jobs: [ProcessingJob] = [
            ProcessingJob(kind: .audioExtraction, updatedAt: now),
            ProcessingJob(kind: .transcription, updatedAt: now)
        ]
        if diarizationConfigured {
            jobs.append(ProcessingJob(kind: .diarization, updatedAt: now))
        }
        if analysisConfigured {
            jobs.append(ProcessingJob(kind: .analysis, updatedAt: now))
            if finalReportConfigured {
                jobs.append(ProcessingJob(kind: .finalReport, updatedAt: now))
            }
        }
        return jobs
    }

    /// 续跑准备：崩溃遗留的 running 回退为 pending（真实状态未知，从该阶段重跑）；
    /// failedRetryable 回退为 pending（用户或启动触发的重试）；
    /// completed / failedFinal 保持不动；
    /// 若分析 Key 在中途配置好且尚无分析 Job，补建（转写已完成的项目也能补分析）。
    static func jobsForResume(_ existing: [ProcessingJob],
                              analysisConfigured: Bool,
                              finalReportConfigured: Bool = false,
                              diarizationConfigured: Bool = false,
                              now: Date = Date()) -> [ProcessingJob] {
        var jobs = existing.map { job -> ProcessingJob in
            var job = job
            if job.status == .running || job.status == .failedRetryable {
                job.status = .pending
                job.progress = nil
                job.updatedAt = now
            }
            return job
        }
        if diarizationConfigured, !jobs.contains(where: { $0.kind == .diarization }) {
            jobs.append(ProcessingJob(kind: .diarization, updatedAt: now))
            for index in jobs.indices where jobs[index].kind == .analysis
                || jobs[index].kind == .finalReport {
                jobs[index].status = .pending
                jobs[index].progress = nil
            }
        }
        if analysisConfigured, !jobs.contains(where: { $0.kind == .analysis }) {
            jobs.append(ProcessingJob(kind: .analysis, updatedAt: now))
        }
        if analysisConfigured,
           finalReportConfigured,
           !jobs.contains(where: { $0.kind == .finalReport }) {
            jobs.append(ProcessingJob(kind: .finalReport, updatedAt: now))
        }
        return sortedCanonically(jobs)
    }

    /// 按规范顺序排序
    static func sortedCanonically(_ jobs: [ProcessingJob]) -> [ProcessingJob] {
        jobs.sorted {
            (canonicalOrder.firstIndex(of: $0.kind) ?? .max) < (canonicalOrder.firstIndex(of: $1.kind) ?? .max)
        }
    }

    /// 下一个待执行 Job（按规范顺序的第一个 pending）。
    /// 任何失败（含可重试）都阻断后续阶段：转写依赖提取产物、分析依赖转写，
    /// 跳过失败阶段继续执行只会制造次生失败；重试时失败 Job 先回 pending 再续跑。
    static func nextPendingJob(_ jobs: [ProcessingJob]) -> ProcessingJob? {
        for job in sortedCanonically(jobs) {
            switch job.status {
            case .failedFinal, .failedRetryable:
                return nil
            case .pending:
                return job
            case .running, .completed:
                continue
            }
        }
        return nil
    }

    /// 流水线结束后的项目状态。
    /// 必需阶段：提取 + 转写。可选阶段：分人 / 分析 / 知识关联（03 §6.2：失败仍可部分完成）。
    /// - 必需阶段有 failedFinal → .failed
    /// - 必需阶段未全部完成（含 failedRetryable/pending）→ .processing（可重试续跑）
    /// - 必需完成、可选全部完成或不存在 → .ready
    /// - 必需完成、可选存在失败 → .readyWithWarnings
    static func projectStatus(after jobs: [ProcessingJob]) -> ProjectStatus {
        let required: Set<ProcessingJobKind> = [.audioExtraction, .transcription]
        let requiredJobs = jobs.filter { required.contains($0.kind) }
        let optionalJobs = jobs.filter { !required.contains($0.kind) }

        if requiredJobs.contains(where: { $0.status == .failedFinal }) {
            return .failed
        }
        guard requiredJobs.count == required.count,
              requiredJobs.allSatisfy({ $0.status == .completed }) else {
            return .processing
        }
        if optionalJobs.allSatisfy({ $0.status == .completed }) {
            return .ready
        }
        return .readyWithWarnings
    }

    /// 来源类型判定（inspect 结果为准，不按扩展名猜测）
    static func sourceType(hasVideoTrack: Bool) -> ProjectSourceType {
        hasVideoTrack ? .importedVideo : .importedAudio
    }

    /// 导入项目的默认标题：原文件名去扩展名；空名与隐藏文件名（如 ".m4a"）兜底
    static func defaultTitle(forFileName fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespaces)
        let base: String
        if let dotIndex = trimmed.lastIndex(of: "."), dotIndex != trimmed.startIndex {
            base = String(trimmed[..<dotIndex])
        } else if trimmed.hasPrefix(".") {
            base = ""
        } else {
            base = trimmed
        }
        let cleaned = base.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "导入的音视频" : cleaned
    }
}
