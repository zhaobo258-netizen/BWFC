import Foundation

struct HistoricalPersonProjectSummary: Equatable, Sendable, Identifiable {
    var projectID: UUID
    var title: String
    var lastActivityAt: Date
    var attributedSegmentCount: Int
    var userConfirmedSegmentCount: Int

    var id: UUID { projectID }
}

struct HistoricalPersonSummary: Equatable, Sendable, Identifiable {
    var profile: SpeakerVoiceProfile
    var projects: [HistoricalPersonProjectSummary]

    var id: UUID { profile.id }
    var attributedSegmentCount: Int {
        projects.reduce(0) { $0 + $1.attributedSegmentCount }
    }
    var userConfirmedSegmentCount: Int {
        projects.reduce(0) { $0 + $1.userConfirmedSegmentCount }
    }
}

struct SpeakerCommunicationEvidence: Equatable, Sendable {
    var projectID: UUID
    var segmentID: UUID
    var startMs: Int64
    var text: String
}

struct HistoricalVoiceprintSampleClip: Equatable, Sendable {
    var projectID: UUID
    var sourceAudioRelativePath: String
    var audioStartMs: Int64
    var audioEndMs: Int64
}

enum HistoricalPersonLibrary {
    static func summaries(
        profiles: [SpeakerVoiceProfile],
        projects: [Project]
    ) -> [HistoricalPersonSummary] {
        profiles.map { profile in
            let matches = projects.compactMap { project -> HistoricalPersonProjectSummary? in
                let speakerIDs = Set(
                    project.speakers
                        .filter { $0.voiceProfileId == profile.id }
                        .map(\.id)
                )
                guard !speakerIDs.isEmpty else { return nil }
                let segmentCount = project.segments.filter {
                    guard let participantID = $0.participantId else { return false }
                    return speakerIDs.contains(participantID)
                        && ($0.state == .final || $0.state == .edited)
                }.count
                let confirmedCount = project.segments.filter {
                    guard let participantID = $0.participantId else { return false }
                    return speakerIDs.contains(participantID)
                        && ($0.state == .final || $0.state == .edited)
                        && $0.speakerWasUserConfirmed == true
                }.count
                return HistoricalPersonProjectSummary(
                    projectID: project.id,
                    title: project.title,
                    lastActivityAt: project.lastActivityAt,
                    attributedSegmentCount: segmentCount,
                    userConfirmedSegmentCount: confirmedCount
                )
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            return HistoricalPersonSummary(profile: profile, projects: matches)
        }
        .sorted { $0.profile.updatedAt > $1.profile.updatedAt }
    }

    static func communicationEvidence(
        profileID: UUID,
        projects: [Project]
    ) -> [SpeakerCommunicationEvidence] {
        projects
            .sorted { $0.lastActivityAt < $1.lastActivityAt }
            .flatMap { project -> [SpeakerCommunicationEvidence] in
                let speakerIDs = Set(
                    project.speakers
                        .filter { $0.voiceProfileId == profileID }
                        .map(\.id)
                )
                guard !speakerIDs.isEmpty else { return [] }
                return project.segments
                    .filter {
                        guard let participantID = $0.participantId else { return false }
                        return speakerIDs.contains(participantID)
                            && ($0.state == .final || $0.state == .edited)
                            && $0.speakerWasUserConfirmed == true
                            && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    .sorted { $0.startMs < $1.startMs }
                    .map {
                        SpeakerCommunicationEvidence(
                            projectID: project.id,
                            segmentID: $0.id,
                            startMs: $0.startMs,
                            text: $0.text
                        )
                    }
            }
    }

    /// 从已人工确认归属的历史发言中选取真实语音，拼足讯飞注册需要的时长。
    /// 不使用仅云端自动归属的片段，也不用静音填充或重复音频伪造时长。
    static func voiceprintSampleClips(
        profileID: UUID,
        projects: [Project],
        targetDurationMs: Int64
    ) -> [HistoricalVoiceprintSampleClip] {
        guard targetDurationMs > 0 else { return [] }
        let candidates = projects.flatMap { project -> [HistoricalVoiceprintSampleClip] in
            guard let relativePath = project.runtimeAssetRelativePath,
                  !relativePath.isEmpty else { return [] }
            let speakerIDs = Set(
                project.speakers
                    .filter { $0.voiceProfileId == profileID }
                    .map(\.id)
            )
            guard !speakerIDs.isEmpty else { return [] }
            return project.segments.compactMap { segment in
                guard let participantID = segment.participantId,
                      speakerIDs.contains(participantID),
                      segment.speakerWasUserConfirmed == true,
                      segment.state == .final || segment.state == .edited,
                      segment.endMs > segment.startMs else {
                    return nil
                }
                let audioStart = SpeakerSampleWindowPlanner.audioMs(
                    forWallMs: segment.startMs,
                    pauseIntervals: project.pauseIntervals
                )
                let audioEnd = SpeakerSampleWindowPlanner.audioMs(
                    forWallMs: segment.endMs,
                    pauseIntervals: project.pauseIntervals
                )
                guard audioEnd > audioStart else { return nil }
                return HistoricalVoiceprintSampleClip(
                    projectID: project.id,
                    sourceAudioRelativePath: relativePath,
                    audioStartMs: audioStart,
                    audioEndMs: audioEnd
                )
            }
        }
        .sorted {
            ($0.audioEndMs - $0.audioStartMs) > ($1.audioEndMs - $1.audioStartMs)
        }

        var selected: [HistoricalVoiceprintSampleClip] = []
        var accumulated: Int64 = 0
        for candidate in candidates where accumulated < targetDurationMs {
            let remaining = targetDurationMs - accumulated
            let duration = candidate.audioEndMs - candidate.audioStartMs
            guard duration > 0 else { continue }
            var trimmed = candidate
            if duration > remaining {
                trimmed.audioEndMs = trimmed.audioStartMs + remaining
            }
            selected.append(trimmed)
            accumulated += trimmed.audioEndMs - trimmed.audioStartMs
        }
        return accumulated == targetDurationMs ? selected : []
    }

    @discardableResult
    static func applyProfile(
        _ profile: SpeakerVoiceProfile,
        to projects: [Project]
    ) -> Int {
        var updated = 0
        for project in projects {
            for speaker in project.speakers where speaker.voiceProfileId == profile.id {
                speaker.displayName = profile.displayName
                speaker.role = profile.role
                speaker.colorToken = profile.colorToken
                speaker.backgroundContext = profile.backgroundContext
                speaker.communicationProfile = profile.communicationProfile
                speaker.isCurrentUser = profile.isCurrentUser
                speaker.voiceSamplePath = profile.sampleRelativePath
                speaker.voiceSampleDurationMs = profile.sampleDurationMs
                speaker.iflytekFeatureID = profile.iflytekFeatureID
                updated += 1
            }
        }
        return updated
    }

    @discardableResult
    static func unlinkProfile(
        _ profile: SpeakerVoiceProfile,
        from projects: [Project]
    ) -> Int {
        var updated = 0
        for project in projects {
            for speaker in project.speakers where speaker.voiceProfileId == profile.id {
                speaker.voiceProfileId = nil
                if speaker.voiceSamplePath == profile.sampleRelativePath {
                    speaker.voiceSamplePath = nil
                    speaker.voiceSampleDurationMs = nil
                }
                speaker.backgroundContext = nil
                speaker.communicationProfile = nil
                speaker.isCurrentUser = nil
                speaker.iflytekFeatureID = nil
                updated += 1
            }
        }
        return updated
    }
}
