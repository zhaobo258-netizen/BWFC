import AppKit
import SwiftUI

struct SettingsView: View {
    private enum SettingsSection: String, CaseIterable, Identifiable {
        case ai = "大模型与 AI"
        case knowledge = "MCP 与知识源"
        case lexicon = "词库与纠错"
        case people = "人物库与我的背景"
        case recording = "录音与说话人"
        case storage = "存储与隐私"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .ai: return "sparkles"
            case .knowledge: return "point.3.connected.trianglepath.dotted"
            case .lexicon: return "text.book.closed"
            case .people: return "person.2.wave.2"
            case .recording: return "waveform.and.mic"
            case .storage: return "externaldrive"
            }
        }
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    let onStorageLocationChanged: () -> Void

    @State private var selectedSection: SettingsSection? = .ai
    @State private var analysisKeyInput = ""
    @State private var diarizationKeyInput = ""
    @State private var volcengineKeyInput = ""
    @State private var volcengineAccessTokenInput = ""
    @State private var iflytekAccessKeyIDInput = ""
    @State private var iflytekAccessKeySecretInput = ""
    @State private var diarizationConfiguration = DiarizationProviderConfiguration()
    @State private var diarizationMessage: String?
    @State private var volcengineTestResult: (ok: Bool, text: String)?
    @State private var isTestingVolcengine = false
    @State private var iflytekTestResult: (ok: Bool, text: String)?
    @State private var isTestingIFlytek = false
    @State private var testResults: [CloudProvider: (ok: Bool, text: String)] = [:]
    @State private var testingProvider: CloudProvider?
    @State private var login: KimiLoginController?
    @State private var isShowingKimiFallbackKey = false

    @State private var aiConfiguration = AIProviderConfiguration()
    @State private var openAIKeyInput = ""
    @State private var aiMessage: String?
    @State private var isTestingAI = false
    @State private var isConfirmingCustomAIDeletion = false

    @State private var mcpConfigurations: [ExternalMCPConfiguration] = []
    @State private var selectedMCPID: UUID?
    @State private var mcpDraft = ExternalMCPConfiguration()
    @State private var mcpTokenInput = ""
    @State private var mcpMessage: String?
    @State private var discoveredMCPTools: [String] = []
    @State private var isTestingMCP = false
    @State private var pendingMCPDeletion: ExternalMCPConfiguration?

    @State private var lexiconPaste = ""
    @State private var lexiconSearch = ""
    @State private var newLexiconTerm = ""
    @State private var editingLexiconTerm: String?
    @State private var editingLexiconDraft = ""
    @State private var editingCorrectionRule: CorrectionRule?
    @State private var correctionWrongDraft = ""
    @State private var correctionRightDraft = ""
    @State private var lexiconMessage: String?
    @State private var isConfirmingLexiconClear = false

    @State private var storageMessage: String?
    @State private var isMigratingStorage = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsSection.allCases, selection: $selectedSection) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
                Divider()
                Text(appVersionText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 10)
            }
            .navigationTitle("设置")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            detail
                .navigationTitle(selectedSection?.rawValue ?? "设置")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") {
                            router.closeSettings()
                        }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isMigratingStorage)
                    }
                }
        }
        .onAppear {
            aiConfiguration = environment.aiProviderConfigurationStore.load()
            diarizationConfiguration = environment.diarizationProviderConfigurationStore.load()
            reloadMCPConfigurations()
        }
        .confirmationDialog(
            "删除这个 MCP 连接？",
            isPresented: Binding(
                get: { pendingMCPDeletion != nil },
                set: { if !$0 { pendingMCPDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除连接和凭证", role: .destructive) {
                if let configuration = pendingMCPDeletion {
                    deleteMCP(configuration)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("历史项目中已经保存的来源结果不会被删除。")
        }
        .confirmationDialog(
            "清空专业词库？",
            isPresented: $isConfirmingLexiconClear,
            titleVisibility: .visible
        ) {
            Button("清空词库", role: .destructive) {
                clearLexicon()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("纠错规则会保留；已完成的文稿不会改变。")
        }
        .confirmationDialog(
            "删除 OpenAI 兼容连接？",
            isPresented: $isConfirmingCustomAIDeletion,
            titleVisibility: .visible
        ) {
            Button("删除并切回 Kimi", role: .destructive) {
                deleteCustomAIConfiguration()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Base URL、Model ID 和独立 API Key 会被删除；正在执行的请求不会中断。")
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "帮我分析 v\(version) (\(build))"
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedSection ?? .ai {
        case .ai:
            Form {
                activeAIProviderSection
                if aiConfiguration.selectedProvider == .kimi {
                    kimiConfigurationSection
                } else {
                    openAICompatibleSection
                }
                Section("提示词") {
                    LabeledContent("当前版本", value: PromptRegistry.version)
                    Text("实时分析、完整总结、项目对话和开花使用统一安全规则。普通设置不开放原始提示词编辑。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .knowledge:
            Form {
                builtInKnowledgeSection
                mcpConnectionsSection
                mcpEditorSection
            }
            .formStyle(.grouped)
        case .lexicon:
            Form {
                lexiconManagementSection
                correctionRulesSection
            }
            .formStyle(.grouped)
        case .people:
            HistoricalPeopleLibraryView()
        case .recording:
            Form {
                diarizationProviderSection
                if diarizationConfiguration.selectedProvider == .openAICompatible {
                    diarizationOpenAIConfigurationSection
                    keySection(
                        provider: .diarization,
                        title: "高精度转写与说话人 API Key（OpenAI 兼容）",
                        input: $diarizationKeyInput,
                        footnote: "凭证只供当前分人 provider 使用，不会借给 Kimi 或其他服务。"
                    )
                } else if diarizationConfiguration.selectedProvider == .volcengine {
                    diarizationVolcengineConfigurationSection
                } else if diarizationConfiguration.selectedProvider == .iflytek {
                    diarizationIFlytekConfigurationSection
                }
                Section("当前能力") {
                    LabeledContent("本地实时转写", value: "Apple Speech · 始终启用")
                    LabeledContent("云端增强", value: diarizationConfiguration.selectedProvider.displayName)
                    Text("设置变更从下一次会议生效；正在录音或恢复中的队列继续使用会议开始时冻结的配置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("专业词条在下一次录音或导入时进入 Apple Speech 上下文；录音中不会重启转写。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .storage:
            Form {
                storageSection
                privacySection
            }
            .formStyle(.grouped)
        }
    }

    private var diarizationProviderSection: some View {
        Section("云端高精度转写与分人") {
            Picker("Provider", selection: $diarizationConfiguration.selectedProvider) {
                ForEach(DiarizationProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName)
                        .tag(provider)
                }
            }
            .pickerStyle(.segmented)
            Button("保存默认 Provider") {
                saveDiarizationConfiguration()
            }
            if let diarizationMessage {
                statusText(diarizationMessage)
            }
            Text("关闭云端增强不会关闭本地录音和 Apple Speech。Provider 变更只影响下一次会议，待处理分片不会静默改投其他服务。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var diarizationOpenAIConfigurationSection: some View {
        Section("OpenAI 兼容配置") {
            TextField(
                "Base URL，例如 https://api.openai.com/v1",
                text: $diarizationConfiguration.openAIBaseURL
            )
            .textFieldStyle(.roundedBorder)
            TextField("Model ID", text: $diarizationConfiguration.openAIModelID)
                .textFieldStyle(.roundedBorder)
            Button("保存非敏感配置") {
                saveDiarizationConfiguration()
            }
            Text("仅允许 HTTPS；本机服务可使用 localhost。音频分片会发送到该服务，高精度结果用于校正文稿和匿名说话人分离。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var diarizationVolcengineConfigurationSection: some View {
        let keyStore = environment.volcengineDiarizationKeyStore
        let hasSavedKey = keyStore.hasConfiguredKey
        let hasSavedAccessToken = environment.volcengineDiarizationAccessTokenStore.hasConfiguredKey
        return Section("火山引擎录音文件极速识别") {
            TextField(
                "Resource ID",
                text: $diarizationConfiguration.volcengineResourceID
            )
            .textFieldStyle(.roundedBorder)
            .disabled(true)
            SecureField(
                hasSavedKey
                    ? "API Key / App Key 已保存；粘贴可替换"
                    : "粘贴 API Key / App Key",
                text: $volcengineKeyInput
            )
            .textFieldStyle(.roundedBorder)
            SecureField(
                hasSavedAccessToken
                    ? "Access Token 已保存；粘贴可替换"
                    : "粘贴 Access Token（服务接口认证）",
                text: $volcengineAccessTokenInput
            )
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存") {
                    saveVolcengineConfiguration()
                }
                Button(isTestingVolcengine ? "测试中…" : "保存并测试") {
                    saveAndTestVolcengine()
                }
                .disabled(
                    isTestingVolcengine
                        || (!hasSavedKey
                            && volcengineKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
                Button("删除已保存的凭据", role: .destructive) {
                    deleteVolcengineKey()
                }
                .disabled(!hasSavedKey && !hasSavedAccessToken)
                Spacer()
                configurationBadge(
                    configured: diarizationConfiguration.isValid && hasSavedKey
                )
            }
            if hasSavedKey {
                Label(
                    hasSavedAccessToken
                        ? "API Key 与 Access Token 已明文保存在本机配置中，此处不会回显。"
                        : "API Key 已明文保存在本机配置中，此处不会回显。",
                    systemImage: "checkmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let result = volcengineTestResult {
                statusText(result.text)
            }
            Text("支持新版单 API Key 鉴权；填写 Access Token 后自动使用服务接口双凭据鉴权。Secret Key 不用于此接口。Resource ID 固定为极速版。连接测试只发送约 0.1 秒合成静音，不发送项目、录音或逐字稿。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var diarizationIFlytekConfigurationSection: some View {
        let hasSavedCredentials = environment.iflytekCredentialStore.hasConfiguredKey
        return Section("讯飞录音文件转写大模型") {
            TextField("APPID", text: $diarizationConfiguration.iflytekAppID)
                .textFieldStyle(.roundedBorder)
            SecureField(
                hasSavedCredentials ? "APIKey 已保存；粘贴可替换" : "APIKey",
                text: $iflytekAccessKeyIDInput
            )
            .textFieldStyle(.roundedBorder)
            SecureField(
                hasSavedCredentials ? "APISecret 已保存；粘贴可替换" : "APISecret",
                text: $iflytekAccessKeySecretInput
            )
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存") {
                    saveIFlytekConfiguration()
                }
                Button(isTestingIFlytek ? "测试中…" : "保存并测试") {
                    saveAndTestIFlytek()
                }
                .disabled(
                    isTestingIFlytek
                        || (!hasSavedCredentials
                            && (iflytekAccessKeyIDInput.isEmpty
                                || iflytekAccessKeySecretInput.isEmpty))
                )
                Button("删除已保存的凭据", role: .destructive) {
                    deleteIFlytekCredentials()
                }
                .disabled(!hasSavedCredentials)
                Spacer()
                configurationBadge(
                    configured: diarizationConfiguration.isValid && hasSavedCredentials
                )
            }
            if hasSavedCredentials {
                Label(
                    "APIKey 和 APISecret 已明文保存在本机配置中，此处不会回显。",
                    systemImage: "checkmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let result = iflytekTestResult {
                statusText(result.text)
            }
            Text("连接测试只用随机无效订单号验证鉴权，不上传项目、录音或逐字稿。历史人物还需在人物库用 10 秒样本注册讯飞声纹。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var activeAIProviderSection: some View {
        Section("当前分析模型") {
            Picker("Provider", selection: $aiConfiguration.selectedProvider) {
                ForEach(AIProviderKind.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: aiConfiguration.selectedProvider) { _, provider in
                if provider == .kimi || aiConfiguration.isOpenAIConfigurationValid {
                    _ = saveAIConfiguration(saveKey: false)
                } else {
                    aiMessage = "请填写 Base URL 和 Model ID 后保存；当前请求仍使用原模型。"
                }
            }
            // LabeledContent 会把长值挤到右侧贴边截断，窄窗口读不全，改为上下两行
            VStack(alignment: .leading, spacing: 3) {
                Text("生效范围")
                    .foregroundStyle(.secondary)
                Text("实时分析 · 完整总结 · 项目对话 · 开花（把选中内容展开成延伸知识）")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("修改从下一次 AI 请求开始生效；正在执行的请求不会被中断或切换模型。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let aiMessage {
                statusText(aiMessage)
            }
        }
    }

    private var kimiConfigurationSection: some View {
        let hasFallbackKey = environment.isConfigured(.analysis)
        return Section("Kimi 配置") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kimi 账号")
                    Text(
                        isKimiLoggedIn
                            ? "登录成功，后续请求会自动刷新凭证。"
                            : "登录后即可使用实时分析、完整总结、项目对话和开花。"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                configurationBadge(
                    configured: isKimiLoggedIn,
                    configuredText: "已连接",
                    unconfiguredText: "未连接"
                )
            }
            switch login?.phase {
            case .starting:
                Text("正在发起授权…").foregroundStyle(.secondary)
            case .waitingApproval(let userCode):
                VStack(alignment: .leading, spacing: 6) {
                    Text("已在浏览器打开授权页，请确认后回到本页。")
                    Text("确认码 \(userCode)")
                        .font(.title3.monospaced().bold())
                        .textSelection(.enabled)
                }
            case .failed(let message):
                statusText(message)
            default:
                EmptyView()
            }
            HStack {
                Button(isKimiLoggedIn ? "重新登录" : "登录 Kimi 账号") {
                    ensureLoginController().begin()
                }
                if isKimiLoggedIn {
                    Button("退出登录") {
                        ensureLoginController().logout()
                    }
                }
                Spacer()
                Button(testingProvider == .analysis ? "测试中…" : "测试连接") {
                    runConnectionTest(provider: .analysis)
                }
                .disabled(testingProvider != nil || !canTestConnection(.analysis))
            }
            if let result = testResults[.analysis] {
                statusText(result.text)
            }
            Text("登录凭证保存在本机配置中，不再使用系统钥匙串。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Divider()

            Picker(
                "优先模型",
                selection: $aiConfiguration.kimiModel
            ) {
                ForEach(KimiModelPreference.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .onChange(of: aiConfiguration.kimiModel) { _, _ in
                _ = saveAIConfiguration(saveKey: false)
            }
            LabeledContent(
                "当前 Model ID",
                value: aiConfiguration.kimiModel.modelID
            )
            Text("默认使用 Kimi K3 256K；K3 需要相应会员权限，连接失败时不会静默切换模型。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Divider()

            DisclosureGroup(isExpanded: $isShowingKimiFallbackKey) {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField(
                        hasFallbackKey
                            ? "Key 已保存；粘贴新 Key 可替换"
                            : "粘贴 API Key（将明文保存在本机）",
                        text: $analysisKeyInput
                    )
                    .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存到本机") {
                            saveKey(provider: .analysis, rawValue: analysisKeyInput)
                        }
                        .disabled(
                            analysisKeyInput
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                        Button("删除已保存的 Key") {
                            deleteKey(provider: .analysis)
                        }
                        .disabled(!hasFallbackKey)
                    }
                    if hasFallbackKey {
                        Label(
                            "已明文保存在本机配置中，重开 App 无需再次输入；此处不会回显原 Key。",
                            systemImage: "checkmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Text(
                        isKimiLoggedIn
                            ? "账号已连接，正常请求不会使用备用 Key。"
                            : "账号授权不可用时，可以改用 API Key。"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } label: {
                HStack {
                    Text("备用 API Key")
                    Spacer()
                    configurationBadge(
                        configured: hasFallbackKey,
                        configuredText: "已保存",
                        unconfiguredText: "未设置"
                    )
                }
            }
        }
    }

    private var openAICompatibleSection: some View {
        let hasSavedKey = environment.openAICompatibleKeyStore.hasConfiguredKey
        return Section("OpenAI 兼容连接") {
            TextField("Base URL，例如 https://api.openai.com/v1", text: $aiConfiguration.openAIBaseURL)
                .textFieldStyle(.roundedBorder)
            TextField("Model ID", text: $aiConfiguration.openAIModelID)
                .textFieldStyle(.roundedBorder)
            SecureField(
                hasSavedKey
                    ? "Key 已保存；粘贴新 Key 可替换"
                    : "粘贴 API Key",
                text: $openAIKeyInput
            )
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存") {
                    saveAIConfiguration(saveKey: true)
                }
                Button(isTestingAI ? "测试中…" : "保存并测试") {
                    saveAndTestAI()
                }
                .disabled(isTestingAI)
                Button("删除自定义连接", role: .destructive) {
                    isConfirmingCustomAIDeletion = true
                }
                Spacer()
                configurationBadge(
                    configured: aiConfiguration.isOpenAIConfigurationValid
                        && hasSavedKey
                )
            }
            if hasSavedKey {
                Label(
                    "Key 已明文保存在本机配置中，重开 App 无需再次输入；此处不会回显原 Key。",
                    systemImage: "checkmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Text("仅允许 HTTPS；本机服务可使用 localhost。连接测试不发送项目、逐字稿或笔记。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var builtInKnowledgeSection: some View {
        Section("内置知识来源") {
            LabeledContent(
                "Obsidian",
                value: environment.obsidianVaultURL == nil ? "未连接" : "已连接"
            )
            LabeledContent("互联网", value: "已启用 · 中文维基百科")
            Text("外部 MCP 只接收最长 24 字的知识检索词，不接收完整逐字稿、录音、笔记正文或整个 Vault。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var mcpConnectionsSection: some View {
        Section("外部 MCP 连接") {
            if mcpConfigurations.isEmpty {
                ContentUnavailableView(
                    "还没有 MCP 连接",
                    systemImage: "link.badge.plus",
                    description: Text("添加得到大脑或其他只读知识搜索 MCP。")
                )
            } else {
                ForEach(mcpConfigurations) { configuration in
                    HStack(spacing: 10) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { configuration.isEnabled },
                                set: { setMCPEnabled(configuration, enabled: $0) }
                            )
                        )
                        .labelsHidden()
                        .disabled(!configuration.isReadOnlyToolVerified)
                        .accessibilityLabel("启用 \(configuration.normalizedDisplayName)")
                        .accessibilityValue(configuration.isEnabled ? "已启用" : "已停用")
                        .help(
                            configuration.isReadOnlyToolVerified
                                ? "控制该知识来源是否参与下一次开花"
                                : "测试并确认只读工具后才能启用"
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(configuration.normalizedDisplayName)
                                .fontWeight(.medium)
                            Text(configuration.endpoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !configuration.isReadOnlyToolVerified {
                                Text("需测试并选择只读工具")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("编辑") {
                            selectMCP(configuration)
                        }
                        Button(role: .destructive) {
                            pendingMCPDeletion = configuration
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除 \(configuration.normalizedDisplayName)")
                    }
                }
            }
            Button {
                beginNewMCP()
            } label: {
                Label("新增 MCP", systemImage: "plus")
            }
        }
    }

    private var mcpEditorSection: some View {
        Section(selectedMCPID == nil ? "新增连接" : "编辑连接") {
            TextField("来源名称，例如：得到大脑", text: $mcpDraft.displayName)
                .textFieldStyle(.roundedBorder)
            TextField("Streamable HTTP MCP 地址", text: $mcpDraft.endpoint)
                .textFieldStyle(.roundedBorder)
            if !discoveredMCPTools.isEmpty {
                Picker("只读知识工具", selection: $mcpDraft.toolName) {
                    Text("请选择").tag("")
                    ForEach(discoveredMCPTools, id: \.self) { Text($0).tag($0) }
                }
            } else {
                TextField("只读知识工具名（测试连接后自动发现）", text: $mcpDraft.toolName)
                    .textFieldStyle(.roundedBorder)
            }
            SecureField("Bearer Token（留空表示保留已保存的 Token）", text: $mcpTokenInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存") {
                    saveMCPDraft()
                }
                .disabled(mcpDraft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(isTestingMCP ? "测试中…" : "保存并测试") {
                    testMCPDraft()
                }
                .disabled(
                    isTestingMCP
                        || mcpDraft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                Spacer()
            }
            if let mcpMessage {
                statusText(mcpMessage)
            }
        }
    }

    private var lexiconManagementSection: some View {
        Section("专业词库") {
            HStack {
                TextField("新增词条", text: $newLexiconTerm)
                Button("新增") {
                    do {
                        try environment.addLexiconTerm(newLexiconTerm)
                        newLexiconTerm = ""
                        lexiconMessage = "词条已新增；下一次录音或导入生效。"
                    } catch {
                        lexiconMessage = "新增失败：\(error.localizedDescription)"
                    }
                }
                .disabled(newLexiconTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("搜索 \(environment.lexiconTerms.count) 个词条", text: $lexiconSearch)
                .textFieldStyle(.roundedBorder)
            ForEach(filteredLexiconTerms, id: \.self) { term in
                HStack {
                    if editingLexiconTerm == term {
                        TextField("词条", text: $editingLexiconDraft)
                        Button("保存") {
                            updateLexiconTerm(term)
                        }
                        Button("取消") {
                            editingLexiconTerm = nil
                        }
                    } else {
                        Text(term)
                        Spacer()
                        Button("编辑") {
                            editingLexiconTerm = term
                            editingLexiconDraft = term
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            removeLexiconTerm(term)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除词条 \(term)")
                    }
                }
            }
            HStack {
                Button("从文件导入…") { importLexiconFromFile() }
                Button("导出词库…") { exportLexicon() }
                    .disabled(environment.lexiconTerms.isEmpty)
                Button("清空词库", role: .destructive) {
                    isConfirmingLexiconClear = true
                }
                .disabled(environment.lexiconTerms.isEmpty)
            }
            TextField(
                "批量粘贴（每行一个，兼容顿号和逗号）",
                text: $lexiconPaste,
                axis: .vertical
            )
            .lineLimit(2...4)
            HStack {
                Button("导入粘贴内容") {
                    importLexicon(text: lexiconPaste)
                    lexiconPaste = ""
                }
                .disabled(lexiconPaste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let lexiconMessage {
                    statusText(lexiconMessage)
                }
            }
            Text("专业词条只在下一次录音或导入时进入识别上下文；不会在录音中重启 Apple Speech。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var correctionRulesSection: some View {
        Section("纠错规则") {
            if environment.correctionRules.isEmpty {
                Text("还没有纠错规则。可在工作台文稿中使用右键“纠错”创建。")
                    .foregroundStyle(.secondary)
            }
            ForEach(environment.correctionRules) { rule in
                HStack {
                    if editingCorrectionRule?.id == rule.id {
                        TextField("错词", text: $correctionWrongDraft)
                        Text("→")
                        TextField("正词", text: $correctionRightDraft)
                        Button("保存") { updateCorrectionRule(rule) }
                        Button("取消") { editingCorrectionRule = nil }
                    } else {
                        Text("\(rule.wrong) → \(rule.right)")
                        Spacer()
                        Button("编辑") {
                            editingCorrectionRule = rule
                            correctionWrongDraft = rule.wrong
                            correctionRightDraft = rule.right
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            removeCorrectionRule(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除纠错规则 \(rule.wrong) 到 \(rule.right)")
                    }
                }
            }
            Text("纠错规则保存后会作用于当前录音后续产生的最终片段；不会自动改写已经完成的历史文稿。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        Section("存储位置") {
            LabeledContent("当前目录") {
                Text(displayedStoragePath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            HStack {
                Button(
                    environment.obsidianVaultURL == nil
                        ? "选择 Obsidian Vault…"
                        : "重新选择 Obsidian Vault…"
                ) {
                    chooseObsidianVault()
                }
                .disabled(isMigratingStorage || environment.isStorageChangeBlocked)
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [environment.fileStore.baseDirectory]
                    )
                }
                if isMigratingStorage {
                    ProgressView().controlSize(.small)
                    Text("正在复制并校验现有数据…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if environment.isStorageChangeBlocked {
                Text("录音、导入或收尾进行中，暂时不能切换存储位置。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let storageMessage {
                statusText(storageMessage)
            } else if let storageWarning = environment.storageWarning {
                statusText(storageWarning)
            }
            Text("选择 Vault 根目录后，应用在其中使用“帮我分析”子文件夹。切换会先复制并校验，旧目录保留。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var privacySection: some View {
        Section("隐私说明") {
            Text("录音前请确认参与者已知晓并同意。说话人识别会按需发送音频分片；AI 分析会发送转写文本。")
            Text("在项目中开启“允许上传笔记给 AI”后，项目对话和开花会把请求发起时的最新笔记交给当前分析模型；外部知识源只接收短检索词，完整总结仍不读取笔记。")
            Text("登录凭证、模型 Key 和每个 MCP Token 分别明文保存在本机配置中，不写入项目、日志或 Markdown；拥有当前 macOS 账户文件访问权限的人可能读取它们。")
            Text("MCP 只能调用已经验证的只读知识检索工具。")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var filteredLexiconTerms: [String] {
        let query = lexiconSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return environment.lexiconTerms }
        return environment.lexiconTerms.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    @discardableResult
    private func saveAIConfiguration(saveKey: Bool) -> Bool {
        do {
            try environment.aiProviderConfigurationStore.save(aiConfiguration)
            if saveKey {
                let key = openAIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    try environment.openAICompatibleKeyStore.saveKey(key)
                    openAIKeyInput = ""
                }
            }
            environment.refreshCloudConfiguration()
            aiMessage = "已保存；从下一次 AI 请求开始生效。"
            return true
        } catch {
            aiMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func saveAndTestAI() {
        guard saveAIConfiguration(saveKey: true) else { return }
        guard environment.aiProviderConfigurationStore.load().selectedProvider
                == .openAICompatible,
              environment.isAnalysisConfigured else {
            aiMessage = "请先保存有效配置和 API Key。"
            return
        }
        isTestingAI = true
        Task { @MainActor in
            defer { isTestingAI = false }
            do {
                let descriptor = try await environment.aiProviderRegistry.testActiveConnection()
                aiMessage = "连接正常：\(descriptor.displayName) · \(descriptor.modelID)"
            } catch {
                aiMessage = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    private func deleteCustomAIConfiguration() {
        do {
            try environment.openAICompatibleKeyStore.deleteKey()
            try environment.aiProviderConfigurationStore.selectKimiAndClearCustomConfiguration()
            aiConfiguration = environment.aiProviderConfigurationStore.load()
            openAIKeyInput = ""
            environment.refreshCloudConfiguration()
            aiMessage = "已删除自定义连接并切回 Kimi。"
        } catch {
            aiMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func reloadMCPConfigurations() {
        mcpConfigurations = environment.externalMCPConfigurationStore.loadAll()
        if let selectedMCPID,
           let selected = mcpConfigurations.first(where: { $0.id == selectedMCPID }) {
            mcpDraft = selected
        } else if let first = mcpConfigurations.first {
            selectMCP(first)
        } else {
            beginNewMCP()
        }
    }

    private func beginNewMCP() {
        selectedMCPID = nil
        mcpDraft = ExternalMCPConfiguration()
        mcpTokenInput = ""
        mcpMessage = nil
        discoveredMCPTools = []
    }

    private func selectMCP(_ configuration: ExternalMCPConfiguration) {
        selectedMCPID = configuration.id
        mcpDraft = configuration
        mcpTokenInput = ""
        mcpMessage = nil
        discoveredMCPTools = configuration.toolName.isEmpty
            ? []
            : [configuration.toolName]
    }

    private func saveMCPDraft() {
        do {
            let saved = mcpDraftInvalidatingChangedConnection()
            try environment.externalMCPConfigurationStore.save(saved)
            let token = mcpTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                try environment.externalMCPTokenStore(for: saved).saveKey(token)
                mcpTokenInput = ""
            }
            mcpDraft = saved
            selectedMCPID = saved.id
            reloadMCPConfigurations()
            mcpMessage = saved.isReadOnlyToolVerified
                ? "已保存；下一次开花开始使用。"
                : "连接已保存但保持停用；请先测试并确认只读工具。"
        } catch {
            mcpMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func testMCPDraft() {
        guard mcpDraft.validatedURL != nil else {
            mcpMessage = "请输入有效的 HTTPS（或本机 localhost）地址。"
            return
        }
        do {
            mcpDraft = mcpDraftInvalidatingChangedConnection()
            try environment.externalMCPConfigurationStore.save(mcpDraft)
            selectedMCPID = mcpDraft.id
            let token = mcpTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                try environment.externalMCPTokenStore(for: mcpDraft).saveKey(token)
                mcpTokenInput = ""
            }
        } catch {
            mcpMessage = "连接保存失败：\(error.localizedDescription)"
            return
        }
        isTestingMCP = true
        mcpMessage = nil
        let provider = ExternalMCPKnowledgeProvider(
            configuration: mcpDraft,
            tokenStore: environment.externalMCPTokenStore(for: mcpDraft)
        )
        Task { @MainActor in
            defer { isTestingMCP = false }
            do {
                let tools = try await provider.discoverReadOnlyToolNames()
                guard !tools.isEmpty else {
                    mcpDraft.isEnabled = false
                    mcpDraft.verifiedReadOnlyToolName = nil
                    try environment.externalMCPConfigurationStore.save(mcpDraft)
                    reloadMCPConfigurations()
                    mcpMessage = "连接成功，但没有找到只读知识搜索工具。"
                    return
                }
                discoveredMCPTools = tools
                if tools.count == 1 {
                    mcpDraft.toolName = tools[0]
                    mcpDraft.verifiedReadOnlyToolName = tools[0]
                    mcpDraft.isEnabled = true
                    try environment.externalMCPConfigurationStore.save(mcpDraft)
                    selectedMCPID = mcpDraft.id
                    reloadMCPConfigurations()
                    let health = await ExternalMCPKnowledgeProvider(
                        configuration: mcpDraft,
                        tokenStore: environment.externalMCPTokenStore(for: mcpDraft)
                    ).healthCheck()
                    mcpMessage = health.isAvailable
                        ? "连接正常：\(health.message)"
                        : "连接失败：\(health.message)"
                } else if tools.contains(mcpDraft.toolName) {
                    mcpDraft.verifiedReadOnlyToolName = mcpDraft.toolName
                    mcpDraft.isEnabled = true
                    try environment.externalMCPConfigurationStore.save(mcpDraft)
                    selectedMCPID = mcpDraft.id
                    reloadMCPConfigurations()
                    mcpMessage = "发现 \(tools.count) 个只读工具；当前选择已验证并启用。"
                } else {
                    mcpDraft.toolName = ""
                    mcpDraft.isEnabled = false
                    mcpDraft.verifiedReadOnlyToolName = nil
                    try environment.externalMCPConfigurationStore.save(mcpDraft)
                    selectedMCPID = mcpDraft.id
                    reloadMCPConfigurations()
                    mcpMessage = "发现 \(tools.count) 个只读工具，请选择后再次测试。"
                }
            } catch {
                mcpMessage = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    private func mcpDraftInvalidatingChangedConnection() -> ExternalMCPConfiguration {
        var saved = mcpDraft
        let original = mcpConfigurations.first { $0.id == saved.id }
        let endpointChanged = original.map {
            $0.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                != saved.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? false
        if endpointChanged || saved.verifiedReadOnlyToolName != saved.toolName {
            saved.verifiedReadOnlyToolName = nil
            saved.isEnabled = false
        }
        return saved
    }

    private func setMCPEnabled(
        _ configuration: ExternalMCPConfiguration,
        enabled: Bool
    ) {
        if enabled, !configuration.isReadOnlyToolVerified {
            selectMCP(configuration)
            mcpMessage = "请先测试连接并确认只读知识工具。"
            return
        }
        var updated = configuration
        updated.isEnabled = enabled
        do {
            try environment.externalMCPConfigurationStore.save(updated)
            reloadMCPConfigurations()
        } catch {
            mcpMessage = "更新失败：\(error.localizedDescription)"
        }
    }

    private func deleteMCP(_ configuration: ExternalMCPConfiguration) {
        do {
            try environment.externalMCPTokenStore(for: configuration).deleteKey()
            environment.externalMCPConfigurationStore.remove(id: configuration.id)
            pendingMCPDeletion = nil
            beginNewMCP()
            reloadMCPConfigurations()
            mcpMessage = "已删除连接；历史来源结果仍保留。"
        } catch {
            mcpMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func updateLexiconTerm(_ term: String) {
        guard !editingLexiconDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            lexiconMessage = "词条不能为空。"
            return
        }
        do {
            try environment.updateLexiconTerm(term, to: editingLexiconDraft)
            editingLexiconTerm = nil
            lexiconMessage = "词条已更新；下一次录音或导入生效。"
        } catch {
            // 冲突等情况保持编辑态，让用户直接改回去，不丢输入
            lexiconMessage = "更新失败：\(error.localizedDescription)"
        }
    }

    private func updateCorrectionRule(_ rule: CorrectionRule) {
        guard TranscriptCorrector.isValidRule(
            wrong: correctionWrongDraft,
            right: correctionRightDraft
        ) else {
            lexiconMessage = "纠错规则无效，请填写不同的错词和正词。"
            return
        }
        do {
            try environment.updateCorrectionRule(
                rule,
                wrong: correctionWrongDraft,
                right: correctionRightDraft
            )
            editingCorrectionRule = nil
            lexiconMessage = "纠错规则已更新。"
        } catch {
            lexiconMessage = "更新失败：\(error.localizedDescription)"
        }
    }

    private func removeLexiconTerm(_ term: String) {
        do {
            try environment.removeLexiconTerm(term)
            lexiconMessage = "词条已删除；下一次录音或导入生效。"
        } catch {
            lexiconMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func clearLexicon() {
        do {
            try environment.clearLexicon()
            lexiconMessage = "已清空词库。"
        } catch {
            lexiconMessage = "清空失败：\(error.localizedDescription)"
        }
    }

    private func removeCorrectionRule(_ rule: CorrectionRule) {
        do {
            try environment.removeCorrectionRule(rule)
            lexiconMessage = "纠错规则已删除。"
        } catch {
            lexiconMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func importLexiconFromFile() {
        let panel = NSOpenPanel()
        panel.title = "导入词库"
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lexiconMessage = "文件读取失败（需为 UTF-8 文本）。"
            return
        }
        importLexicon(text: text)
    }

    private func importLexicon(text: String) {
        do {
            let added = try environment.importLexicon(text: text)
            lexiconMessage = added > 0
                ? "新增 \(added) 个词条；下一次录音或导入生效。"
                : "没有新词条。"
        } catch {
            lexiconMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func exportLexicon() {
        let panel = NSSavePanel()
        panel.title = "导出词库"
        panel.nameFieldStringValue = "帮我分析-专业词库.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try environment.lexiconTerms.joined(separator: "\n")
                .write(to: url, atomically: true, encoding: .utf8)
            lexiconMessage = "词库已导出。"
        } catch {
            lexiconMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func ensureLoginController() -> KimiLoginController {
        if let login { return login }
        let controller = KimiLoginController(
            tokenStore: environment.kimiOAuthTokenStore,
            openURL: { url in NSWorkspace.shared.open(url) }
        )
        controller.onLoginStateChanged = { [weak environment] in
            environment?.refreshCloudConfiguration()
        }
        login = controller
        return controller
    }

    private var isKimiLoggedIn: Bool {
        environment.isKimiAccountConnected
    }

    private func keySection(
        provider: CloudProvider,
        title: String,
        input: Binding<String>,
        footnote: String
    ) -> some View {
        let hasSavedKey = environment.isConfigured(provider)
        return Section(provider.displayName) {
            HStack {
                Text(title)
                Spacer()
                configurationBadge(configured: hasSavedKey)
            }
            SecureField(
                hasSavedKey
                    ? "Key 已保存；粘贴新 Key 可替换"
                    : "粘贴 API Key（将明文保存在本机）",
                text: input
            )
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存到本机") {
                    saveKey(provider: provider, rawValue: input.wrappedValue)
                }
                .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("删除已保存的 Key") {
                    deleteKey(provider: provider)
                }
                .disabled(!hasSavedKey)
                Spacer()
                Button(testingProvider == provider ? "测试中…" : "连接测试") {
                    runConnectionTest(provider: provider)
                }
                .disabled(testingProvider != nil || !canTestConnection(provider))
            }
            if hasSavedKey {
                Label(
                    "已明文保存在本机配置中，重开 App 无需再次输入；此处不会回显原 Key。",
                    systemImage: "checkmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let result = testResults[provider] {
                statusText(result.text)
            }
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func configurationBadge(
        configured: Bool,
        configuredText: String = "已配置",
        unconfiguredText: String = "未配置"
    ) -> some View {
        Text(configured ? configuredText : unconfiguredText)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (configured ? Color.green : Color.gray).opacity(0.18),
                in: Capsule()
            )
    }

    private func saveKey(provider: CloudProvider, rawValue: String) {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try environment.keyStore(for: provider).saveKey(key)
            environment.refreshCloudConfiguration()
            switch provider {
            case .analysis: analysisKeyInput = ""
            case .diarization: diarizationKeyInput = ""
            }
            testResults[provider] = (true, "已保存到本机配置。")
        } catch {
            testResults[provider] = (false, "保存失败：\(error.localizedDescription)")
        }
    }

    private func saveDiarizationConfiguration() {
        do {
            try environment.diarizationProviderConfigurationStore.save(diarizationConfiguration)
            environment.refreshCloudConfiguration()
            diarizationMessage = "已保存；从下一次会议开始生效。"
        } catch {
            diarizationMessage = "保存失败：\(error.localizedDescription)"
            diarizationConfiguration = environment.diarizationProviderConfigurationStore.load()
        }
    }

    private func saveVolcengineConfiguration() {
        do {
            try environment.diarizationProviderConfigurationStore.save(diarizationConfiguration)
            let key = volcengineKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                try environment.volcengineDiarizationKeyStore.saveKey(key)
                volcengineKeyInput = ""
            }
            let accessToken = volcengineAccessTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !accessToken.isEmpty {
                try environment.volcengineDiarizationAccessTokenStore.saveKey(accessToken)
                volcengineAccessTokenInput = ""
            }
            environment.refreshCloudConfiguration()
            volcengineTestResult = (true, "已保存；从下一次会议开始生效。")
        } catch {
            volcengineTestResult = (false, "保存失败：\(error.localizedDescription)")
        }
    }

    private func deleteVolcengineKey() {
        do {
            try environment.volcengineDiarizationKeyStore.deleteKey()
            try environment.volcengineDiarizationAccessTokenStore.deleteKey()
            environment.refreshCloudConfiguration()
            volcengineTestResult = (true, "已删除火山引擎认证凭据。")
        } catch {
            volcengineTestResult = (false, "删除失败：\(error.localizedDescription)")
        }
    }

    private func saveAndTestVolcengine() {
        guard !isTestingVolcengine else { return }
        saveVolcengineConfiguration()
        guard diarizationConfiguration.isValid,
              environment.volcengineDiarizationKeyStore.hasConfiguredKey else { return }
        isTestingVolcengine = true
        volcengineTestResult = nil
        Task { @MainActor in
            defer { isTestingVolcengine = false }
            do {
                let ok = try await environment.makeDiarizationService(
                    for: diarizationConfiguration
                ).testConnection()
                volcengineTestResult = ok
                    ? (true, "连接正常（火山引擎可用）")
                    : (false, "连接失败")
            } catch {
                volcengineTestResult = (false, "不可用：\(error.localizedDescription)")
            }
        }
    }

    private func saveIFlytekConfiguration() {
        do {
            try environment.diarizationProviderConfigurationStore.save(diarizationConfiguration)
            let accessKeyID = iflytekAccessKeyIDInput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let accessKeySecret = iflytekAccessKeySecretInput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !accessKeyID.isEmpty || !accessKeySecret.isEmpty {
                guard !accessKeyID.isEmpty, !accessKeySecret.isEmpty else {
                    throw DiarizationAPIError.providerError(
                        code: "local",
                        message: "APIKey 和 APISecret 需要同时填写"
                    )
                }
                try IFlytekCredentials(
                    accessKeyID: accessKeyID,
                    accessKeySecret: accessKeySecret
                ).save(to: environment.iflytekCredentialStore)
                iflytekAccessKeyIDInput = ""
                iflytekAccessKeySecretInput = ""
            }
            environment.refreshCloudConfiguration()
            iflytekTestResult = (true, "已保存；从下一次会议开始生效。")
        } catch {
            iflytekTestResult = (false, "保存失败：\(error.localizedDescription)")
        }
    }

    private func saveAndTestIFlytek() {
        guard !isTestingIFlytek else { return }
        saveIFlytekConfiguration()
        guard diarizationConfiguration.isValid,
              environment.iflytekCredentialStore.hasConfiguredKey else { return }
        isTestingIFlytek = true
        iflytekTestResult = nil
        Task { @MainActor in
            defer { isTestingIFlytek = false }
            do {
                let ok = try await environment.makeDiarizationService(
                    for: diarizationConfiguration
                ).testConnection()
                iflytekTestResult = ok
                    ? (true, "连接正常（讯飞转写鉴权可用）")
                    : (false, "连接失败")
            } catch {
                iflytekTestResult = (false, "不可用：\(error.localizedDescription)")
            }
        }
    }

    private func deleteIFlytekCredentials() {
        do {
            try environment.iflytekCredentialStore.deleteKey()
            environment.refreshCloudConfiguration()
            iflytekTestResult = (true, "已删除讯飞认证凭据。")
        } catch {
            iflytekTestResult = (false, "删除失败：\(error.localizedDescription)")
        }
    }

    private func deleteKey(provider: CloudProvider) {
        do {
            try environment.keyStore(for: provider).deleteKey()
            environment.refreshCloudConfiguration()
            testResults[provider] = (true, "已删除。")
        } catch {
            testResults[provider] = (false, "删除失败：\(error.localizedDescription)")
        }
    }

    private func canTestConnection(_ provider: CloudProvider) -> Bool {
        switch provider {
        case .analysis:
            return aiConfiguration.selectedProvider == .kimi
                && (environment.isConfigured(.analysis) || isKimiLoggedIn)
        case .diarization:
            return environment.isConfigured(provider)
        }
    }

    private func runConnectionTest(provider: CloudProvider) {
        guard testingProvider == nil else { return }
        testingProvider = provider
        testResults[provider] = nil
        Task { @MainActor in
            defer { testingProvider = nil }
            do {
                let ok: Bool
                switch provider {
                case .analysis:
                    _ = try await environment.aiProviderRegistry.testActiveConnection()
                    ok = true
                case .diarization:
                    let configuration = environment.diarizationProviderConfigurationStore.load()
                    ok = try await environment.makeDiarizationService(
                        for: configuration
                    ).testConnection()
                }
                testResults[provider] = ok
                    ? (true, "连接正常（\(provider.displayName) 可用）")
                    : (false, "连接失败")
            } catch {
                testResults[provider] = (false, "不可用：\(error.localizedDescription)")
            }
        }
    }

    private var displayedStoragePath: String {
        let path = environment.fileStore.baseDirectory.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard path == homePath || path.hasPrefix(homePath + "/") else {
            return path
        }
        return "~" + String(path.dropFirst(homePath.count))
    }

    private func chooseObsidianVault() {
        let panel = NSOpenPanel()
        panel.title = "选择 Obsidian Vault"
        panel.message = "应用将在所选 Vault 下建立“帮我分析”子文件夹。"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = environment.obsidianVaultURL
            ?? AppStorageLocation.suggestedObsidianVault()
        guard panel.runModal() == .OK, let vaultURL = panel.url else { return }

        let accessed = vaultURL.startAccessingSecurityScopedResource()
        let bookmarkData: Data
        do {
            bookmarkData = try AppStorageLocation.bookmarkData(for: vaultURL)
        } catch {
            if accessed { vaultURL.stopAccessingSecurityScopedResource() }
            storageMessage = "无法保存文件夹授权：\(error.localizedDescription)"
            return
        }
        let sourceDirectory = environment.fileStore.baseDirectory
        isMigratingStorage = true
        storageMessage = nil
        Task { @MainActor in
            defer {
                if accessed { vaultURL.stopAccessingSecurityScopedResource() }
                isMigratingStorage = false
            }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try AppStorageLocation.prepareVault(
                        vaultURL,
                        migratingFrom: sourceDirectory
                    )
                }.value
                AppStorageLocation.saveBookmarkData(bookmarkData)
                storageMessage = "已切换到 Obsidian Vault。"
                onStorageLocationChanged()
            } catch {
                storageMessage = "切换失败：\(error.localizedDescription)"
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(
                text.contains("失败")
                    || text.contains("无法")
                    || text.contains("未连接")
                    ? Color.orange
                    : Color.secondary
            )
    }
}
