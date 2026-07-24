import SwiftUI
import AppKit

/// 设置页：分析（Kimi）凭证与分人（OpenAI 兼容）Key 管理。
/// - 分析（Kimi）：推荐用账号登录（设备码授权，token 自动刷新）；
///   静态 Key 粘贴保留为后备通道（未登录时才使用）。
/// - 分人（OpenAI 兼容）：说话人识别，未配置时说话人显示为待识别，可手动标注。
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var analysisKeyInput: String = ""
    @State private var diarizationKeyInput: String = ""
    @State private var saveMessage: String?
    @State private var showError: String?
    @State private var testingProvider: CloudProvider?
    @State private var testResults: [CloudProvider: (ok: Bool, text: String)] = [:]
    @State private var login: KimiLoginController?

    var body: some View {
        Form {
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
            }
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
        environment.kimiOAuthTokenStore.hasTokens
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
