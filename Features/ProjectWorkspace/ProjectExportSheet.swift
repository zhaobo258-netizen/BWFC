import AppKit
import SwiftUI

struct ProjectExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let recordingURL: URL?

    @State private var selection: Set<ProjectExportContent>
    @State private var isExporting = false
    @State private var errorMessage: String?

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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("导出项目资料")
                        .font(.title2.bold())
                    Text("选择要放进导出资料包的内容")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("全选") { selection = available }
                    .disabled(available.isEmpty || selection == available)
                Button("取消全选") { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }

            VStack(spacing: 0) {
                ForEach(ProjectExportContent.allCases) { content in
                    let enabled = available.contains(content)
                    Toggle(isOn: Binding(
                        get: { selection.contains(content) },
                        set: { checked in
                            if checked { selection.insert(content) }
                            else { selection.remove(content) }
                        }
                    )) {
                        HStack {
                            Text(content.title)
                            Spacer()
                            if !enabled {
                                Text("暂无内容")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!enabled || isExporting)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    if content != ProjectExportContent.allCases.last {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            Text("文档会分别保存为 Markdown，录音保留原格式；所有文件放入同一个以项目名命名的文件夹。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isExporting ? "正在导出…" : "选择位置并导出") {
                    chooseDestinationAndExport()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || isExporting)
            }
        }
        .padding(22)
        .frame(width: 560, height: 600)
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
                contents: selection,
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
