import SwiftUI

struct FinalReportView: View {
    let project: Project
    let state: FinalReportCoordinator.State
    let isAIConfigured: Bool
    var onGenerate: () -> Void
    var onOpenSettings: () -> Void
    var onEvidenceTap: (UUID) -> Void

    @State private var selectedReportID: UUID?

    private var reports: [FinalReportSnapshot] {
        project.finalReportSnapshots.sorted { $0.version > $1.version }
    }

    private var selectedReport: FinalReportSnapshot? {
        if let selectedReportID,
           let report = reports.first(where: { $0.id == selectedReportID }) {
            return report
        }
        return reports.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let report = selectedReport {
                    reportHeader(report)
                    generationStatusKeepingReport
                    if let collaborationSummary =
                        report.collaborationSummary {
                        collaborationSection(collaborationSummary)
                    }
                    ForEach(FinalReportItemCategory.allCases, id: \.self) { category in
                        let items = report.items.filter { $0.category == category }
                        if !items.isEmpty {
                            reportGroup(category: category, items: items)
                        }
                    }
                } else {
                    emptyReportState
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            selectedReportID = reports.first?.id
        }
        .onChange(of: reports.map(\.id)) { _, ids in
            if let selectedReportID, ids.contains(selectedReportID) {
                return
            } else {
                selectedReportID = ids.first
            }
        }
    }

    private func reportHeader(_ report: FinalReportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("完整总结", systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(BWTheme.accent)
                Spacer()
                if reports.count > 1 {
                    Picker("报告版本", selection: Binding(
                        get: { selectedReportID ?? report.id },
                        set: { selectedReportID = $0 }
                    )) {
                        ForEach(reports) { item in
                            Text("第 \(item.version) 版").tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 110)
                    .accessibilityLabel("完整总结版本")
                }
            }

            Text(report.headline)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(report.overview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("第 \(report.version) 版")
                Text(report.generatedAt.formatted(date: .abbreviated, time: .shortened))
                Text("\(report.providerName) · \(report.modelID)")
                    .lineLimit(1)
                Spacer()
                Button("重新生成", action: onGenerate)
                    .controlSize(.small)
                    .disabled(state == .generating || !isAIConfigured)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if report.inputFingerprint != FinalReportFingerprint.make(for: project) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("文稿、说话人、场景或共创记录已变化，需要更新完整总结。旧版本仍可查看。")
                    Spacer()
                    Button("更新", action: onGenerate)
                        .controlSize(.small)
                        .disabled(state == .generating || !isAIConfigured)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(9)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(BWTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(BWTheme.accent.opacity(0.22), lineWidth: 1)
        )
    }

    private func collaborationSection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "我的思考与 AI 共创",
                systemImage: "bubble.left.and.text.bubble.right"
            )
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(BWTheme.accent)

            Text(summary)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "本节来自用户想法、此前笔记与 AI 反馈，不等同于录音事实",
                systemImage: "person.crop.circle.badge.checkmark"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            BWTheme.accent.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BWTheme.accent.opacity(0.2), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var generationStatusKeepingReport: some View {
        switch state {
        case .generating:
            statusRow(
                icon: "arrow.triangle.2.circlepath",
                text: "正在后台重新分析并生成新版本…",
                color: BWTheme.accent,
                showsProgress: true
            )
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("\(message)；上一版仍然保留。")
                    .font(.caption)
                Spacer()
                Button("重试", action: onGenerate)
                    .controlSize(.small)
                Button("前往设置", action: onOpenSettings)
                    .controlSize(.small)
            }
            .padding(9)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .idle:
            if hasInterruptedFinalReportJob {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.orange)
                    Text("上次生成未完成；旧版本仍可查看，不会自动重复调用模型。")
                        .font(.caption)
                    Spacer()
                    Button("继续生成", action: onGenerate)
                        .controlSize(.small)
                }
                .padding(9)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        case .completed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var emptyReportState: some View {
        switch state {
        case .generating:
            VStack(spacing: 10) {
                ProgressView()
                Text("正在生成完整总结")
                    .font(.callout)
                    .fontWeight(.medium)
                Text("你可以切换页签或离开项目，完成后会提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        case .failed(let message):
            reportUnavailable(
                title: "完整总结生成失败",
                detail: message,
                primaryTitle: "重试",
                primaryAction: onGenerate,
                showsSettings: true
            )
        case .idle, .completed:
            if project.processingJobs.contains(where: {
                $0.kind == .finalReport && $0.status == .running
            }) {
                reportUnavailable(
                    title: "上次生成未完成",
                    detail: "App 关闭时不会重复调用模型，你可以继续生成。",
                    primaryTitle: "继续生成",
                    primaryAction: onGenerate,
                    showsSettings: false
                )
            } else if !isAIConfigured {
                reportUnavailable(
                    title: "AI 未连接",
                    detail: "连接 Kimi 或 OpenAI 兼容模型后，可以生成完整总结。",
                    primaryTitle: "前往设置",
                    primaryAction: onOpenSettings,
                    showsSettings: false
                )
            } else {
                reportUnavailable(
                    title: "还没有完整总结",
                    detail: "录音或导入完成后会自动生成；也可以现在手动开始。",
                    primaryTitle: "生成完整总结",
                    primaryAction: onGenerate,
                    showsSettings: false
                )
            }
        }
    }

    private func reportUnavailable(
        title: String,
        detail: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        showsSettings: Bool
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(BWTheme.accent.opacity(0.75))
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                if showsSettings {
                    Button("前往设置", action: onOpenSettings)
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func reportGroup(
        category: FinalReportItemCategory,
        items: [FinalReportItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(BWTheme.accent.opacity(0.7))
                    .frame(width: 2.5, height: 10)
                Text(category.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                reportItem(item)
            }
        }
    }

    private func reportItem(_ item: FinalReportItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if item.category == .chapter,
               let firstEvidenceID = item.evidenceSegmentIds.first,
               let startMs = project.segments.first(where: {
                   $0.id == firstEvidenceID
               })?.startMs {
                Text(timeString(startMs))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(BWTheme.accent)
            }
            Text(item.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                BWBadge(
                    text: item.epistemicStatus == .explicit ? "事实" : "推断",
                    color: item.epistemicStatus == .explicit ? .green : .orange
                )
                Text(confidenceText(item.confidence))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let owner = item.ownerSpeakerId.flatMap(speakerName) {
                    Text("责任人：\(owner)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let deadline = item.deadlineText {
                    Text("期限：\(deadline)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(Array(item.evidenceSegmentIds.prefix(4)), id: \.self) { id in
                    Button {
                        onEvidenceTap(id)
                    } label: {
                        Image(systemName: "text.quote")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BWTheme.accent)
                    .help("查看原话")
                    .accessibilityLabel("查看这条结论的原话证据")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bwCard(padding: 11)
    }

    private func statusRow(
        icon: String,
        text: String,
        color: Color,
        showsProgress: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
            }
            Text(text)
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(color)
        .padding(9)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func speakerName(_ id: UUID) -> String? {
        project.speakers.first(where: { $0.id == id })?.displayName
    }

    private func confidenceText(_ confidence: Confidence) -> String {
        switch confidence {
        case .low: return "低置信"
        case .medium: return "中置信"
        case .high: return "高置信"
        }
    }

    private func timeString(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
    }

    private var hasInterruptedFinalReportJob: Bool {
        project.processingJobs.contains {
            $0.kind == .finalReport && $0.status == .running
        }
    }
}
