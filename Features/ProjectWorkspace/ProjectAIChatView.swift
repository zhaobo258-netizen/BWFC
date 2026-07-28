import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectAIChatView: View {
    @Bindable var controller: ProjectAIChatController
    let legacyNoteMarkdown: String
    let legacyNoteContextEnabled: Bool
    let canReanalyze: Bool
    let onLegacyNoteContextChanged: (Bool) -> Void
    let onReanalyze: () -> Void
    let onOpenSettings: () -> Void

    @State private var isConfirmingClear = false
    @State private var isSelectingReferenceDocuments = false
    @State private var isLegacyNoteExpanded = false

    private static let supportedReferenceDocumentTypes = [
        "pdf", "md", "markdown", "txt", "rtf", "doc", "docx"
    ].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if controller.messages.isEmpty && normalizedLegacyNote == nil {
                    emptyState
                } else {
                    messages
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            if let errorMessage = controller.errorMessage {
                errorRow(errorMessage)
            }
            composer
        }
        .background(BWTheme.columnBackground.opacity(0.72))
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: 220,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .fileImporter(
            isPresented: $isSelectingReferenceDocuments,
            allowedContentTypes: Self.supportedReferenceDocumentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await controller.addReferenceDocuments(from: urls)
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    controller.reportReferenceDocumentSelectionFailure()
                }
            }
        }
        .confirmationDialog(
            "清空 AI 共创记录？",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("清空共创记录", role: .destructive) {
                controller.clearConversation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此前笔记和逐字稿不会删除；已有完整总结会标记为需要更新。")
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(BWTheme.accent)
                    .frame(width: 3, height: 13)
                Label(
                    "AI 共创笔记",
                    systemImage: "bubble.left.and.text.bubble.right"
                )
                .font(.subheadline)
                .fontWeight(.semibold)
                Spacer()
                Button {
                    onReanalyze()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(!canReanalyze || controller.isSending)
                .help("使用共创记录中的背景和纠正更新完整分析")
                .accessibilityLabel("使用共创记录更新分析")
                if !controller.messages.isEmpty {
                    Button {
                        isConfirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .accessibilityLabel("清空 AI 共创记录")
                }
            }
            HStack(spacing: 6) {
                Text("记录想法，发送后 AI 反馈")
                Spacer()
                Label("纳入完整总结", systemImage: "doc.text")
                    .foregroundStyle(BWTheme.accent)
                    .help("用户想法与 AI 反馈会在完整总结中单独标明来源")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(BWTheme.accent.opacity(0.75))
                Text("把你的判断、疑问或灵感直接写在这里。发送后，AI 会结合录音、已有分析和你明确授权的此前笔记回应。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                Text("用左下角“＋”可引用 PDF、Word、Markdown 或文本，与 AI 一起阅读。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let normalizedLegacyNote {
                        legacyNoteCard(normalizedLegacyNote)
                    }
                    ForEach(controller.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    if controller.isSending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("AI 正在结合录音和共创内容回应…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .onChange(of: controller.messages.count) { _, _ in
                if let id = controller.messages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func messageBubble(_ message: ProjectAIChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 28)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(message.role == .user ? "我的想法" : "AI 反馈")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(
                        message.role == .user ? BWTheme.accent : .secondary
                    )
                Text(message.text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(message.attachments) { attachment in
                            Label {
                                Text(attachment.fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "doc.text")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                if message.role == .assistant,
                   let providerName = message.providerName,
                   let modelID = message.modelID {
                    Text("\(providerName) · \(modelID)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(9)
            .background(
                (message.role == .user
                    ? BWTheme.accent.opacity(0.10)
                    : Color.secondary.opacity(0.07)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            if message.role == .assistant {
                Spacer(minLength: 28)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func legacyNoteCard(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("此前笔记", systemImage: "note.text")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Toggle(
                    "供 AI 使用",
                    isOn: Binding(
                        get: { legacyNoteContextEnabled },
                        set: { value in
                            onLegacyNoteContextChanged(value)
                        }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("开启后，此前笔记会用于 AI 回应、开花和完整总结的共创章节")
            }

            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(isLegacyNoteExpanded ? nil : 7)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(
                    legacyNoteContextEnabled
                        ? "作为用户观点使用，不会混成录音事实"
                        : "原文保留在本机，暂不发送给 AI"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                Spacer()
                Button(isLegacyNoteExpanded ? "收起" : "展开") {
                    isLegacyNoteExpanded.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
        .padding(9)
        .background(
            BWTheme.accent.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(BWTheme.accent.opacity(0.18), lineWidth: 1)
        }
    }

    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text(text)
                .lineLimit(2)
            if text.contains("设置") {
                Spacer()
                Button("前往设置", action: onOpenSettings)
                    .controlSize(.mini)
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !controller.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(controller.pendingAttachments) { attachment in
                            pendingAttachmentChip(attachment)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    isSelectingReferenceDocuments = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(
                            Color.secondary.opacity(0.10),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    controller.isSending
                        || controller.isLoadingAttachments
                        || controller.pendingAttachments.count
                            >= ProjectAIChatAttachmentPolicy.maximumCount
                )
                .help("引用 PDF、Word、Markdown 或文本")
                .accessibilityLabel("引用文档")
                .accessibilityHint("选择最多四份文档，与本次想法一起发送给 AI")

                ZStack(alignment: .topLeading) {
                    StableNoteEditor(
                        text: $controller.draft,
                        isEditable: !controller.isSending,
                        onSubmit: {
                            guard controller.canSend else { return }
                            Task { await controller.send() }
                        }
                    )
                    if controller.draft.isEmpty {
                        Text("记录想法，或向 AI 追问（⌘↩发送）")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 54, idealHeight: 70, maxHeight: 116)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(0.82),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }

                Button {
                    Task { await controller.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(BWTheme.accent)
                .disabled(!controller.canSend)
                .help("发送想法并获取 AI 反馈（⌘↩）")
                .accessibilityLabel("发送想法并获取 AI 反馈")
            }

            composerStatus
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder
    private var composerStatus: some View {
        if controller.isLoadingAttachments {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在提取引用文档正文…")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if let draftSaveError = controller.draftSaveError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(draftSaveError)
                Spacer()
                Button("重试") {
                    controller.saveDraftNow()
                }
                .buttonStyle(.borderless)
            }
            .font(.caption2)
            .foregroundStyle(.orange)
        } else if !controller.pendingAttachments.isEmpty {
            Text("发送时上传所选正文给当前 AI；仅保存文件名和提取后的文字，不保存原文件路径。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 5) {
                if !controller.draft.isEmpty {
                    if let savedAt = controller.lastDraftSavedAt {
                        Text(
                            "草稿已自动保存 "
                                + savedAt.formatted(
                                    date: .omitted,
                                    time: .shortened
                                )
                        )
                    } else {
                        Text("草稿仅保存在本机")
                    }
                } else {
                    Text("发送后 AI 才会看到，并纳入完整总结")
                }
                Spacer()
                if controller.draft.count > 3_600 {
                    Text(
                        "\(controller.draft.count)/"
                            + "\(ProjectAIChatController.maximumDraftCharacters)"
                    )
                    .foregroundStyle(
                        controller.draft.count
                            > ProjectAIChatController.maximumDraftCharacters
                            ? .orange
                            : .secondary
                    )
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func pendingAttachmentChip(
        _ attachment: ProjectAIChatAttachment
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .foregroundStyle(BWTheme.accent)
            Text(attachment.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            if attachment.wasTruncated {
                Text("已截取")
                    .foregroundStyle(.secondary)
            }
            Button {
                controller.removePendingAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除引用文档 \(attachment.fileName)")
        }
        .font(.caption2)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(
            BWTheme.accent.opacity(0.08),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(BWTheme.accent.opacity(0.25), lineWidth: 1)
        }
    }

    private var normalizedLegacyNote: String? {
        let trimmed = legacyNoteMarkdown.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}
