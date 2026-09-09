import AppKit
import SwiftUI

/// 编辑器回车语义。
enum NoteEditorSubmitPolicy: Equatable {
    /// 旧语义（默认）：↩ 发送，⇧↩ 换行，⌘↩ 也发送。
    case sendOnReturn
    /// A 版语义：↩ 换行、⌘↩ 发送；手写笔记使用 `.never`。
    case newlineOnReturnSendOnCommand
    /// 手写笔记等纯文本场景：永远不触发发送。
    case never
}

struct StableNoteEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var accessibilityLabel = "AI 共创笔记输入"
    var accessibilityHelp = "录音过程中也可连续输入；草稿自动保存在当前项目中；回车发送，Shift Return 换行"
    var submitPolicy: NoteEditorSubmitPolicy = .sendOnReturn
    var onSubmit: () -> Void = {}
    /// 非空时在下次刷新发起一次焦点请求（每次请求传新 UUID，避免每帧抢焦点）
    var focusRequestToken: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = StableNoteTextView()
        textView.submitPolicy = submitPolicy
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = isEditable
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 7, height: 7)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHelp)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable
        (textView as? StableNoteTextView)?.submitPolicy = submitPolicy
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHelp)
        if let token = focusRequestToken,
           context.coordinator.lastHandledFocusToken != token,
           let window = scrollView.window {
            // 一次性聚焦：同一令牌只处理一次，避免每帧抢焦点
            context.coordinator.lastHandledFocusToken = token
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }
        guard NoteEditorTextSync.shouldApplyExternalText(
            current: textView.string,
            incoming: text,
            hasMarkedText: textView.hasMarkedText()
        ) else {
            return
        }
        let selectedRanges = textView.selectedRanges
        context.coordinator.isApplyingExternalText = true
        textView.string = text
        let length = (text as NSString).length
        let safeRanges = selectedRanges.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location <= length else { return nil }
            return NSValue(
                range: NSRange(
                    location: range.location,
                    length: min(range.length, length - range.location)
                )
            )
        }
        if !safeRanges.isEmpty {
            textView.selectedRanges = safeRanges
        }
        context.coordinator.isApplyingExternalText = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StableNoteEditor
        weak var textView: NSTextView?
        var isApplyingExternalText = false
        var lastHandledFocusToken: UUID?

        init(parent: StableNoteEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView else {
                return
            }
            parent.text = textView.string
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            guard parent.submitPolicy != .never else {
                // 手写笔记永不发送：回车一律交回默认换行行为
                return false
            }
            guard NoteEditorSubmitDecision.shouldSubmit(
                modifiers: NSEvent.modifierFlags,
                hasMarkedText: textView.hasMarkedText(),
                policy: parent.submitPolicy
            ) else {
                return false
            }
            parent.onSubmit()
            return true
        }
    }
}

/// Command Return can be dispatched as a key equivalent instead of
/// insertNewline(_:). Handle the native event in both paths, once per event.
@MainActor
final class StableNoteTextView: NSTextView {
    var submitPolicy: NoteEditorSubmitPolicy = .sendOnReturn
    var onSubmit: () -> Void = {}

    private func handlesSubmit(_ event: NSEvent) -> Bool {
        isEditable && (event.keyCode == 36 || event.keyCode == 76)
            && NoteEditorSubmitDecision.shouldSubmit(
                modifiers: event.modifierFlags,
                hasMarkedText: hasMarkedText(),
                policy: submitPolicy)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), handlesSubmit(event) {
            onSubmit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handlesSubmit(event) {
            onSubmit()
        } else {
            super.keyDown(with: event)
        }
    }
}

enum NoteEditorSubmitDecision {
    /// 回车语义（旧默认 `.sendOnReturn`）：↩ 发送，⇧↩ 换行，⌘↩ 仍发送。
    /// A 版 `.newlineOnReturnSendOnCommand`：只有 ⌘↩ 发送，↩ 换行。
    ///
    /// 中文输入法联想未上屏时（hasMarkedText），↩ 是「选中候选词」而不是「发送」，
    /// 此刻发送会把半截拼音当成消息发出去，所以一律让位给输入法。
    static func shouldSubmit(
        modifiers: NSEvent.ModifierFlags,
        hasMarkedText: Bool,
        policy: NoteEditorSubmitPolicy = .sendOnReturn
    ) -> Bool {
        guard !hasMarkedText, policy != .never else { return false }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        switch policy {
        case .newlineOnReturnSendOnCommand:
            return flags.contains(.command)
        case .sendOnReturn:
            if flags.contains(.command) { return true }
            if flags.contains(.shift) { return false }
            return !flags.contains(.option) && !flags.contains(.control)
        case .never:
            return false
        }
    }
}

enum NoteEditorTextSync {
    static func shouldApplyExternalText(
        current: String,
        incoming: String,
        hasMarkedText: Bool
    ) -> Bool {
        !hasMarkedText && current != incoming
    }
}
