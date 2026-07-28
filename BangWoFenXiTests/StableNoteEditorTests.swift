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
}
