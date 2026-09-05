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
        var remoteLabels: [UUID: String] = [:]
        var recordingSegments: [DiarizationChunkResult.Segment] = []
        var speakerIDsByRemoteLabel: [String: UUID] = [:]
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

    func diarizeRecording(
        audioURL: URL,
        pauseIntervals: [PauseInterval],
        existingSegments: [SegmentSnapshot],
        speakerReferences: [SpeakerReference]
    ) async throws -> Result {
        guard let limits = diarization.recordingLimits else {
            throw DiarizationRecordingError.unsupportedProvider
        }
        guard speakerReferences.count <= KnownSpeakerReference.maximumCount else {
            throw DiarizationAPIError.tooManyKnownSpeakers(
                maximum: KnownSpeakerReference.maximumCount, actual: speakerReferences.count
            )
        }
        try Task.checkCancellation()
        let duration = try AudioChunkExtractor.durationMs(of: audioURL)
        // 16 kHz mono Int16 WAV is 32 bytes/ms, plus its container header.
        guard duration <= (limits.maximumBytes - 4_096) / 32 else {
            throw DiarizationRecordingError.exceedsProviderLimit
        }
        try limits.validate(byteCount: duration * 32 + 4_096, durationMs: duration)
        let directory = fileManager.temporaryDirectory.appending(
            path: "帮我分析 整场分人 % \(UUID().uuidString)", directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let converted = directory.appending(path: "recording.wav")
        try AudioChunkExtractor.exportRecordingWAV(from: audioURL, to: converted)
        let bytes = try converted.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try limits.validate(byteCount: Int64(bytes), durationMs: duration)
        try Task.checkCancellation()
        let references = speakerReferences.map {
            KnownSpeakerReference(alias: $0.alias, sampleURL: $0.sampleURL,
                                  iflytekFeatureID: $0.iflytekFeatureID)
        }
        let result = try await diarization.transcribeRecording(at: converted, knownSpeakers: references)
        try Task.checkCancellation()
        let mapped = DiarizationChunkResult(durationMs: result.durationMs, segments: result.segments.map {
            var segment = $0
            segment.startMs = Self.wallMs(forAudioMs: $0.startMs, pauseIntervals: pauseIntervals)
            segment.endMs = Self.wallMs(forAudioMs: $0.endMs, pauseIntervals: pauseIntervals)
            return segment
        })
        let labels = HistoricalSpeakerRelabelMatcher.labels(
            result: mapped, chunkWallStartMs: 0, existingSegments: existingSegments
        )
        let knownIDs = Dictionary(speakerReferences.map { ($0.alias, $0.speakerID) },
                                  uniquingKeysWith: { first, _ in first })
        let assignments = HistoricalSpeakerRelabelMatcher.resolvedAssignments(
            labels: labels, knownSpeakerIDs: knownIDs, existingSegments: existingSegments
        )
        let scope = "recording:\(UUID().uuidString):"
        let peopleByLabel = HistoricalSpeakerRelabelMatcher.resolvedSpeakerIDs(
            labels: labels, knownSpeakerIDs: knownIDs, existingSegments: existingSegments
        )
        return Result(
            assignments: assignments, processedChunkCount: 1,
            remoteLabels: labels.mapValues { scope + $0 },
            recordingSegments: mapped.segments.map {
                var segment = $0
                segment.speakerLabel = $0.speakerLabel.map { scope + $0 }
                return segment
            },
            speakerIDsByRemoteLabel: Dictionary(uniqueKeysWithValues: peopleByLabel.map { (scope + $0.key, $0.value) })
        )
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
    static func resolvedAssignments(
        labels: [UUID: String],
        knownSpeakerIDs: [String: UUID],
        existingSegments: [HistoricalSpeakerRelabeler.SegmentSnapshot]
    ) -> [UUID: UUID] {
        let people = resolvedSpeakerIDs(labels: labels, knownSpeakerIDs: knownSpeakerIDs,
                                        existingSegments: existingSegments)
        var assignments: [UUID: UUID] = [:]
        for segment in existingSegments where !segment.speakerWasUserConfirmed {
            if let label = labels[segment.id], let person = people[label] {
                assignments[segment.id] = person
            }
        }
        return assignments
    }

    static func resolvedSpeakerIDs(
        labels: [UUID: String],
        knownSpeakerIDs: [String: UUID],
        existingSegments: [HistoricalSpeakerRelabeler.SegmentSnapshot]
    ) -> [String: UUID] {
        var confirmed: [String: Set<UUID>] = [:]
        for segment in existingSegments where segment.speakerWasUserConfirmed {
            if let label = labels[segment.id], let person = segment.participantId {
                confirmed[label, default: []].insert(person)
            }
        }
        var people: [String: UUID] = [:]
        for label in Set(labels.values).union(knownSpeakerIDs.keys) {
            let anchors = confirmed[label] ?? []
            guard anchors.count <= 1 else { continue }
            let known = knownSpeakerIDs[label]
            if let anchor = anchors.first {
                guard known == nil || known == anchor else { continue }
                people[label] = anchor
            } else if let known {
                people[label] = known
            }
        }
        return people
    }

    static func assignments(
        result: DiarizationChunkResult,
        chunkWallStartMs: Int64,
        knownSpeakerIDs: [String: UUID],
        existingSegments: [HistoricalSpeakerRelabeler.SegmentSnapshot]
    ) -> [UUID: UUID] {
        let matchedLabels = labels(result: result, chunkWallStartMs: chunkWallStartMs,
                                   existingSegments: existingSegments.filter { !$0.speakerWasUserConfirmed })
        return matchedLabels.reduce(into: [:]) { assignments, item in
            if let speakerID = knownSpeakerIDs[item.value] { assignments[item.key] = speakerID }
        }
    }

    static func labels(
        result: DiarizationChunkResult,
        chunkWallStartMs: Int64,
        existingSegments: [HistoricalSpeakerRelabeler.SegmentSnapshot]
    ) -> [UUID: String] {
        var matches: [UUID: String] = [:]
        for segment in existingSegments {
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
                  !label.isEmpty else { continue }

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
            matches[segment.id] = label
        }
        return matches
    }
}
