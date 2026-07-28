import SwiftUI
import AppKit

/// 设置页：分析（Kimi）凭证与分人（OpenAI 兼容）Key 管理。
/// - 分析（Kimi）：推荐用账号登录（设备码授权，token 自动刷新）；
///   静态 Key 粘贴保留为后备通道（未登录时才使用）。
/// - 分人（OpenAI 兼容）：说话人识别，未配置时说话人显示为待识别，可手动标注。
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    let onStorageLocationChanged: () -> Void

    @State private var analysisKeyInput: String = ""
    @State private var diarizationKeyInput: String = ""
    @State private var saveMessage: String?
    @State private var showError: String?
    @State private var testingProvider: CloudProvider?
    @State private var testResults: [CloudProvider: (ok: Bool, text: String)] = [:]
    @State private var login: KimiLoginController?
    @State private var lexiconPaste: String = ""
    @State private var lexiconMessage: String?
    @State private var storageMessage: String?
    @State private var isMigratingStorage = false
    @State private var mcpDisplayName = "得到大脑"
    @State private var mcpEndpoint = ""
    @State private var mcpToolName = ""
    @State private var mcpTokenInput = ""
    @State private var mcpMessage: String?
    @State private var isTestingMCP = false

    var body: some View {
        Form {
            storageSection
            knowledgeSourceSection
            lexiconSection
            kimiAccountSection
            keySection(
                provider: .analysis,
                title: "静态分析 Key（后备）",
                input: $analysisKeyInput,
                footnote: "后备通道：未登录 Kimi 账号时才使用此 Key。用于对话语义分析。"
            )
            keySection(
                provider: .diarization,
                title: "分人 Key（OpenAI 兼容）",
                input: $diarizationKeyInput,
                footnote: "可用任意 OpenAI 兼容的 diarize 接口。未配置时说话人将显示为待识别，可手动标注；本地录音与转写不受影响。"
            )

            Section {
                LabeledContent("谈判分析", value: "\(CloudModelConfig.analysisProviderName) · \(CloudModelConfig.analysisModelID)")
                LabeledContent("说话人识别", value: "OpenAI 兼容 · \(CloudModelConfig.diarizationModelID)")
                Text("模型版本由应用统一固定，发布前会锁定为评测通过的具体版本。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("模型配置")
            }

            Section {
                Text("使用本 App 录音前，请确认所有参会人已知晓并同意录音；会议音频会分段发送至云端进行说话人识别，这些分片合起来基本覆盖整场谈话。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("登录凭证与两个 Key 分别保存在本机 Keychain 的独立条目中，不会写入磁盘、日志或任何文件，也不会互相借用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("隐私说明")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") {
                    router.closeSettings()
                }
                .disabled(isMigratingStorage)
            }
        }
        .onAppear {
            loadExternalMCPSettings()
        }
    }

    // MARK: - 开花知识来源

    @ViewBuilder
    private var knowledgeSourceSection: some View {
        Section {
            HStack {
                Text("Obsidian")
                Spacer()
                Text(environment.obsidianVaultURL == nil ? "未连接" : "已连接")
                    .font(.caption)
                    .foregroundStyle(environment.obsidianVaultURL == nil ? Color.gray : Color.green)
            }
            HStack {
                Text("互联网")
                Spacer()
                Text("已启用 · 中文维基百科")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Divider()

            TextField("来源名称，例如：得到大脑", text: $mcpDisplayName)
                .textFieldStyle(.roundedBorder)
            TextField("Streamable HTTP MCP 地址，例如：https://example.com/mcp", text: $mcpEndpoint)
                .textFieldStyle(.roundedBorder)
            TextField("知识搜索工具名（留空时自动发现）", text: $mcpToolName)
                .textFieldStyle(.roundedBorder)
            SecureField("Bearer Token（可选，仅保存到 Keychain）", text: $mcpTokenInput)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("保存 MCP") {
                    saveExternalMCPSettings()
                }
                .disabled(mcpEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(isTestingMCP ? "测试中…" : "保存并测试连接") {
                    testExternalMCP()
                }
                .disabled(isTestingMCP
                          || mcpEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("删除连接") {
                    deleteExternalMCPSettings()
                }
                .disabled(environment.externalMCPConfigurationStore.load() == nil
                          && !environment.externalMCPTokenStore.hasConfiguredKey)
                Spacer()
            }

            if let mcpMessage {
                Text(mcpMessage)
                    .font(.footnote)
                    .foregroundStyle(
                        mcpMessage.hasPrefix("已") || mcpMessage.hasPrefix("连接正常")
                            ? .green : .orange
                    )
            }
            Text("“开花”会自动检索 Obsidian 和互联网；配置外部 MCP 后会一并查询。MCP 只接收当前知识种子的短检索词，不发送整场录音、完整逐字稿或整个 Vault。远程地址必须使用 HTTPS，本机地址可使用 localhost。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("开花 · 知识来源")
        }
    }

    private func loadExternalMCPSettings() {
        guard let configuration = environment.externalMCPConfigurationStore.load() else {
            return
        }
        mcpDisplayName = configuration.displayName
        mcpEndpoint = configuration.endpoint
        mcpToolName = configuration.toolName
    }

    @discardableResult
    private func saveExternalMCPSettings() -> ExternalMCPConfiguration? {
        let configuration = ExternalMCPConfiguration(
            displayName: mcpDisplayName,
            endpoint: mcpEndpoint,
            toolName: mcpToolName
        )
        do {
            try environment.externalMCPConfigurationStore.save(configuration)
        } catch {
            mcpMessage = "无法保存：请使用 HTTPS 地址，或本机 localhost 地址。"
            return nil
        }
        let token = mcpTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            do {
                try environment.externalMCPTokenStore.saveKey(token)
                mcpTokenInput = ""
            } catch {
                // 地址已保存成功；Token 写入 Keychain 失败要如实区分，不能误报成地址问题
                mcpMessage = "地址已保存，但 Token 写入 Keychain 失败，请重试。"
                return nil
            }
        }
        mcpMessage = "已保存外部 MCP。"
        return configuration
    }

    private func testExternalMCP() {
        guard let configuration = saveExternalMCPSettings() else { return }
        isTestingMCP = true
        mcpMessage = nil
        let provider = ExternalMCPKnowledgeProvider(
            configuration: configuration,
            tokenStore: environment.externalMCPTokenStore
        )
        Task { @MainActor in
            let health = await provider.healthCheck()
            mcpMessage = health.isAvailable
                ? "连接正常：\(health.message)"
                : "连接失败：\(health.message)"
            isTestingMCP = false
        }
    }

    private func deleteExternalMCPSettings() {
        environment.externalMCPConfigurationStore.clear()
        do {
            try environment.externalMCPTokenStore.deleteKey()
            mcpEndpoint = ""
            mcpToolName = ""
            mcpTokenInput = ""
            mcpDisplayName = "得到大脑"
            mcpMessage = "已删除外部 MCP 连接。"
        } catch {
            mcpMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Obsidian 存储

    @ViewBuilder
    private var storageSection: some View {
        Section {
            LabeledContent("当前目录") {
                Text(displayedStoragePath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }

            HStack {
                Button(environment.obsidianVaultURL == nil
                       ? "选择 Obsidian Vault…"
                       : "重新选择 Obsidian Vault…") {
                    chooseObsidianVault()
                }
                .disabled(isMigratingStorage || environment.importProcessing.activeProjectID != nil)

                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([environment.fileStore.baseDirectory])
                }

                if isMigratingStorage {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在复制并校验现有数据…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let storageMessage {
                Text(storageMessage)
                    .font(.footnote)
                    .foregroundStyle(storageMessage.hasPrefix("切换失败")
                                     || storageMessage.hasPrefix("无法")
                                     ? .orange : .green)
            } else if let storageWarning = environment.storageWarning {
                Text(storageWarning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Text("选择 Vault 根目录后，默认在其中建立“帮我分析”子文件夹。首次切换会复制并校验现有数据，旧目录保留，不直接删除。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("存储位置")
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

        let didStartAccessing = vaultURL.startAccessingSecurityScopedResource()
        let bookmarkData: Data
        do {
            bookmarkData = try AppStorageLocation.bookmarkData(for: vaultURL)
        } catch {
            if didStartAccessing {
                vaultURL.stopAccessingSecurityScopedResource()
            }
            storageMessage = "无法保存文件夹授权：\(error.localizedDescription)"
            return
        }

        let sourceDirectory = environment.fileStore.baseDirectory
        isMigratingStorage = true
        storageMessage = nil
        Task { @MainActor in
            defer {
                if didStartAccessing {
                    vaultURL.stopAccessingSecurityScopedResource()
                }
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

    // MARK: - 专业词库与纠错（老板 2026-07-27）

    @ViewBuilder
    private var lexiconSection: some View {
        Section {
            HStack {
                Text("已导入 \(environment.lexiconTerms.count) 个词条")
                Spacer()
                Button("从文件导入…") { importLexiconFromFile() }
                Button("清空词库") {
                    try? environment.clearLexicon()
                    lexiconMessage = "已清空。"
                }
                .disabled(environment.lexiconTerms.isEmpty)
            }
            TextField("或在此粘贴词条（每行一个，兼容顿号/逗号分隔）", text: $lexiconPaste, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("导入粘贴内容") {
                    importLexicon(text: lexiconPaste)
                    lexiconPaste = ""
                }
                .disabled(lexiconPaste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let lexiconMessage {
                    Text(lexiconMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            if !environment.correctionRules.isEmpty {
                DisclosureGroup("纠错规则（\(environment.correctionRules.count) 条，转写自动套用）") {
                    ForEach(environment.correctionRules) { rule in
                        HStack {
                            Text("\(rule.wrong) → \(rule.right)")
                                .font(.callout)
                            Spacer()
                            Button {
                                try? environment.removeCorrectionRule(rule)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("词条在录音与导入转写时作为识别上下文（只改善识别，不改写原意），并作为分析的已知名词。纠错规则来自工作台文稿右键「纠错」，也在此管理。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("专业词库")
        }
    }

    private func importLexiconFromFile() {
        let panel = NSOpenPanel()
        panel.title = "导入词库"
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.startAccessingSecurityScopedResource() else {
            lexiconMessage = "无法访问所选文件。"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lexiconMessage = "文件读取失败（需为 UTF-8 文本）。"
            return
        }
        importLexicon(text: text)
    }

    private func importLexicon(text: String) {
        do {
            let added = try environment.importLexicon(text: text)
            lexiconMessage = added > 0 ? "新增 \(added) 个词条。" : "没有新词条（已全部存在）。"
        } catch {
            lexiconMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Kimi 账号登录区（推荐通道）

    /// 惰性创建登录控制器（依赖 environment，不能在属性初始化时取）
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

    @ViewBuilder
    private var kimiAccountSection: some View {
        Section {
            HStack {
                Text("Kimi 账号（推荐）")
                Spacer()
                Text(isKimiLoggedIn ? "已登录" : "未登录")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (isKimiLoggedIn ? Color.green : Color.gray).opacity(0.18),
                        in: Capsule()
                    )
            }
            switch login?.phase {
            case .starting:
                Text("正在发起授权…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .waitingApproval(let userCode):
                VStack(alignment: .leading, spacing: 6) {
                    Text("已在浏览器打开授权页，请确认后回到本页。")
                        .font(.footnote)
                    HStack(spacing: 8) {
                        Text("确认码")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(userCode)
                            .font(.title3.monospaced().bold())
                            .textSelection(.enabled)
                    }
                }
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            case .succeeded:
                Text("登录成功，分析请求将自动刷新凭证。")
                    .font(.footnote)
                    .foregroundStyle(.green)
            default:
                EmptyView()
            }
            HStack {
                if case .waitingApproval = login?.phase {
                    Button("取消登录") {
                        login?.cancel()
                    }
                } else {
                    Button(isKimiLoggedIn ? "重新登录" : "登录 Kimi 账号") {
                        ensureLoginController().begin()
                    }
                    .disabled(login?.phase == .starting)
                }
                if isKimiLoggedIn {
                    Button("退出登录") {
                        ensureLoginController().logout()
                    }
                }
            }
            Text("登录后凭证保存在本机 Keychain，并在过期前自动刷新；无需手动粘贴 Key。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("分析（Kimi）· 账号登录")
        }
    }

    // MARK: - 单 provider 的 Key 管理区

    @ViewBuilder
    private func keySection(
        provider: CloudProvider,
        title: String,
        input: Binding<String>,
        footnote: String
    ) -> some View {
        Section {
            HStack {
                Text(title)
                Spacer()
                configurationBadge(provider: provider)
            }
            SecureField("粘贴 \(provider.displayName) 的 API Key（不会明文保存）", text: input)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存到 Keychain") {
                    saveKey(provider: provider, rawValue: input.wrappedValue)
                }
                .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("删除已保存的 Key") {
                    deleteKey(provider: provider)
                }
                .disabled(!environment.isConfigured(provider))
                Spacer()
                Button(testingProvider == provider ? "测试中…" : "连接测试") {
                    runConnectionTest(provider: provider)
                }
                .disabled(testingProvider != nil || !canTestConnection(provider))
            }
            if let result = testResults[provider] {
                Text(result.text)
                    .font(.footnote)
                    .foregroundStyle(result.ok ? .green : .orange)
            }
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(provider.displayName)
        }
    }

    /// 已配置 / 未配置 状态徽标
    private func configurationBadge(provider: CloudProvider) -> some View {
        Text(environment.isConfigured(provider) ? "已配置" : "未配置")
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (environment.isConfigured(provider) ? Color.green : Color.gray).opacity(0.18),
                in: Capsule()
            )
    }

    /// 保存 API Key 到对应 provider 的 Keychain 条目（互不外借）
    private func saveKey(provider: CloudProvider, rawValue: String) {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try environment.keyStore(for: provider).saveKey(key)
            environment.refreshCloudConfiguration()
            switch provider {
            case .analysis: analysisKeyInput = ""
            case .diarization: diarizationKeyInput = ""
            }
            saveMessage = nil
            showError = nil
            testResults[provider] = (true, "已保存到 Keychain。")
        } catch {
            // 只展示错误类型，不展示 Key 内容
            testResults[provider] = (false, "保存失败：\(error.localizedDescription)")
        }
    }

    /// 删除指定 provider 已保存的 API Key
    private func deleteKey(provider: CloudProvider) {
        do {
            try environment.keyStore(for: provider).deleteKey()
            environment.refreshCloudConfiguration()
            testResults[provider] = (true, "已删除。")
        } catch {
            testResults[provider] = (false, "删除失败：\(error.localizedDescription)")
        }
    }

    /// 连接测试是否可用：分析侧账号登录或静态 Key 任一配置即可
    private func canTestConnection(_ provider: CloudProvider) -> Bool {
        switch provider {
        case .analysis: return environment.isAnalysisConfigured
        case .diarization: return environment.isConfigured(provider)
        }
    }

    /// 连接测试：对应 provider 的最小真实请求，只显示可用/不可用与脱敏错误
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
                    ok = try await environment.negotiationAnalysis.testConnection()
                case .diarization:
                    ok = try await environment.diarization.testConnection()
                }
                testResults[provider] = ok
                    ? (true, "连接正常（\(provider.displayName) 可用）")
                    : (false, "连接失败")
            } catch {
                // 错误描述已脱敏（不含 Key 与正文）
                testResults[provider] = (false, "不可用：\(error.localizedDescription)")
            }
        }
    }
}
