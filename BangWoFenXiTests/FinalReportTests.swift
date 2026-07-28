import Foundation
import Testing
@testable import BangWoFenXi

private actor FinalReportAIService: AITextGenerationServing {
    let output: String
    private var requests: [AITextGenerationRequest] = []

    init(output: String) {
        self.output = output
    }

    func generate(
        _ request: AITextGenerationRequest
    ) async throws -> AITextGenerationResponse {
        requests.append(request)
        return AITextGenerationResponse(
            text: output,
            provider: AIProviderDescriptor(
                id: "test-provider",
                displayName: "测试模型",
                modelID: "test-model"
            )
        )
    }

    func testActiveConnection() async throws -> AIProviderDescriptor {
        AIProviderDescriptor(
            id: "test-provider",
            displayName: "测试模型",
            modelID: "test-model"
        )
    }

    func capturedRequests() -> [AITextGenerationRequest] {
        requests
    }
}

private enum FinalReportTestError: Error {
    case injectedPersistenceFailure
}

@MainActor
private final class CoordinatorFinalReportGenerator:
    FinalReportGenerating,
    @unchecked Sendable
{
    var error: AnalysisAPIError?
    var delay: Duration = .zero
    private(set) var callCount = 0

    func generate(
        project: Project,
        analysis: ConversationAnalysisSnapshot,
        knownTerms: [String],
        version: Int
    ) async throws -> FinalReportSnapshot {
        callCount += 1
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let error {
            throw error
        }
        guard let segment = project.segments.first else {
            throw AnalysisAPIError.invalidResponse
        }
        return FinalReportSnapshot(
            version: version,
            providerID: "mock",
            providerName: "Mock",
            modelID: "mock-model",
            promptVersion: PromptRegistry.version,
            inputFingerprint: FinalReportFingerprint.make(for: project),
            headline: "测试完整总结",
            overview: "这是由测试生成器产生的完整概述。",
            items: [
                FinalReportItem(
                    category: .fact,
                    text: "一条有证据的事实",
                    epistemicStatus: .explicit,
                    confidence: .high,
                    evidenceSegmentIds: [segment.id]
                )
            ]
        )
    }
}

@Suite("完整总结", .serialized)
@MainActor
struct FinalReportTests {
    @Test("Agent 只接收证据账本，过滤无效证据并记录模型与提示词版本")
    func agentEvidenceContract() async throws {
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "客户甲",
            role: "采购"
        )
        let segment = TranscriptSegment(
            startMs: 0,
            endMs: 2_000,
            text: "我们下周三由我提交新的对账方案。",
            participantId: speaker.id,
            source: .local,
            state: .final
        )
        let provisional = TranscriptSegment(
            startMs: 2_000,
            endMs: 3_000,
            text: "不得进入报告的临时片段",
            participantId: speaker.id,
            source: .local,
            state: .provisional
        )
        let project = Project(
            title: "总结测试",
            sourceType: .importedAudio,
            scenario: .internalMeeting,
            speakers: [speaker],
            segments: [segment, provisional],
            note: NoteDocument(markdown: "不得发送的用户私密笔记")
        )
        let analysis = ConversationAnalysisSnapshot(
            version: 1,
            analyzedThroughMs: segment.endMs,
            headline: "讨论对账方案",
            items: [
                AnalysisItem(
                    category: .actionItem,
                    text: "提交新方案",
                    subjectSpeakerId: speaker.id,
                    epistemicStatus: .explicit,
                    confidence: .high,
                    evidenceSegmentIds: [segment.id]
                ),
                AnalysisItem(
                    category: .fact,
                    text: "临时内容不得作为证据",
                    subjectSpeakerId: speaker.id,
                    epistemicStatus: .explicit,
                    confidence: .low,
                    evidenceSegmentIds: [provisional.id]
                )
            ]
        )
        let invalidID = UUID()
        let output = """
        {
          "headline": "双方明确了下一步",
          "overview": "讨论围绕对账方案展开，并形成了下一步安排。",
          "items": [
            {
              "category": "action_item",
              "text": "下周三提交新的对账方案",
              "subject_speaker_id": "p_01",
              "owner_speaker_id": "p_01",
              "deadline_text": "下周三",
              "epistemic_status": "explicit",
              "confidence": "high",
              "evidence_segment_ids": ["\(segment.id.uuidString)"]
            },
            {
              "category": "fact",
              "text": "对账方案需要更新",
              "subject_speaker_id": "p_01",
              "owner_speaker_id": "p_01",
              "deadline_text": "下周三",
              "epistemic_status": "explicit",
              "confidence": "high",
              "evidence_segment_ids": ["\(segment.id.uuidString)"]
            },
            {
              "category": "decision",
              "text": "无效证据不得保存",
              "subject_speaker_id": null,
              "owner_speaker_id": null,
              "deadline_text": null,
              "epistemic_status": "explicit",
              "confidence": "high",
              "evidence_segment_ids": ["\(invalidID.uuidString)"]
            }
          ]
        }
        """
        let service = FinalReportAIService(output: output)
        let orchestrator = ProjectAIOrchestrator(
            finalReportAgent: FinalReportAgent(generationService: service)
        )
        let report = try await orchestrator.generate(
            project: project,
            analysis: analysis,
            knownTerms: ["对账方案"],
            version: 1
        )

        #expect(report.items.count == 2)
        let action = try #require(report.items.first {
            $0.category == .actionItem
        })
        #expect(action.ownerSpeakerId == speaker.id)
        #expect(action.deadlineText == "下周三")
        let fact = try #require(report.items.first { $0.category == .fact })
        #expect(fact.ownerSpeakerId == nil)
        #expect(fact.deadlineText == nil)
        #expect(report.providerName == "测试模型")
        #expect(report.modelID == "test-model")
        #expect(report.promptVersion == PromptRegistry.version)
        #expect(report.inputFingerprint == FinalReportFingerprint.make(for: project))

        let requests = await service.capturedRequests()
        let request = try #require(requests.first)
        #expect(request.system.contains(PromptRegistry.sharedGuardrails))
        #expect(request.input.contains("untrusted_transcript_data"))
        #expect(request.input.contains("对账方案"))
        #expect(!request.input.contains("不得进入报告的临时片段"))
        #expect(!request.input.contains("临时内容不得作为证据"))
        #expect(!request.input.contains("不得发送的用户私密笔记"))
    }

    @Test("旧 Project 缺少完整总结字段仍可读取，版本最多保留三版")
    func projectCompatibilityAndRetention() throws {
        let project = Project(
            title: "旧项目",
            sourceType: .importedAudio
        )
        let encoded = try JSONEncoder().encode(project)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "finalReportSnapshots")
        let legacy = try JSONDecoder().decode(
            Project.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.schemaVersion == 2)
        #expect(legacy.finalReportSnapshots.isEmpty)

        let reports = (1...5).map {
            FinalReportSnapshot(
                version: $0,
                providerID: "p",
                providerName: "P",
                modelID: "m",
                promptVersion: "v",
                inputFingerprint: "f\($0)",
                headline: "h\($0)",
                overview: "o\($0)",
                items: []
            )
        }
        #expect(
            FinalReportSnapshotRetention.keepingMostRecent([
                reports[4], reports[0], reports[3], reports[1], reports[2]
            ])
                .map(\.version) == [3, 4, 5]
        )
    }

    @Test("场景、说话人或最终文稿变化都会使输入指纹变化")
    func fingerprintTracksOwnedInputs() {
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "说话人一"
        )
        let segment = TranscriptSegment(
            startMs: 0,
            endMs: 1_000,
            text: "原始内容",
            participantId: speaker.id,
            source: .local,
            state: .final
        )
        let project = Project(
            title: "指纹",
            sourceType: .liveRecording,
            speakers: [speaker],
            segments: [segment]
        )
        let original = FinalReportFingerprint.make(for: project)
        project.scenario = .clientVisit
        let scenarioChanged = FinalReportFingerprint.make(for: project)
        #expect(scenarioChanged != original)
        speaker.role = "客户"
        let speakerChanged = FinalReportFingerprint.make(for: project)
        #expect(speakerChanged != scenarioChanged)
        segment.text = "人工修订内容"
        segment.state = .edited
        #expect(FinalReportFingerprint.make(for: project) != speakerChanged)
    }

    @Test("Markdown 原子更新前保存外部修改冲突副本")
    func markdownConflictCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-final-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = MeetingFileStore(baseDirectory: directory)
        let writer = FinalReportFileWriter(fileStore: fileStore)
        let projectID = UUID()

        let firstHash = try writer.write(
            markdown: "# 第一版\n",
            projectID: projectID,
            expectedExistingHash: nil
        )
        let reportURL = fileStore.meetingDirectory(for: projectID)
            .appending(path: "完整总结.md")
        try Data("# 用户在外部修改\n".utf8).write(to: reportURL, options: .atomic)
        _ = try writer.write(
            markdown: "# 第二版\n",
            projectID: projectID,
            expectedExistingHash: firstHash
        )

        #expect(try String(contentsOf: reportURL, encoding: .utf8) == "# 第二版\n")
        let conflicts = try FileManager.default.contentsOfDirectory(
            at: fileStore.meetingDirectory(for: projectID),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("完整总结-外部修改-") }
        #expect(conflicts.count == 1)
        #expect(
            try String(contentsOf: conflicts[0], encoding: .utf8)
                == "# 用户在外部修改\n"
        )
    }

    @Test("后台协调器同一项目只触发一次，完成后持久化且失败不重复旧提示")
    func coordinatorDeduplicatesAndPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-final-coordinator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = MeetingFileStore(baseDirectory: directory)
        let store = InMemoryProjectStore()
        let segment = TranscriptSegment(
            startMs: 0,
            endMs: 1_000,
            text: "真实片段",
            source: .local,
            state: .final
        )
        let project = Project(
            title: "协调器",
            sourceType: .liveRecording,
            status: .ready,
            segments: [segment]
        )
        try store.saveProjects([project])

        let analysis = MockConversationAnalysisService()
        analysis.resultQueue = [ConversationAnalysisOutputDTO(
            headline: "总览",
            detectedScenario: nil,
            scenarioConfidence: nil,
            items: [
                .init(
                    category: "fact",
                    text: "真实事实",
                    subjectSpeakerId: nil,
                    epistemicStatus: "explicit",
                    confidence: "high",
                    evidenceSegmentIds: [segment.id.uuidString]
                )
            ]
        )]
        let generator = CoordinatorFinalReportGenerator()
        generator.delay = .milliseconds(80)
        let coordinator = makeCoordinator(
            analysis: analysis,
            generator: generator,
            fileStore: fileStore,
            store: store
        )

        coordinator.start(projectID: project.id)
        coordinator.start(projectID: project.id)
        await waitUntil {
            if case .completed = coordinator.state(for: project.id) {
                return true
            }
            return false
        }

        #expect(generator.callCount == 1)
        let stored = try #require(
            try store.loadProjects().first { $0.id == project.id }
        )
        #expect(stored.finalReportSnapshots.count == 1)
        #expect(
            stored.processingJobs.first { $0.kind == .finalReport }?.status
                == .completed
        )
        #expect(FileManager.default.fileExists(
            atPath: fileStore.meetingDirectory(for: project.id)
                .appending(path: "完整总结.md").path
        ))

        generator.error = .network
        coordinator.start(projectID: project.id)
        await waitUntil {
            if case .failed = coordinator.state(for: project.id) {
                return true
            }
            return false
        }
        #expect(coordinator.latestCompletion == nil)
    }

    @Test("生成失败保留上一版并留下可重试任务")
    func coordinatorFailureKeepsPreviousReport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-final-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = MeetingFileStore(baseDirectory: directory)
        let store = InMemoryProjectStore()
        let segment = TranscriptSegment(
            startMs: 0,
            endMs: 1_000,
            text: "真实片段",
            source: .local,
            state: .final
        )
        let previous = FinalReportSnapshot(
            version: 1,
            providerID: "old",
            providerName: "旧模型",
            modelID: "old-model",
            promptVersion: "old",
            inputFingerprint: "old",
            headline: "旧报告",
            overview: "旧报告仍需保留",
            items: [
                FinalReportItem(
                    category: .fact,
                    text: "旧事实",
                    epistemicStatus: .explicit,
                    confidence: .high,
                    evidenceSegmentIds: [segment.id]
                )
            ]
        )
        let project = Project(
            title: "失败保留",
            sourceType: .liveRecording,
            status: .ready,
            segments: [segment],
            finalReportSnapshots: [previous]
        )
        try store.saveProjects([project])
        let analysis = MockConversationAnalysisService()
        analysis.resultQueue = [ConversationAnalysisOutputDTO(
            headline: "总览",
            detectedScenario: nil,
            scenarioConfidence: nil,
            items: [
                .init(
                    category: "fact",
                    text: "真实事实",
                    subjectSpeakerId: nil,
                    epistemicStatus: "explicit",
                    confidence: "high",
                    evidenceSegmentIds: [segment.id.uuidString]
                )
            ]
        )]
        let generator = CoordinatorFinalReportGenerator()
        generator.error = .network
        let coordinator = makeCoordinator(
            analysis: analysis,
            generator: generator,
            fileStore: fileStore,
            store: store
        )
        coordinator.start(projectID: project.id)
        await waitUntil {
            if case .failed = coordinator.state(for: project.id) {
                return true
            }
            return false
        }

        let stored = try #require(
            try store.loadProjects().first { $0.id == project.id }
        )
        #expect(stored.finalReportSnapshots.map(\.id) == [previous.id])
        #expect(
            stored.processingJobs.first { $0.kind == .finalReport }?.status
                == .failedRetryable
        )
    }

    @Test("报告落库失败会回滚 Project 和 Markdown，上一版保持一致")
    func coordinatorPersistenceFailureRollsBackReportAndFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-final-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = MeetingFileStore(baseDirectory: directory)
        let writer = FinalReportFileWriter(fileStore: fileStore)
        let store = InMemoryProjectStore()
        let segment = TranscriptSegment(
            startMs: 0,
            endMs: 1_000,
            text: "真实片段",
            source: .local,
            state: .final
        )
        let previousMarkdown = "# 上一版完整总结\n"
        var previous = FinalReportSnapshot(
            version: 1,
            providerID: "old",
            providerName: "旧模型",
            modelID: "old-model",
            promptVersion: "old",
            inputFingerprint: "old",
            headline: "上一版",
            overview: "上一版概述",
            items: [
                FinalReportItem(
                    category: .fact,
                    text: "旧事实",
                    epistemicStatus: .explicit,
                    confidence: .high,
                    evidenceSegmentIds: [segment.id]
                )
            ]
        )
        let project = Project(
            title: "回滚",
            sourceType: .liveRecording,
            status: .ready,
            segments: [segment],
            finalReportSnapshots: [previous]
        )
        let reportURL = fileStore.meetingDirectory(for: project.id)
            .appending(path: "完整总结.md")
        previous.markdownHash = try writer.write(
            markdown: previousMarkdown,
            projectID: project.id,
            expectedExistingHash: nil
        )
        project.finalReportSnapshots = [previous]
        try store.saveProjects([project])

        let analysis = MockConversationAnalysisService()
        analysis.resultQueue = [ConversationAnalysisOutputDTO(
            headline: "总览",
            detectedScenario: nil,
            scenarioConfidence: nil,
            items: [
                .init(
                    category: "fact",
                    text: "真实事实",
                    subjectSpeakerId: nil,
                    epistemicStatus: "explicit",
                    confidence: "high",
                    evidenceSegmentIds: [segment.id.uuidString]
                )
            ]
        )]
        let generator = CoordinatorFinalReportGenerator()
        var rejectedGeneratedReport = false
        let coordinator = FinalReportCoordinator(
            analysisService: analysis,
            finalReportGenerator: generator,
            fileWriter: writer,
            loadProject: { id in
                try store.loadProjects().first { $0.id == id }
            },
            persistProject: { candidate, fields in
                if fields == .finalReport,
                   candidate.finalReportSnapshots.count > 1,
                   !rejectedGeneratedReport {
                    rejectedGeneratedReport = true
                    throw FinalReportTestError.injectedPersistenceFailure
                }
                var projects = try store.loadProjects()
                ProjectPersistence.upsert(
                    candidate,
                    into: &projects,
                    fields: fields
                )
                try store.saveProjects(projects)
            },
            knownTermsProvider: { [] }
        )

        coordinator.start(projectID: project.id)
        await waitUntil {
            if case .failed = coordinator.state(for: project.id) {
                return true
            }
            return false
        }

        #expect(rejectedGeneratedReport)
        let stored = try #require(
            try store.loadProjects().first { $0.id == project.id }
        )
        #expect(stored.finalReportSnapshots.map(\.id) == [previous.id])
        #expect(
            try String(contentsOf: reportURL, encoding: .utf8)
                == previousMarkdown
        )
        #expect(
            stored.processingJobs.first { $0.kind == .finalReport }?.status
                == .failedRetryable
        )
    }

    private func makeCoordinator(
        analysis: MockConversationAnalysisService,
        generator: CoordinatorFinalReportGenerator,
        fileStore: MeetingFileStore,
        store: InMemoryProjectStore
    ) -> FinalReportCoordinator {
        FinalReportCoordinator(
            analysisService: analysis,
            finalReportGenerator: generator,
            fileWriter: FinalReportFileWriter(fileStore: fileStore),
            loadProject: { id in
                try store.loadProjects().first { $0.id == id }
            },
            persistProject: { project, fields in
                var projects = try store.loadProjects()
                ProjectPersistence.upsert(
                    project,
                    into: &projects,
                    fields: fields
                )
                try store.saveProjects(projects)
            },
            knownTermsProvider: { ["测试词"] }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
