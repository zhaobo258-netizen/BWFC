import AppKit
import Testing
@testable import BangWoFenXi

@Suite("录音中的共创笔记编辑器")
struct StableNoteEditorTests {
    @Test("中文输入法存在 marked text 时不回写编辑器")
    func preservesMarkedText() {
        #expect(
            !NoteEditorTextSync.shouldApplyExternalText(
                current: "白酒pin",
                incoming: "白酒",
                hasMarkedText: true
            )
        )
    }

    @Test("非输入法组合状态下允许载入真实外部变化")
    func appliesExternalChangesOutsideComposition() {
        #expect(
            NoteEditorTextSync.shouldApplyExternalText(
                current: "旧草稿",
                incoming: "新草稿",
                hasMarkedText: false
            )
        )
        #expect(
            !NoteEditorTextSync.shouldApplyExternalText(
                current: "相同内容",
                incoming: "相同内容",
                hasMarkedText: false
            )
        )
    }

    @Test("回车发送、Shift 回车换行、Command 回车仍发送")
    func plainReturnSubmitsAndShiftReturnInsertsNewline() {
        #expect(NoteEditorSubmitDecision.shouldSubmit(modifiers: [], hasMarkedText: false))
        #expect(!NoteEditorSubmitDecision.shouldSubmit(modifiers: .shift, hasMarkedText: false))
        #expect(NoteEditorSubmitDecision.shouldSubmit(modifiers: .command, hasMarkedText: false))
        // ⇧⌘↩ 仍按发送处理：⌘ 是明确的发送意图
        #expect(NoteEditorSubmitDecision.shouldSubmit(
            modifiers: [.command, .shift], hasMarkedText: false
        ))
        // 其他修饰键不承担发送语义，交回系统默认处理
        #expect(!NoteEditorSubmitDecision.shouldSubmit(modifiers: .option, hasMarkedText: false))
        #expect(!NoteEditorSubmitDecision.shouldSubmit(modifiers: .control, hasMarkedText: false))
    }

    @Test("中文输入法联想未上屏时回车让位给输入法，不发送半截拼音")
    func markedTextNeverSubmits() {
        #expect(!NoteEditorSubmitDecision.shouldSubmit(modifiers: [], hasMarkedText: true))
        #expect(!NoteEditorSubmitDecision.shouldSubmit(modifiers: .command, hasMarkedText: true))
        #expect(!NoteEditorSubmitDecision.shouldSubmit(modifiers: .shift, hasMarkedText: true))
    }

    @Test("大写锁定等不承担语义的修饰位不影响回车发送")
    func capsLockDoesNotBlockSubmit() {
        #expect(NoteEditorSubmitDecision.shouldSubmit(
            modifiers: [.capsLock], hasMarkedText: false
        ))
    }
}
