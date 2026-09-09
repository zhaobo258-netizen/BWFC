import AppKit
import Testing
@testable import BangWoFenXi

@Suite("A版原生编辑器键盘事件")
@MainActor
struct StableNoteEditorNativeEventTests {
    @Test("真实Command Return事件作为key equivalent可发送且只调用一次")
    func commandReturnKeyEquivalent() throws {
        let editor = StableNoteTextView()
        editor.submitPolicy = .newlineOnReturnSendOnCommand
        editor.isEditable = true
        var count = 0
        editor.onSubmit = { count += 1 }
        let event = try #require(NSEvent.keyEvent(with: .keyDown,
            location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(editor.performKeyEquivalent(with: event))
        #expect(count == 1)
    }

    @Test("手写笔记与不可编辑状态不能经原生快捷键发送")
    func protectedEditorDoesNotSubmit() throws {
        let editor = StableNoteTextView()
        var count = 0
        editor.onSubmit = { count += 1 }
        let event = try #require(NSEvent.keyEvent(with: .keyDown,
            location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.submitPolicy = .never
        _ = editor.performKeyEquivalent(with: event)
        editor.submitPolicy = .newlineOnReturnSendOnCommand
        editor.isEditable = false
        _ = editor.performKeyEquivalent(with: event)
        #expect(count == 0)
    }
}
