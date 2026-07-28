import SwiftUI
import AppKit

struct KnowledgeGardenView: View {
    @Bindable var controller: KnowledgeGardenController
    var onEvidenceTap: ((UUID) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if controller.seeds.isEmpty {
                    ContentUnavailableView(
                        "还没有可开花的内容",
                        systemImage: "leaf",
                        description: Text("完成一次分析或标记一段原话后，这里会出现知识种子。")
                    )
                    .padding(.vertical, 32)
                } else {
                    seedHeader
                    if let seed = controller.selectedSeed {
                        seedEvidence(seed)
                        expansionSection(seed)
                        sourcesSection(seed)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: controller.selectedSeedID) {
            await controller.bloomIfNeeded()
        }
    }

    private var seedHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("知识种子", systemImage: "leaf.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
                Spacer()
                Menu {
                    ForEach(controller.seeds) { seed in
                        Button {
                            controller.selectSeed(seed.id)
                        } label: {
                            if seed.id == controller.selectedSeedID {
                                Label(seed.seedText, systemImage: "checkmark")
                            } else {
                                Text(seed.seedText)
                            }
                        }
                    }
                } label: {
                    Label("换一个种子", systemImage: "arrow.triangle.2.circlepath")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
            }

            if let seed = controller.selectedSeed {
                Text(seed.seedText)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(seed.whyItMatters)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(seed.isAddedToProject ? "已收藏到项目" : "收藏到项目") {
                        controller.setAddedToProject(!seed.isAddedToProject)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(controller.state == .expanding ? "正在开花…" : "重新开花") {
                        Task { await controller.bloomSelected() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(controller.state == .expanding)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.green.opacity(0.22), lineWidth: 1)
        )
    }

    private func seedEvidence(_ seed: KnowledgeSeed) -> some View {
        HStack(spacing: 6) {
            Text("源自原话")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(seed.evidenceSegmentIds.prefix(4), id: \.self) { id in
                Button {
                    onEvidenceTap?(id)
                } label: {
                    Image(systemName: "text.quote")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(BWTheme.accent)
                .help("查看原话")
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func expansionSection(_ seed: KnowledgeSeed) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("AI 联想", icon: "sparkles")
            if controller.state == .expanding && seed.branches.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在解释概念并寻找跨领域连接…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            if let message = controller.expansionMessage {
                sourceStatus(message)
            }
            ForEach(KnowledgeBranchType.allCases, id: \.self) { type in
                let branches = seed.branches.filter { $0.type == type }
                if !branches.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(type.displayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        ForEach(branches) { branch in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(branch.title)
                                    .font(.callout)
                                    .fontWeight(.semibold)
                                Text(branch.body)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .bwCard(padding: 11)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sourcesSection(_ seed: KnowledgeSeed) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("相关知识", icon: "point.3.connected.trianglepath.dotted")
            Text("来源结果与 AI 联想分开显示，点击可回到真实文件或网页。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(KnowledgeProviderKind.allCases, id: \.self) { provider in
                let connections = seed.connections.filter { $0.provider == provider }
                if !connections.isEmpty || controller.providerMessages[provider] != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(connections.first?.providerName ?? provider.displayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        if let message = controller.providerMessages[provider] {
                            sourceStatus(message)
                        }
                        ForEach(connections) { connection in
                            sourceCard(connection)
                        }
                    }
                }
            }

            if controller.state == .expanding && seed.connections.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检索 Obsidian、互联网和已连接的 MCP…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func sourceCard(_ connection: KnowledgeConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(connection.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Spacer()
                Button("打开") {
                    open(connection)
                }
                .controlSize(.small)
                .disabled(connection.sourceLocation.isEmpty)
            }
            if !connection.excerpt.isEmpty {
                Text(connection.excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !connection.sourceLocation.isEmpty {
                Text(connection.sourceLocation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bwCard(padding: 11)
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(BWTheme.accent)
            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
        }
    }

    private func sourceStatus(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func open(_ connection: KnowledgeConnection) {
        let url: URL?
        if connection.provider == .obsidian {
            url = URL(fileURLWithPath: connection.sourceLocation)
        } else {
            url = URL(string: connection.sourceLocation)
        }
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
