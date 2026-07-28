import Foundation

enum ProjectFieldOwnership: Sendable, Equatable {
    case all
    case note
    case title
    case userScenario
    case speakers
    case manualSegments
    case analysis
    case finalReport
    case knowledgeGarden
    case importPipeline
}

enum ProjectFieldOwner: String, Sendable {
    case identity
    case workspace
    case runtime
    case shared
}

enum ProjectPersistence {
    static let fieldOwnership: [String: ProjectFieldOwner] = [
        "schemaVersion": .identity,
        "id": .identity,
        "title": .workspace,
        "sourceType": .identity,
        "scenario": .shared,
        "scenarioWasUserSelected": .shared,
        "status": .runtime,
        "createdAt": .identity,
        "startedAt": .runtime,
        "endedAt": .runtime,
        "lastActivityAt": .shared,
        "runtimeAssetRelativePath": .runtime,
        "originalFileName": .identity,
        "durationMs": .runtime,
        "preferredInputDeviceID": .runtime,
        "pauseIntervals": .runtime,
        "speakers": .workspace,
        "segments": .shared,
        "legacySnapshots": .runtime,
        "analysisSnapshots": .runtime,
        "finalReportSnapshots": .runtime,
        "knowledgeSeeds": .workspace,
        "legacyMetadata": .runtime,
        "note": .workspace,
        "processingJobs": .runtime,
        "archive": .runtime
    ]

    static func upsert(
        _ incoming: Project,
        into projects: inout [Project],
        fields: ProjectFieldOwnership
    ) {
        guard let index = projects.firstIndex(where: { $0.id == incoming.id }) else {
            projects.append(incoming)
            return
        }
        guard fields != .all else {
            projects[index] = incoming
            return
        }

        let stored = projects[index]
        switch fields {
        case .all:
            break
        case .note:
            stored.note = incoming.note
        case .title:
            stored.title = incoming.title
            stored.lastActivityAt = incoming.lastActivityAt
        case .userScenario:
            stored.scenario = incoming.scenario
            stored.scenarioWasUserSelected = incoming.scenarioWasUserSelected
        case .speakers:
            stored.speakers = incoming.speakers
        case .manualSegments:
            mergeManualSegments(incoming.segments, into: stored)
            stored.lastActivityAt = incoming.lastActivityAt
        case .analysis:
            stored.analysisSnapshots = incoming.analysisSnapshots
            if !stored.scenarioWasUserSelected {
                stored.scenario = incoming.scenario
                stored.scenarioWasUserSelected = incoming.scenarioWasUserSelected
            }
        case .finalReport:
            stored.finalReportSnapshots = incoming.finalReportSnapshots
            stored.processingJobs = incoming.processingJobs
            stored.lastActivityAt = incoming.lastActivityAt
        case .knowledgeGarden:
            stored.knowledgeSeeds = incoming.knowledgeSeeds
        case .importPipeline:
            stored.status = incoming.status
            stored.processingJobs = incoming.processingJobs
            mergePipelineSegments(incoming.segments, into: stored)
            stored.legacySnapshots = incoming.legacySnapshots
            stored.analysisSnapshots = incoming.analysisSnapshots
            stored.finalReportSnapshots = incoming.finalReportSnapshots
            if !stored.scenarioWasUserSelected {
                stored.scenario = incoming.scenario
            }
            stored.runtimeAssetRelativePath = incoming.runtimeAssetRelativePath
            stored.startedAt = incoming.startedAt
            stored.endedAt = incoming.endedAt
            stored.durationMs = incoming.durationMs
            stored.lastActivityAt = incoming.lastActivityAt
        }
    }

    private static func mergeManualSegments(
        _ incoming: [TranscriptSegment],
        into stored: Project
    ) {
        let storedByID = Dictionary(
            stored.segments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let manualChanges = Dictionary(
            uniqueKeysWithValues: incoming.compactMap { segment -> (UUID, TranscriptSegment)? in
                guard let existing = storedByID[segment.id],
                      segment.state == .edited || segment.isStarred != existing.isStarred else {
                    return nil
                }
                return (segment.id, segment)
            }
        )
        stored.segments = stored.segments.map { manualChanges[$0.id] ?? $0 }
    }

    private static func mergePipelineSegments(
        _ incoming: [TranscriptSegment],
        into stored: Project
    ) {
        let storedByID = Dictionary(
            stored.segments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let incomingIDs = Set(incoming.map(\.id))
        var merged = incoming.map { segment in
            guard let existing = storedByID[segment.id],
                  existing.state == .edited || existing.isStarred != segment.isStarred else {
                return segment
            }
            return existing
        }
        merged.append(contentsOf: stored.segments.filter {
            !incomingIDs.contains($0.id) && ($0.state == .edited || $0.isStarred)
        })
        stored.segments = merged.sorted {
            $0.startMs == $1.startMs ? $0.endMs < $1.endMs : $0.startMs < $1.startMs
        }
    }
}

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
    /// 已授权的 Obsidian Vault；为 nil 时使用 App Sandbox 内的安全回退目录。
    let obsidianVaultURL: URL?
    /// Vault 失权等情况下向设置页展示的可恢复提示。
    let storageWarning: String?
    /// 持有安全作用域访问直至环境释放，避免运行中 Vault 权限提前失效。
    private let securityScopedStorageAccess: SecurityScopedStorageAccess?

    /// 音频采集（阶段 1：AVAudioEngine 实现）
    let audioCapture: any AudioCaptureServicing
    /// 本地转写（阶段 2 实现）
    let localTranscription: any LocalTranscriptionServicing
    /// 云端说话人识别（阶段 3 实现）
    let diarization: any DiarizationServicing
    /// 云端谈判分析（阶段 4 实现；V1 遗留，旧会议页面使用）
    let negotiationAnalysis: any NegotiationAnalysisServicing
    /// V2 通用对话分析（阶段 D，语义分析师；工作台与导入流水线使用）
    let conversationAnalysis: any ConversationAnalysisServicing
    /// “开花”中的概念解释、跨领域连接与检索词生成
    let knowledgeExpansion: any KnowledgeExpansionServicing
    /// 完整总结生成器（证据账本 → 独立报告）
    let finalReportGenerator: any FinalReportGenerating
    /// 导出（阶段 5 实现：生成 Markdown/JSON 内容，保存位置由用户选择）
    let exporter: any MeetingExportServicing
    /// 音视频导入（阶段 C 实现：检查 + 音轨提取）
    let audioImport: any AudioImportServicing
    /// 导入用转写服务工厂：每次导入独立实例，不与实时录音会话争抢
    let makeImportTranscriptionService: () -> any LocalTranscriptionServicing

    /// 导入处理控制器（App 级单例：离开工作台后后台继续；首版一次一个导入）
    private var _importProcessing: ImportProcessingController?
    var importProcessing: ImportProcessingController {
        if let existing = _importProcessing { return existing }
        let controller = ImportProcessingController(
            importService: audioImport,
            makeTranscriptionService: makeImportTranscriptionService,
            analysisService: conversationAnalysis,
            finalReportGenerator: finalReportGenerator,
            fileStore: fileStore,
            isAnalysisConfigured: { [weak self] in self?.isAnalysisConfigured ?? false },
            loadProject: { [weak self] id in
                try self?.allProjects().first(where: { $0.id == id })
            },
            persistProject: { [weak self] project, fields in
                try self?.persist(project, fields: fields)
            }
        )
        controller.lexiconProvider = { [weak self] in self?.lexiconTerms ?? [] }
        controller.correctionRulesProvider = { [weak self] in self?.correctionRules ?? [] }
        _importProcessing = controller
        return controller
    }

    private var _finalReportCoordinator: FinalReportCoordinator?
    var finalReportCoordinator: FinalReportCoordinator {
        if let existing = _finalReportCoordinator { return existing }
        let coordinator = FinalReportCoordinator(
            analysisService: conversationAnalysis,
            finalReportGenerator: finalReportGenerator,
            fileWriter: FinalReportFileWriter(fileStore: fileStore),
            loadProject: { [weak self] id in
                try self?.allProjects().first(where: { $0.id == id })
            },
            persistProject: { [weak self] project, fields in
                try self?.persist(project, fields: fields)
            },
            knownTermsProvider: { [weak self] in self?.lexiconTerms ?? [] }
        )
        _finalReportCoordinator = coordinator
        return coordinator
    }

    /// 全局专业词库与纠错规则（App 级；转写上下文 + 分析已知名词 + 自动纠错）
    let lexiconStore: LexiconStore
    private(set) var lexiconTerms: [String] = []
    private(set) var correctionRules: [CorrectionRule] = []
    private(set) var lexiconRevision = 0

    /// 各 provider 的 Keychain 存储（Key 分家，互不外借）
    private let keyStores: [CloudProvider: CloudAPIKeyStore]
    private let keychainServiceName: String
    /// Kimi 账号 OAuth 凭证存储（设备码登录；与静态分析 Key 独立条目）
    let kimiOAuthTokenStore: KimiOAuthTokenStore
    let aiProviderConfigurationStore: AIProviderConfigurationStore
    let openAICompatibleKeyStore: CloudAPIKeyStore
    let aiProviderRegistry: AIProviderRegistry
    /// 外部知识 MCP 的非敏感连接配置与独立 Keychain Token
    let externalMCPConfigurationStore: ExternalMCPConfigurationStore
    private(set) var cloudConfigurationRevision = 0
    /// Kimi OAuth 凭证条目是否存在；启动状态检查不解密凭证，避免阻塞主线程。
    private(set) var isKimiAccountConnected: Bool
    /// 分人（OpenAI 兼容）Key 是否已配置
    private(set) var isDiarizationConfigured: Bool

    var externalMCPTokenStore: CloudAPIKeyStore {
        CloudAPIKeyStore(
            service: keychainServiceName,
            account: ExternalMCPConfigurationStore.legacyTokenAccount
        )
    }

    func externalMCPTokenStore(
        for configuration: ExternalMCPConfiguration
    ) -> CloudAPIKeyStore {
        CloudAPIKeyStore(
            service: keychainServiceName,
            account: configuration.credentialAccount
        )
    }

    var isAnalysisConfigured: Bool {
        _ = cloudConfigurationRevision
        switch aiProviderConfigurationStore.load().selectedProvider {
        case .kimi:
            return isConfigured(.analysis) || isKimiAccountConnected
        case .openAICompatible:
            let configuration = aiProviderConfigurationStore.load()
            return configuration.isOpenAIConfigurationValid
                && openAICompatibleKeyStore.hasConfiguredKey
        }
    }

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
        obsidianVaultURL: URL? = nil,
        storageWarning: String? = nil,
        securityScopedStorageAccess: SecurityScopedStorageAccess? = nil,
        audioCapture: any AudioCaptureServicing = AVAudioCaptureService(),
        localTranscription: any LocalTranscriptionServicing = AppleSpeechTranscriptionService(),
        diarization: any DiarizationServicing = OpenAIDiarizationService(),
        negotiationAnalysis: (any NegotiationAnalysisServicing)? = nil,
        conversationAnalysis: (any ConversationAnalysisServicing)? = nil,
        knowledgeExpansion: (any KnowledgeExpansionServicing)? = nil,
        finalReportGenerator: (any FinalReportGenerating)? = nil,
        kimiCredentials: (any KimiCredentialProviding)? = nil,
        exporter: (any MeetingExportServicing)? = nil,
        audioImport: (any AudioImportServicing)? = nil,
        makeImportTranscriptionService: (() -> any LocalTranscriptionServicing)? = nil,
        keychainServiceName: String = CloudAPIKeyStore.defaultService,
        aiProviderConfigurationStore: AIProviderConfigurationStore? = nil,
        externalMCPConfigurationStore: ExternalMCPConfigurationStore? = nil,
        isPersistentStorageUnavailable: Bool = false
    ) {
        var stores: [CloudProvider: CloudAPIKeyStore] = [:]
        for provider in CloudProvider.allCases {
            stores[provider] = CloudAPIKeyStore.store(for: provider, service: keychainServiceName)
        }
        let oauthStore = KimiOAuthTokenStore(service: keychainServiceName)
        let analysisKeyStore = stores[.analysis]
            ?? CloudAPIKeyStore.store(for: .analysis, service: keychainServiceName)
        let sharedCredentials = kimiCredentials ?? KimiCredentialProvider(
            tokenStore: oauthStore,
            staticKeyStore: analysisKeyStore
        )
        let sharedTransport = KimiAnalysisService(
            apiKeyStore: analysisKeyStore,
            credentials: sharedCredentials
        )
        let aiConfigurationStore = aiProviderConfigurationStore
            ?? AIProviderConfigurationStore()
        let openAIKeyStore = CloudAPIKeyStore(
            service: keychainServiceName,
            account: AIProviderConfigurationStore.openAIKeychainAccount
        )
        let providerRegistry = AIProviderRegistry(
            configurationStore: aiConfigurationStore,
            openAIKeyStore: openAIKeyStore,
            kimiTransport: sharedTransport
        )

        self.meetingStore = meetingStore
        self.fileStore = fileStore
        self.projectStore = projectStore ?? InMemoryProjectStore()
        self.obsidianVaultURL = obsidianVaultURL
        self.storageWarning = storageWarning
        self.securityScopedStorageAccess = securityScopedStorageAccess
        self.audioCapture = audioCapture
        self.localTranscription = localTranscription
        self.diarization = diarization
        self.negotiationAnalysis = negotiationAnalysis ?? sharedTransport
        self.conversationAnalysis = conversationAnalysis
            ?? KimiConversationAnalysisService(generationService: providerRegistry)
        self.knowledgeExpansion = knowledgeExpansion
            ?? KimiKnowledgeExpansionService(generationService: providerRegistry)
        self.finalReportGenerator = finalReportGenerator
            ?? ProjectAIOrchestrator(
                finalReportAgent: FinalReportAgent(
                    generationService: providerRegistry
                )
            )
        self.exporter = exporter ?? LocalMeetingExportService(meetingStore: meetingStore)
        self.audioImport = audioImport ?? AVFoundationAudioImportService(fileStore: fileStore)
        self.makeImportTranscriptionService = makeImportTranscriptionService ?? { AppleSpeechTranscriptionService() }
        self.isPersistentStorageUnavailable = isPersistentStorageUnavailable

        self.lexiconStore = LexiconStore(baseDirectory: fileStore.baseDirectory)
        let loaded = lexiconStore.load()
        self.lexiconTerms = loaded.terms
        self.correctionRules = loaded.corrections

        self.keyStores = stores
        self.keychainServiceName = keychainServiceName
        self.kimiOAuthTokenStore = oauthStore
        self.aiProviderConfigurationStore = aiConfigurationStore
        self.openAICompatibleKeyStore = openAIKeyStore
        self.aiProviderRegistry = providerRegistry
        self.externalMCPConfigurationStore = externalMCPConfigurationStore
            ?? ExternalMCPConfigurationStore()
        let hasStoredOAuthTokens = oauthStore.hasStoredTokens
        self.isKimiAccountConnected = hasStoredOAuthTokens
        self.isDiarizationConfigured = stores[.diarization]?.hasConfiguredKey ?? false
    }

    // MARK: - 专业词库与纠错规则

    /// 导入词库文本（追加合并，去重保序）；返回新增词数
    @discardableResult
    func importLexicon(text: String) throws -> Int {
        let parsed = LexiconStore.parse(text)
        let merged = LexiconStore.merge(lexiconTerms, adding: parsed)
        let added = merged.count - lexiconTerms.count
        try lexiconStore.save(terms: merged, corrections: correctionRules)
        lexiconTerms = merged
        lexiconRevision += 1
        return added
    }

    /// 清空词库（纠错规则保留）
    func clearLexicon() throws {
        try lexiconStore.save(terms: [], corrections: correctionRules)
        lexiconTerms = []
        lexiconRevision += 1
    }

    func addLexiconTerm(_ rawValue: String) throws {
        guard let term = LexiconStore.parse(rawValue).first else { return }
        let merged = LexiconStore.merge(lexiconTerms, adding: [term])
        guard merged != lexiconTerms else { return }
        try lexiconStore.save(terms: merged, corrections: correctionRules)
        lexiconTerms = merged
        lexiconRevision += 1
    }

    func updateLexiconTerm(_ existing: String, to rawValue: String) throws {
        guard let replacement = LexiconStore.parse(rawValue).first,
              let index = lexiconTerms.firstIndex(of: existing) else {
            return
        }
        var updated = lexiconTerms
        updated[index] = replacement
        updated = LexiconStore.merge([], adding: updated)
        try lexiconStore.save(terms: updated, corrections: correctionRules)
        lexiconTerms = updated
        lexiconRevision += 1
    }

    func removeLexiconTerm(_ term: String) throws {
        let updated = lexiconTerms.filter { $0 != term }
        guard updated != lexiconTerms else { return }
        try lexiconStore.save(terms: updated, corrections: correctionRules)
        lexiconTerms = updated
        lexiconRevision += 1
    }

    /// 记录纠错规则（同错词后写覆盖）；正词自动进入词库供后续识别
    func addCorrectionRule(wrong: String, right: String) throws {
        guard TranscriptCorrector.isValidRule(wrong: wrong, right: right) else { return }
        let rule = CorrectionRule(wrong: wrong, right: right)
        let rules = TranscriptCorrector.mergeRule(rule, into: correctionRules)
        let terms = LexiconStore.merge(lexiconTerms, adding: [right])
        try lexiconStore.save(terms: terms, corrections: rules)
        correctionRules = rules
        lexiconTerms = terms
        lexiconRevision += 1
    }

    /// 删除纠错规则
    func removeCorrectionRule(_ rule: CorrectionRule) throws {
        let rules = correctionRules.filter { $0.id != rule.id }
        try lexiconStore.save(terms: lexiconTerms, corrections: rules)
        correctionRules = rules
        lexiconRevision += 1
    }

    func updateCorrectionRule(
        _ rule: CorrectionRule,
        wrong: String,
        right: String
    ) throws {
        guard TranscriptCorrector.isValidRule(wrong: wrong, right: right) else {
            return
        }
        var rules = correctionRules.filter { $0.id != rule.id }
        rules = TranscriptCorrector.mergeRule(
            CorrectionRule(wrong: wrong, right: right),
            into: rules
        )
        let terms = LexiconStore.merge(lexiconTerms, adding: [right])
        try lexiconStore.save(terms: terms, corrections: rules)
        correctionRules = rules
        lexiconTerms = terms
        lexiconRevision += 1
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

    /// API Key / 登录状态变更后刷新各 provider 配置状态
    func refreshCloudConfiguration() {
        isKimiAccountConnected = kimiOAuthTokenStore.hasStoredTokens
        isDiarizationConfigured = isConfigured(.diarization)
        cloudConfigurationRevision += 1
    }

    /// Obsidian 检索索引跨多次“开花”复用（actor 内含 5 分钟缓存；
    /// 每次新建实例会让缓存失效，导致重复全量扫描 Vault）。
    /// Vault URL 在环境生命周期内不变，重选 Vault 会重建整个 AppEnvironment，
    /// 因此不存在旧 Vault 索引带入新 Vault 的问题。
    private var cachedObsidianProvider: ObsidianKnowledgeProvider?

    func makeKnowledgeProviders() -> [any KnowledgeProvider] {
        var providers: [any KnowledgeProvider] = []
        if let obsidianVaultURL {
            let obsidian = cachedObsidianProvider
                ?? ObsidianKnowledgeProvider(vaultURL: obsidianVaultURL)
            cachedObsidianProvider = obsidian
            providers.append(obsidian)
        }
        providers.append(InternetKnowledgeProvider())
        for configuration in externalMCPConfigurationStore.loadAll()
        where configuration.isEnabled
            && configuration.isReadOnlyToolVerified
            && configuration.validatedURL != nil {
            providers.append(ExternalMCPKnowledgeProvider(
                configuration: configuration,
                tokenStore: externalMCPTokenStore(for: configuration)
            ))
        }
        return providers
    }

    var isStorageChangeBlocked: Bool {
        if importProcessing.activeProjectID != nil { return true }
        if _finalReportCoordinator?.hasActiveTasks == true { return true }
        let projects = (try? allProjects()) ?? []
        return projects.contains {
            $0.sourceType == .liveRecording
                && ($0.status == .recording
                    || $0.status == .paused
                    || $0.status == .processing)
        }
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

    /// 保存单个项目；导入项目按调用方字段所有权合并，避免并发副本互相覆盖。
    func persist(
        _ project: Project,
        fields: ProjectFieldOwnership = .all
    ) throws {
        var projects = try projectStore.loadProjects()
        ProjectPersistence.upsert(project, into: &projects, fields: fields)
        try projectStore.saveProjects(projects)
    }

    /// 生产环境：默认 JSON 持久化 + 文件存储
    static func live() -> AppEnvironment {
        do {
            let storage = try AppStorageLocation.resolveDefault()
            let directory = storage.baseDirectory
            let store = try JSONMeetingStore(directory: directory)
            let projectStore = try JSONProjectStore(directory: directory)
            let fileStore = MeetingFileStore(baseDirectory: directory)
            // V1 → V2 一次性迁移：失败只脱敏记录，绝不抛出、绝不影响启动与旧数据
            var migrationSucceeded = true
            do {
                _ = try ProjectMigrationCoordinator(directory: directory).migrateIfNeeded()
            } catch {
                migrationSucceeded = false
                AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent("project_migration_failed", error: String(describing: type(of: error))))
            }
            // 录音资产缺失安全恢复（幂等；仅补写空路径且文件真实存在的项目，不动录音文件）
            if migrationSucceeded {
                do {
                    _ = try ProjectAssetRepair.repairIfNeeded(store: projectStore, fileStore: fileStore)
                } catch {
                    AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent("project_asset_repair_failed", error: String(describing: type(of: error))))
                }
            }
            let environment = AppEnvironment(
                meetingStore: store,
                fileStore: fileStore,
                projectStore: projectStore,
                obsidianVaultURL: storage.obsidianVaultURL,
                storageWarning: storage.warning,
                securityScopedStorageAccess: storage.securityScopedAccess
            )
            scheduleLegacyKeyMigration(refreshing: environment)
            return environment
        } catch {
            // 持久化初始化失败：降级为内存库，保证界面可用；
            // 仅记录脱敏错误，不含路径与正文
            AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent("storage_init_failed", error: String(describing: type(of: error))))
            let environment = AppEnvironment(
                meetingStore: InMemoryMeetingStore(),
                fileStore: MeetingFileStore(baseDirectory: FileManager.default.temporaryDirectory),
                projectStore: InMemoryProjectStore(),
                isPersistentStorageUnavailable: true
            )
            scheduleLegacyKeyMigration(refreshing: environment)
            return environment
        }
    }

    /// 旧版统一 Keychain 条目迁移（account=openai → 分析 kimi 条目）。
    /// 迁移需要解密旧条目：ad-hoc 重签名后 Keychain ACL 可能不再信任新签名，
    /// 解密会触发 SecurityAgent 授权交互——绝不能在启动主线程同步执行，
    /// 否则首帧渲染前即被阻塞（与 hasStoredTokens/contains 修复同一类问题）。
    private static func scheduleLegacyKeyMigration(refreshing environment: AppEnvironment) {
        Task.detached(priority: .utility) {
            CloudAPIKeyStore.migrateLegacyKeyIfNeeded()
            await MainActor.run {
                environment.refreshCloudConfiguration()
            }
        }
    }
}
