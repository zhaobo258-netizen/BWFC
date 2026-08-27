import Foundation

/// 分片队列条目（持久化到 chunks/queue.json；App 重启后队列可恢复，实施计划 7.4）
struct ChunkQueueEntry: Codable, Equatable, Sendable {
    /// 分片序号
    var index: Int
    /// 音频流起止毫秒（用于从完整录音中提取分片）
    var audioStartMs: Int64
    var audioEndMs: Int64
    /// 会议时间轴起止毫秒（入队时换算并固化，避免时间线后续变化影响）
    var wallStartMs: Int64
    var wallEndMs: Int64
    /// 分片文件名（分片目录内）
    var fileName: String
    /// 会议开始时冻结的云端 provider；旧队列按 OpenAI 兼容迁移。
    var provider: DiarizationProvider
    /// 非敏感配置指纹，用于阻止恢复时静默改投其他配置。
    var providerConfigurationFingerprint: String
    /// 处理状态
    var status: Status
    /// 已失败次数（退避与上限判断依据）
    var attemptCount: Int

    enum Status: String, Codable, Sendable {
        case pending           // 待上传
        case uploading         // 上传中
        case succeeded         // 已确认并入片段
        case failed            // 失败，等待退避重试
        case awaitingUserRetry // 超过重试上限，待用户手动重试
    }

    init(
        index: Int,
        audioStartMs: Int64,
        audioEndMs: Int64,
        wallStartMs: Int64,
        wallEndMs: Int64,
        fileName: String,
        provider: DiarizationProvider = .openAICompatible,
        providerConfigurationFingerprint: String = "",
        status: Status,
        attemptCount: Int
    ) {
        self.index = index
        self.audioStartMs = audioStartMs
        self.audioEndMs = audioEndMs
        self.wallStartMs = wallStartMs
        self.wallEndMs = wallEndMs
        self.fileName = fileName
        self.provider = provider
        self.providerConfigurationFingerprint = providerConfigurationFingerprint
        self.status = status
        self.attemptCount = attemptCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        audioStartMs = try container.decode(Int64.self, forKey: .audioStartMs)
        audioEndMs = try container.decode(Int64.self, forKey: .audioEndMs)
        wallStartMs = try container.decode(Int64.self, forKey: .wallStartMs)
        wallEndMs = try container.decode(Int64.self, forKey: .wallEndMs)
        fileName = try container.decode(String.self, forKey: .fileName)
        provider = try container.decodeIfPresent(
            DiarizationProvider.self,
            forKey: .provider
        ) ?? .openAICompatible
        providerConfigurationFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .providerConfigurationFingerprint
        ) ?? ""
        status = try container.decode(Status.self, forKey: .status)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
    }

    /// 是否还需要处理（恢复队列时的过滤条件）
    var needsProcessing: Bool {
        switch status {
        case .pending, .uploading, .failed:
            return true
        case .succeeded, .awaitingUserRetry:
            return false
        }
    }
}

/// 分片队列存储：JSON 原子写入会议分片目录（重启恢复依据）
struct ChunkQueueStore: Sendable {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 读取队列；文件不存在返回空数组
    func load() throws -> [ChunkQueueEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode([ChunkQueueEntry].self, from: data)
    }

    /// 原子保存队列
    func save(_ entries: [ChunkQueueEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
