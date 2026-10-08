import AppKit
import SwiftUI

/// 导出资料弹层（界面设计定稿 v1.0 / S08）：
/// 8 项复选，默认勾选实际可用项，无内容项禁用；计数 + 说明条（临时目录→整体移动）；
/// Obsidian 归档选项如实标注「尚未完成」；导出中有进度反馈。
struct ProjectExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let recordingURL: URL?

    @State private var selection: Set<ProjectExportContent>
    @State private var isExporting = false
    @State private var errorMessage: String?
    /// Obsidian 归档为未完成能力（结构化项目页与 block 证据链接未接通），
    /// 选项只读展示，不参与导出（行为真源：功能与交互 §6 / PRODUCT.md 范围表）。
    private let obsidianArchiveAvailable = false

    private let service = ProjectExportService()

    init(project: Project, recordingURL: URL?) {
        self.project = project
        self.recordingURL = recordingURL
        let available = ProjectExportService().availableContents(
            project: project,
            recordingURL: recordingURL
        )
        _selection = State(initialValue: available)
    }

    private var available: Set<ProjectExportContent> {
        service.availableContents(project: project, recordingURL: recordingURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 0) {
                ForEach(ProjectExportContent.allCases) { content in
                    itemRow(content)
                    if content != ProjectExportContent.allCases.last {
                        Divider().overlay(BWTheme.border).padding(.leading, 44)
                    }
                }
            }
            .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(BWTheme.border, lineWidth: 1)
            )

            obsidianRow

            Text("先写临时目录，完成后整体移到目标位置；失败会显示错误，不会静默丢内容。录音、暂停和收尾时导出入口禁用。")
                .font(.system(size: BWTheme.fontSizeDetail))
                .foregroundStyle(BWTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.danger)
            }

            HStack {
                Text("已选 \(selection.intersection(available).count) 项")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink2)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isExporting ? "正在导出…" : "导出到文件夹…") {
                    chooseDestinationAndExport()
                }
                .buttonStyle(.borderedProminent)
                .tint(BWTheme.accentButton)
                .keyboardShortcut(.defaultAction)
                .disabled(selection.intersection(available).isEmpty || isExporting)
            }

            if isExporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在写入临时目录并整体移动…")
                        .font(.system(size: BWTheme.fontSizeDetail))
                        .foregroundStyle(BWTheme.ink2)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(BWTheme.canvas)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("导出项目资料")
                    .font(.system(size: BWTheme.fontSizeSectionTitle, weight: .bold))
                    .foregroundStyle(BWTheme.ink)
                Text("「\(project.title)」· 生成独立资料文件夹：音频副本 + 分项 Markdown")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink2)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BWTheme.ink2)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭导出")
        }
    }

    private func itemRow(_ content: ProjectExportContent) -> some View {
        let enabled = available.contains(content)
        return Toggle(isOn: Binding(
            get: { selection.contains(content) },
            set: { checked in
                if checked { selection.insert(content) }
                else { selection.remove(content) }
            }
        )) {
            HStack(spacing: 8) {
                Text(content.title)
                    .font(.system(size: BWTheme.fontSizeBody))
                    .foregroundStyle(enabled ? BWTheme.ink : BWTheme.ink3)
                Spacer()
                Text(enabled ? metaText(content) : "暂无内容")
                    .font(.system(size: BWTheme.fontSizeDetail))
                    .foregroundStyle(BWTheme.ink3)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled || isExporting)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Obsidian 归档项：未完成能力如实标注，不伪装成可用功能
    private var obsidianRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.square")
                .foregroundStyle(BWTheme.ink3.opacity(0.5))
            Text("同时复制到 Obsidian Vault")
                .font(.system(size: BWTheme.fontSizeBody))
                .foregroundStyle(BWTheme.ink3)
            Text("尚未完成")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BWTheme.warn)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(BWTheme.warnBg, in: RoundedRectangle(cornerRadius: 5))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(BWTheme.border, lineWidth: 1)
        )
        .opacity(0.8)
        .help("Markdown 文件归档可用导出代替；结构化项目页与 block 证据链接尚未完成")
        .accessibilityLabel("同时复制到 Obsidian Vault（尚未完成，暂不可用）")
        .allowsHitTesting(false)
    }

    /// 每项的规格行（真实统计，不编造）
    private func metaText(_ content: ProjectExportContent) -> String {
        switch content {
        case .recording:
            let ext = recordingURL?.pathExtension.uppercased() ?? "音频"
            return "\(LiveMeetingView.formatDuration(ms: project.durationMs)) · \(ext)"
        case .transcript:
            let count = project.segments.filter { $0.state == .final || $0.state == .edited }.count
            return "\(count) 条 · Markdown"
        case .liveSummary:
            let version = project.analysisSnapshots.map(\.version).max() ?? 0
            return version > 0 ? "v\(version) · Markdown" : "Markdown"
        case .motives:
            return "Markdown"
        case .finalReport:
            let version = project.finalReportSnapshots.map(\.version).max() ?? 0
            return version > 0 ? "v\(version) · 当前 · Markdown" : "Markdown"
        case .knowledgeGarden:
            let seeds = project.knowledgeSeeds.count
            return seeds > 0 ? "\(seeds) 种子 · Markdown" : "Markdown"
        case .aiCollaboration:
            let rounds = project.aiChatMessages.filter { $0.role == .user }.count
            return rounds > 0 ? "\(rounds) 轮 · Markdown" : "Markdown"
        case .projectNote:
            return "含手写与 AI 归结 · Markdown"
        }
    }

    private func chooseDestinationAndExport() {
        let panel = NSOpenPanel()
        panel.title = "选择导出资料包的保存位置"
        panel.prompt = "导出到这里"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        errorMessage = nil
        do {
            let exportedURL = try service.export(
                project: project,
                recordingURL: recordingURL,
                contents: selection.intersection(available),
                to: destination
            )
            NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isExporting = false
    }
}
