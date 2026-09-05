import Foundation
import Testing
@testable import BangWoFenXi

@Suite("人物表达与沟通画像")
struct SpeakerCommunicationProfileTests {
    @Test("只保留引用真实片段的可观察表达特征")
    func builderFiltersUnsupportedObservations() throws {
        let valid = UUID()
        let invalid = UUID()
        let dto = SpeakerCommunicationProfileOutputDTO(
            summary: "先给结论，再补充数字。",
            observations: [
                .init(
                    title: "结论优先",
                    observation: "经常先表达决定，再说明条件。",
                    evidenceSegmentIds: [valid.uuidString]
                ),
                .init(
                    title: "无证据判断",
                    observation: "不应保留。",
                    evidenceSegmentIds: [invalid.uuidString]
                )
            ]
        )

        let profile = try SpeakerCommunicationProfileBuilder.build(
            dto: dto,
            validSegmentIds: [valid],
            sourceProjectId: UUID(),
            now: Date(timeIntervalSince1970: 3_000)
        )

        #expect(profile.observations.count == 1)
        #expect(profile.observations[0].evidenceSegmentIds == [valid])
        #expect(profile.summary == "先给结论，再补充数字。")
    }

    @Test("没有任何真实证据时拒绝生成画像")
    func builderRejectsEvidenceFreeProfile() {
        let dto = SpeakerCommunicationProfileOutputDTO(
            summary: "看似完整但没有证据。",
            observations: []
        )
        #expect(throws: AnalysisAPIError.invalidResponse) {
            try SpeakerCommunicationProfileBuilder.build(
                dto: dto,
                validSegmentIds: [],
                sourceProjectId: UUID()
            )
        }
    }
    @MainActor
    @Test("本场画像只上传人工确认归属的有效发言")
    func currentProjectProfileRequiresConfirmedSpeakerEvidence() async throws {
        let speaker = Speaker(cloudAlias: "p_01", displayName: "测试人物")
        let confirmedOne = TranscriptSegment(
            startMs: 0, endMs: 1_000, text: "确认一", participantId: speaker.id,
            source: .local, state: .final, speakerWasUserConfirmed: true
        )
        let confirmedTwo = TranscriptSegment(
            startMs: 1_000, endMs: 2_000, text: "确认二", participantId: speaker.id,
            source: .local, state: .edited, speakerWasUserConfirmed: true
        )
        let automatic = TranscriptSegment(
            startMs: 2_000, endMs: 3_000, text: "仅自动归属", participantId: speaker.id,
            source: .cloud, state: .final
        )
        let provisional = TranscriptSegment(
            startMs: 3_000, endMs: 4_000, text: "未定稿", participantId: speaker.id,
            source: .local, state: .provisional, speakerWasUserConfirmed: true
        )
        let generation = CommunicationProfileCapturingGeneration(evidenceID: confirmedOne.id)
        _ = try await SpeakerCommunicationProfileAgent(generationService: generation).analyze(
            speaker: speaker, projectId: UUID(),
            segments: [confirmedOne, automatic, provisional, confirmedTwo]
        )

        let input = try #require(await generation.lastInput())
        let root = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let transcript = try #require(root["untrusted_transcript_data"] as? [String: Any])
        let segments = try #require(transcript["segments"] as? [[String: Any]])
        #expect(segments.compactMap { $0["id"] as? String } == [confirmedOne.id.uuidString, confirmedTwo.id.uuidString])
    }

    @MainActor
    @Test("自动归属不能凑足画像所需两条人工确认证据")
    func unconfirmedSpeechDoesNotStartProfileRequest() async {
        let speaker = Speaker(cloudAlias: "p_01", displayName: "测试人物")
        let confirmed = TranscriptSegment(
            startMs: 0, endMs: 1_000, text: "确认一", participantId: speaker.id,
            source: .local, state: .final, speakerWasUserConfirmed: true
        )
        let automatic = TranscriptSegment(
            startMs: 1_000, endMs: 2_000, text: "仅自动归属", participantId: speaker.id,
            source: .cloud, state: .final
        )
        let generation = CommunicationProfileCapturingGeneration(evidenceID: confirmed.id)
        await #expect(throws: AnalysisAPIError.invalidResponse) {
            _ = try await SpeakerCommunicationProfileAgent(generationService: generation).analyze(
                speaker: speaker, projectId: UUID(), segments: [confirmed, automatic]
            )
        }
        #expect(await generation.lastInput() == nil)
    }

}

private actor CommunicationProfileCapturingGeneration: AITextGenerationServing {
    private let evidenceID: UUID
    private var input: String?

    init(evidenceID: UUID) { self.evidenceID = evidenceID }

    func generate(_ request: AITextGenerationRequest) async throws -> AITextGenerationResponse {
        input = request.input
        return AITextGenerationResponse(
            text: """
            {"summary":"结论清楚","observations":[{"title":"清楚","observation":"明确表达结论","evidence_segment_ids":["\(evidenceID.uuidString)"]}]}
            """,
            provider: .init(id: "fixture", displayName: "本地测试", modelID: "fixture")
        )
    }

    func lastInput() -> String? { input }

    func testActiveConnection() async throws -> AIProviderDescriptor {
        .init(id: "fixture", displayName: "本地测试", modelID: "fixture")
    }
}
