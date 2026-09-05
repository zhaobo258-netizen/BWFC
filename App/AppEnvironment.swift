import Foundation

enum TranscriptReviewCommitPersistenceError: Error, Equatable {
    case rollbackFailed
}

enum ProjectFieldOwnership: Sendable, Equatable {
    case all
    case note
    case title
    case businessGrouping
    case relatedContext
    case userScenario
    case speakers
    case manualSegments
    case recordingRuntime
    case analysis
    case legacyAnalysis
    case transcriptReview
    case memoryCandidates
    case finalReport
    case knowledgeGarden
    case aiContext
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
        "businessCategory": .workspace,
        "projectBackgroundContext": .workspace,
        "relatedProjectIDs": .workspace,
        "sourceType": .identity,
        "sourceRecordings": .identity,
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
        "analysisSpeakerOverrides": .workspace,
        "transcriptReviewCandidates": .workspace,
        "businessMemoryCandidates": .workspace,
        "followUpCandidates": .workspace,
        "finalReportSnapshots": .runtime,
        "knowledgeSeeds": .workspace,
        "aiChatMessages": .workspace,
        "aiChatDraft": .workspace,
        "noteAIContextEnabled": .workspace,
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
        case .businessGrouping:
            stored.businessCategory = incoming.businessCategory
            stored.lastActivityAt = incoming.lastActivityAt
        case .relatedContext:
            stored.businessCategory = incoming.businessCategory
            stored.projectBackgroundContext = incoming.projectBackgroundContext
            stored.relatedProjectIDs = incoming.relatedProjectIDs
            stored.lastActivityAt = incoming.lastActivityAt
        case .userScenario:
            stored.scenario = incoming.scenario
            stored.scenarioWasUserSelected = incoming.scenarioWasUserSelected
        case .speakers:
            stored.speakers = incoming.speakers
        case .manualSegments:
            mergeManualSegments(incoming.segments, into: stored)
            stored.lastActivityAt = incoming.lastActivityAt
        case .recordingRuntime:
            stored.status = incoming.status
            stored.startedAt = incoming.startedAt
            stored.endedAt = incoming.endedAt
            stored.runtimeAssetRelativePath = incoming.runtimeAssetRelativePath
            stored.durationMs = incoming.durationMs
            stored.preferredInputDeviceID = incoming.preferredInputDeviceID
            stored.pauseIntervals = incoming.pauseIntervals
            stored.legacyMetadata = incoming.legacyMetadata
            stored.legacySnapshots = incoming.legacySnapshots
            mergePipelineSegments(incoming.segments, into: stored)
            stored.lastActivityAt = incoming.lastActivityAt
        case .analysis:
            stored.analysisSnapshots = incoming.analysisSnapshots
            stored.analysisSpeakerOverrides = incoming.analysisSpeakerOverrides
            if !stored.scenarioWasUserSelected {
                stored.scenario = incoming.scenario
                stored.scenarioWasUserSelected = incoming.scenarioWasUserSelected
            }
        case .legacyAnalysis:
            stored.legacySnapshots = incoming.legacySnapshots
        case .transcriptReview:
            stored.transcriptReviewCandidates = incoming.transcriptReviewCandidates
        case .memoryCandidates:
            stored.businessMemoryCandidates = incoming.businessMemoryCandidates
            stored.followUpCandidates = incoming.followUpCandidates
        case .finalReport:
            let reportJobs = incoming.processingJobs.filter { $0.kind == .finalReport }
            stored.finalReportSnapshots = incoming.finalReportSnapshots
            stored.processingJobs.removeAll { $0.kind == .finalReport }
            stored.processingJobs.append(contentsOf: reportJobs)
            stored.lastActivityAt = incoming.lastActivityAt
        case .knowledgeGarden:
            stored.knowledgeSeeds = incoming.knowledgeSeeds
        case .aiContext:
            stored.aiChatMessages = incoming.aiChatMessages
            stored.aiChatDraft = incoming.aiChatDraft
            stored.noteAIContextEnabled = incoming.noteAIContextEnabled
        case .importPipeline:
            stored.status = incoming.status
            stored.processingJobs = incoming.processingJobs
            mergePipelineSegments(incoming.segments, into: stored)
            stored.legacySnapshots = incoming.legacySnapshots
            stored.analysisSnapshots = incoming.analysisSnapshots
            stored.analysisSpeakerOverrides = incoming.analysisSpeakerOverrides
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
                      segment.state == .edited
                        || segment.speakerWasUserConfirmed == true
                        || segment.participantId != existing.participantId
                        || segment.isStarred != existing.isStarred else {
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
                  existing.state == .edited
                    || existing.textWasUserEdited == true
                    || existing.speakerWasUserConfirmed == true
                    || existing.isStarred != segment.isStarred else {
                return segment
            }
            return existing
        }
        merged.append(contentsOf: stored.segments.filter {
            !incomingIDs.contains($0.id)
                && ($0.state == .edited
                    || $0.textWasUserEdited == true
                    || $0.speakerWasUserConfirmed == true
                    || $0.isStarred)
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
    /// 应用级永久声纹库；与单个项目目录分离，供后续录音复用。
    let speakerVoiceProfileStore: SpeakerVoiceProfileStore
    /// 独立人物库（12 号 §5）：跨录音身份权威，声纹只是可选附件。
    let personLibraryStore: PersonLibraryStore
    /// 轻 CRM 业务项目库（12 号 §7）
    let businessProjectStore: BusinessProjectStore
    /// 业务记忆与跟进候选提取（12 号 §6.3 / §7.3）
    let businessMemoryCandidateAgent: BusinessMemoryCandidateAgent
    /// AI 回答语音外放（12 号 §10：点击播放、可取消）
    let answerSpeechController: AnswerSpeechController
    /// 已授权的 Obsidian Vault；为 nil 时使用 App Sandbox 内的安全回退目录。
    let obsidianVaultURL: URL?
    /// Vault 失权等情况下向设置页展示的可恢复提示。
    let storageWarning: String?
    /// 持有安全作用域访问直至环境释放，避免运行中 Vault 权限提前失效。
    private let securityScopedStorageAccess: SecurityScopedStorageAccess?

    /// 本次 App 运行期间真正在录音/暂停的项目 id。
    /// 首页据此区分「此刻正在录」与「上次异常退出留下的 recording 状态」：
    /// 磁盘状态无法自证是哪一种，只有运行时登记能区分。
    private(set) var liveRecordingProjectIDs: Set<UUID> = []
    private var pendingProjectWarnings: [UUID: String] = [:]

    /// 工作台开始录音时登记
    func markProjectLive(_ projectID: UUID) {
        liveRecordingProjectIDs.insert(projectID)
    }

    /// 录音正常结束或页面收尾时注销
    func clearProjectLive(_ projectID: UUID) {
        liveRecordingProjectIDs.remove(projectID)
    }

    func setPendingWarning(_ message: String, for projectID: UUID) {
        pendingProjectWarnings[projectID] = message
    }

    func consumePendingWarning(for projectID: UUID) -> String? {
        pendingProjectWarnings.removeValue(forKey: projectID)
    }

    func refreshCurrentUserCommunicationProfile(
        from project: Project
    ) async throws -> Int? {
        guard let speaker = project.speakers.first(where: {
            $0.isCurrentUser == true && $0.voiceProfileId != nil
        }), let profileID = speaker.voiceProfileId else {
            return nil
        }
        let projects = try projectStore.loadProjects()
        let evidence = HistoricalPersonLibrary.communicationEvidence(
            profileID: profileID,
            projects: projects
        )
        guard evidence.count >= 2 else { return nil }
        _ = try await HistoricalPersonLibrary.updateCommunicationProfile(
            profileID: profileID,
            profileStore: speakerVoiceProfileStore,
            projectStore: projectStore,
            generationService: aiProviderRegistry
        )
        if let current = try speakerVoiceProfileStore.loadForManagement().first(where: { $0.id == profileID }) {
            speaker.backgroundContext = current.backgroundContext
            speaker.communicationProfile = current.communicationProfile
            speaker.isCurrentUser = current.isCurrentUser
        }
        return evidence.count
    }

    /// 音频采集（阶段 1：AVAudioEngine 实现）
    let audioCapture: any AudioCaptureServicing
    /// 本地转写（阶段 2 实现）
    let localTranscription: any LocalTranscriptionServicing
    /// 测试可注入固定服务；生产运行按会议配置快照创建实例。
    private let diarizationServiceOverride: (any DiarizationServicing)?
    /// 云端谈判分析（阶段 4 实现；V1 遗留，旧会议页面使用）
    let negotiationAnalysis: any NegotiationAnalysisServicing
    /// V2 通用对话分析（阶段 D，语义分析师；工作台与导入流水线使用）
    let conversationAnalysis: any ConversationAnalysisServicing
    /// “开花”中的概念解释、跨领域连接与检索词生成
    let knowledgeExpansion: any KnowledgeExpansionServicing
    /// 项目级背景补充、主题纠正与追问
    let projectAIChat: any ProjectAIChatServing
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
            makeDiarizationService: { [weak self] in
                guard let self, self.isDiarizationConfigured else { return nil }
                return self.makeDiarizationService(for: self.diarizationConfigurationSnapshot())
            },
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
        controller.prepareSpeakerReferences = { [weak self] project in
            guard let self else { throw CancellationError() }
            project.speakers = try self.refreshAutomaticSpeakerReferences(for: project.id)
        }
        _importProcessing = controller
        return controller
    }

    private var _finalReportCoordinator: FinalReportCoordinator?
    private var deletedProjectIDs: Set<UUID> = []
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
            knownTermsProvider: { [weak self] in self?.lexiconTerms ?? [] },
            connectionProbe: { [aiProviderRegistry] in
                _ = try await aiProviderRegistry.testActiveConnection()
            }
        )
        _finalReportCoordinator = coordinator
        return coordinator
    }

    /// 全局专业词库与纠错规则（App 级；转写上下文 + 分析已知名词 + 自动纠错）
    let lexiconStore: LexiconStore
    private(set) var lexiconTerms: [String] = []
    private(set) var correctionRules: [CorrectionRule] = []
    private(set) var lexiconRevision = 0

    /// 各 provider 的本机凭证存储（Key 分家，互不外借）
    private let keyStores: [CloudProvider: CloudAPIKeyStore]
    private let credentialServiceName: String
    /// Kimi 账号 OAuth 凭证存储（设备码登录；与静态分析 Key 独立条目）
    let kimiOAuthTokenStore: KimiOAuthTokenStore
    let aiProviderConfigurationStore: AIProviderConfigurationStore
    let diarizationProviderConfigurationStore: DiarizationProviderConfigurationStore
    let openAICompatibleKeyStore: CloudAPIKeyStore
    let volcengineDiarizationKeyStore: CloudAPIKeyStore
    let volcengineDiarizationAccessTokenStore: CloudAPIKeyStore
    let iflytekCredentialStore: CloudAPIKeyStore
    let aiProviderRegistry: AIProviderRegistry
    /// 外部知识 MCP 的非敏感连接配置与独立本机 Token
    let externalMCPConfigurationStore: ExternalMCPConfigurationStore
    private(set) var cloudConfigurationRevision = 0
    /// Kimi OAuth 凭证条目是否存在。
    private(set) var isKimiAccountConnected: Bool
    /// 分人（OpenAI 兼容）Key 是否已配置
    private(set) var isDiarizationConfigured: Bool

    var externalMCPTokenStore: CloudAPIKeyStore {
        CloudAPIKeyStore(
            service: credentialServiceName,
            account: ExternalMCPConfigurationStore.legacyTokenAccount
        )
    }

    func externalMCPTokenStore(
        for configuration: ExternalMCPConfiguration
    ) -> CloudAPIKeyStore {
        CloudAPIKeyStore(
            service: credentialServiceName,
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
        diarization: (any DiarizationServicing)? = nil,
        diarizationProvider: DiarizationProvider? = nil,
        negotiationAnalysis: (any NegotiationAnalysisServicing)? = nil,
        conversationAnalysis: (any ConversationAnalysisServicing)? = nil,
        knowledgeExpansion: (any KnowledgeExpansionServicing)? = nil,
        projectAIChat: (any ProjectAIChatServing)? = nil,
        finalReportGenerator: (any FinalReportGenerating)? = nil,
        kimiCredentials: (any KimiCredentialProviding)? = nil,
        exporter: (any MeetingExportServicing)? = nil,
        audioImport: (any AudioImportServicing)? = nil,
        makeImportTranscriptionService: (() -> any LocalTranscriptionServicing)? = nil,
        credentialServiceName: String = CloudAPIKeyStore.defaultService,
        aiProviderConfigurationStore: AIProviderConfigurationStore? = nil,
        diarizationProviderConfigurationStore: DiarizationProviderConfigurationStore? = nil,
        externalMCPConfigurationStore: ExternalMCPConfigurationStore? = nil,
        isPersistentStorageUnavailable: Bool = false
    ) {
        var stores: [CloudProvider: CloudAPIKeyStore] = [:]
        for provider in CloudProvider.allCases {
            stores[provider] = CloudAPIKeyStore.store(for: provider, service: credentialServiceName)
        }
        let oauthStore = KimiOAuthTokenStore(service: credentialServiceName)
        let analysisKeyStore = stores[.analysis]
            ?? CloudAPIKeyStore.store(for: .analysis, service: credentialServiceName)
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
        let diarizationConfigurationStore = diarizationProviderConfigurationStore
            ?? DiarizationProviderConfigurationStore()
        let openAIKeyStore = CloudAPIKeyStore(
            service: credentialServiceName,
            account: AIProviderConfigurationStore.openAICredentialAccount
        )
        let providerRegistry = AIProviderRegistry(
            configurationStore: aiConfigurationStore,
            openAIKeyStore: openAIKeyStore,
            kimiTransport: sharedTransport
        )

        self.meetingStore = meetingStore
        self.fileStore = fileStore
        self.speakerVoiceProfileStore = SpeakerVoiceProfileStore(baseDirectory: fileStore.baseDirectory)
        let writeIndex: (Data, URL) throws -> Void = { data, url in
            guard !isPersistentStorageUnavailable else { throw ProjectWriteError.storageUnavailable }
            try data.write(to: url, options: .atomic)
        }
        self.personLibraryStore = PersonLibraryStore(baseDirectory: fileStore.baseDirectory, indexWriter: writeIndex)
        self.businessProjectStore = BusinessProjectStore(baseDirectory: fileStore.baseDirectory, indexWriter: writeIndex)
        self.businessMemoryCandidateAgent = BusinessMemoryCandidateAgent(generationService: providerRegistry)
        self.answerSpeechController = AnswerSpeechController(player: SystemAnswerSpeechPlayer())
        self.projectStore = projectStore ?? InMemoryProjectStore()
        self.obsidianVaultURL = obsidianVaultURL
        self.storageWarning = storageWarning
        self.securityScopedStorageAccess = securityScopedStorageAccess
        self.audioCapture = audioCapture
        self.localTranscription = localTranscription
        var diarizationConfiguration = diarizationConfigurationStore.load()
        if let diarizationProvider {
            diarizationConfiguration.selectedProvider = diarizationProvider
        }
        let diarizationStore = stores[.diarization]
            ?? CloudAPIKeyStore.store(for: .diarization, service: credentialServiceName)
        let volcengineDiarizationKeyStore = CloudAPIKeyStore(
            service: credentialServiceName,
            account: VolcengineDiarizationService.credentialAccount
        )
        let volcengineDiarizationAccessTokenStore = CloudAPIKeyStore(
            service: credentialServiceName,
            account: VolcengineDiarizationService.accessTokenCredentialAccount
        )
        let iflytekCredentialStore = CloudAPIKeyStore(
            service: credentialServiceName,
            account: IFlytekCredentials.credentialAccount
        )
        self.diarizationServiceOverride = diarization
        self.negotiationAnalysis = negotiationAnalysis ?? sharedTransport
        self.conversationAnalysis = conversationAnalysis
            ?? KimiConversationAnalysisService(generationService: providerRegistry)
        self.knowledgeExpansion = knowledgeExpansion
            ?? KimiKnowledgeExpansionService(generationService: providerRegistry)
        self.projectAIChat = projectAIChat
            ?? ProjectAIChatAgent(
                generationService: providerRegistry,
                webSearchProvider: InternetKnowledgeProvider(
                    credentials: sharedCredentials
                )
            )
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
        self.credentialServiceName = credentialServiceName
        self.kimiOAuthTokenStore = oauthStore
        self.aiProviderConfigurationStore = aiConfigurationStore
        self.diarizationProviderConfigurationStore = diarizationConfigurationStore
        self.openAICompatibleKeyStore = openAIKeyStore
        self.volcengineDiarizationKeyStore = volcengineDiarizationKeyStore
        self.volcengineDiarizationAccessTokenStore = volcengineDiarizationAccessTokenStore
        self.iflytekCredentialStore = iflytekCredentialStore
        self.aiProviderRegistry = providerRegistry
        self.externalMCPConfigurationStore = externalMCPConfigurationStore
            ?? ExternalMCPConfigurationStore()
        let hasStoredOAuthTokens = oauthStore.hasStoredTokens
        self.isKimiAccountConnected = hasStoredOAuthTokens
        self.isDiarizationConfigured = Self.isDiarizationConfigured(
            configuration: diarizationConfiguration,
            keyStore: {
                switch diarizationConfiguration.selectedProvider {
                case .volcengine: return volcengineDiarizationKeyStore
                case .iflytek: return iflytekCredentialStore
                case .disabled, .openAICompatible: return diarizationStore
                }
            }()
        )
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

    /// 改词。改后的值与列表里其他词重复时抛错并保持原样——
    /// 旧实现走 merge 去重会让数组少一位，表现为「改了一个词，另一个词消失」。
    func updateLexiconTerm(_ existing: String, to rawValue: String) throws {
        guard let replacement = LexiconStore.parse(rawValue).first else {
            throw LexiconEditError.emptyTerm
        }
        guard let index = lexiconTerms.firstIndex(of: existing) else {
            throw LexiconEditError.termNotFound(existing)
        }
        if replacement == existing { return }
        if lexiconTerms.contains(replacement) {
            throw LexiconEditError.duplicateTerm(replacement)
        }
        var updated = lexiconTerms
        updated[index] = replacement
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

    /// 一次确认多条 AI 校对候选：先原子写入规则与正词，再保存文稿；
    /// 文稿保存失败时恢复旧词库，避免两份权威数据只成功一半。
    func applyTranscriptReviewCommit(
        _ commit: TranscriptReviewCommit,
        persistTranscript: () throws -> Void
    ) throws {
        let previousRules = correctionRules
        let previousTerms = lexiconTerms
        var rules = correctionRules
        for rule in commit.correctionRules {
            rules = TranscriptCorrector.mergeRule(rule, into: rules)
        }
        let terms = LexiconStore.merge(lexiconTerms, adding: commit.terms)
        try lexiconStore.save(terms: terms, corrections: rules)
        correctionRules = rules
        lexiconTerms = terms
        lexiconRevision += 1
        do {
            try persistTranscript()
        } catch {
            let transcriptPersistenceError = error
            correctionRules = previousRules
            lexiconTerms = previousTerms
            lexiconRevision += 1
            do {
                try lexiconStore.save(
                    terms: previousTerms,
                    corrections: previousRules
                )
            } catch {
                throw TranscriptReviewCommitPersistenceError.rollbackFailed
            }
            throw transcriptPersistenceError
        }
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

    /// 指定 provider 的本机凭证存储（视图层读写 Key 的唯一入口）
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

    func makeDiarizationService(
        for configuration: DiarizationProviderConfiguration
    ) -> any DiarizationServicing {
        if let diarizationServiceOverride {
            return diarizationServiceOverride
        }
        return DiarizationServiceFactory.make(
            configuration: configuration,
            keyStore: keyStore(for: .diarization),
            volcengineKeyStore: volcengineDiarizationKeyStore,
            volcengineAccessTokenStore: volcengineDiarizationAccessTokenStore,
            iflytekCredentialStore: iflytekCredentialStore
        )
    }

    func diarizationKeyStore(
        for configuration: DiarizationProviderConfiguration
    ) -> CloudAPIKeyStore {
        switch configuration.selectedProvider {
        case .volcengine:
            return volcengineDiarizationKeyStore
        case .iflytek:
            return iflytekCredentialStore
        case .disabled, .openAICompatible:
            return keyStore(for: .diarization)
        }
    }

    func diarizationConfigurationSnapshot() -> DiarizationProviderConfiguration {
        diarizationProviderConfigurationStore.load()
    }

    /// API Key / 登录状态变更后刷新各 provider 配置状态
    func refreshCloudConfiguration() {
        isKimiAccountConnected = kimiOAuthTokenStore.hasStoredTokens
        isDiarizationConfigured = Self.isDiarizationConfigured(
            configuration: diarizationProviderConfigurationStore.load(),
            keyStore: diarizationKeyStore(
                for: diarizationProviderConfigurationStore.load()
            )
        )
        cloudConfigurationRevision += 1
    }

    private static func isDiarizationConfigured(
        configuration: DiarizationProviderConfiguration,
        keyStore: CloudAPIKeyStore
    ) -> Bool {
        switch configuration.selectedProvider {
        case .disabled:
            return false
        case .openAICompatible:
            return configuration.isValid && keyStore.hasConfiguredKey
        case .volcengine:
            return configuration.isValid && keyStore.hasConfiguredKey
        case .iflytek:
            return configuration.isValid && keyStore.hasConfiguredKey
        }
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
        guard !isPersistentStorageUnavailable else { throw ProjectWriteError.storageUnavailable }
        guard !deletedProjectIDs.contains(project.id) else { throw ProjectWriteError.projectDeleted }
        var projects = try projectStore.loadProjects()
        ProjectPersistence.upsert(project, into: &projects, fields: fields)
        try projectStore.saveProjects(projects)
    }

    /// 删除整个项目：先摘记录再删目录（镜像 `deleteMeeting(_:)`）。
    /// 顺序不可颠倒——先删目录再写 projects.json，中途失败会留下「有记录、无文件」的
    /// 幽灵项目，界面里点开就是一片空白；反过来失败只剩下一个孤儿目录，
    /// 用户看不见、下次删同名项目也不会撞车，代价小得多。
    func deleteProject(_ project: Project) throws {
        var projects = try projectStore.loadProjects()
        projects.removeAll { $0.id == project.id }
        try projectStore.saveProjects(projects)
        deletedProjectIDs.insert(project.id)
        _finalReportCoordinator?.cancel(projectID: project.id)
        if _importProcessing?.activeProjectID == project.id { _importProcessing?.cancel() }
        try propagatePersonCleanup(forDeletedProject: project)
        try fileStore.deleteMeetingFiles(for: project.id)
    }

    /// 删除录音后的人物侧清理（12 号 §5.3 / §6.5）：
    /// 解除该录音的说话人关联账本；来源指向该录音的记忆标记需复核（不静默删）。
    private func propagatePersonCleanup(forDeletedProject project: Project) throws {
        let persons = try personLibraryStore.load()
        for person in persons {
            let hasLink = person.speakerLinks.contains { $0.projectID == project.id }
            let hasMemory = person.memoryEntries.contains {
                $0.source?.recordingID == project.id
            }
            guard hasLink || hasMemory else { continue }
            var updated = person
            updated.speakerLinks.removeAll { $0.projectID == project.id }
            for index in updated.memoryEntries.indices
            where updated.memoryEntries[index].source?.recordingID == project.id
                && (updated.memoryEntries[index].status == .active
                    || updated.memoryEntries[index].status == .candidate) {
                updated.memoryEntries[index].status = .needsReview
                updated.memoryEntries[index].reviewReason = "来源录音已删除；请撤回或改为人工背景"
                updated.memoryEntries[index].updatedAt = Date()
            }
            _ = try personLibraryStore.updatePerson(updated)
        }
        // 业务项目：解除录音关联，跟进不自动删除（来源失效由页面提示）
        let businessProjects = try businessProjectStore.load()
        for businessProject in businessProjects {
            var updated = businessProject
            updated.linkedProjectIDs.removeAll { $0 == project.id }
            for index in updated.memoryEntries.indices
            where updated.memoryEntries[index].source?.recordingID == project.id
                && (updated.memoryEntries[index].status == .active
                    || updated.memoryEntries[index].status == .candidate) {
                updated.memoryEntries[index].status = .needsReview
                updated.memoryEntries[index].reviewReason = "来源录音已删除"
                updated.memoryEntries[index].updatedAt = Date()
            }
            if updated != businessProject { _ = try businessProjectStore.update(updated) }
        }
    }

    // MARK: - 业务记忆上下文（12 号 §6.1：回答时使用相关已确认记忆并说明来源）

    /// 适用于某场录音的有效记忆：本场说话人关联人物的有效记忆 +
    /// 关联到本场录音的业务项目记忆；按更新时间排序、条数封顶。
    func applicableMemories(
        for project: Project,
        maximumCount: Int = 12
    ) throws -> [MemoryEntry] {
        let personIDs = Set(project.speakers.compactMap(\.personId))
        let businessProjects = try businessProjectStore.load().filter {
            $0.status == .active && $0.linkedProjectIDs.contains(project.id)
        }
        let businessIDs = Set(businessProjects.map(\.id))
        let sources = try projectStore.loadProjects()
        let persons = try personLibraryStore.load()
        let entries = persons.filter { personIDs.contains($0.id) }.flatMap(\.activeMemories)
            + businessProjects.flatMap(\.activeMemories)
        var seen = Set<UUID>()
        return Array(entries.filter { entry in
            guard entry.scope.personID.map({ personIDs.contains($0) }) ?? true,
                  entry.scope.businessProjectID.map({ businessIDs.contains($0) }) ?? true,
                  entry.effectiveFrom.map({ $0 <= Date() }) ?? true else { return false }
            if let source = entry.source {
                guard let recording = sources.first(where: { $0.id == source.recordingID }),
                      let segment = recording.segments.first(where: { $0.id == source.segmentID }),
                      segment.state == .final || segment.state == .edited,
                      segment.speakerWasUserConfirmed == true,
                      let speakerID = segment.participantId,
                      let speaker = recording.speakers.first(where: { $0.id == speakerID }),
                      entry.scope.personID.map({ $0 == speaker.personId }) ?? true,
                      source.sourceVersion == BusinessMemoryCandidateBuilder.sourceVersion(
                        project: recording, segment: segment
                      ) else { return false }
            } else if !entry.isManuallyAuthored {
                return false
            }
            return seen.insert(entry.id).inserted
        }.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(0, maximumCount)))
    }

    func activeMemoryContents(for project: Project) throws -> [String] {
        try applicableMemories(for: project, maximumCount: 100).map(\.content)
    }

    /// 按显示名精确找人（跟进责任人默认猜测用；姓名只是显示字段，
    /// 找不到就留空，业务项目页可再人工指定）。
    func personByExactDisplayName(_ name: String) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let matches = ((try? personLibraryStore.load()) ?? [])
            .filter { $0.displayName == trimmed }
        return matches.count == 1 ? matches[0] : nil
    }

    func automaticSpeakersWithPeople() throws -> [Speaker] {
        let persons = try personLibraryStore.load()
        let speakers = try speakerVoiceProfileStore.automaticSpeakers()
        for speaker in speakers {
            guard let profileID = speaker.voiceProfileId,
                  let person = persons.first(where: { $0.voiceProfileIDs.contains(profileID) }) else { continue }
            speaker.personId = person.id
            speaker.displayName = person.displayName
            speaker.role = person.role
            speaker.backgroundContext = person.backgroundContext
            speaker.isCurrentUser = person.isCurrentUser
        }
        return speakers
    }

    func refreshAutomaticSpeakerReferences(for projectID: UUID) throws -> [Speaker] {
        guard !isPersistentStorageUnavailable else { throw ProjectWriteError.storageUnavailable }
        guard let current = try allProjects().first(where: { $0.id == projectID }) else {
            throw ProjectWriteError.projectDeleted
        }
        let profiles = try speakerVoiceProfileStore.loadForManagement()
        let persons = try personLibraryStore.load()
        let automatic = try automaticSpeakersWithPeople()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(current.speakers)
        var speakers = try JSONDecoder().decode([Speaker].self, from: original)
        for speaker in speakers {
            guard let profileID = speaker.voiceProfileId,
                  SpeakerPanelLogic.voiceReferencePath(for: speaker) != nil,
                  let profile = profiles.first(where: { $0.id == profileID }) else { continue }
            if let person = persons.first(where: { $0.voiceProfileIDs.contains(profileID) }) {
                guard speaker.personId == nil || speaker.personId == person.id else {
                    throw PersonLibraryStoreError.conflictingVoiceProfile
                }
                speaker.personId = person.id
                speaker.displayName = person.displayName
                speaker.role = person.role
                speaker.backgroundContext = person.backgroundContext
                speaker.isCurrentUser = person.isCurrentUser
            }
            speaker.voiceSamplePath = profile.sampleRelativePath
            speaker.voiceSampleDurationMs = profile.sampleDurationMs
            speaker.iflytekFeatureID = profile.iflytekFeatureID
            speaker.communicationProfile = profile.communicationProfile
        }
        for candidate in automatic {
            guard let profileID = candidate.voiceProfileId, let personID = candidate.personId,
                  !speakers.contains(where: { $0.voiceProfileId == profileID }),
                  SpeakerPanelLogic.activeVoiceReferenceCount(in: speakers) < KnownSpeakerReference.maximumCount else {
                continue
            }
            if let existing = speakers.first(where: { $0.personId == personID }) {
                // 有 profile ID 但无样本表示用户在本场停用，不自动重新启用。
                guard existing.voiceProfileId == nil,
                      SpeakerPanelLogic.voiceReferencePath(for: existing) == nil else { continue }
                existing.voiceProfileId = profileID
                existing.voiceSamplePath = candidate.voiceSamplePath
                existing.voiceSampleDurationMs = candidate.voiceSampleDurationMs
                existing.iflytekFeatureID = candidate.iflytekFeatureID
                existing.communicationProfile = candidate.communicationProfile
            } else {
                candidate.cloudAlias = SpeakerPanelLogic.nextCloudAlias(existing: speakers)
                speakers.append(candidate)
            }
        }
        guard try encoder.encode(speakers) != original else { return current.speakers }
        try personLibraryStore.changeIdentity(
            projectStore: projectStore, businessProjectStore: businessProjectStore,
            profileStore: speakerVoiceProfileStore
        ) { _, projects, _ in
            guard let stored = projects.first(where: { $0.id == projectID }) else {
                throw ProjectWriteError.projectDeleted
            }
            stored.speakers = speakers
        }
        return speakers
    }

    func updateLibraryPersonMetadata(
        personID: UUID, displayName: String, role: String?, backgroundContext: String?
    ) throws {
        guard !isPersistentStorageUnavailable else { throw ProjectWriteError.storageUnavailable }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PersonLibraryStoreError.personNotFound }
        try personLibraryStore.changeIdentity(
            projectStore: projectStore, businessProjectStore: businessProjectStore,
            profileStore: speakerVoiceProfileStore
        ) { persons, projects, _ in
            guard let index = persons.firstIndex(where: { $0.id == personID }) else {
                throw PersonLibraryStoreError.personNotFound
            }
            persons[index].displayName = name
            persons[index].role = role
            persons[index].backgroundContext = backgroundContext
            persons[index].updatedAt = Date()
            for project in projects {
                for speaker in project.speakers where speaker.personId == personID {
                    speaker.displayName = name
                    speaker.role = role
                    speaker.backgroundContext = backgroundContext
                }
            }
        }
    }

    /// 首次人物迁移前的权威数据备份（12 号 §9.4 合同第 1 条）：
    /// 把 projects.json 与 speaker-profiles.json 复制到 MigrationBackups/<时间戳>/。
    static func backupAuthorityFilesBeforeMigration(
        in directory: URL,
        fileManager: FileManager
    ) throws {
        let files = ["projects.json", "speaker-profiles.json", "persons.json", "business-projects.json"]
        let existing = files
            .map { directory.appending(path: $0, directoryHint: .notDirectory) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupDirectory = directory.appending(
            path: "MigrationBackups/\(stamp)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        for source in existing {
            try fileManager.copyItem(
                at: source,
                to: backupDirectory.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
            )
        }
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
            // 阶段 B 人物迁移（12 号 §9.4）：声纹档案 → Person，回填 Speaker.personId。
            // 幂等可重跑；失败只脱敏记录，不阻断启动。
            do {
                // 迁移合同第 1 条：写入前备份当前权威数据（仅首次无标记时执行）
                if !FileManager.default.fileExists(
                    atPath: PersonMigrationCoordinator.markerURL(in: directory).path
                ) {
                    try Self.backupAuthorityFilesBeforeMigration(
                        in: directory,
                        fileManager: .default
                    )
                }
                let environment = AppEnvironment(
                    meetingStore: store,
                    fileStore: fileStore,
                    projectStore: projectStore,
                    obsidianVaultURL: storage.obsidianVaultURL,
                    storageWarning: storage.warning,
                    securityScopedStorageAccess: storage.securityScopedAccess
                )
                _ = try PersonMigrationCoordinator.migrateIfNeeded(
                    personStore: environment.personLibraryStore,
                    profileStore: environment.speakerVoiceProfileStore,
                    projectStore: projectStore,
                    baseDirectory: directory
                )
                return environment
            } catch {
                AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent("person_migration_failed", error: String(describing: type(of: error))))
                return AppEnvironment(
                    meetingStore: store,
                    fileStore: fileStore,
                    projectStore: projectStore,
                    obsidianVaultURL: storage.obsidianVaultURL,
                    storageWarning: "人物迁移未完成，原始资料已保留。请检查存储位置后重启重试。",
                    securityScopedStorageAccess: storage.securityScopedAccess
                )
            }
        } catch {
            // 持久化初始化失败：降级为内存库，保证界面可用；
            // 仅记录脱敏错误，不含路径与正文
            AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent("storage_init_failed", error: String(describing: type(of: error))))
            let environment = AppEnvironment(
                meetingStore: InMemoryMeetingStore(),
                fileStore: MeetingFileStore(baseDirectory: FileManager.default.temporaryDirectory),
                projectStore: InMemoryProjectStore(),
                storageWarning: "原存储位置暂不可用，录音与导入已停用。请重新连接原知识库后重启应用。",
                isPersistentStorageUnavailable: true
            )
            return environment
        }
    }
}

enum ProjectWriteError: LocalizedError {
    case storageUnavailable
    case projectDeleted

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "存储位置不可用，请重新连接原知识库后重试。"
        case .projectDeleted: return "录音已删除，后台结果未保存。"
        }
    }
}
