import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

@Suite("历史发言声纹重标")
struct HistoricalSpeakerRelabelerTests {
    @Test("整场只请求一次，非相邻同标签稳定，恢复暂停时间并保留人工锚点")
    func wholeRecordingGroupsAndProtectsManualIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "中文 空格 % 整场-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appending(path: "原始 音频 %.caf")
        try Self.makeSyntheticAudio(at: audio)
        let person = UUID()
        let existing: [HistoricalSpeakerRelabeler.SegmentSnapshot] = [
            .init(id: UUID(), startMs: 0, endMs: 2_000, text: "库存需要盘点", participantId: person, speakerWasUserConfirmed: true),
            .init(id: UUID(), startMs: 4_000, endMs: 6_000, text: "交付安排下周", participantId: nil, speakerWasUserConfirmed: false),
            .init(id: UUID(), startMs: 6_000, endMs: 8_000, text: "库存需要盘点", participantId: nil, speakerWasUserConfirmed: false)
        ]
        let service = RecordingDiarizationFixture()
        let result = try await HistoricalSpeakerRelabeler(diarization: service).diarizeRecording(
            audioURL: audio, pauseIntervals: [.init(startMs: 2_000, endMs: 4_000)],
            existingSegments: existing, speakerReferences: []
        )
        #expect(service.calls == 1)
        #expect(service.receivedSampleRate == 16_000)
        #expect(service.receivedChannels == 1)
        #expect(result.remoteLabels[existing[0].id] == result.remoteLabels[existing[2].id])
        #expect(result.remoteLabels[existing[0].id] != result.remoteLabels[existing[1].id])
        #expect(result.assignments == [existing[2].id: person])
        #expect(result.recordingSegments[1].startMs == 4_000)
        #expect(result.speakerIDsByRemoteLabel[result.recordingSegments[2].speakerLabel ?? ""] == person)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(service.uploadedURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test("整场限制在请求前失败，取消后不接受不配合取消的服务结果")
    func wholeRecordingLimitsAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "中文 空格 % 限制-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appending(path: "audio.caf")
        try Self.makeSyntheticAudio(at: audio)
        let small = RecordingDiarizationFixture(maximumBytes: 1_000)
        await #expect(throws: DiarizationRecordingError.exceedsProviderLimit) {
            try await HistoricalSpeakerRelabeler(diarization: small).diarizeRecording(
                audioURL: audio, pauseIntervals: [], existingSegments: [], speakerReferences: []
            )
        }
        #expect(small.calls == 0)
        let canceling = RecordingDiarizationFixture(cancelCurrentTask: true)
        let task = Task {
            try await HistoricalSpeakerRelabeler(diarization: canceling).diarizeRecording(
                audioURL: audio, pauseIntervals: [], existingSegments: [], speakerReferences: []
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(canceling.calls == 1)
    }

    @Test("人物组内人工冲突及声纹与人工冲突均不传播")
    func conflictingAnchorsBlockAutomaticIdentity() {
        let first = UUID(), other = UUID()
        let anchor = HistoricalSpeakerRelabeler.SegmentSnapshot(id: UUID(), startMs: 0, endMs: 1_000,
            text: "甲", participantId: first, speakerWasUserConfirmed: true)
        let target = HistoricalSpeakerRelabeler.SegmentSnapshot(id: UUID(), startMs: 2_000, endMs: 3_000,
            text: "乙", participantId: nil, speakerWasUserConfirmed: false)
        let conflict = HistoricalSpeakerRelabeler.SegmentSnapshot(id: UUID(), startMs: 4_000, endMs: 5_000,
            text: "丙", participantId: other, speakerWasUserConfirmed: true)
        let labels = [anchor.id: "speaker_0", target.id: "speaker_0", conflict.id: "speaker_0"]
        #expect(HistoricalSpeakerRelabelMatcher.resolvedAssignments(
            labels: labels, knownSpeakerIDs: [:], existingSegments: [anchor, target]
        ) == [target.id: first])
        #expect(HistoricalSpeakerRelabelMatcher.resolvedAssignments(
            labels: labels, knownSpeakerIDs: [:], existingSegments: [anchor, target, conflict]
        ).isEmpty)
        #expect(HistoricalSpeakerRelabelMatcher.resolvedAssignments(
            labels: labels, knownSpeakerIDs: ["speaker_0": other], existingSegments: [anchor, target]
        ).isEmpty)
    }

    private static func makeSyntheticAudio(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 6)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.05) * 0.1
            }
        }
        try file.write(from: buffer)
    }

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

private final class RecordingDiarizationFixture: DiarizationServicing, @unchecked Sendable {
    let recordingLimits: DiarizationRecordingLimits?
    let cancelCurrentTask: Bool
    private(set) var calls = 0
    private(set) var receivedSampleRate: Double = 0
    private(set) var receivedChannels: AVAudioChannelCount = 0
    private(set) var uploadedURL: URL?

    init(maximumBytes: Int64 = 25_000_000, cancelCurrentTask: Bool = false) {
        recordingLimits = .init(maximumBytes: maximumBytes, maximumDurationMs: nil)
        self.cancelCurrentTask = cancelCurrentTask
    }

    func transcribeChunk(at chunkURL: URL, knownSpeakers: [KnownSpeakerReference]) async throws -> DiarizationChunkResult {
        calls += 1
        uploadedURL = chunkURL
        let audio = try AVAudioFile(forReading: chunkURL)
        receivedSampleRate = audio.processingFormat.sampleRate
        receivedChannels = audio.processingFormat.channelCount
        if cancelCurrentTask { withUnsafeCurrentTask { $0?.cancel() } }
        return .init(durationMs: 6_000, segments: [
            .init(startMs: 0, endMs: 2_000, text: "库存需要盘点", speakerLabel: "speaker_0"),
            .init(startMs: 2_000, endMs: 4_000, text: "交付安排下周", speakerLabel: "speaker_1"),
            .init(startMs: 4_000, endMs: 6_000, text: "库存需要盘点", speakerLabel: "speaker_0")
        ])
    }
    func testConnection() async throws -> Bool { true }
}
