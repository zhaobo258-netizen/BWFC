import Foundation
import Testing
@testable import BangWoFenXi

@Suite("A版界面收尾合同")
struct AWorkspaceAcceptanceTests {
    @Test("笔记整区占总高四分之一，矮窗为回复留出空间")
    func noteHeightBudget() {
        #expect(ThoughtWorkspaceNoteHeightPolicy.reservedNoteHeight(totalHeight: 620) == 155)
        #expect(ThoughtWorkspaceNoteHeightPolicy.editorHeight(totalHeight: 620) == 93)
        #expect(ThoughtWorkspaceNoteHeightPolicy.shouldExpandNotes(totalHeight: 620))
        #expect(!ThoughtWorkspaceNoteHeightPolicy.shouldExpandNotes(totalHeight: 520))
        #expect(ThoughtWorkspaceNoteHeightPolicy.reservedNoteHeight(totalHeight: 1200) == 180)
        #expect(ThoughtWorkspaceNoteHeightPolicy.editorHeight(totalHeight: 0) == 0)
    }

    @Test("历史定位按轮次找回答，不将缺失轮次指向最新回答")
    func historicalTurnSelection() {
        let oldTurn = UUID(), newTurn = UUID()
        let old = ProjectAIChatMessage(role: .assistant, text: "当时回答", turnID: oldTurn)
        let messages = [ProjectAIChatMessage(role: .user, text: "旧问题", turnID: oldTurn), old,
            ProjectAIChatMessage(role: .assistant, text: "新回答", turnID: newTurn)]
        #expect(AIChatTurnLocator.assistantMessageID(turnID: oldTurn, in: messages) == old.id)
        #expect(AIChatTurnLocator.assistantMessageID(turnID: UUID(), in: messages) == nil)
        #expect(!AIChatTurnLocator.isRetained(turnID: oldTurn, in: []))
        #expect(AIChatNavigationRequest(turnID: oldTurn).id != AIChatNavigationRequest(turnID: oldTurn).id)
    }

    @Test("来源提问仅允许当前有效的定稿或修订原话")
    func currentQuoteEligibility() {
        #expect(!EvidenceSegmentAskEligibility.canAsk(segment: nil))
        let segment = TranscriptSegment(startMs: 1000, endMs: 2000,
            text: "合成原话", source: .local, state: .final)
        #expect(EvidenceSegmentAskEligibility.canAsk(segment: segment))
        segment.state = .edited
        #expect(EvidenceSegmentAskEligibility.canAsk(segment: segment))
        segment.text = " \n "
        #expect(!EvidenceSegmentAskEligibility.canAsk(segment: segment))
    }
}
