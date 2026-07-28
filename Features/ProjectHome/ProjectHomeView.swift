import SwiftUI
import UniformTypeIdentifiers

/// 首页（阶段 B/C，03 文档 §6.1）：开始录音 / 导入音视频 双入口 + 最近项目。
/// 开始录音：零预填，首次仅一次录音知情确认，随后直达工作台并立即开录。
/// 导入音视频（阶段 C）：文件选择或拖放；检查通过即创建项目直达工作台，
/// 提取/转写/分析在后台流水线执行，重启后可续跑。
struct ProjectHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    @State private var projects: [Project] = []
    @State private var loadError: String?
    @State private var showConsent = false
    @State private var importErrorMessage: String?
    @State private var isDropTargeted = false
    @State private var selectedRecordingScenario: ProjectScenario?
    /// 首次录音知情确认只做一次（03 §6.1）
    @AppStorage("bwfx.recordingConsentConfirmed") private var consentConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    actionArea
                    recordingScenarioSection
                    if let loadError {
                        Label("项目读取失败：\(loadError)", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    abnormalNotice
                    recentSection
                }
                .padding(24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
        }
        .background(BWTheme.paper)
        .navigationTitle("帮我分析")
        .onAppear {
            selectedRecordingScenario = nil
            reload()
        }
        .confirmationDialog("开始录音前请确认", isPresented: $showConsent, titleVisibility: .visible) {
            Button("已告知，开始录音") {
                consentConfirmed = true
                startRecordingProject()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请确认参与者已知晓本次录音。\n录音、文稿与笔记默认只保存在本机；配置云端分析或说话人识别服务后，仅对应内容按需发送给对应服务，API Key 仅存于系统钥匙串。")
        }
        .alert("无法导入", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            BWBrandMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("帮我分析")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("录音 · 转写 · 实时分析")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                router.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 主动作区

    private var actionArea: some View {
        HStack(spacing: 16) {
            Button {
                if consentConfirmed {
                    startRecordingProject()
                } else {
                    showConsent = true
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.18), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开始录音")
                            .font(.headline)
                        Text("边录边转写，AI 实时分析")
                            .font(.caption)
                            .opacity(0.85)
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(BWTheme.accentGradient, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: BWTheme.accent.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)

            Button {
                pickAndImportFile()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: environment.importProcessing.isRunning
                          ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BWTheme.accent)
                        .frame(width: 46, height: 46)
                        .background(BWTheme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(environment.importProcessing.isRunning ? "导入处理中…" : "导入音视频")
                            .font(.headline)
                        Text("m4a / mp3 / wav / mp4 · 可直接拖入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(BWTheme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isDropTargeted ? BWTheme.accent : BWTheme.cardStroke,
                                      lineWidth: isDropTargeted ? 2 : 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(environment.importProcessing.isRunning)
        }
        .padding(.bottom, 6)
    }

    // MARK: - 录音场景

    private var recordingScenarioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("录音场景（可选）")
                    .font(.headline)
                Spacer()
                Text("仅用于现场录音")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                recordingScenarioButton(nil)
                ForEach(ProjectHomeSupport.recordingScenarioOrder, id: \.self) { scenario in
                    recordingScenarioButton(scenario)
                }
            }

            Text("默认由 AI 根据内容判断，也可以提前指定；进入工作台后仍可随时修改。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(BWTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(BWTheme.cardStroke, lineWidth: 1)
        )
    }

    private func recordingScenarioButton(_ scenario: ProjectScenario?) -> some View {
        let isSelected = selectedRecordingScenario == scenario
        let label = scenario?.displayName ?? "自动判断"
        return Button {
            selectedRecordingScenario = scenario
        } label: {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                }
                Text(label)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .foregroundStyle(isSelected ? BWTheme.accent : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? BWTheme.accent.opacity(0.13) : Color.clear,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? BWTheme.accent.opacity(0.75) : BWTheme.cardStroke,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("录音场景：\(label)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .help(isSelected ? "当前录音场景：\(label)" : "将录音场景设为\(label)")
    }

    // MARK: - 异常项目提示（非阻塞）

    @ViewBuilder
    private var abnormalNotice: some View {
        let abnormal = projects.filter { $0.status.isAbnormalIfAppRelaunched }
        if !abnormal.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                Text("有 \(abnormal.count) 个项目上次未正常结束，打开后可查看或标记结束。")
                    .font(.callout)
                Spacer()
            }
            .padding(12)
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - 最近项目

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近项目")
                .font(.headline)
            if projects.isEmpty && loadError == nil {
                Text("还没有项目。点击「开始录音」创建第一个项目。")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 24)
            }
            ForEach(ProjectHomeSupport.sortedForDisplay(projects)) { project in
                Button {
                    router.showProjectWorkspace(project.id, autoStart: false)
                } label: {
                    projectRow(project)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    statusBadge(project.status)
                }
                Text(ProjectHomeSupport.summary(for: project))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(ProjectHomeSupport.sourceLabel(for: project.sourceType))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LiveMeetingView.formatDuration(ms: project.durationMs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(project.lastActivityAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .bwCard(padding: 14)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusBadge(_ status: ProjectStatus) -> some View {
        BWBadge(text: status.displayName, color: badgeColor(status))
    }

    private func badgeColor(_ status: ProjectStatus) -> Color {
        switch status {
        case .recording: return .red
        case .paused, .processing, .readyWithWarnings: return .orange
        case .ready: return .green
        case .creating: return .gray
        case .failed: return .red
        }
    }

    // MARK: - 行为

    /// 开始录音：立即创建临时项目并直达工作台开录（两次交互内）
    private func startRecordingProject() {
        let now = Date()
        let project = ProjectHomeSupport.makeRecordingProject(
            at: now,
            scenario: selectedRecordingScenario
        )
        do {
            try environment.persist(project)
            router.showProjectWorkspace(project.id, autoStart: true)
        } catch {
            loadError = "项目创建失败（\(String(describing: type(of: error)))）"
        }
    }

    private func reload() {
        do {
            projects = try environment.allProjects()
            loadError = nil
        } catch {
            projects = []
            loadError = Self.loadErrorMessage(for: error)
        }
    }

    static func loadErrorMessage(for error: Error) -> String {
        guard case let ProjectStoreError.dataCorrupted(backupFileName) = error else {
            return String(describing: type(of: error))
        }
        if let backupFileName {
            return "数据文件损坏，已备份为 \(backupFileName)，原始数据未丢失。"
        }
        return "数据文件损坏，自动备份未完成，已阻止写入。"
    }

    // MARK: - 导入音视频（阶段 C，03 §6.2）

    /// 文件选择导入：检查通过即创建项目并直达工作台，处理在后台流水线继续
    private func pickAndImportFile() {
        let panel = NSOpenPanel()
        panel.title = "导入音视频"
        panel.allowsMultipleSelection = false // 首版一次一个文件（03 §6.2）
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginImport(url: url)
    }

    /// 拖放导入：只取第一个文件（首版一次一个）
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                // provider 只交付 file URL；外部文件的 security scope 由导入控制器
                // 覆盖检查与原件复制，后续阶段只读取项目目录内副本。
                beginImport(url: url)
            }
        }
        return true
    }

    private func beginImport(url: URL) {
        Task {
            do {
                let projectID = try await environment.importProcessing.beginImport(url: url)
                reload()
                router.showProjectWorkspace(projectID, autoStart: false)
            } catch let error as AudioImportError {
                importErrorMessage = error.userMessage
            } catch let error as ImportBusyError {
                importErrorMessage = error.userMessage
            } catch {
                importErrorMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}
