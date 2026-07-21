import SwiftUI

/// 设置页（阶段 0）：API Key 写入 Keychain、显示配置状态；
/// 连接测试按钮为占位（阶段 3 提供真实实现）。
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var apiKeyInput: String = ""
    @State private var saveMessage: String?
    @State private var showError: String?
    @State private var isTestingConnection = false
    @State private var connectionTestResult: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("API Key（\(CloudModelConfig.analysisProviderName)）")
                    Spacer()
                    configurationBadge
                }
                SecureField("粘贴你的 \(CloudModelConfig.analysisProviderName) API Key（不会明文保存）", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存到 Keychain") {
                        saveKey()
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("删除已保存的 Key") {
                        deleteKey()
                    }
                    .disabled(!environment.isCloudConfigured)
                    Spacer()
                }
                if let saveMessage {
                    Text(saveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let showError {
                    Text(showError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text("API Key 仅保存在本机 Keychain，不会写入磁盘、日志或任何文件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("云端服务")
            }

            Section {
                HStack {
                    Button(isTestingConnection ? "测试中…" : "连接测试") {
                        runConnectionTest()
                    }
                    .disabled(isTestingConnection || !environment.isCloudConfigured)
                    if let connectionTestResult {
                        Text(connectionTestResult.text)
                            .font(.footnote)
                            .foregroundStyle(connectionTestResult.ok ? .green : .orange)
                    }
                }
                Text("对 \(CloudModelConfig.analysisProviderName) 网关发起一次最小请求，只返回「可用 / 不可用」与脱敏错误。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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
            } header: {
                Text("隐私说明")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") {
                    router.showMeetingList()
                }
            }
        }
    }

    /// 已配置 / 未配置 状态徽标
    private var configurationBadge: some View {
        Text(environment.isCloudConfigured ? "已配置" : "未配置")
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (environment.isCloudConfigured ? Color.green : Color.gray).opacity(0.18),
                in: Capsule()
            )
    }

    /// 保存 API Key 到 Keychain（不落盘、不进日志）
    private func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try environment.apiKeyStore.saveKey(key)
            environment.refreshCloudConfiguration()
            apiKeyInput = ""
            saveMessage = "已保存到 Keychain。"
            showError = nil
        } catch {
            // 只展示错误类型，不展示 Key 内容
            showError = "保存失败：\(error.localizedDescription)"
            saveMessage = nil
        }
    }

    /// 连接测试：最小真实请求，只显示可用/不可用与脱敏错误
    private func runConnectionTest() {
        guard !isTestingConnection else { return }
        isTestingConnection = true
        connectionTestResult = nil
        Task { @MainActor in
            defer { isTestingConnection = false }
            do {
                let ok = try await environment.negotiationAnalysis.testConnection()
                connectionTestResult = ok
                    ? (true, "连接正常（\(CloudModelConfig.analysisProviderName) 网关可用）")
                    : (false, "连接失败")
            } catch {
                // 错误描述已脱敏（不含 Key 与正文）
                connectionTestResult = (false, "不可用：\(error.localizedDescription)")
            }
        }
    }

    /// 删除已保存的 API Key
    private func deleteKey() {
        do {
            try environment.apiKeyStore.deleteKey()
            environment.refreshCloudConfiguration()
            saveMessage = "已删除。"
            showError = nil
        } catch {
            showError = "删除失败：\(error.localizedDescription)"
            saveMessage = nil
        }
    }
}
