import SwiftUI
import AppKit

struct KnowledgeGardenView: View {
    @Bindable var controller: KnowledgeGardenController
    var onEvidenceTap: ((UUID) -> Void)?
    /// AI 是否已连接（09 号计划需求 3-③：空态如实区分「链路断了」和「内容不够」）
    var isAIConfigured: Bool = true
    /// 项目是否已有对话内容（已确认片段）
    var hasConversationContent: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if controller.seeds.isEmpty {
                    // 空态三分（09 号计划需求 3-③）：链路断了 / 没内容 / 等分析，不再静默
                    if !isAIConfigured {
                        ContentUnavailableView(
                            "AI 未连接，开花不可用",
                            systemImage: "leaf",
                            description: Text("前往设置连接分析模型（登录 Kimi 或保存 API Key）后，即可展开当前原话的概念解释与延伸知识。")
                        )
                        .padding(.vertical, 32)
                    } else if !hasConversationContent {
                        ContentUnavailableView(
                            "还没有对话内容",
                            systemImage: "leaf",
                            description: Text("开始录音或导入音视频后，进入「开花」可选择原话，生成概念解释与延伸知识。")
                        )
                        .padding(.vertical, 32)
                    } else {
                        ContentUnavailableView(
                            "暂无可展开的原话",
                            systemImage: "leaf",
                            description: Text("需要至少一条四个字以上的最终原话。继续录音，或等待当前转写定稿后再打开本页。")
                        )
                        .padding(.vertical, 32)
                    }
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
            guard isAIConfigured else { return }
            await controller.bloomIfNeeded()
        }
        .onDisappear { controller.cancelBloom() }
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
                    .disabled(controller.state == .expanding || !isAIConfigured)
                    if controller.state == .expanding {
                        Button("停止") { controller.cancelBloom() }
                            .controlSize(.small)
                    }
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
            if !isAIConfigured {
                sourceStatus("AI 未连接；请在设置中连接分析模型后重新开花。")
            }
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
            Text("检索到的来源摘录会发送给当前分析模型生成速览；再按需打开 Obsidian、网页或 MCP 原文。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let synthesis = seed.sourceSynthesis {
                sourceSynthesisCard(synthesis, seed: seed)
            } else if controller.state == .expanding && !seed.connections.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在把检索结果整理成一眼能懂的知识速览…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            if let message = controller.sourceSynthesisMessage {
                sourceStatus(message)
            }

            ForEach(controller.providerIDs(for: seed), id: \.self) { providerID in
                let connections = seed.connections.filter {
                    $0.stableProviderID == providerID
                }
                if !connections.isEmpty || controller.providerMessages[providerID] != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(controller.providerDisplayName(for: providerID, in: seed))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        if let message = controller.providerMessages[providerID] {
                            sourceStatus(message)
                        }
                        ForEach(connections) { connection in
                            sourceCard(connection)
                        }
                    }
                }
            }

            if controller.state == .expanding && seed.connections.isEmpty
                && controller.sourceSynthesisMessage == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备短检索词并查询已连接来源…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func sourceSynthesisCard(
        _ synthesis: KnowledgeSourceSynthesis,
        seed: KnowledgeSeed
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("来源速览", systemImage: "sparkles.rectangle.stack")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(BWTheme.accent)
            Text(synthesis.summary)
                .font(.callout)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(synthesis.keyPoints.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(BWTheme.accent)
                        .frame(width: 5, height: 5)
                    Text(point)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Text("和本场讨论的关系")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(synthesis.discussionRelevance)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            let citations = synthesis.sourceIds.compactMap { sourceID in
                seed.connections.first {
                    "\($0.stableProviderID)|\($0.sourceId)" == sourceID
                }?.title
            }
            if !citations.isEmpty {
                Text("依据：\(citations.joined(separator: " · "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BWTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(BWTheme.accent.opacity(0.2), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("相关知识来源速览")
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
                .disabled(openableURL(for: connection) == nil)
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
        if let url = openableURL(for: connection) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openableURL(for connection: KnowledgeConnection) -> URL? {
        if connection.provider == .obsidian {
            guard !connection.sourceLocation.isEmpty else { return nil }
            return URL(fileURLWithPath: connection.sourceLocation)
        }
        guard let url = URL(string: connection.sourceLocation),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }
}
