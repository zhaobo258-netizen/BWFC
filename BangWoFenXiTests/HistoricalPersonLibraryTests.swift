import Foundation
import Testing
@testable import BangWoFenXi

@Suite("历史人物库")
struct HistoricalPersonLibraryTests {
    @Test("人物档案聚合跨会议发言和证据")
    func summariesAndEvidence() {
        let profileID = UUID()
        let speakerOne = Speaker(
            cloudAlias: "p_01",
            displayName: "张三",
            voiceProfileId: profileID
        )
        let speakerTwo = Speaker(
            cloudAlias: "p_02",
            displayName: "张三",
            voiceProfileId: profileID
        )
        let first = TranscriptSegment(
            startMs: 0,
            endMs: 2_000,
            text: "先讲结论。",
            participantId: speakerOne.id,
            source: .cloud,
            state: .final
        )
        first.speakerWasUserConfirmed = true
        let second = TranscriptSegment(
            startMs: 3_000,
            endMs: 5_000,
            text: "再说三个依据。",
            participantId: speakerTwo.id,
            source: .cloud,
            state: .edited
        )
        second.speakerWasUserConfirmed = true
        let projects = [
            Project(
                title: "第一次会议",
                sourceType: .liveRecording,
                lastActivityAt: Date(timeIntervalSince1970: 10),
                speakers: [speakerOne],
                segments: [first]
            ),
            Project(
                title: "第二次会议",
                sourceType: .liveRecording,
                lastActivityAt: Date(timeIntervalSince1970: 20),
                speakers: [speakerTwo],
                segments: [second]
            )
        ]
        let profile = SpeakerVoiceProfile(
            id: profileID,
            displayName: "张三",
            role: "区域负责人",
            colorToken: "blue",
            sampleRelativePath: "VoiceProfiles/\(profileID.uuidString)/reference.wav",
            sampleDurationMs: 3_000,
            isAutoEnabled: true,
            createdAt: .distantPast,
            updatedAt: .now
        )

        let summary = HistoricalPersonLibrary.summaries(
            profiles: [profile],
            projects: projects
        )[0]
        let evidence = HistoricalPersonLibrary.communicationEvidence(
            profileID: profileID,
            projects: projects
        )

        #expect(summary.projects.map(\.title) == ["第二次会议", "第一次会议"])
        #expect(summary.attributedSegmentCount == 2)
        #expect(summary.userConfirmedSegmentCount == 2)
        #expect(evidence.map(\.segmentID) == [first.id, second.id])
    }

    @Test("表达画像不把云端自动归属冒充人工确认证据")
    func communicationEvidenceRequiresUserConfirmation() {
        let profileID = UUID()
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "张三",
            voiceProfileId: profileID
        )
        let automatic = TranscriptSegment(
            startMs: 0,
            endMs: 2_000,
            text: "云端自动归属。",
            participantId: speaker.id,
            source: .cloud,
            state: .final
        )
        let confirmed = TranscriptSegment(
            startMs: 3_000,
            endMs: 5_000,
            text: "用户已确认。",
            participantId: speaker.id,
            source: .cloud,
            state: .final
        )
        confirmed.speakerWasUserConfirmed = true
        let project = Project(
            title: "会议",
            sourceType: .liveRecording,
            speakers: [speaker],
            segments: [automatic, confirmed]
        )

        let evidence = HistoricalPersonLibrary.communicationEvidence(
            profileID: profileID,
            projects: [project]
        )

        #expect(evidence.map(\.segmentID) == [confirmed.id])
    }

    @Test("档案更新会同步所有关联会议，删除时解除关联")
    func applyAndUnlink() {
        let profileID = UUID()
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "旧名",
            voiceSamplePath: "VoiceProfiles/\(profileID.uuidString)/reference.wav",
            voiceSampleDurationMs: 3_000,
            voiceProfileId: profileID
        )
        let project = Project(
            title: "会议",
            sourceType: .liveRecording,
            speakers: [speaker]
        )
        let profile = SpeakerVoiceProfile(
            id: profileID,
            displayName: "新名",
            role: "总经理",
            colorToken: "orange",
            sampleRelativePath: "VoiceProfiles/\(profileID.uuidString)/reference.wav",
            sampleDurationMs: 3_000,
            isAutoEnabled: true,
            createdAt: .distantPast,
            updatedAt: .now,
            backgroundContext: "关注渠道效率"
        )

        #expect(HistoricalPersonLibrary.applyProfile(profile, to: [project]) == 1)
        #expect(speaker.displayName == "新名")
        #expect(speaker.backgroundContext == "关注渠道效率")

        #expect(HistoricalPersonLibrary.unlinkProfile(profile, from: [project]) == 1)
        #expect(speaker.voiceProfileId == nil)
        #expect(speaker.voiceSamplePath == nil)
        #expect(speaker.backgroundContext == nil)
    }
}
