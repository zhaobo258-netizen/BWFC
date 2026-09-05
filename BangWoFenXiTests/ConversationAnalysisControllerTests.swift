import Foundation
import Testing
@testable import BangWoFenXi

/// V2 通用分析调度（阶段 D，03 §9.2 / §10.3）：
/// 触发 / 防抖 / 串行 / 游标 / 非法结果保留上一版 / 场景建议与用户修正。
@Suite("通用分析调度")
@MainActor
final class ConversationAnalysisControllerTests {
    let mock: MockConversationAnalysisService
    let controller: ConversationAnalysisController
    let project: Project
    private let nowBox: LockedBox<Int64>

    init() {
        mock = MockConversationAnalysisService()
        let nowBox = LockedBox<Int64>(1_000_000)
        self.nowBox = nowBox
        controller = ConversationAnalysisController(
            service: mock,
            nowMs: { nowBox.withLock { $0 } }
        )
        project = Project(title: "调度测试", sourceType: .liveRecording)
        project.speakers.append(
            Speaker(cloudAlias: "p_01", displayName: "王经理", role: "客户采购")
        )
        controller.attach(to: project)
    }

    /// 推进假时钟（毫秒）
    private func advance(_ ms: Int64) {
        nowBox.withLock { $0 += ms }
    }

    /// 向项目添加一个最终片段并通知调度器
    @discardableResult
    private func addFinalSegment(startMs: Int64, text: String) -> TranscriptSegment {
        let segment = TranscriptSegment(
            startMs: startMs, endMs: startMs + 2_000, text: text,
            participantId: project.speakers[0].id,
            source: .local, state: .final
        )
        project.segments.append(segment)
        controller.noteNewFinalSegment()
        return segment
    }

    /// 满足触发条件的三个片段
    private func addThreeSegments() {
        addFinalSegment(startMs: 0, text: "第一句。")
        addFinalSegment(startMs: 2_000, text: "第二句。")
        addFinalSegment(startMs: 4_000, text: "第三句。")
    }

    /// 造一个引用真实片段的合法条目
    private func makeItem(text: String, category: String = "fact",
                          evidence: TranscriptSegment) -> ConversationAnalysisOutputDTO.ItemDTO {
        ConversationAnalysisOutputDTO.ItemDTO(
            category: category, text: text, subjectSpeakerId: "p_01",
            epistemicStatus: "explicit", confidence: "high",
            evidenceSegmentIds: [evidence.id.uuidString]
        )
    }

    @Test("不足 3 个新片段不发起分析")
    func belowThresholdNoCall() async {
        addFinalSegment(startMs: 0, text: "第一句。")
        addFinalSegment(startMs: 2_000, text: "第二句。")
        advance(20_000)
        await controller.tick()
        #expect(mock.calls.isEmpty)
    }

    @Test("满 3 个片段且过防抖：发起分析、快照落到 Project、游标推进、持久化回调触发")
    func firesAfterDebounce() async {
        addThreeSegments()
        var persisted = false
        controller.onSnapshotUpdated = { persisted = true }

        await controller.tick()
        #expect(mock.calls.isEmpty, "防抖未过不触发")

        advance(10_100)
        await controller.tick()
        #expect(mock.calls.count == 1)
        #expect(controller.currentSnapshot?.version == 1)
        #expect(controller.currentSnapshot?.analyzedThroughMs == 6_000, "游标推进到已分析片段末尾")
        #expect(project.analysisSnapshots.count == 1, "快照写入 Project 权威容器")
        #expect(persisted, "快照更新必须触发持久化回调")
        #expect(controller.lastSuccessAt != nil)
        #expect(mock.calls[0].instructions == ConversationAnalysisPrompt.text(scenario: nil),
                "未选场景时使用 auto 指令")
    }

    @Test("增量：新片段按游标发送，旧证据和上一版状态分别进入独立字段")
    func incrementalUsesCursor() async throws {
        addThreeSegments()
        let evidence = try #require(project.segments.first)
        mock.resultQueue = [ConversationAnalysisOutputDTO(
            headline: "第一版总览", detectedScenario: nil, scenarioConfidence: nil,
            items: [makeItem(text: "第一版条目", evidence: evidence)]
        )]
        advance(10_100)
        await controller.tick()
        #expect(controller.currentSnapshot?.version == 1)

        addFinalSegment(startMs: 6_000, text: "第四句。")
        addFinalSegment(startMs: 8_000, text: "第五句。")
        addFinalSegment(startMs: 10_000, text: "第六句。")
        advance(10_100)
        await controller.tick()

        #expect(mock.calls.count == 2)
        let secondInput = mock.calls[1].inputJSON
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(secondInput.utf8)) as? [String: Any]
        )
        let transcript = try #require(payload["untrusted_transcript_data"] as? [String: Any])
        let newSegments = try #require(transcript["new_segments"] as? [[String: Any]])
        #expect(newSegments.count == 3)
        #expect(newSegments.compactMap { $0["text"] as? String } == ["第四句。", "第五句。", "第六句。"])
        #expect(newSegments.compactMap { $0["id"] as? String } == project.segments.suffix(3).map { $0.id.uuidString })
        let previousEvidence = try #require(transcript["previous_evidence_segments"] as? [[String: Any]])
        #expect(previousEvidence.count == 1)
        #expect(previousEvidence.first?["id"] as? String == evidence.id.uuidString)
        #expect(previousEvidence.first?["text"] as? String == "第一句。")
        let previousState = try #require(payload["previous_state"] as? [String: Any])
        #expect(previousState["headline"] as? String == "第一版总览")
        let previousItems = try #require(previousState["items"] as? [[String: Any]])
        #expect(previousItems.count == 1)
        #expect(previousItems.first?["text"] as? String == "第一版条目")
        #expect(previousItems.first?["evidence_segment_ids"] as? [String] == [evidence.id.uuidString])
        #expect(controller.currentSnapshot?.version == 2)
        #expect(project.analysisSnapshots.count == 2)
    }

    @Test("证据校验端到端：云端返回引用不存在片段的项不进快照")
    func evidenceFilteringEndToEnd() async throws {
        addThreeSegments()
        let real = try #require(project.segments.first)
        mock.resultQueue = [ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: nil, scenarioConfidence: nil,
            items: [
                ConversationAnalysisOutputDTO.ItemDTO(
                    category: "fact", text: "引用不存在片段", subjectSpeakerId: nil,
                    epistemicStatus: "explicit", confidence: "high",
                    evidenceSegmentIds: [UUID().uuidString]
                ),
                makeItem(text: "引用真实片段", evidence: real)
            ]
        )]
        advance(10_100)
        await controller.tick()
        let snapshot = try #require(controller.currentSnapshot)
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items.first?.text == "引用真实片段")
        #expect(snapshot.items.first?.subjectSpeakerId == project.speakers[0].id,
                "代号回映射为本地说话人 ID")
    }

    @Test("串行：分析期间的 tick 不并发第二个请求（长会议不堆积）")
    func serialSingleRequest() async {
        mock.delayMs = 300
        addThreeSegments()
        advance(10_100)

        async let first: Void = controller.tick()
        try? await Task.sleep(for: .milliseconds(50))
        addFinalSegment(startMs: 6_000, text: "第四句。")
        await controller.tick()
        await first
        try? await Task.sleep(for: .milliseconds(500))

        let callCount = mock.calls.count
        #expect(callCount <= 2, "同一时间最多一个请求；新内容合并到下一次，实际 \(callCount) 次")
    }

    @Test("分析期间新增片段须重新满足防抖后才补发")
    func pendingFireRechecksDebounce() async {
        var trigger = AnalysisTrigger()
        trigger.minNewSegments = 1
        trigger.failureRetryMs = 0
        let clock = LockedBox<Int64>(2_000_000)
        let service = MockConversationAnalysisService()
        service.suspendNextCall = true
        service.errorQueue = [AnalysisAPIError.invalidResponse]
        let controller = ConversationAnalysisController(
            service: service,
            triggerConfig: trigger,
            nowMs: { clock.withLock { $0 } }
        )
        let project = Project(title: "防抖复核", sourceType: .liveRecording)
        controller.attach(to: project)

        func addSegment(_ index: Int) {
            project.segments.append(TranscriptSegment(
                startMs: Int64(index * 2_000),
                endMs: Int64((index + 1) * 2_000),
                text: "片段 \(index)",
                source: .local,
                state: .final
            ))
            controller.noteNewFinalSegment()
        }

        addSegment(0)
        clock.withLock { $0 += 10_100 }
        async let first: Void = controller.tick()
        await waitUntil { service.hasSuspendedCall }

        addSegment(1)
        clock.withLock { $0 += 10_100 }
        await controller.tick()
        addSegment(2)

        service.resumeSuspendedCall()
        await first

        #expect(service.calls.count == 1, "最新片段重置防抖后不得立即补发")

        clock.withLock { $0 += 10_100 }
        await controller.tick()
        #expect(service.calls.count == 2, "推进假时钟越过防抖后才补发")
    }

    @Test("成功请求在途新增片段不丢失，当前请求完成后自动补发")
    func successfulInFlightRequestPreservesPendingSegments() async throws {
        var trigger = AnalysisTrigger()
        trigger.minNewSegments = 1
        trigger.debounceMs = 0
        trigger.failureRetryMs = 0
        let clock = LockedBox<Int64>(3_000_000)
        let service = MockConversationAnalysisService()
        service.suspendNextCall = true
        let controller = ConversationAnalysisController(
            service: service,
            triggerConfig: trigger,
            nowMs: { clock.withLock { $0 } }
        )
        let project = Project(title: "在途新片段", sourceType: .liveRecording)
        controller.attach(to: project)

        func addSegment(_ index: Int) {
            project.segments.append(TranscriptSegment(
                startMs: Int64(index * 2_000),
                endMs: Int64((index + 1) * 2_000),
                text: "在途片段 \(index)",
                source: .local,
                state: .final
            ))
            controller.noteNewFinalSegment()
        }

        addSegment(0)
        async let first: Void = controller.tick()
        await waitUntil { service.hasSuspendedCall }

        addSegment(1)
        await controller.tick()
        service.resumeSuspendedCall()
        await first

        #expect(service.calls.count == 2, "在途到达的最终片段必须自动补发")
        let secondInput = try #require(service.calls.last?.inputJSON)
        #expect(secondInput.contains("在途片段 1"))
        #expect(!secondInput.contains("在途片段 0"), "补发仍按游标做增量")
        #expect(controller.currentSnapshot?.analyzedThroughMs == 4_000)
    }

    @Test("旧片段说话人修正后重新进入增量分析，游标不回退")
    func changedSpeakerContextReentersIncrementalAnalysis() async throws {
        addThreeSegments()
        advance(10_100)
        await controller.tick()
        #expect(controller.currentSnapshot?.analyzedThroughMs == 6_000)

        let firstSegment = try #require(project.segments.first)
        let correctedSpeaker = Speaker(
            cloudAlias: "p_02",
            displayName: "李经理",
            role: "项目负责人"
        )
        project.speakers.append(correctedSpeaker)
        firstSegment.participantId = correctedSpeaker.id
        controller.noteSpeakerContextChanged(segmentIDs: [firstSegment.id])

        advance(10_100)
        await controller.tick()

        #expect(mock.calls.count == 2)
        let inputData = try #require(mock.calls.last?.inputJSON.data(using: .utf8))
        let input = try #require(
            try JSONSerialization.jsonObject(with: inputData) as? [String: Any]
        )
        let untrusted = try #require(
            input["untrusted_transcript_data"] as? [String: Any]
        )
        let segments = try #require(untrusted["new_segments"] as? [[String: Any]])
        #expect(segments.count == 1)
        #expect(segments[0]["id"] as? String == firstSegment.id.uuidString)
        #expect(segments[0]["speaker_id"] as? String == "p_02")
        #expect(controller.currentSnapshot?.analyzedThroughMs == 6_000,
                "只重发旧片段时不得使分析游标回退")
    }

    @Test("云端更正与晚到旧时间戳片段经运行时同步后重新进入分析")
    func cloudRevisionsFlowThroughRuntimeIntoAnalysis() async throws {
        let correctedSpeaker = Speaker(
            cloudAlias: "p_02", displayName: "李经理", role: "项目负责人"
        )
        project.speakers.append(correctedSpeaker)
        let original = TranscriptSegment(
            startMs: 0, endMs: 2_000,
            text: "本次试点需要由采购负责人再次确人。",
            participantId: project.speakers[0].id, source: .local, state: .final
        )
        let later = TranscriptSegment(
            startMs: 8_000, endMs: 10_000, text: "流程确认以后再扩围。",
            participantId: project.speakers[0].id, source: .local, state: .final
        )
        project.segments = [original, later]
        project.analysisSnapshots = [ConversationAnalysisSnapshot(
            version: 1, analyzedThroughMs: 10_000,
            items: [AnalysisItem(
                category: .possibleMotive, text: "等待采购确认。",
                subjectSpeakerId: project.speakers[0].id,
                epistemicStatus: .inference, confidence: .medium,
                evidenceSegmentIds: [original.id]
            )]
        )]
        let clock = nowBox
        let analysis = ConversationAnalysisController(
            service: mock, triggerConfig: .liveRecording,
            nowMs: { clock.withLock { $0 } }
        )
        analysis.attach(to: project)
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        let transcription = LocalTranscriptionController(service: MockLocalTranscriptionService())
        transcription.attach(to: meeting)
        var persistedCount = 0
        let runtime = ProjectRuntimePersistenceController(
            meeting: meeting, project: project,
            persist: { _ in persistedCount += 1 }, debounce: .seconds(60)
        )
        transcription.onFinalSegment = { runtime.schedule() }
        transcription.onNewFinalSegment = { segmentID in
            analysis.noteNewFinalSegment(segmentID: segmentID)
        }
        mock.resultQueue = [ConversationAnalysisOutputDTO(
            headline: "已按云端更正更新", detectedScenario: nil, scenarioConfidence: nil,
            items: [ConversationAnalysisOutputDTO.ItemDTO(
                category: "possible_motive", text: "项目负责人正在推进确认。",
                subjectSpeakerId: "p_02", epistemicStatus: "inference", confidence: "medium",
                evidenceSegmentIds: [original.id.uuidString]
            )]
        )]

        transcription.applyCloudSegment(
            wallStartMs: 0, wallEndMs: 2_000,
            text: "本次试点需要由采购负责人再次确认。",
            participantId: correctedSpeaker.id, remoteSpeakerLabel: "p_02"
        )
        transcription.applyCloudSegment(
            wallStartMs: 4_000, wallEndMs: 6_000, text: "补充验收口径后再定目标。",
            participantId: project.speakers[0].id, remoteSpeakerLabel: "p_01"
        )
        let lateID = try #require(meeting.segments.first { $0.startMs == 4_000 }?.id)
        #expect(project.segments.count == 2)
        #expect(project.segments.first?.text == "本次试点需要由采购负责人再次确人。")
        #expect(!project.segments.contains { $0.id == lateID },
                "变更通知发出时，新增片段尚未同步到 Project")
        #expect(runtime.hasPendingChanges)
        #expect(persistedCount == 0)

        #expect(runtime.flush())
        #expect(persistedCount == 1)
        advance(5_100)
        await analysis.tick()

        #expect(mock.calls.count == 1)
        let inputData = try #require(mock.calls.last?.inputJSON.data(using: .utf8))
        let input = try #require(
            try JSONSerialization.jsonObject(with: inputData) as? [String: Any]
        )
        let untrusted = try #require(input["untrusted_transcript_data"] as? [String: Any])
        let segments = try #require(untrusted["new_segments"] as? [[String: Any]])
        #expect(segments.compactMap { $0["id"] as? String } == [original.id.uuidString, lateID.uuidString])
        #expect(segments.compactMap { $0["text"] as? String } == [
            "本次试点需要由采购负责人再次确认。", "补充验收口径后再定目标。"
        ])
        #expect(segments.first?["speaker_id"] as? String == "p_02")
        #expect(analysis.currentSnapshot?.analyzedThroughMs == 10_000)
        #expect(analysis.currentSnapshot?.version == 2)
        #expect(analysis.currentSnapshot?.items.first?.subjectSpeakerId == correctedSpeaker.id)

        advance(60_000)
        await analysis.tick()
        #expect(mock.calls.count == 1, "已消费的云端修订不应重复分析")
    }

    @Test("AI 推断卡片可独立确认说话人并持久化，不篡改多条证据原话")
    func confirmsAnalysisItemSpeakerWithoutChangingTranscript() async throws {
        let first = addFinalSegment(startMs: 0, text: "甲方提问。")
        let second = addFinalSegment(startMs: 2_000, text: "乙方回答。")
        first.participantId = nil
        second.participantId = nil
        let item = AnalysisItem(
            category: .possibleMotive,
            text: "希望尽快推进",
            epistemicStatus: .inference,
            confidence: .medium,
            evidenceSegmentIds: [first.id, second.id]
        )
        project.analysisSnapshots = [ConversationAnalysisSnapshot(
            version: 3,
            analyzedThroughMs: 4_000,
            items: [item]
        )]
        controller.attach(to: project)
        var persisted = false
        controller.onSnapshotUpdated = { persisted = true }

        let confirmed = controller.confirmSubjectSpeaker(
            itemID: item.id,
            speakerID: project.speakers[0].id
        )

        #expect(confirmed)
        #expect(controller.currentSnapshot?.version == 4)
        #expect(controller.currentSnapshot?.items.first?.subjectSpeakerId == project.speakers[0].id)
        #expect(project.analysisSnapshots.last?.items.first?.subjectSpeakerId == project.speakers[0].id)
        #expect(project.analysisSpeakerOverrides.count == 1)
        #expect(first.participantId == nil)
        #expect(second.participantId == nil)
        #expect(persisted)

        mock.resultQueue = [ConversationAnalysisOutputDTO(
            headline: nil,
            detectedScenario: nil,
            scenarioConfidence: nil,
            items: [ConversationAnalysisOutputDTO.ItemDTO(
                category: "possible_motive",
                text: "希望尽快推进",
                subjectSpeakerId: nil,
                epistemicStatus: "inference",
                confidence: "medium",
                evidenceSegmentIds: [first.id.uuidString, second.id.uuidString]
            )]
        )]
        await controller.generateFinalAnalysis()
        #expect(controller.currentSnapshot?.items.first?.subjectSpeakerId == project.speakers[0].id,
                "后续模型遗漏 subject 时仍保留用户确认")
    }

    @Test("说话人确认持久化失败时回滚快照和覆盖")
    func confirmationPersistenceFailureRollsBack() throws {
        let evidence = addFinalSegment(startMs: 0, text: "需要确认归属。")
        let item = AnalysisItem(
            category: .possibleMotive,
            text: "希望尽快推进",
            epistemicStatus: .inference,
            confidence: .medium,
            evidenceSegmentIds: [evidence.id]
        )
        let original = ConversationAnalysisSnapshot(
            version: 3,
            analyzedThroughMs: evidence.endMs,
            items: [item]
        )
        project.analysisSnapshots = [original]
        controller.attach(to: project)
        controller.persistManualSpeakerConfirmation = {
            throw AnalysisAPIError.network
        }

        let confirmed = controller.confirmSubjectSpeaker(
            itemID: item.id,
            speakerID: project.speakers[0].id
        )

        #expect(!confirmed)
        #expect(controller.currentSnapshot === original)
        #expect(project.analysisSnapshots.count == 1)
        #expect(project.analysisSnapshots[0] === original)
        #expect(project.analysisSpeakerOverrides.isEmpty)
    }

    @Test("非法 JSON：保留上一版快照，不推进游标，状态如实提示")
    func invalidResponseKeepsPreviousSnapshot() async throws {
        addThreeSegments()
        let evidence = try #require(project.segments.first)
        mock.resultQueue = [ConversationAnalysisOutputDTO(
            headline: "第一版", detectedScenario: nil, scenarioConfidence: nil,
            items: [makeItem(text: "第一版条目", evidence: evidence)]
        )]
        advance(10_100)
        await controller.tick()
        let firstSnapshot = try #require(controller.currentSnapshot)

        addFinalSegment(startMs: 6_000, text: "第四句。")
        addFinalSegment(startMs: 8_000, text: "第五句。")
        addFinalSegment(startMs: 10_000, text: "第六句。")
        mock.errorQueue = [AnalysisAPIError.invalidResponse]
        advance(10_100)
        await controller.tick()

        #expect(controller.currentSnapshot?.id == firstSnapshot.id, "非法结果必须保留上一版")
        #expect(controller.currentSnapshot?.analyzedThroughMs == 6_000, "失败不推进游标")
        #expect(project.analysisSnapshots.count == 1, "非法结果不落库")
        #expect(controller.hasRecentFailure)
        #expect(controller.statusDescription.contains("重试失败（结果不合规）"))
        #expect(controller.statusDescription.contains("自动重试"))
    }

    @Test("401：云端分析暂停；修复后恢复")
    func unauthorizedSuspends() async {
        addThreeSegments()
        mock.errorQueue = [AnalysisAPIError.unauthorized]
        advance(10_100)
        await controller.tick()

        guard case .suspended = controller.state else {
            Issue.record("401 必须使云端分析暂停")
            return
        }
        await controller.tick()
        #expect(mock.calls.count == 1, "暂停期间不发请求")

        controller.resumeAfterKeyFix()
        advance(30_100) // 过失败退避
        await controller.tick()
        #expect(mock.calls.count == 2)
    }

    @Test("结束后最终分析：消费完整最终转写（含已分析过的片段）")
    func finalAnalysisUsesFullTranscript() async {
        addThreeSegments()
        advance(10_100)
        await controller.tick()
        #expect(controller.currentSnapshot?.version == 1)

        await controller.generateFinalAnalysis()
        #expect(mock.calls.count == 2)
        let input = mock.calls[1].inputJSON
        #expect(input.contains("第一句。"))
        #expect(input.contains("第二句。"))
        #expect(input.contains("第三句。"))
        #expect(controller.currentSnapshot?.version == 2)
    }

    @Test("人工已修订片段参与分析；临时片段不参与")
    func editedSegmentsEligible() async {
        let edited = TranscriptSegment(startMs: 0, endMs: 2_000, text: "人工修订的句子。",
                                       source: .manual, state: .edited)
        project.segments.append(edited)
        let provisional = TranscriptSegment(startMs: 2_000, endMs: 4_000, text: "临时半句",
                                            source: .local, state: .provisional)
        project.segments.append(provisional)
        controller.noteNewFinalSegment()
        controller.noteNewFinalSegment()
        controller.noteNewFinalSegment()
        advance(10_100)
        await controller.tick()

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].inputJSON.contains("人工修订的句子。"))
        #expect(!mock.calls[0].inputJSON.contains("临时半句"), "临时片段不参与分析")
    }

    @Test("场景自动建议：用户未手选时采纳模型建议并触发回调")
    func scenarioSuggestionAdopted() async throws {
        addThreeSegments()
        let evidence = try #require(project.segments.first)
        mock.resultQueue = [ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: "client_visit", scenarioConfidence: "high",
            items: [makeItem(text: "条目", evidence: evidence)]
        )]
        var suggested = false
        controller.onScenarioSuggested = { suggested = true }
        advance(10_100)
        await controller.tick()

        #expect(project.scenario == .clientVisit, "未手选时采纳模型建议")
        #expect(!project.scenarioWasUserSelected, "自动建议不冒充用户手选")
        #expect(suggested)
    }

    @Test("用户手选场景优先：模型建议不得覆盖，指令按手选场景组装")
    func userScenarioNotOverridden() async throws {
        project.scenario = .classLearning
        project.scenarioWasUserSelected = true
        addThreeSegments()
        let evidence = try #require(project.segments.first)
        mock.resultQueue = [ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: "journalist_interview", scenarioConfidence: "high",
            items: [makeItem(text: "条目", evidence: evidence)]
        )]
        var suggested = false
        controller.onScenarioSuggested = { suggested = true }
        advance(10_100)
        await controller.tick()

        #expect(project.scenario == .classLearning, "手选场景不被模型建议覆盖")
        #expect(project.scenarioWasUserSelected)
        #expect(!suggested)
        #expect(mock.calls[0].instructions == ConversationAnalysisPrompt.text(scenario: .classLearning),
                "指令按手选场景组装")
        #expect(mock.calls[0].inputJSON.contains(#""scenario":"class_learning""#))
    }

    @Test("人工场景切回自动后重新采纳模型建议")
    func resettingManualScenarioRestoresSuggestion() async throws {
        project.scenario = .classLearning
        project.scenarioWasUserSelected = true
        project.scenario = nil
        project.scenarioWasUserSelected = false

        addThreeSegments()
        let evidence = try #require(project.segments.first)
        mock.resultQueue = [ConversationAnalysisOutputDTO(
            headline: nil, detectedScenario: "internal_meeting", scenarioConfidence: "high",
            items: [makeItem(text: "会议决定", evidence: evidence)]
        )]
        advance(10_100)
        await controller.tick()

        #expect(project.scenario == .internalMeeting)
        #expect(!project.scenarioWasUserSelected)
        #expect(mock.calls[0].inputJSON.contains(#""scenario":"auto""#))
    }

    @Test("attach 恢复：重新进入项目时以最高版本快照为当前版")
    func attachRestoresLatestSnapshot() {
        let old = ConversationAnalysisSnapshot(version: 1, analyzedThroughMs: 10_000, items: [])
        let latest = ConversationAnalysisSnapshot(version: 4, analyzedThroughMs: 88_000, items: [])
        project.analysisSnapshots = [latest, old]
        controller.attach(to: project)
        #expect(controller.currentSnapshot?.version == 4)
        #expect(controller.currentSnapshot?.analyzedThroughMs == 88_000)
    }

    @Test("快照不足五版时保持原序列")
    func snapshotRetentionKeepsShortHistory() {
        let snapshots = (1...4).map {
            ConversationAnalysisSnapshot(version: $0, analyzedThroughMs: Int64($0 * 1_000), items: [])
        }

        let retained = ConversationAnalysisSnapshotRetention.keepingMostRecent(snapshots)

        #expect(retained.map(\.version) == [1, 2, 3, 4])
    }

    @Test("快照超过五版时移除最旧版本")
    func snapshotRetentionRemovesOldest() {
        let snapshots = (1...7).map {
            ConversationAnalysisSnapshot(version: $0, analyzedThroughMs: Int64($0 * 1_000), items: [])
        }

        let retained = ConversationAnalysisSnapshotRetention.keepingMostRecent(snapshots)

        #expect(retained.map(\.version) == [3, 4, 5, 6, 7])
    }

    @Test("修剪后下一版版本号继续单调递增")
    func snapshotVersionContinuesAfterRetention() {
        let snapshots = (1...8).map {
            ConversationAnalysisSnapshot(version: $0, analyzedThroughMs: Int64($0 * 1_000), items: [])
        }
        let retained = ConversationAnalysisSnapshotRetention.keepingMostRecent(snapshots)
        let nextVersion = (retained.map(\.version).max() ?? 0) + 1

        #expect(retained.map(\.version) == [4, 5, 6, 7, 8])
        #expect(nextVersion == 9)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(10)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 实时尾巴（09 号计划需求 3-②）

    @Test("临时尾巴进入输入并标记 provisional，但游标只按最终片段推进")
    func provisionalTailInInputButNotCursor() async throws {
        addThreeSegments()
        let tail = TranscriptSegment(
            startMs: 6_000, endMs: 9_000, text: "这句话还在识别中但已经够长了",
            source: .local, state: .provisional
        )
        controller.provisionalTailProvider = { tail }

        advance(10_100)
        await controller.tick()
        #expect(mock.calls.count == 1)
        let input = try #require(mock.calls.first?.inputJSON)
        #expect(input.contains(tail.id.uuidString), "尾巴片段进入输入")
        #expect(input.contains("\"provisional\":true"), "尾巴带 provisional 标记")
        #expect(controller.currentSnapshot?.analyzedThroughMs == 6_000,
                "游标只按最终片段推进，不吃尾巴的 endMs")
    }

    @Test("无新最终片段时，仅有尾巴不驱动分析")
    func tailAloneDoesNotFire() async {
        let tail = TranscriptSegment(
            startMs: 0, endMs: 3_000, text: "只有识别中的临时内容在这里",
            source: .local, state: .provisional
        )
        controller.provisionalTailProvider = { tail }
        advance(60_000)
        await controller.tick()
        #expect(mock.calls.isEmpty)
    }

    @Test("最终分析（forceFullTranscript）不带临时尾巴")
    func finalAnalysisSkipsTail() async throws {
        addThreeSegments()
        let tail = TranscriptSegment(
            startMs: 6_000, endMs: 9_000, text: "识别中的尾巴不该进入最终分析",
            source: .local, state: .provisional
        )
        controller.provisionalTailProvider = { tail }
        await controller.generateFinalAnalysis()
        #expect(mock.calls.count == 1)
        let input = try #require(mock.calls.first?.inputJSON)
        #expect(!input.contains(tail.id.uuidString))
    }
}
