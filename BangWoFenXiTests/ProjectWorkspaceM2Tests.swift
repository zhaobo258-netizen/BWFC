import AppKit
import Foundation
import Testing
@testable import BangWoFenXi

/// A 版双区布局边界（M2）：扣除常驻项目侧栏后按可用宽度判定双区/单区。
@Suite("A版双区布局")
final class WorkspaceZoneLayoutTests {
    @Test("637 预览宽与不足双区下限走单区，960 起满足最小宽度走双区")
    func modeBoundaries() {
        #expect(WorkspaceDualZonePolicy.mode(for: 637) == .single)
        #expect(WorkspaceDualZonePolicy.mode(for: 799) == .single)
        #expect(WorkspaceDualZonePolicy.mode(for: 800) == .dual)
        #expect(WorkspaceDualZonePolicy.mode(for: 960) == .dual)
    }

    @Test("双区宽度满足左400右360且恒等：left + right + gap == usableWidth")
    func solveKeepsInvariantAndMinimums() {
        for total: CGFloat in [800, 960, 1_024, 1_200] {
            let widths = WorkspaceDualZonePolicy.solve(usableWidth: total)
            #expect(widths.left + widths.right + WorkspaceDualZonePolicy.gap == total)
            if total >= 800 {
                #expect(widths.left >= WorkspaceDualZonePolicy.leftMinimum)
                #expect(widths.right >= WorkspaceDualZonePolicy.rightMinimum)
            }
        }
        // 不足最小宽度也不产生负值
        let tiny = WorkspaceDualZonePolicy.solve(usableWidth: 637)
        #expect(tiny.left >= 0)
        #expect(tiny.right >= 0)
        #expect(tiny.left + tiny.right + WorkspaceDualZonePolicy.gap == 637)
    }

    @Test("扣除常驻侧栏后才是真正可用宽度")
    func sidebarDeduction() {
        let without = ProjectSidebarWidthAccounting.contentWidth(
            totalWindowWidth: 1280, sidebarShown: false
        )
        #expect(without == 1280)
        let with = ProjectSidebarWidthAccounting.contentWidth(
            totalWindowWidth: 1280, sidebarShown: true
        )
        #expect(with == 1280 - ProjectWorkspaceView.projectSidebarWidth - 1)
        #expect(ProjectSidebarWidthAccounting.zoneMode(
            totalWindowWidth: 1280, sidebarShown: true
        ) == .dual)
        #expect(ProjectSidebarWidthAccounting.zoneMode(
            totalWindowWidth: 637, sidebarShown: false
        ) == .single)
    }
}

/// 人物归属与证据投影（M2 纯逻辑）。
@Suite("人物理解投影")
final class AnalysisPresentationMapperTests {
    private func segment(_ id: UUID, speakerID: UUID?, text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            startMs: 1_000,
            endMs: 3_000,
            text: text,
            participantId: speakerID,
            source: .local,
            state: .final
        )
    }

    @Test("无主体内容不归给证据第一人；openQuestion 属于其他/待确认")
    func unknownSubjectStaysUnassignedAndOpenQuestionIsNotStatement() throws {
        let speakerA = Speaker(cloudAlias: "p_01", displayName: "王经理",
                               isUserConfirmed: true)
        let segA = segment(UUID(), speakerID: speakerA.id, text: "我们要求下月交付。")
        let explicitA = AnalysisItem(
            category: .explicitNeed,
            text: "要求下月交付",
            subjectSpeakerId: nil,
            epistemicStatus: .explicit,
            confidence: .high,
            evidenceSegmentIds: [segA.id]
        )
        let openQuestion = AnalysisItem(
            category: .openQuestion,
            text: "是否真的能下月交付？",
            subjectSpeakerId: speakerA.id,
            epistemicStatus: .inference,
            confidence: .low,
            evidenceSegmentIds: [segA.id]
        )
        let snapshot = ConversationAnalysisSnapshot(
            version: 1,
            analyzedThroughMs: 10_000,
            items: [explicitA, openQuestion]
        )
        let projection = AnalysisPresentationMapper.project(
            snapshot: snapshot,
            speakers: [speakerA],
            segments: [segA]
        )

        // 无主体条目留在归属待确认，绝不上挂到证据第一人
        #expect(projection.people.contains { !$0.explicitNeedsAndCommitments.isEmpty } == false)
        #expect(projection.unassignedEntries.count == 1)
        #expect(projection.unassignedEntries.first?.category == .explicitNeed)

        let person = try #require(projection.people.first)
        // openQuestion 不再冒充“明确说了什么”的原话事实
        #expect(person.spokenSummaryEntries.isEmpty)
        #expect(person.otherExplanations.contains { $0.category == .openQuestion })
    }

    @Test("证据过滤：Entry 只保留当前仍有效的证据 ID")
    func entryKeepsOnlyValidEvidenceIDs() throws {
        let speakerA = Speaker(cloudAlias: "p_01", displayName: "王经理",
                               isUserConfirmed: false)
        let validID = UUID()
        let staleID = UUID()
        let valid = segment(validID, speakerID: speakerA.id, text: "目标是 120 万。")
        let item = AnalysisItem(
            category: .fact,
            text: "目标是 120 万。",
            subjectSpeakerId: speakerA.id,
            epistemicStatus: .explicit,
            confidence: .high,
            evidenceSegmentIds: [validID, staleID]
        )
        let snapshot = ConversationAnalysisSnapshot(
            version: 1,
            analyzedThroughMs: 5_000,
            items: [item]
        )
        let projection = AnalysisPresentationMapper.project(
            snapshot: snapshot,
            speakers: [speakerA],
            segments: [valid]
        )
        let person = try #require(projection.people.first)
        let entry = try #require(person.spokenSummaryEntries.first)
        #expect(entry.evidenceSegmentIDs == [validID])
        #expect(!entry.evidenceSegmentIDs.contains(staleID))
    }

    @Test("只有行动承诺时动机证据不足，不补造动机")
    func actionOnlyYieldsInsufficientMotiveEvidence() throws {
        let speakerA = Speaker(cloudAlias: "p_01", displayName: "王经理",
                               isUserConfirmed: false)
        let segA = segment(UUID(), speakerID: speakerA.id, text: "我会确认后答复。")
        let action = AnalysisItem(
            category: .actionItem,
            text: "会后确认报价口径",
            subjectSpeakerId: speakerA.id,
            epistemicStatus: .explicit,
            confidence: .high,
            evidenceSegmentIds: [segA.id]
        )
        let snapshot = ConversationAnalysisSnapshot(
            version: 1,
            analyzedThroughMs: 5_000,
            items: [action]
        )
        let projection = AnalysisPresentationMapper.project(
            snapshot: snapshot,
            speakers: [speakerA],
            segments: [segA]
        )
        let person = try #require(projection.people.first)
        #expect(person.possibleMotives.isEmpty)
        #expect(person.motiveEvidenceInsufficient)
        #expect(person.explicitNeedsAndCommitments.count == 1)
    }

    @Test("身份状态来自模型真实字段，不因本地编号显示已确认")
    func identityStatusFromRealModelFields() {
        let unconfirmed = Speaker(cloudAlias: "p_07", displayName: "待识别用户",
                                  isUserConfirmed: false)
        let identity = AnalysisPresentationMapper.Identity(
            speakerID: unconfirmed.id,
            displayName: unconfirmed.displayName,
            role: nil,
            isUserConfirmed: unconfirmed.isUserConfirmed,
            isPersonLinked: unconfirmed.personId != nil,
            hasVoiceProfile: unconfirmed.voiceProfileId != nil
                || (unconfirmed.voiceSamplePath?.isEmpty == false)
        )
        #expect(identity.statusText.contains("未确认"))
        let confirmed = Speaker(cloudAlias: "p_01", displayName: "王经理",
                                isUserConfirmed: true, personId: UUID())
        let identity2 = AnalysisPresentationMapper.Identity(
            speakerID: confirmed.id,
            displayName: confirmed.displayName,
            role: nil,
            isUserConfirmed: confirmed.isUserConfirmed,
            isPersonLinked: confirmed.personId != nil,
            hasVoiceProfile: confirmed.voiceProfileId != nil
        )
        #expect(identity2.statusText == "已确认身份")
    }
}

/// 历史证据对照与路由（M2 纯逻辑）。
@Suite("历史证据对照")
final class EvidenceRouteTests {
    private func copy(_ id: UUID, name: String?, startMs: Int64, text: String,
                      wasConfirmed: Bool = true) -> ProjectAIChatEvidenceSnapshot.SegmentCopy {
        ProjectAIChatEvidenceSnapshot.SegmentCopy(
            id: id, startMs: startMs, endMs: startMs + 1_000, text: text,
            participantId: nil, speakerAlias: nil,
            speakerDisplayName: name, speakerWasUserConfirmed: wasConfirmed,
            sourceAssetId: nil, updatedAt: Date()
        )
    }

    private func route(id: UUID, copy: ProjectAIChatEvidenceSnapshot.SegmentCopy) -> EvidenceRouteTarget {
        .aiHistory(turnID: UUID(), requestScopeLabel: "测试轮", copy: copy)
    }

    @Test("文本、归属、时间都未变：intact 且不报变化")
    func intactWithoutChange() {
        let id = UUID()
        let c = copy(id, name: "王经理", startMs: 2_000, text: "报价五百万。")
        let current = TranscriptSegment(
            id: id, startMs: 2_000, endMs: 3_000, text: "报价五百万。",
            participantId: UUID(), source: .local, state: .final
        )
        let status = EvidenceRouteResolver.currentStatus(
            of: route(id: id, copy: c),
            currentSegments: [current]
        ) { _ in EvidenceSpeakerInfo(displayName: "王经理", isUserConfirmed: true) }
        if case .intact = status {
            // 通过
        } else {
            Issue.record("期望 intact，实际 \(status)")
        }
        #expect(!status.speakerOrTimeChanged)
    }

    @Test("归属/姓名变化：显示修订提示且保留当时身份，不用当前人物覆盖标题")
    func speakerChangeReportedAsRevised() {
        let id = UUID()
        let c = copy(id, name: "王经理", startMs: 2_000, text: "报价五百万。")
        let current = TranscriptSegment(
            id: id, startMs: 2_000, endMs: 3_000, text: "报价五百万。",
            participantId: UUID(), source: .local, state: .final
        )
        let status = EvidenceRouteResolver.currentStatus(
            of: route(id: id, copy: c),
            currentSegments: [current]
        ) { _ in EvidenceSpeakerInfo(displayName: "李总监", isUserConfirmed: true) }
        guard case .revised(let historical, let currentCtx) = status else {
            Issue.record("期望 revised，实际 \(status)")
            return
        }
        #expect(historical.speaker?.displayName == "王经理")
        #expect(currentCtx.speaker?.displayName == "李总监")
        #expect(status.speakerOrTimeChanged)
    }

    @Test("片段已移除：显示冻结快照但禁止假定位")
    func missingKeepsSnapshotButCannotLocate() {
        let id = UUID()
        let c = copy(id, name: "王经理", startMs: 2_000, text: "报价五百万。")
        let status = EvidenceRouteResolver.currentStatus(
            of: route(id: id, copy: c),
            currentSegments: []
        ) { _ in nil }
        guard case .missing(let historical) = status else {
            Issue.record("期望 missing，实际 \(status)")
            return
        }
        #expect(historical.text == "报价五百万。")
        #expect(!status.canLocate)
        #expect(status.speakerOrTimeChanged)
    }

    @Test("现场条目（无历史）不被判为变化")
    func liveTargetNeverReportsChange() {
        let id = UUID()
        let current = TranscriptSegment(
            id: id, startMs: 2_000, endMs: 3_000, text: "报价五百万。",
            participantId: UUID(), source: .local, state: .final
        )
        let status = EvidenceRouteResolver.currentStatus(
            of: .live(sourceLabel: "整体理解", segmentID: id),
            currentSegments: [current]
        ) { _ in EvidenceSpeakerInfo(displayName: "王经理", isUserConfirmed: true) }
        #expect(!status.speakerOrTimeChanged)
        #expect(status.canLocate)
    }
}

/// 「摘入笔记」只追加 + 按稳定 ID 去重（M2）。
@Suite("摘入笔记")
final class NoteExcerptInsertionTests {
    @Test("摘入状态即时可观察，保存失败保留内容并允许重试，不重复追加")
    @MainActor
    func observableInsertionAndSaveRetry() {
        let project = Project(title: "合成保存失败", sourceType: .importedAudio,
                              note: NoteDocument(markdown: "原有手写"))
        var fails = true
        var savedIDs: [UUID] = []
        let controller = NoteController(project: project, persist: { incoming in
            if fails { throw CocoaError(.fileWriteUnknown) }
            savedIDs = incoming.note.insertedSummaryIDs
        })
        let summary = NoteDocument.ConversationSummary(id: UUID(), markdown: "合成归结", createdAt: Date())
        #expect(controller.insertSummary(summary) == .inserted(summary.id))
        #expect(controller.insertedSummaryIDs == [summary.id])
        #expect(controller.saveError != nil)
        let pendingMarkdown = controller.markdown
        #expect(controller.insertSummary(summary) == .duplicate)
        #expect(controller.markdown == pendingMarkdown)
        fails = false
        #expect(controller.saveNow())
        #expect(controller.saveError == nil)
        #expect(savedIDs == [summary.id])
        #expect(project.note.markdown == pendingMarkdown)
    }

    @Test("摘入标记跨存储重开保留，旧 AI 上下文合并不会抹掉标记或手写正文")
    func insertionSurvivesPersistenceAndStaleAIContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONProjectStore(directory: directory)
        let summary = NoteDocument.ConversationSummary(id: UUID(), markdown: "合成归结", createdAt: Date())
        let project = Project(title: "合成摘入持久化", sourceType: .importedAudio,
                              note: NoteDocument(markdown: " 原有正文\n"))
        project.note.conversationSummaries = [summary]
        try store.saveProjects([project])
        let staleAIProject = try #require(store.loadProjects().first)
        let edited = try #require(store.loadProjects().first)
        var editedNote = edited.note
        #expect(NoteExcerptInsertion.insert(summary: summary, into: &editedNote.markdown,
            insertedIDs: &editedNote.insertedSummaryIDs) == .inserted(summary.id))
        edited.note = editedNote
        let expectedMarkdown = edited.note.markdown
        var projects = try store.loadProjects()
        ProjectPersistence.upsert(edited, into: &projects, fields: .note)
        try store.saveProjects(projects)
        let reopenedStore = try JSONProjectStore(directory: directory)
        projects = try reopenedStore.loadProjects()
        #expect(projects.first?.note.insertedSummaryIDs == [summary.id])
        staleAIProject.note.conversationSummaries.append(
            NoteDocument.ConversationSummary(id: UUID(), markdown: "下一轮合成归结", createdAt: Date()))
        ProjectPersistence.upsert(staleAIProject, into: &projects, fields: .aiContext)
        try reopenedStore.saveProjects(projects)
        let restored = try #require(JSONProjectStore(directory: directory).loadProjects().first)
        #expect(restored.note.markdown == expectedMarkdown)
        #expect(restored.note.conversationSummaries.count == 2)
        #expect(restored.note.insertedSummaryIDs == [summary.id])
        var restoredNote = restored.note
        #expect(NoteExcerptInsertion.insert(summary: summary, into: &restoredNote.markdown,
            insertedIDs: &restoredNote.insertedSummaryIDs) == .duplicate)
        #expect(restoredNote.markdown == expectedMarkdown)
        #expect(restored.note.markdown == expectedMarkdown)
    }

    @Test("只追加，不改既有正文任何字符")
    func appendOnly() throws {
        let summary = NoteDocument.ConversationSummary(
            id: UUID(),
            markdown: "- 归结一：报价五百万。",
            createdAt: Date()
        )
        var note = " 首行缩进开头\n\t第二行前有制表符\n正文末尾无换行"
        var inserted: [UUID] = []
        let result = NoteExcerptInsertion.insert(
            summary: summary, into: &note, insertedIDs: &inserted
        )
        #expect(result == .inserted(summary.id))
        #expect(note.hasPrefix(" 首行缩进开头\n\t第二行前有制表符\n正文末尾无换行"))
        #expect(inserted == [summary.id])
        #expect(note.contains(summary.markdown))
    }

    @Test("同一轮次不重复插入")
    func deduplicatesByStableID() {
        let summary = NoteDocument.ConversationSummary(
            id: UUID(),
            markdown: "- 归结一。",
            createdAt: Date()
        )
        var note = "原有正文"
        var inserted: [UUID] = [summary.id]
        let second = NoteExcerptInsertion.insert(
            summary: summary, into: &note, insertedIDs: &inserted
        )
        #expect(second == .duplicate)
        #expect(note == "原有正文")
    }

    @Test("空归结不插入")
    func emptySummaryIsRejected() {
        let summary = NoteDocument.ConversationSummary(
            id: UUID(),
            markdown: "  \n ",
            createdAt: Date()
        )
        var note = "原有正文"
        var inserted: [UUID] = []
        let result = NoteExcerptInsertion.insert(
            summary: summary, into: &note, insertedIDs: &inserted
        )
        #expect(result == .emptySummary)
        #expect(inserted.isEmpty)
    }
}

/// StableNoteEditor 提交策略（M2：A 版 Enter 换行、Cmd+Enter 发送；手写笔记永不 submit）。
@Suite("StableNoteEditor 提交策略")
final class NoteEditorSubmitPolicyTests {
    @Test("旧语义默认不变：↩ 发送、⇧↩ 换行、⌘↩ 发送")
    func legacyDefaultSemanticsPreserved() {
        #expect(NoteEditorSubmitDecision.shouldSubmit(
            modifiers: [], hasMarkedText: false, policy: .sendOnReturn))
        #expect(!NoteEditorSubmitDecision.shouldSubmit(
            modifiers: .shift, hasMarkedText: false, policy: .sendOnReturn))
        #expect(NoteEditorSubmitDecision.shouldSubmit(
            modifiers: .command, hasMarkedText: false, policy: .sendOnReturn))
    }

    @Test("A 版语义：↩ 换行，仅 ⌘↩ 发送")
    func aEditionSendOnCommandReturn() {
        #expect(!NoteEditorSubmitDecision.shouldSubmit(
            modifiers: [], hasMarkedText: false, policy: .newlineOnReturnSendOnCommand))
        #expect(NoteEditorSubmitDecision.shouldSubmit(
            modifiers: .command, hasMarkedText: false, policy: .newlineOnReturnSendOnCommand))
        #expect(!NoteEditorSubmitDecision.shouldSubmit(
            modifiers: .shift, hasMarkedText: false, policy: .newlineOnReturnSendOnCommand))
    }

    @Test("手写笔记永不发送；输入法联想期间任何策略都不发送")
    func neverAndMarkedTextRules() {
        #expect(!NoteEditorSubmitDecision.shouldSubmit(
            modifiers: [], hasMarkedText: false, policy: .never))
        #expect(!NoteEditorSubmitDecision.shouldSubmit(
            modifiers: .command, hasMarkedText: false, policy: .never))
        #expect(!NoteEditorSubmitDecision.shouldSubmit(
            modifiers: [], hasMarkedText: true, policy: .sendOnReturn))
        #expect(!NoteEditorSubmitDecision.shouldSubmit(
            modifiers: .command, hasMarkedText: true, policy: .newlineOnReturnSendOnCommand))
    }
}

/// 范围切换保留草稿、绝不自动发送（M2）。
@Suite("范围切换草稿保持")
@MainActor
final class QueryScopeDraftPreservationTests {
    private actor CaptureService: ProjectAIChatServing {
        private var requests: [ProjectAIChatRequest] = []
        func captured() -> [ProjectAIChatRequest] { requests }
        func reply(to request: ProjectAIChatRequest) async throws -> ProjectAIChatResponse {
            requests.append(request)
            return ProjectAIChatResponse(reply: "片段回答", provider: AIProviderDescriptor(
                id: "mock", displayName: "测试", modelID: "m"))
        }
    }

    @Test("从默认联网切到原话后可以直接发送，实际请求不联网")
    func strictSelectionCanSendFromDefaultState() async throws {
        let segment = TranscriptSegment(startMs: 1000, endMs: 2000,
            text: "请先确认验收口径", source: .local, state: .final)
        let project = Project(title: "合成范围测试", sourceType: .importedAudio, segments: [segment])
        let service = CaptureService()
        let controller = ProjectAIChatController(service: service, persist: { _ in })
        controller.attach(to: project)
        #expect(controller.isWebSearchEnabled)
        #expect(controller.setQueryScope(.selectedSegments(selectedSegmentIDs: [segment.id])))
        #expect(!controller.isWebSearchEnabled)
        controller.draft = "这句话说了什么？"
        await controller.send()
        let requests = await service.captured()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(!request.webSearchEnabled)
        #expect(request.transcript.map(\.id) == [segment.id.uuidString])
        #expect(project.aiChatMessages.last?.role == .assistant)
    }

    @Test("重新打开已保存片段范围时不恢复为联网开启")
    func reattachStrictScopeKeepsWebOff() {
        let project = Project(title: "恢复范围", sourceType: .importedAudio)
        project.aiChatQueryScope = .selectedSegments(selectedSegmentIDs: [UUID()])
        let controller = ProjectAIChatController(service: NoopService(), persist: { _ in })
        controller.attach(to: project)
        #expect(controller.queryScope.isStrictSegments)
        #expect(!controller.isWebSearchEnabled)
    }

    @Test("范围保存失败不改变原联网设置与范围")
    func failedScopeSavePreservesWebSetting() {
        let project = Project(title: "保存失败", sourceType: .importedAudio)
        let controller = ProjectAIChatController(service: NoopService(), persist: { _ in
            throw CocoaError(.fileWriteUnknown)
        })
        controller.attach(to: project)
        #expect(!controller.setQueryScope(.selectedSegments(selectedSegmentIDs: [UUID()])))
        #expect(controller.queryScope == .wholeConversation)
        #expect(controller.isWebSearchEnabled)
    }

    private final class NoopService: ProjectAIChatServing, @unchecked Sendable {
        func reply(to request: ProjectAIChatRequest) async throws
            -> ProjectAIChatResponse {
            ProjectAIChatResponse(
                reply: "测试回答",
                provider: AIProviderDescriptor(id: "mock", displayName: "测试", modelID: "m")
            )
        }
    }

    @Test("切换范围后草稿原样保留，不触发发送")
    func draftSurvivesScopeSwitch() throws {
        let project = Project(title: "范围测试", sourceType: .importedAudio)
        let controller = ProjectAIChatController(
            service: NoopService(),
            persist: { _ in }
        )
        controller.attach(to: project)
        controller.draft = "待发送的草稿：仍然保留"
        let beforeDraft = controller.draft

        let scope = ProjectAIChatQueryScope.selectedSegments(
            selectedSegmentIDs: [UUID()]
        )
        let applied = controller.setQueryScope(scope)
        #expect(applied)
        #expect(controller.draft == beforeDraft)
        #expect(controller.queryScope == scope)
        #expect(project.aiChatMessages.isEmpty)

        let back = controller.setQueryScope(.wholeConversation)
        #expect(back)
        #expect(controller.draft == beforeDraft)
        #expect(controller.queryScope == .wholeConversation)
        #expect(project.aiChatMessages.isEmpty)
    }
}
