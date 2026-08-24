import SwiftUI

struct TranscriptReviewCandidatesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let candidates: [TranscriptReviewCandidate]
    let onApply: ([TranscriptReviewCandidate]) -> String?
    let onDiscardAll: () -> String?

    @State private var selectedIDs: Set<String> = []
    @State private var applyError: String?
    @State private var showDiscardConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("确认转写更正")
                        .font(.headline)
                    Text("AI 只提供候选；勾选并确认后才会修改原文、记住纠错规则。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(16)
            Divider()

            if let applyError {
                Label(applyError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(12)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Button("忽略全部", role: .destructive) {
                    showDiscardConfirmation = true
                }
                Button("全选") { selectedIDs = Set(candidates.map(\.id)) }
                Button("全不选") { selectedIDs.removeAll() }
                Spacer()
                Text("已选 \(selectedIDs.count) / \(candidates.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("应用已选择") { applySelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
        .confirmationDialog(
            "忽略全部候选？",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("忽略全部", role: .destructive) {
                if let error = onDiscardAll() {
                    applyError = error
                } else {
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会清除未处理候选，不会修改原文或记入纠错词库。")
        }
    }

    private func candidateRow(_ candidate: TranscriptReviewCandidate) -> some View {
        Toggle(isOn: selectionBinding(for: candidate.id)) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(candidate.wrong)
                        .strikethrough()
                        .foregroundStyle(.red)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(candidate.right)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                }
                Text(candidate.sourceTextAtReview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .toggleStyle(.checkbox)
        .bwCard(padding: 11)
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { selected in
                if selected { selectedIDs.insert(id) }
                else { selectedIDs.remove(id) }
            }
        )
    }

    private func applySelection() {
        let selected = candidates.filter { selectedIDs.contains($0.id) }
        if let error = onApply(selected) {
            applyError = error
        } else {
            dismiss()
        }
    }
}
