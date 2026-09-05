import SwiftUI

/// 业务记忆与跟进候选确认页（产品文档 12 号 §6.3 / §7.3）。
/// AI 只提供候选；勾选并确认后才写入人物记忆或业务项目跟进。
/// 批量确认必须能看到具体条目——本页逐条展示内容、来源原话、作用域与冲突标记。
struct MemoryCandidatesSheet: View {
    struct MemoryItem: Identifiable {
        var candidate: BusinessMemoryCandidate
        var isConfirmed: Bool
        var editedStatement: String
        var personName: String

        var id: UUID { candidate.id }
    }

    struct FollowUpItem: Identifiable {
        var candidate: FollowUpCandidate
        var isConfirmed: Bool

        var id: UUID { candidate.id }
    }

    /// 跟进候选确认时选择的目标业务项目（已有 or 新建名）
    struct FollowUpTarget: Equatable {
        var existingBusinessProjectID: UUID?
        var newBusinessProjectName: String?

        static let none = FollowUpTarget(
            existingBusinessProjectID: nil,
            newBusinessProjectName: nil
        )
    }

    let memoryItems: [MemoryItem]
    let followUpItems: [FollowUpItem]
    let existingBusinessProjects: [BusinessProject]
    let suggestedBusinessProjectName: String?

    var operationError: String? = nil
    var canPropose = true
    var onRefresh: () -> Void = {}

    let onConfirmMemories: ([MemoryItem]) -> Void
    let onResolveMemory: (UUID, PendingCandidateStatus) -> Void
    let onConfirmFollowUps: ([FollowUpItem], FollowUpTarget) -> Void
    let onResolveFollowUp: (UUID, PendingCandidateStatus) -> Void

    @State private var memorySelection: [UUID: Bool] = [:]
    @State private var selectedMemoryProjects: [UUID: UUID] = [:]
    @State private var editedStatements: [UUID: String] = [:]
    @State private var followUpSelection: [UUID: Bool] = [:]
    @State private var followUpTarget: FollowUpTarget = .none
    @State private var newBusinessProjectName = ""

    private var confirmableMemories: [MemoryItem] {
        memoryItems.filter { memorySelection[$0.id] == true }
    }

    private var confirmableFollowUps: [FollowUpItem] {
        followUpItems.filter { followUpSelection[$0.id] == true }
    }

    private var selectedFollowUpTarget: FollowUpTarget {
        if let id = followUpTarget.existingBusinessProjectID {
            return FollowUpTarget(
                existingBusinessProjectID: id,
                newBusinessProjectName: nil
            )
        }
        let trimmed = newBusinessProjectName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        return FollowUpTarget(
            existingBusinessProjectID: nil,
            newBusinessProjectName: trimmed
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let operationError {
                        Text(operationError).font(.callout).foregroundStyle(.red)
                    }
                    if !memoryItems.isEmpty {
                        memorySection
                    }
                    if !followUpItems.isEmpty {
                        followUpSection
                    }
                    if memoryItems.isEmpty && followUpItems.isEmpty {
                        Text("没有待确认的候选。")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("记忆与跟进候选", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                Text("AI 只提供候选；确认后才写入长期记忆")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("确认的记忆用于后续相关问答，作为已确认背景，不改写录音事实；同一来源版本的已拒绝候选不再提出。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("业务记忆候选（\(memoryItems.count)）")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button("全选") {
                    for item in memoryItems {
                        memorySelection[item.id] = true
                    }
                }
                .controlSize(.mini)
            }
            ForEach(memoryItems) { item in
                memoryRow(item)
            }
        }
    }

    private func memoryRow(_ item: MemoryItem) -> some View {
        let isConfirmed = memorySelection[item.id] == true
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { isConfirmed },
                set: { memorySelection[item.id] = $0 }
            )) {
                HStack(spacing: 6) {
                    Text(item.candidate.kind.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(BWTheme.accent.opacity(0.14), in: Capsule())
                    Text("人物：\(item.personName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if item.candidate.conflictsWithExisting {
                        Label("与现有记忆冲突", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .toggleStyle(.checkbox)
            TextField(
                "拟收录内容（可修改后确认）",
                text: Binding(
                    get: { editedStatements[item.id] ?? item.candidate.statement },
                    set: { editedStatements[item.id] = $0 }
                ),
                axis: .vertical
            )
            .font(.callout)
            .lineLimit(2...5)
            .padding(6)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            if !item.candidate.reason.isEmpty {
                Text("收录原因：\(item.candidate.reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("来源原话：\(item.candidate.evidenceSnippet)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("作用域：\(item.candidate.scopeDescription)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if item.candidate.requiresBusinessProjectScope == true {
                Picker("适用业务项目", selection: Binding(
                    get: { selectedMemoryProjects[item.id] ?? item.candidate.targetBusinessProjectID },
                    set: { selectedMemoryProjects[item.id] = $0 }
                )) {
                    Text("请选择业务项目").tag(UUID?.none)
                    ForEach(existingBusinessProjects) { businessProject in
                        Text(businessProject.name).tag(Optional(businessProject.id))
                    }
                }
                if existingBusinessProjects.isEmpty {
                    Text("请先在业务项目页创建项目；当前候选可仅留本场。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button("仅留本场") {
                    onResolveMemory(item.id, .keptLocalOnly)
                }
                .controlSize(.mini)
                Button("拒绝") {
                    onResolveMemory(item.id, .rejected)
                }
                .controlSize(.mini)
                Spacer()
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("跟进事项候选（\(followUpItems.count)）")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button("全选") {
                    for item in followUpItems {
                        followUpSelection[item.id] = true
                    }
                }
                .controlSize(.mini)
            }
            ForEach(followUpItems) { item in
                followUpRow(item)
            }
            if !followUpItems.isEmpty {
                followUpTargetPicker
            }
        }
    }

    private func followUpRow(_ item: FollowUpItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: Binding(
                get: { followUpSelection[item.id] == true },
                set: { followUpSelection[item.id] = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.candidate.title)
                        .font(.callout)
                    HStack(spacing: 10) {
                        if let owner = item.candidate.ownerDisplayText {
                            Text("责任人：\(owner)")
                        } else {
                            Text("责任人：原话未明确")
                        }
                        if let due = item.candidate.dueDate {
                            Text("期限：\(due.formatted(date: .abbreviated, time: .omitted))")
                        } else {
                            Text("期限：未定")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            Text("来源原话：\(item.candidate.evidenceSnippet)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack {
                Button("仅留本场") { onResolveFollowUp(item.id, .keptLocalOnly) }
                    .controlSize(.mini)
                Button("拒绝") { onResolveFollowUp(item.id, .rejected) }
                    .controlSize(.mini)
                Spacer()
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var followUpTargetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("确认后放入哪个业务项目？")
                .font(.subheadline)
                .fontWeight(.semibold)
            if existingBusinessProjects.isEmpty {
                TextField(
                    "新建业务项目名称",
                    text: $newBusinessProjectName
                )
                .textFieldStyle(.roundedBorder)
            } else {
                Picker("目标业务项目", selection: Binding(
                    get: { followUpTarget.existingBusinessProjectID?.uuidString ?? "__new__" },
                    set: { newValue in
                        if newValue == "__new__" {
                            followUpTarget = .none
                        } else if let id = UUID(uuidString: newValue) {
                            followUpTarget = FollowUpTarget(
                                existingBusinessProjectID: id,
                                newBusinessProjectName: nil
                            )
                        }
                    }
                )) {
                    ForEach(existingBusinessProjects) { businessProject in
                        Text(businessProject.name).tag(businessProject.id.uuidString)
                    }
                    Text("新建业务项目…").tag("__new__")
                }
                if followUpTarget.existingBusinessProjectID == nil {
                    if let suggested = suggestedBusinessProjectName,
                       suggestedBusinessProjectName == newBusinessProjectName {
                        Text("建议名称：\(suggested)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "新建业务项目名称\(suggestedBusinessProjectName.map { "（建议：\($0)）" } ?? "")",
                        text: $newBusinessProjectName
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }
            Text("没有责任人或期限的项保持留空；完成后需要在业务项目页记录实际结果。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(BWTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Text("已选 \(confirmableMemories.count) 条记忆、\(confirmableFollowUps.count) 条跟进")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("重新提取") { onRefresh() }
                .disabled(!canPropose)
            Button("全部仅留本场") {
                for item in memoryItems { onResolveMemory(item.id, .keptLocalOnly) }
                for item in followUpItems { onResolveFollowUp(item.id, .keptLocalOnly) }
            }
            .controlSize(.regular)
            Button("确认所选") {
                let memories = confirmableMemories.map { item in
                    var candidate = item.candidate
                    candidate.targetBusinessProjectID = selectedMemoryProjects[item.id]
                        ?? candidate.targetBusinessProjectID
                    return MemoryItem(
                        candidate: candidate,
                        isConfirmed: true,
                        editedStatement: editedStatements[item.id] ?? item.candidate.statement,
                        personName: item.personName
                    )
                }
                onConfirmMemories(memories)
                if !confirmableFollowUps.isEmpty {
                    onConfirmFollowUps(confirmableFollowUps, selectedFollowUpTarget)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                (confirmableMemories.isEmpty && confirmableFollowUps.isEmpty)
                    || (!confirmableFollowUps.isEmpty && selectedFollowUpTarget == .none)
                    || confirmableMemories.contains { item in
                        (editedStatements[item.id] ?? item.candidate.statement)
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (item.candidate.requiresBusinessProjectScope == true
                                && selectedMemoryProjects[item.id] == nil
                                && item.candidate.targetBusinessProjectID == nil)
                    }
            )
        }
        .padding(12)
    }
}
