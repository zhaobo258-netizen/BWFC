import Foundation

/// 处理任务种类（产品文档 03 号 §8.6）
enum ProcessingJobKind: String, Codable, Sendable, CaseIterable {
    case audioExtraction    // 音视频提取
    case transcription      // 转写
    case diarization        // 分人
    case analysis           // 分析
    case knowledgeExpansion // 知识扩展
    case obsidianArchive    // Obsidian 归档
}

/// 处理任务状态（产品文档 03 号 §8.6）
enum ProcessingJobStatus: String, Codable, Sendable, CaseIterable {
    case pending        // 排队中
    case running        // 执行中
    case completed      // 已完成
    case failedRetryable // 失败，可重试
    case failedFinal    // 失败，不可重试
}

/// 处理任务（产品文档 03 号 §8.6）：记录项目后台处理流水，
/// 支持进度、重试计数与错误分类，供阶段 B 处理队列使用。
struct ProcessingJob: Identifiable, Codable, Sendable, Hashable {
    /// 主键
    var id: UUID
    /// 任务种类
    var kind: ProcessingJobKind
    /// 任务状态
    var status: ProcessingJobStatus
    /// 进度（0–1；无进度可报告时为 nil）
    var progress: Double?
    /// 已重试次数
    var retryCount: Int
    /// 最近一次失败的错误分类（脱敏后的类别名）
    var lastErrorCategory: String?
    /// 最近更新时间
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: ProcessingJobKind,
        status: ProcessingJobStatus = .pending,
        progress: Double? = nil,
        retryCount: Int = 0,
        lastErrorCategory: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.progress = progress
        self.retryCount = retryCount
        self.lastErrorCategory = lastErrorCategory
        self.updatedAt = updatedAt
    }
}
