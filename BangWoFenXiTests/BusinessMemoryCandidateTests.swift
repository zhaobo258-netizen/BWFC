import Foundation
import Testing
@testable import BangWoFenXi

@Suite("业务记忆候选构建与上下文装配")
struct BusinessMemoryCandidateTests {
    private func makeProject() -> (Project, personID: UUID, segmentID: UUID) {
        let personID = UUID()
        let speakerID = UUID()
        let segmentID = UUID()
        let project = Project(title: "客户拜访", businessCategory: "满分便利店", sourceType: .liveRecording)
        project.speakers = []
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "王总",
            voiceProfileId: personID,
            personId: personID
        )
        // 手工装进 speakers（Project 是类，直接改）
        project.speakers.append(speaker)
        _ = speakerID
        project.segments = [
            TranscriptSegment(
                id: segmentID,
                startMs: 0,
                endMs: 3_000,
                text: "我们这个项目里有效客户指的是月活的门店",
                participantId: speaker.id,
                source: .local,
                state: .final,
                speakerWasUserConfirmed: true
            ),
            TranscriptSegment(
                id: UUID(),
                startMs: 3_000,
                endMs: 6_000,
                text: "下个月再确认一次配送费",
                participantId: speaker.id,
                source: .local,
                state: .final,
                speakerWasUserConfirmed: true
            ),
        ]
        return (project, personID, segmentID)
    }

    @Test("合格候选通过：证据归属到已关联人物的说话人")
    func buildValidCandidates() throws {
        let (project, personID, segmentID) = makeProject()
        let speaker = project.speakers[0]
        let dto = BusinessMemoryCandidateOutputDTO(
            memoryCandidates: [
                .init(
                    kind: "terminology",
                    statement: "有效客户指月活门店",
                    scope: "person_and_project",
                    reason: "口径定义",
                    speakerAlias: speaker.cloudAlias,
                    evidenceSegmentIds: [segmentID.uuidString]
                ),
                .init(
                    kind: "unknown_kind",
                    statement: "无效类别",
                    speakerAlias: speaker.cloudAlias,
                    evidenceSegmentIds: [segmentID.uuidString]
                ),
                .init(
                    kind: "terminology",
                    statement: "证据不存在",
                    speakerAlias: speaker.cloudAlias,
                    evidenceSegmentIds: [UUID().uuidString]
                ),
            ],
            followUpCandidates: [
                .init(
                    title: "确认配送费",
                    ownerText: nil,
                    dueDate: nil,
                    speakerAlias: speaker.cloudAlias,
                    evidenceSegmentIds: [project.segments[1].id.uuidString]
                ),
                .init(
                    title: "编造期限的候选",
                    ownerText: "没有说的责任人",
                    dueDate: "2026-10-01",
                    speakerAlias: speaker.cloudAlias,
                    evidenceSegmentIds: [segmentID.uuidString]
                ),
            ]
        )
        let speakers = [BusinessMemoryCandidateBuilder.SpeakerContext(
            speakerID: speaker.id,
            cloudAlias: speaker.cloudAlias,
            displayName: speaker.displayName,
            personID: personID
        )]
        let segmentsById = Dictionary(
            uniqueKeysWithValues: project.segments.map { ($0.id, $0) }
        )
        let result = BusinessMemoryCandidateBuilder.build(
            dto: dto,
            speakers: speakers,
            segmentsById: segmentsById,
            existingMemoryCandidates: [],
            existingFollowUpCandidates: [],
            existingActiveMemoryContents: ["有效客户指季度销售额"],
            businessCategory: project.businessCategory,
            now: Date()
        )
        // 无效类别与假证据被丢弃
        #expect(result.memory.count == 1)
        let candidate = try #require(result.memory.first)
        #expect(candidate.targetPersonID == personID)
        #expect(candidate.kind == .terminology)
        #expect(candidate.conflictsWithExisting) // 与现有“季度销售额”口径不同说法
        #expect(candidate.scopeDescription.contains("满分便利店"))
        // 期限解析失败 → nil（不能补一个看似合理的值）
        #expect(result.followUps.count == 2)
        let fabricated = result.followUps.first { $0.title.contains("编造") }
        #expect(fabricated?.dueDate == nil)
        #expect(fabricated?.ownerDisplayText == nil) // 没有原话支持的责任人不能进入确认页
    }

    @Test("已拒绝候选不重提（重开页面/重跑同输入）")
    func rejectedCandidatesNotReproposed() throws {
        let (project, personID, segmentID) = makeProject()
        let speaker = project.speakers[0]
        let existing = BusinessMemoryCandidate(
            targetPersonID: personID,
            targetPersonDisplayName: speaker.displayName,
            kind: .terminology,
            statement: "有效客户指月活门店",
            scopeDescription: "人物",
            reason: "",
            evidenceSegmentID: segmentID,
            evidenceSnippet: "x",
            status: .rejected
        )
        let dto = BusinessMemoryCandidateOutputDTO(
            memoryCandidates: [
                .init(
                    kind: "terminology",
                    statement: "有效客户指月活门店",
                    speakerAlias: speaker.cloudAlias,
                    evidenceSegmentIds: [segmentID.uuidString]
                ),
                .init(
                    kind: "ongoing_topic",
                    statement: "配送费待确认",
                    speakerAlias: speaker.cloudAlias,
                    evidenceSegmentIds: [segmentID.uuidString]
                ),
            ]
        )
        let result = BusinessMemoryCandidateBuilder.build(
            dto: dto,
            speakers: [BusinessMemoryCandidateBuilder.SpeakerContext(
                speakerID: speaker.id,
                cloudAlias: speaker.cloudAlias,
                displayName: speaker.displayName,
                personID: personID
            )],
            segmentsById: Dictionary(uniqueKeysOfValues: project.segments.map { ($0.id, $0) }),
            existingMemoryCandidates: [existing],
            existingFollowUpCandidates: [],
            existingActiveMemoryContents: [],
            businessCategory: nil
        )
        // 同证据+同类别被拒后不再出现；不同类别可以再提
        #expect(result.memory.count == 1)
        let survivor = try #require(result.memory.first)
        #expect(survivor.kind == .ongoingTopic)
    }

    @Test("日期解析只接受合理范围")
    func dateParsing() {
        #expect(BusinessMemoryCandidateBuilder.parseDate("2026-10-01") != nil)
        #expect(BusinessMemoryCandidateBuilder.parseDate("1999-01-01") == nil)
        #expect(BusinessMemoryCandidateBuilder.parseDate("2099-01-01") == nil)
        #expect(BusinessMemoryCandidateBuilder.parseDate("明天") == nil)
        #expect(BusinessMemoryCandidateBuilder.parseDate("") == nil)
    }

    @Test("冲突启发式：互含与公共前缀")
    func conflictHeuristic() {
        #expect(BusinessMemoryCandidateBuilder.appearsConflicting(
            "有效客户指月活门店", "有效客户指月活门店"
        ))
        #expect(BusinessMemoryCandidateBuilder.appearsConflicting(
            "有效客户指季度销售额", "有效客户指月活门店"
        ))
        #expect(BusinessMemoryCandidateBuilder.appearsConflicting(
            "预算 50 万已确认", "预算 50 万"
        ))
        #expect(!BusinessMemoryCandidateBuilder.appearsConflicting(
            "配送成本按件计费", "品牌方负责促销投放"
        ))
        #expect(!BusinessMemoryCandidateBuilder.appearsConflicting("预算", "完全无关的话题"))
    }

    @Test("聊天请求携带已确认记忆并封顶")
    func chatRequestCarriesConfirmedMemories() {
        let (project, _, _) = makeProject()
        var memories: [MemoryEntry] = []
        for index in 0..<20 {
            memories.append(MemoryEntry(
                content: "记忆\(index)——\(String(repeating: "内", count: 300))",
                kind: .terminology,
                scope: MemoryScope(personID: UUID(), businessProjectID: nil, displayText: "人物（王总）"),
                status: .active,
                confirmedAt: Date()
            ))
        }
        let request = ProjectAIChatRequestBuilder.make(
            project: project,
            currentRequest: "有效客户是什么口径？",
            noteMarkdown: nil,
            confirmedMemories: memories
        )
        #expect(request.confirmedBusinessMemories.count
            == ProjectAIChatRequestBuilder.maximumConfirmedMemoryCount)
        let total = request.confirmedBusinessMemories.reduce(0) { $0 + $1.content.count }
        #expect(total <= ProjectAIChatRequestBuilder.maximumConfirmedMemoryCharacters)

        // 无记忆时不携带
        let emptyRequest = ProjectAIChatRequestBuilder.make(
            project: project,
            currentRequest: "问一个问题",
            noteMarkdown: nil
        )
        #expect(emptyRequest.confirmedBusinessMemories.isEmpty)
        // inputJSON 含 confirmed_business_memories
        let json = try? ProjectAIChatAgent.inputJSON(request)
        #expect(json?.contains("confirmed_business_memories") == true)
        #expect(json?.contains("人物（王总）") == true)
    }

    @Test("来源版本覆盖原话、确认和人物归属，不依赖更新时间")
    func sourceVersionTracksEvidence() {
        let (project, personID, segmentID) = makeProject()
        let segment = project.segments[0]
        let version = BusinessMemoryCandidateBuilder.sourceVersion(project: project, segment: segment)
        segment.updatedAt = .distantFuture
        #expect(BusinessMemoryCandidateBuilder.sourceIsCurrent(
            project: project, segmentID: segmentID, version: version, personID: personID
        ))
        segment.text += "，按季度复核"
        #expect(!BusinessMemoryCandidateBuilder.sourceIsCurrent(
            project: project, segmentID: segmentID, version: version, personID: personID
        ))
        let editedVersion = BusinessMemoryCandidateBuilder.sourceVersion(project: project, segment: segment)
        project.speakers[0].personId = UUID()
        #expect(!BusinessMemoryCandidateBuilder.sourceIsCurrent(
            project: project, segmentID: segmentID, version: editedVersion, personID: personID
        ))
        #expect(!BusinessMemoryCandidateBuilder.sourceIsCurrent(
            project: project, segmentID: segmentID, version: nil
        ))
        project.segments.removeAll()
        #expect(!BusinessMemoryCandidateBuilder.sourceIsCurrent(
            project: project, segmentID: segmentID, version: editedVersion
        ))
    }

    @Test("候选保留真实项目作用域，同批去重，旧候选可刷新，拒绝后改写不重提")
    func candidateScopeAndDeduplication() throws {
        let (project, personID, segmentID) = makeProject()
        let speaker = project.speakers[0]
        let version = BusinessMemoryCandidateBuilder.sourceVersion(project: project, segment: project.segments[0])
        let businessID = UUID()
        let memoryDTO = BusinessMemoryCandidateOutputDTO.MemoryCandidate(
            kind: "terminology", statement: "有效客户指月活门店", scope: "person_and_project",
            speakerAlias: speaker.cloudAlias, evidenceSegmentIds: [segmentID.uuidString]
        )
        let followUpDTO = BusinessMemoryCandidateOutputDTO.FollowUpCandidate(
            title: "复核口径", speakerAlias: speaker.cloudAlias, evidenceSegmentIds: [segmentID.uuidString]
        )
        let contexts = [BusinessMemoryCandidateBuilder.SpeakerContext(speakerID: speaker.id,
            cloudAlias: speaker.cloudAlias, displayName: speaker.displayName, personID: personID)]
        func build(_ existingMemory: [BusinessMemoryCandidate], _ existingFollowUps: [FollowUpCandidate])
            -> (memory: [BusinessMemoryCandidate], followUps: [FollowUpCandidate]) {
            BusinessMemoryCandidateBuilder.build(
                dto: .init(memoryCandidates: [memoryDTO, memoryDTO], followUpCandidates: [followUpDTO, followUpDTO]),
                speakers: contexts, segmentsById: [segmentID: project.segments[0]],
                existingMemoryCandidates: existingMemory, existingFollowUpCandidates: existingFollowUps,
                existingActiveMemoryContents: [], businessCategory: project.businessCategory,
                sourceVersions: [segmentID: version], businessProjectID: businessID
            )
        }
        let first = build([], [])
        #expect(first.memory.count == 1)
        #expect(first.followUps.count == 1)
        var memory = try #require(first.memory.first)
        #expect(memory.targetBusinessProjectID == businessID)
        #expect(memory.requiresBusinessProjectScope == true)
        #expect(memory.sourceVersion == version)
        memory.sourceVersion = nil
        #expect(build([memory], []).memory.count == 1)
        memory.status = .rejected
        #expect(build([memory], []).memory.isEmpty)
        var followUp = try #require(first.followUps.first)
        followUp.title = "人工改写但已拒绝"
        followUp.status = .rejected
        #expect(build([], [followUp]).followUps.isEmpty)
    }

    @Test("未知别名或未确认片段不能提出候选")
    func invalidAttributionIsRejected() {
        let (project, personID, segmentID) = makeProject()
        let speaker = project.speakers[0]
        let result = BusinessMemoryCandidateBuilder.build(
            dto: .init(memoryCandidates: [.init(kind: "terminology", statement: "口径",
                speakerAlias: "invented", evidenceSegmentIds: [segmentID.uuidString])]),
            speakers: [.init(speakerID: speaker.id, cloudAlias: speaker.cloudAlias,
                displayName: speaker.displayName, personID: personID)],
            segmentsById: [segmentID: project.segments[0]], existingMemoryCandidates: [],
            existingFollowUpCandidates: [], existingActiveMemoryContents: [], businessCategory: nil
        )
        #expect(result.memory.isEmpty)
    }

    @Test("聊天仅使用已生效记忆并提供来源定位与版本")
    func chatMemoryValidityAndProvenance() throws {
        let now = Date()
        let source = MemorySourceReference(recordingID: UUID(), segmentID: UUID(), snippet: "原话", sourceVersion: "v1")
        let active = MemoryEntry(content: "月活口径", kind: .terminology,
            scope: .init(personID: UUID(), businessProjectID: UUID(), displayText: "项目范围"),
            source: source, status: .active, confirmedAt: now)
        var future = active
        future.id = UUID()
        future.effectiveFrom = now.addingTimeInterval(600)
        var invalid = active
        invalid.id = UUID()
        invalid.status = .needsReview
        let result = ProjectAIChatRequestBuilder.confirmedMemoryDTOs([future, invalid, active])
        #expect(result.count == 1)
        let item = try #require(result.first)
        #expect(item.id == active.id.uuidString)
        #expect(item.sourceSegmentID == source.segmentID.uuidString)
        #expect(item.sourceVersion == "v1")
        #expect(item.businessProjectID == active.scope.businessProjectID?.uuidString)
    }

    @Test("候选请求晚到时原话已修改则丢弃，人物姓名不进入结构化请求")
    @MainActor
    func lateProposalIsRejected() async throws {
        let (project, _, _) = makeProject()
        let service = MemoryCandidateSuspendedService()
        let agent = BusinessMemoryCandidateAgent(generationService: service)
        let task = Task { try await agent.propose(project: project) }
        await service.waitForRequest()
        let input = await service.input()
        #expect(input?.contains("王总") == false)
        project.segments[0].text += "，原口径已撤回"
        await service.complete()
        do {
            _ = try await task.value
            Issue.record("来源变化后不应接纳晚到的模型候选")
        } catch BusinessMemoryCandidateError.sourceChanged {
        }
    }

    @Test("缺失候选数组的模型回复是格式错误，不是假无结果")
    func malformedResponseDoesNotBecomeEmptySuccess() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BusinessMemoryCandidateOutputDTO.self, from: Data("{}".utf8))
        }
        let result = try JSONDecoder().decode(BusinessMemoryCandidateOutputDTO.self,
            from: Data(#"{"memory_candidates":[],"follow_up_candidates":[]}"#.utf8))
        #expect(result.memoryCandidates.isEmpty && result.followUpCandidates.isEmpty)
    }

    @Test("目标条目已写入而候选状态未保存时，重开先恢复确认状态且不重新激活")
    func committedReceiptsRecoverPendingCandidates() throws {
        let (project, personID, segmentID) = makeProject()
        let memoryCandidate = BusinessMemoryCandidate(targetPersonID: personID,
            targetPersonDisplayName: "王总", kind: .terminology, statement: "月活口径",
            scopeDescription: "人物", reason: "", evidenceSegmentID: segmentID, evidenceSnippet: "原话")
        let followUpCandidate = FollowUpCandidate(title: "确认口径", ownerDisplayText: nil,
            dueDate: nil, evidenceSegmentID: segmentID, evidenceSnippet: "原话")
        project.businessMemoryCandidates = [memoryCandidate]
        project.followUpCandidates = [followUpCandidate]
        // 模拟候选文件仍是 pending，目标已成功落盘，且记忆后来已被忘记。
        let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        let writtenMemory = MemoryEntry(id: memoryCandidate.id, content: "月活口径", kind: .terminology,
            scope: .init(personID: personID, businessProjectID: nil, displayText: "人物"), status: .rejected)
        let writtenFollowUp = FollowUp(id: followUpCandidate.id, title: "确认口径",
            confirmationStatus: .confirmed, handlingStatus: .completed, resultNote: "已确认")
        #expect(BusinessMemoryCandidateBuilder.reconcileCommittedCandidates(
            project: reopened, memories: [writtenMemory], followUps: [writtenFollowUp]
        ))
        #expect(reopened.businessMemoryCandidates[0].status == .confirmed)
        #expect(reopened.followUpCandidates[0].status == .confirmed)
        #expect(!reopened.businessMemoryCandidates.contains { $0.status == .pending })
        #expect(!reopened.followUpCandidates.contains { $0.status == .pending })
        #expect(writtenMemory.status == .rejected)
        #expect(writtenFollowUp.handlingStatus == .completed)
        #expect(!BusinessMemoryCandidateBuilder.reconcileCommittedCandidates(
            project: reopened, memories: [writtenMemory], followUps: [writtenFollowUp]
        ))
    }

    @Test("记忆作用域过滤")
    func scopeFiltering() {
        let personID = UUID()
        let otherPersonID = UUID()
        let businessProjectID = UUID()
        let personScope = MemoryScope(personID: personID, businessProjectID: nil, displayText: "人物")
        let projectScope = MemoryScope(
            personID: nil, businessProjectID: businessProjectID, displayText: "项目"
        )
        let narrowScope = MemoryScope(
            personID: otherPersonID, businessProjectID: nil, displayText: "他人物"
        )
        #expect(personScope.applies(toPerson: personID, businessProjectID: nil))
        #expect(!personScope.applies(toPerson: otherPersonID, businessProjectID: nil))
        #expect(projectScope.applies(toPerson: nil, businessProjectID: businessProjectID))
        #expect(!projectScope.applies(toPerson: nil, businessProjectID: UUID()))
        #expect(!narrowScope.applies(toPerson: personID, businessProjectID: businessProjectID))
    }
}

private extension Dictionary where Key == UUID, Value == TranscriptSegment {
    init(uniqueKeysOfValues pairs: [(UUID, TranscriptSegment)]) {
        self.init(minimumCapacity: pairs.count)
        for (key, value) in pairs { self[key] = value }
    }
}

private actor MemoryCandidateSuspendedService: AITextGenerationServing {
    private var request: AITextGenerationRequest?
    private var responseContinuation: CheckedContinuation<AITextGenerationResponse, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?

    func generate(_ request: AITextGenerationRequest) async throws -> AITextGenerationResponse {
        self.request = request
        return await withCheckedContinuation { continuation in
            responseContinuation = continuation
            requestWaiter?.resume()
            requestWaiter = nil
        }
    }

    func waitForRequest() async {
        if request != nil { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func input() -> String? { request?.input }

    func complete() {
        responseContinuation?.resume(returning: AITextGenerationResponse(
            text: #"{"memory_candidates":[],"follow_up_candidates":[]}"#,
            provider: AIProviderDescriptor(id: "memory-test", displayName: "测试", modelID: "fixture")
        ))
        responseContinuation = nil
    }

    func testActiveConnection() async throws -> AIProviderDescriptor {
        AIProviderDescriptor(id: "memory-test", displayName: "测试", modelID: "fixture")
    }
}
