import AppKit
import SwiftUI

struct StableNoteEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var accessibilityLabel = "AI 共创笔记输入"
    var accessibilityHelp = "录音过程中也可连续输入；草稿自动保存在当前项目中；回车发送，Shift Return 换行"
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
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
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHelp)
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
            guard NoteEditorSubmitDecision.shouldSubmit(
                modifiers: NSEvent.modifierFlags,
                hasMarkedText: textView.hasMarkedText()
            ) else {
                return false
            }
            parent.onSubmit()
            return true
        }
    }
}

enum NoteEditorSubmitDecision {
    /// 回车语义：↩ 发送，⇧↩ 换行，⌘↩ 仍发送（保留老习惯）。
    ///
    /// 中文输入法联想未上屏时（hasMarkedText），↩ 是「选中候选词」而不是「发送」，
    /// 此刻发送会把半截拼音当成消息发出去，所以一律让位给输入法。
    static func shouldSubmit(
        modifiers: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> Bool {
        guard !hasMarkedText else { return false }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return true }
        if flags.contains(.shift) { return false }
        return !flags.contains(.option) && !flags.contains(.control)
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
