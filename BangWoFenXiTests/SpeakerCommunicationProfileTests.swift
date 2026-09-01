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
}
