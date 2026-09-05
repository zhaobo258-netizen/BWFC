import Foundation

struct HistoricalSpeakerRelabeler: @unchecked Sendable {
    struct SpeakerReference: Sendable {
        var speakerID: UUID
        var alias: String
        var sampleURL: URL
        var iflytekFeatureID: String? = nil
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
        guard case .supported = diarization.knownSpeakerMatchingCapability else {
            throw DiarizationAPIError.knownSpeakerMatchingUnsupported
        }
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
            KnownSpeakerReference(
                alias: $0.alias,
                sampleURL: $0.sampleURL,
                iflytekFeatureID: $0.iflytekFeatureID
            )
        }
        let knownSpeakerIDs = Dictionary(
            uniqueKeysWithValues: speakerReferences.map { ($0.alias, $0.speakerID) }
        )
        var assignments: [UUID: UUID] = [:]
        var conflicted = Set<UUID>()
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
            let mapped = DiarizationChunkResult(
                durationMs: result.durationMs,
                segments: result.segments.map { segment in
                    var mapped = segment
                    mapped.startMs = Self.wallMs(
                        forAudioMs: window.audioStartMs + segment.startMs,
                        pauseIntervals: pauseIntervals
                    )
                    mapped.endMs = Self.wallMs(
                        forAudioMs: window.audioStartMs + segment.endMs,
                        pauseIntervals: pauseIntervals
                    )
                    return mapped
                }
            )
            let chunkAssignments = HistoricalSpeakerRelabelMatcher.assignments(
                result: mapped,
                chunkWallStartMs: 0,
                knownSpeakerIDs: knownSpeakerIDs,
                existingSegments: existingSegments
            )
            for (segmentID, speakerID) in chunkAssignments where !conflicted.contains(segmentID) {
                if let previous = assignments[segmentID], previous != speakerID {
                    assignments.removeValue(forKey: segmentID)
                    conflicted.insert(segmentID)
                } else {
                    assignments[segmentID] = speakerID
                }
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
        for segment in existingSegments where !segment.speakerWasUserConfirmed {
            let duration = max(1, segment.endMs - segment.startMs)
            let overlapping = result.segments.filter { remote in
                let overlap = TranscriptReconciler.overlapMs(
                    startA: chunkWallStartMs + remote.startMs,
                    endA: chunkWallStartMs + remote.endMs,
                    startB: segment.startMs,
                    endB: segment.endMs
                )
                return overlap >= min(200, duration / 2)
                    && overlap > 0
            }.sorted { $0.startMs < $1.startMs }
            let labels = Set(overlapping.map { $0.speakerLabel ?? "" })
            guard labels.count == 1,
                  let label = labels.first,
                  let speakerID = knownSpeakerIDs[label] else { continue }

            var covered: Int64 = 0
            var coveredUntil = segment.startMs
            for remote in overlapping {
                let start = max(segment.startMs, chunkWallStartMs + remote.startMs)
                let end = min(segment.endMs, chunkWallStartMs + remote.endMs)
                covered += max(0, end - max(start, coveredUntil))
                coveredUntil = max(coveredUntil, end)
            }
            guard Double(covered) / Double(duration) >= 0.8,
                  TranscriptText.similarity(
                    overlapping.map(\.text).joined(), segment.text
                  ) >= 0.45 else { continue }
            assignments[segment.id] = speakerID
        }
        return assignments
    }
}
