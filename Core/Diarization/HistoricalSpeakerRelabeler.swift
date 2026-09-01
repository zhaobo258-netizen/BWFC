import Foundation

struct HistoricalSpeakerRelabeler: @unchecked Sendable {
    struct SpeakerReference: Sendable {
        var speakerID: UUID
        var alias: String
        var sampleURL: URL
    }

    struct SegmentSnapshot: Sendable, Equatable {
        var id: UUID
        var startMs: Int64
        var endMs: Int64
        var text: String
        var participantId: UUID?
        var speakerWasUserConfirmed: Bool
    }

    struct Result: Sendable, Equatable {
        var assignments: [UUID: UUID]
        var processedChunkCount: Int
    }

    private let diarization: any DiarizationServicing
    private let planner: ChunkPlanner
    private let fileManager: FileManager

    init(
        diarization: any DiarizationServicing,
        planner: ChunkPlanner = ChunkPlanner(),
        fileManager: FileManager = .default
    ) {
        self.diarization = diarization
        self.planner = planner
        self.fileManager = fileManager
    }

    func relabel(
        audioURL: URL,
        pauseIntervals: [PauseInterval],
        existingSegments: [SegmentSnapshot],
        speakerReferences: [SpeakerReference]
    ) async throws -> Result {
        guard !speakerReferences.isEmpty,
              speakerReferences.count <= KnownSpeakerReference.maximumCount else {
            return Result(assignments: [:], processedChunkCount: 0)
        }
        let audioDurationMs = try AudioChunkExtractor.durationMs(of: audioURL)
        var windows = planner.pendingWindows(uptoAudioMs: audioDurationMs, nextIndex: 0)
        if let tail = planner.finalWindow(
            uptoAudioMs: audioDurationMs,
            nextIndex: windows.count
        ) {
            windows.append(tail)
        }
        windows = windows.filter { window in
            let wallStart = Self.wallMs(
                forAudioMs: window.audioStartMs,
                pauseIntervals: pauseIntervals
            )
            let wallEnd = Self.wallMs(
                forAudioMs: window.audioEndMs,
                pauseIntervals: pauseIntervals
            )
            return existingSegments.contains { segment in
                segment.speakerWasUserConfirmed == false
                    && TranscriptReconciler.overlapMs(
                        startA: wallStart,
                        endA: wallEnd,
                        startB: segment.startMs,
                        endB: segment.endMs
                    ) > 0
            }
        }

        let directory = fileManager.temporaryDirectory.appending(
            path: "bwfx-speaker-rematch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let knownSpeakers = speakerReferences.map {
            KnownSpeakerReference(alias: $0.alias, sampleURL: $0.sampleURL)
        }
        let knownSpeakerIDs = Dictionary(
            uniqueKeysWithValues: speakerReferences.map { ($0.alias, $0.speakerID) }
        )
        var assignments: [UUID: UUID] = [:]
        var processed = 0
        for window in windows {
            try Task.checkCancellation()
            let chunkURL = directory.appending(
                path: String(format: "chunk-%05d.wav", window.index),
                directoryHint: .notDirectory
            )
            try AudioChunkExtractor.extract(
                from: audioURL,
                startMs: window.audioStartMs,
                endMs: window.audioEndMs,
                to: chunkURL
            )
            let result = try await diarization.transcribeChunk(
                at: chunkURL,
                knownSpeakers: knownSpeakers
            )
            let chunkAssignments = HistoricalSpeakerRelabelMatcher.assignments(
                result: result,
                chunkWallStartMs: Self.wallMs(
                    forAudioMs: window.audioStartMs,
                    pauseIntervals: pauseIntervals
                ),
                knownSpeakerIDs: knownSpeakerIDs,
                existingSegments: existingSegments
            )
            for (segmentID, speakerID) in chunkAssignments where assignments[segmentID] == nil {
                assignments[segmentID] = speakerID
            }
            processed += 1
        }
        return Result(assignments: assignments, processedChunkCount: processed)
    }

    static func wallMs(
        forAudioMs audioMs: Int64,
        pauseIntervals: [PauseInterval]
    ) -> Int64 {
        var pausedBefore: Int64 = 0
        for interval in pauseIntervals.sorted(by: { $0.startMs < $1.startMs }) {
            let audioAnchor = interval.startMs - pausedBefore
            if audioMs < audioAnchor { return audioMs + pausedBefore }
            pausedBefore += interval.durationMs
        }
        return audioMs + pausedBefore
    }
}

enum HistoricalSpeakerRelabelMatcher {
    static func assignments(
        result: DiarizationChunkResult,
        chunkWallStartMs: Int64,
        knownSpeakerIDs: [String: UUID],
        existingSegments: [HistoricalSpeakerRelabeler.SegmentSnapshot]
    ) -> [UUID: UUID] {
        var assignments: [UUID: UUID] = [:]
        for remote in result.segments {
            guard let label = remote.speakerLabel,
                  let speakerID = knownSpeakerIDs[label] else {
                continue
            }
            let remoteStart = chunkWallStartMs + remote.startMs
            let remoteEnd = chunkWallStartMs + remote.endMs
            let candidate = existingSegments
                .filter { segment in
                    !segment.speakerWasUserConfirmed
                        && TranscriptReconciler.overlapMs(
                            startA: remoteStart,
                            endA: remoteEnd,
                            startB: segment.startMs,
                            endB: segment.endMs
                        ) > 0
                }
                .map { segment -> (HistoricalSpeakerRelabeler.SegmentSnapshot, Double) in
                    let overlap = TranscriptReconciler.overlapMs(
                        startA: remoteStart,
                        endA: remoteEnd,
                        startB: segment.startMs,
                        endB: segment.endMs
                    )
                    let shorter = max(
                        1,
                        min(remoteEnd - remoteStart, segment.endMs - segment.startMs)
                    )
                    let overlapRatio = Double(overlap) / Double(shorter)
                    let similarity = TranscriptText.similarity(remote.text, segment.text)
                    return (segment, overlapRatio * 0.7 + similarity * 0.3)
                }
                .filter { $0.1 >= 0.5 }
                .max { $0.1 < $1.1 }?
                .0
            if let candidate, assignments[candidate.id] == nil {
                assignments[candidate.id] = speakerID
            }
        }
        return assignments
    }
}
