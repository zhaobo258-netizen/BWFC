import SwiftUI

/// 设置页：两个 provider 各自独立的 API Key 管理（Key 分家，互不外借）。
/// - 分析（Kimi）：谈判文字分析；
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

    var body: some View {
        Form {
            keySection(
                provider: .analysis,
                title: "分析 Key（\(CloudModelConfig.analysisProviderName)）",
                input: $analysisKeyInput,
                footnote: "用于谈判文字分析（结构总结与证据化分析）。"
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
                Text("两个 Key 分别保存在本机 Keychain 的独立条目中，不会写入磁盘、日志或任何文件，也不会互相借用。")
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
                .disabled(testingProvider != nil || !environment.isConfigured(provider))
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
