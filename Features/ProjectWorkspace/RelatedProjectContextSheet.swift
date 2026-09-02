import SwiftUI

struct RelatedProjectContextSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentProjectID: UUID
    let availableProjects: [Project]
    let onSave: (String?, String?, [UUID]) -> Bool

    @State private var businessCategory: String
    @State private var backgroundContext: String
    @State private var selectedProjectIDs: Set<UUID>
    @State private var searchText = ""

    init(
        project: Project,
        availableProjects: [Project],
        onSave: @escaping (String?, String?, [UUID]) -> Bool
    ) {
        currentProjectID = project.id
        self.availableProjects = availableProjects
        self.onSave = onSave
        _businessCategory = State(initialValue: project.businessCategory ?? "")
        _backgroundContext = State(initialValue: project.projectBackgroundContext ?? "")
        _selectedProjectIDs = State(initialValue: Set(project.relatedProjectIDs))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("关联录音 / 项目")
                        .font(.title2.weight(.semibold))
                    Text("把业务背景和历史项目摘要交给本场 AI，保持分析连续性。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并用于 AI") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GroupBox("当前项目背景") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("业务项目 / 业务范畴") {
                                TextField("例如：华东经销商增长项目", text: $businessCategory)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 420)
                            }
                            Text("补充本场的项目目标、当前阶段、已知约束和关键关系。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $backgroundContext)
                                .font(.body)
                                .frame(minHeight: 110)
                                .padding(6)
                                .background(.background)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.separator.opacity(0.7))
                                }
                                .accessibilityLabel("当前项目背景")
                        }
                        .padding(.top, 6)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("关联历史录音 / 项目")
                                        .font(.headline)
                                    Text("已选择 \(selectedExistingCount) / \(RelatedProjectContextBuilder.maximumRelatedProjectCount)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField("搜索项目", text: $searchText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                            }

                            if filteredProjects.isEmpty {
                                ContentUnavailableView(
                                    "没有可关联的历史项目",
                                    systemImage: "link.badge.plus",
                                    description: Text("完成过的录音或导入项目会显示在这里。")
                                )
                                .frame(maxWidth: .infinity, minHeight: 150)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(filteredProjects) { project in
                                        projectRow(project)
                                        if project.id != filteredProjects.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                                .background(.background)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.top, 6)
                    }

                    Label {
                        Text("AI 只读取当前背景，以及所选项目的名称、业务归类和最新 AI 总结；不会读取历史逐字稿、笔记或附件。历史内容只能帮助理解上下文，不能充当本场证据。")
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 620, idealHeight: 700)
    }

    private var eligibleProjects: [Project] {
        availableProjects
            .filter {
                $0.id != currentProjectID
                    && ($0.status == .ready || $0.status == .readyWithWarnings)
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var filteredProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return eligibleProjects }
        return eligibleProjects.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.businessCategory?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selectedExistingCount: Int {
        selectedProjectIDs.intersection(Set(eligibleProjects.map(\.id))).count
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = selectedProjectIDs.contains(project.id)
        let selectionLimitReached = !isSelected
            && selectedExistingCount >= RelatedProjectContextBuilder.maximumRelatedProjectCount
        return Button {
            if isSelected {
                selectedProjectIDs.remove(project.id)
            } else if !selectionLimitReached {
                selectedProjectIDs.insert(project.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let category = project.businessCategory, !category.isEmpty {
                            Text(category)
                        }
                        Text(project.createdAt.formatted(date: .abbreviated, time: .omitted))
                        Text(contextAvailability(for: project))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectionLimitReached)
        .accessibilityLabel("\(isSelected ? "取消关联" : "关联")\(project.title)")
    }

    private func contextAvailability(for project: Project) -> String {
        if !project.finalReportSnapshots.isEmpty { return "有完整总结" }
        if !project.analysisSnapshots.isEmpty { return "有实时总结" }
        if RelatedProjectContextBuilder.normalizedCurrentBackground(
            project.projectBackgroundContext
        ) != nil { return "有人工背景" }
        return "仅项目信息"
    }

    private func save() {
        let validIDs = eligibleProjects
            .map(\.id)
            .filter(selectedProjectIDs.contains)
        guard onSave(
            normalized(businessCategory),
            normalized(backgroundContext),
            Array(validIDs.prefix(RelatedProjectContextBuilder.maximumRelatedProjectCount))
        ) else { return }
        dismiss()
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
