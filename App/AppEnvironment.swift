import Foundation

/// 全局运行环境：集中持有持久化存储、密钥存储与各服务依赖。
/// 音频、转写、分人、分析、导出均以协议注入（实施计划第 8 节：
/// 让 UI 通过明确的服务协议依赖各模块，便于测试替换）。
@MainActor
@Observable
final class AppEnvironment {
    /// 会议持久化存储（当前为 JSON 实现；Xcode 可用后替换为 SwiftData 实现）
    let meetingStore: any MeetingStoring
    /// V2 项目持久化存储（产品文档 03 号 §9.1；本阶段仅注入，UI 暂不切换）
    let projectStore: any ProjectStoring
    /// 会议文件存储（录音文件布局与相对路径）
    let fileStore: MeetingFileStore

    /// 音频采集（阶段 1：AVAudioEngine 实现）
    let audioCapture: any AudioCaptureServicing
    /// 本地转写（阶段 2 实现）
    let localTranscription: any LocalTranscriptionServicing
    /// 云端说话人识别（阶段 3 实现）
    let diarization: any DiarizationServicing
    /// 云端谈判分析（阶段 4 实现）
    let negotiationAnalysis: any NegotiationAnalysisServicing
    /// 导出（阶段 5 实现：生成 Markdown/JSON 内容，保存位置由用户选择）
    let exporter: any MeetingExportServicing

    /// 各 provider 的 Keychain 存储（Key 分家，互不外借）
    private let keyStores: [CloudProvider: CloudAPIKeyStore]
    /// 分析（Kimi）Key 是否已配置
    private(set) var isAnalysisConfigured: Bool
    /// 分人（OpenAI 兼容）Key 是否已配置
    private(set) var isDiarizationConfigured: Bool

    /// 兼容旧调用：任一云端能力已配置
    var isCloudConfigured: Bool {
        isAnalysisConfigured || isDiarizationConfigured
    }

    /// 持久化是否不可用（初始化失败时降级为内存库并提示）
    let isPersistentStorageUnavailable: Bool

    init(
        meetingStore: any MeetingStoring,
        fileStore: MeetingFileStore,
        projectStore: (any ProjectStoring)? = nil,
        audioCapture: any AudioCaptureServicing = AVAudioCaptureService(),
        localTranscription: any LocalTranscriptionServicing = AppleSpeechTranscriptionService(),
        diarization: any DiarizationServicing = OpenAIDiarizationService(),
        negotiationAnalysis: any NegotiationAnalysisServicing = KimiAnalysisService(),
        exporter: (any MeetingExportServicing)? = nil,
        keychainServiceName: String = CloudAPIKeyStore.defaultService,
        isPersistentStorageUnavailable: Bool = false
    ) {
        self.meetingStore = meetingStore
        self.fileStore = fileStore
        self.projectStore = projectStore ?? InMemoryProjectStore()
        self.audioCapture = audioCapture
        self.localTranscription = localTranscription
        self.diarization = diarization
        self.negotiationAnalysis = negotiationAnalysis
        self.exporter = exporter ?? LocalMeetingExportService(meetingStore: meetingStore)
        self.isPersistentStorageUnavailable = isPersistentStorageUnavailable

        var stores: [CloudProvider: CloudAPIKeyStore] = [:]
        for provider in CloudProvider.allCases {
            stores[provider] = CloudAPIKeyStore.store(for: provider, service: keychainServiceName)
        }
        self.keyStores = stores
        self.isAnalysisConfigured = stores[.analysis]?.hasConfiguredKey ?? false
        self.isDiarizationConfigured = stores[.diarization]?.hasConfiguredKey ?? false
    }

    /// 指定 provider 的 Keychain 存储（视图层读写 Key 的唯一入口）
    func keyStore(for provider: CloudProvider) -> CloudAPIKeyStore {
        guard let store = keyStores[provider] else {
            return CloudAPIKeyStore.store(for: provider)
        }
        return store
    }

    /// 指定 provider 是否已配置 Key
    func isConfigured(_ provider: CloudProvider) -> Bool {
        keyStore(for: provider).hasConfiguredKey
    }

    /// API Key 变更后刷新各 provider 配置状态
    func refreshCloudConfiguration() {
        isAnalysisConfigured = isConfigured(.analysis)
        isDiarizationConfigured = isConfigured(.diarization)
    }

    // MARK: - 会议持久化便捷入口（集中 store 读写，避免散落各视图）

    /// 读取全部会议
    func allMeetings() throws -> [Meeting] {
        try meetingStore.loadMeetings()
    }

    /// 保存单次会议（按 id 覆盖；不存在则追加）
    func persist(_ meeting: Meeting) throws {
        var meetings = try meetingStore.loadMeetings()
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
        }
        try meetingStore.saveMeetings(meetings)
    }

    /// 删除整场会议（实施计划 12.1）：
    /// 同步删除数据库记录与会议专属目录（本地完整录音、声音样本、
    /// 临时分片与队列状态）。导出文件由用户自行选择保存位置，不在应用目录内，
    /// 不产生需要清理的导出缓存。
    func deleteMeeting(_ meeting: Meeting) throws {
        var meetings = try meetingStore.loadMeetings()
        meetings.removeAll { $0.id == meeting.id }
        try meetingStore.saveMeetings(meetings)
        try fileStore.deleteMeetingFiles(for: meeting.id)
    }

    // MARK: - V2 项目持久化便捷入口（镜像会议的按 id 覆盖语义）

    /// 读取全部项目
    func allProjects() throws -> [Project] {
        try projectStore.loadProjects()
    }

    /// 保存单个项目（按 id 覆盖；不存在则追加）
    func persist(_ project: Project) throws {
        var projects = try projectStore.loadProjects()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        try projectStore.saveProjects(projects)
    }

    /// 生产环境：默认 JSON 持久化 + 文件存储
    static func live() -> AppEnvironment {
        // 旧版统一 Keychain 条目迁移（account=openai → 分析 kimi 条目）
        CloudAPIKeyStore.migrateLegacyKeyIfNeeded()
        do {
            let store = try JSONMeetingStore.makeDefault()
            let projectStore = try JSONProjectStore.makeDefault()
            let fileStore = try MeetingFileStore.makeDefault()
            // V1 → V2 一次性迁移：失败只脱敏记录，绝不抛出、绝不影响启动与旧数据
            if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let directory = base.appending(path: "BangWoFenXi", directoryHint: .isDirectory)
                do {
                    _ = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded()
                } catch {
                    AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent("project_migration_failed", error: String(describing: type(of: error))))
                }
            }
            return AppEnvironment(meetingStore: store, fileStore: fileStore, projectStore: projectStore)
        } catch {
            // 持久化初始化失败：降级为内存库，保证界面可用；
            // 仅记录脱敏错误，不含路径与正文
            AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent("storage_init_failed", error: String(describing: type(of: error))))
            return AppEnvironment(
                meetingStore: InMemoryMeetingStore(),
                fileStore: MeetingFileStore(baseDirectory: FileManager.default.temporaryDirectory),
                projectStore: InMemoryProjectStore(),
                isPersistentStorageUnavailable: true
            )
        }
    }
}
