import Foundation

/// 全局运行环境：集中持有持久化存储、密钥存储与各服务依赖。
/// 音频、转写、分人、分析、导出均以协议注入（实施计划第 8 节：
/// 让 UI 通过明确的服务协议依赖各模块，便于测试替换）。
@MainActor
@Observable
final class AppEnvironment {
    /// 会议持久化存储（当前为 JSON 实现；Xcode 可用后替换为 SwiftData 实现）
    let meetingStore: any MeetingStoring
    /// 会议文件存储（录音文件布局与相对路径）
    let fileStore: MeetingFileStore
    /// 云端 API Key 存储（Keychain）
    let apiKeyStore: CloudAPIKeyStore

    /// 音频采集（阶段 1：AVAudioEngine 实现）
    let audioCapture: any AudioCaptureServicing
    /// 本地转写（阶段 2 实现）
    let localTranscription: any LocalTranscriptionServicing
    /// 云端说话人识别（阶段 3 实现）
    let diarization: any DiarizationServicing
    /// 云端谈判分析（阶段 4 实现）
    let negotiationAnalysis: any NegotiationAnalysisServicing
    /// 导出（阶段 5 实现）
    let exporter: any MeetingExportServicing

    /// 云端功能是否已配置（API Key 存在）
    private(set) var isCloudConfigured: Bool

    /// 持久化是否不可用（初始化失败时降级为内存库并提示）
    let isPersistentStorageUnavailable: Bool

    init(
        meetingStore: any MeetingStoring,
        fileStore: MeetingFileStore,
        apiKeyStore: CloudAPIKeyStore = CloudAPIKeyStore(),
        audioCapture: any AudioCaptureServicing = AVAudioCaptureService(),
        localTranscription: any LocalTranscriptionServicing = UnimplementedLocalTranscriptionService(),
        diarization: any DiarizationServicing = UnimplementedDiarizationService(),
        negotiationAnalysis: any NegotiationAnalysisServicing = UnimplementedNegotiationAnalysisService(),
        exporter: any MeetingExportServicing = UnimplementedMeetingExportService(),
        isPersistentStorageUnavailable: Bool = false
    ) {
        self.meetingStore = meetingStore
        self.fileStore = fileStore
        self.apiKeyStore = apiKeyStore
        self.audioCapture = audioCapture
        self.localTranscription = localTranscription
        self.diarization = diarization
        self.negotiationAnalysis = negotiationAnalysis
        self.exporter = exporter
        self.isPersistentStorageUnavailable = isPersistentStorageUnavailable
        self.isCloudConfigured = apiKeyStore.hasConfiguredKey
    }

    /// API Key 变更后刷新云端配置状态
    func refreshCloudConfiguration() {
        isCloudConfigured = apiKeyStore.hasConfiguredKey
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

    /// 生产环境：默认 JSON 持久化 + 文件存储
    static func live() -> AppEnvironment {
        do {
            let store = try JSONMeetingStore.makeDefault()
            let fileStore = try MeetingFileStore.makeDefault()
            return AppEnvironment(meetingStore: store, fileStore: fileStore)
        } catch {
            // 持久化初始化失败：降级为内存库，保证界面可用；
            // 仅记录脱敏错误，不含路径与正文
            AppLog.persistence.error("\(LogSanitizer.formatEvent("storage_init_failed", error: String(describing: type(of: error))))")
            return AppEnvironment(
                meetingStore: InMemoryMeetingStore(),
                fileStore: MeetingFileStore(baseDirectory: FileManager.default.temporaryDirectory),
                isPersistentStorageUnavailable: true
            )
        }
    }
}
