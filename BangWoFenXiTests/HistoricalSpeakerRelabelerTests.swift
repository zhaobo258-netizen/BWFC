import Foundation
import Testing
@testable import BangWoFenXi

@Suite("历史发言声纹重标")
struct HistoricalSpeakerRelabelerTests {
    @Test("多人或未知人命中同一原稿长段时不整段归给首人")
    func mixedSpeakersAreNotAssignedToOnePerson() {
        let first = UUID()
        let second = UUID()
        let segment = HistoricalSpeakerRelabeler.SegmentSnapshot(
            id: UUID(), startMs: 0, endMs: 10_000,
            text: "甲方问交付时间，乙方回答下周完成", participantId: nil,
            speakerWasUserConfirmed: false
        )
        for otherLabel in ["p_02", "speaker_unknown"] {
            let result = DiarizationChunkResult(durationMs: 10_000, segments: [
                .init(startMs: 0, endMs: 4_000, text: "甲方问交付时间", speakerLabel: "p_01"),
                .init(startMs: 4_000, endMs: 10_000, text: "乙方回答下周完成", speakerLabel: otherLabel)
            ])
            #expect(HistoricalSpeakerRelabelMatcher.assignments(
                result: result, chunkWallStartMs: 0,
                knownSpeakerIDs: ["p_01": first, "p_02": second],
                existingSegments: [segment]
            ).isEmpty)
        }
    }

    @Test("只重叠时间而原话不符不能认作同一人物证据")
    func unrelatedTextDoesNotAssign() {
        let segment = HistoricalSpeakerRelabeler.SegmentSnapshot(
            id: UUID(), startMs: 0, endMs: 3_000, text: "库存需要盘点",
            participantId: nil, speakerWasUserConfirmed: false
        )
        let result = DiarizationChunkResult(durationMs: 3_000, segments: [
            .init(startMs: 0, endMs: 3_000, text: "天气非常晴朗", speakerLabel: "p_01")
        ])
        #expect(HistoricalSpeakerRelabelMatcher.assignments(
            result: result, chunkWallStartMs: 0,
            knownSpeakerIDs: ["p_01": UUID()], existingSegments: [segment]
        ).isEmpty)
    }

    @Test("不支持历史声纹时在读取音频和联网前失败")
    func unsupportedProviderFailsBeforeAudioOrNetwork() async {
        let service = UnsupportedKnownSpeakerDiarizationService()
        let relabeler = HistoricalSpeakerRelabeler(diarization: service)
        let missingAudio = FileManager.default.temporaryDirectory
            .appending(path: "missing-history-audio-\(UUID().uuidString).wav")
        let missingSample = FileManager.default.temporaryDirectory
            .appending(path: "missing-history-sample-\(UUID().uuidString).wav")

        await #expect(throws: DiarizationAPIError.knownSpeakerMatchingUnsupported) {
            try await relabeler.relabel(
                audioURL: missingAudio,
                pauseIntervals: [],
                existingSegments: [
                    .init(
                        id: UUID(),
                        startMs: 0,
                        endMs: 3_000,
                        text: "这段音频不应被读取。",
                        participantId: nil,
                        speakerWasUserConfirmed: false
                    )
                ],
                speakerReferences: [
                    .init(speakerID: UUID(), alias: "p_01", sampleURL: missingSample)
                ]
            )
        }
        #expect(service.transcribeCallCount == 0)
    }

    @Test("已知声纹结果按时间与文本匹配历史片段，保护另一位人工确认")
    func matcherAppliesKnownAliasesOnly() {
        let target = UUID()
        let other = UUID()
        let first = HistoricalSpeakerRelabeler.SegmentSnapshot(
            id: UUID(),
            startMs: 1_000,
            endMs: 5_000,
            text: "年度量能可以保证，返点需要再确认。",
            participantId: nil,
            speakerWasUserConfirmed: false
        )
        let protected = HistoricalSpeakerRelabeler.SegmentSnapshot(
            id: UUID(),
            startMs: 6_000,
            endMs: 9_000,
            text: "这部分我已经人工确认。",
            participantId: other,
            speakerWasUserConfirmed: true
        )
        let result = DiarizationChunkResult(
            durationMs: 10_000,
            segments: [
                .init(
                    startMs: 1_050,
                    endMs: 5_050,
                    text: "年度量能可以保证，返点需要再确认。",
                    speakerLabel: "p_01"
                ),
                .init(
                    startMs: 6_000,
                    endMs: 9_000,
                    text: "这部分我已经人工确认。",
                    speakerLabel: "p_01"
                )
            ]
        )

        let assignments = HistoricalSpeakerRelabelMatcher.assignments(
            result: result,
            chunkWallStartMs: 0,
            knownSpeakerIDs: ["p_01": target],
            existingSegments: [first, protected]
        )

        #expect(assignments == [first.id: target])
    }

    @Test("通用 speaker 标签不冒充已知人物")
    func matcherIgnoresGenericLabels() {
        let segment = HistoricalSpeakerRelabeler.SegmentSnapshot(
            id: UUID(), startMs: 0, endMs: 3_000, text: "你好。",
            participantId: nil, speakerWasUserConfirmed: false
        )
        let result = DiarizationChunkResult(
            durationMs: 3_000,
            segments: [
                .init(startMs: 0, endMs: 3_000, text: "你好。", speakerLabel: "speaker_0")
            ]
        )
        #expect(
            HistoricalSpeakerRelabelMatcher.assignments(
                result: result,
                chunkWallStartMs: 0,
                knownSpeakerIDs: ["p_01": UUID()],
                existingSegments: [segment]
            ).isEmpty
        )
    }
}

private final class UnsupportedKnownSpeakerDiarizationService: DiarizationServicing, @unchecked Sendable {
    private(set) var transcribeCallCount = 0

    func transcribeChunk(
        at chunkURL: URL,
        knownSpeakers: [KnownSpeakerReference]
    ) async throws -> DiarizationChunkResult {
        transcribeCallCount += 1
        throw DiarizationAPIError.invalidResponse
    }

    func testConnection() async throws -> Bool { true }
}
