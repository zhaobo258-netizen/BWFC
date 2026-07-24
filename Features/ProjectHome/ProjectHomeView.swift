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
    /// 首次录音知情确认只做一次（03 §6.1）
    @AppStorage("bwfx.recordingConsentConfirmed") private var consentConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    actionArea
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
        .navigationTitle("帮我分析")
        .onAppear(perform: reload)
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
        HStack {
            Text("帮我分析")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button {
                router.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
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
                Label("开始录音", systemImage: "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                pickAndImportFile()
            } label: {
                Label(environment.importProcessing.isRunning ? "导入处理中…" : "导入音视频",
                      systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(environment.importProcessing.isRunning)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(environment.importProcessing.isRunning
                 ? "已有导入在后台处理，完成后可导入下一个"
                 : "支持 m4a / mp3 / wav / caf / mp4 / mov，也可直接拖入本窗口")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .offset(y: 18)
        }
        .padding(.bottom, 14)
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
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusBadge(_ status: ProjectStatus) -> some View {
        Text(status.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor(status).opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let project = Project(
            title: "未命名录音 · \(formatter.string(from: now))",
            sourceType: .liveRecording,
            status: .creating,
            createdAt: now,
            lastActivityAt: now
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
            loadError = String(describing: type(of: error))
        }
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
