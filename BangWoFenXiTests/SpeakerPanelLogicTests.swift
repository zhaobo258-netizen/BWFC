import Foundation
import Testing
@testable import BangWoFenXi

/// 工作台说话人面板纯逻辑（声纹录入）
@Suite("说话人面板逻辑")
struct SpeakerPanelLogicTests {

    @Test("代号分配：跳过已占用，按序取下一个")
    func aliasAllocation() {
        #expect(SpeakerPanelLogic.nextCloudAlias(existing: []) == "p_01")
        let speakers = [
            Speaker(cloudAlias: "p_01", displayName: "甲"),
            Speaker(cloudAlias: "p_03", displayName: "乙")
        ]
        #expect(SpeakerPanelLogic.nextCloudAlias(existing: speakers) == "p_02")
    }

    @Test("颜色分配：避开已用颜色")
    func colorAllocation() {
        #expect(SpeakerPanelLogic.nextColorToken(existing: []) == "blue")
        let speakers = [
            Speaker(cloudAlias: "p_01", displayName: "甲", colorToken: "blue"),
            Speaker(cloudAlias: "p_02", displayName: "乙", colorToken: "orange")
        ]
        #expect(SpeakerPanelLogic.nextColorToken(existing: speakers) == "green")
    }

    @Test("运行时同步：V2 样本优先于 legacy，id 与代号对齐")
    func runtimeSync() {
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "张三",
            legacyVoiceReferencePath: "old/path.wav",
            voiceSamplePath: "meetings/x/samples/y.wav",
            voiceSampleDurationMs: 3000
        )
        let meeting = Meeting(title: "t")
        SpeakerPanelLogic.syncRuntimeParticipants(speakers: [speaker], meeting: meeting)
        #expect(meeting.participants.count == 1)
        #expect(meeting.participants[0].id == speaker.id)
        #expect(meeting.participants[0].cloudAlias == "p_01")
        #expect(meeting.participants[0].voiceReferencePath == "meetings/x/samples/y.wav")
        #expect(meeting.participants[0].voiceReferenceDurationMs == 3000)
    }

    @Test("运行时同步：无 V2 样本回落 legacy")
    func runtimeSyncLegacyFallback() {
        let speaker = Speaker(
            cloudAlias: "p_02",
            displayName: "李四",
            legacyVoiceReferencePath: "old/path.wav",
            legacyVoiceReferenceDurationMs: 2500
        )
        let meeting = Meeting(title: "t")
        SpeakerPanelLogic.syncRuntimeParticipants(speakers: [speaker], meeting: meeting)
        #expect(meeting.participants[0].voiceReferencePath == "old/path.wav")
        #expect(meeting.participants[0].voiceReferenceDurationMs == 2500)
    }

    @Test("本场声纹容量统一统计 V2 与 legacy")
    func activeReferenceCapacityUsesBothSchemas() {
        let v2 = Speaker(
            cloudAlias: "p_01",
            displayName: "甲",
            voiceSamplePath: "v2.wav",
            voiceSampleDurationMs: 3_000
        )
        let legacy = Speaker(
            cloudAlias: "p_02",
            displayName: "乙",
            legacyVoiceReferencePath: "legacy.wav",
            legacyVoiceReferenceDurationMs: 3_000
        )
        let empty = Speaker(cloudAlias: "p_03", displayName: "丙")

        #expect(SpeakerPanelLogic.activeVoiceReferenceCount(in: [v2, legacy, empty]) == 2)
        #expect(SpeakerPanelLogic.voiceReferencePath(for: legacy) == "legacy.wav")
    }

    @Test("第五人不能激活新样本，已激活人可以重录")
    func fifthReferenceIsRejectedBeforeRecording() {
        let active = (1...4).map { index in
            Speaker(
                cloudAlias: String(format: "p_%02d", index),
                displayName: "说话人 \(index)",
                voiceSamplePath: "\(index).wav",
                voiceSampleDurationMs: 3_000
            )
        }
        let fifth = Speaker(cloudAlias: "p_05", displayName: "说话人 5")
        let speakers = active + [fifth]

        #expect(SpeakerPanelLogic.canActivateVoiceReference(for: active[0].id, in: speakers))
        #expect(!SpeakerPanelLogic.canActivateVoiceReference(for: fifth.id, in: speakers))
    }

    @Test("Speaker V2 样本字段：编解码回环 + 旧数据无字段容错")
    func speakerCodableRoundtrip() throws {
        let speaker = Speaker(cloudAlias: "p_01", displayName: "甲",
                              voiceSamplePath: "a.wav", voiceSampleDurationMs: 4000)
        let data = try JSONEncoder().encode(speaker)
        let decoded = try JSONDecoder().decode(Speaker.self, from: data)
        #expect(decoded.voiceSamplePath == "a.wav")
        #expect(decoded.voiceSampleDurationMs == 4000)

        // 旧数据没有新字段：解码不失败，字段为 nil
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","cloudAlias":"p_01","displayName":"甲",\
        "colorToken":"blue","isUserConfirmed":true}
        """
        let old = try JSONDecoder().decode(Speaker.self, from: Data(legacyJSON.utf8))
        #expect(old.voiceSamplePath == nil)
    }
}

/// 实时录音触发预设（实时分析优化）
@Suite("实时分析触发预设")
struct LiveTriggerPresetTests {

    @Test("实时预设：2 片段 + 5 秒防抖即可触发")
    func livePresetFiresFaster() {
        var trigger = AnalysisTrigger.liveRecording
        trigger.noteNewSegment(atMs: 10_000)
        trigger.noteNewSegment(atMs: 11_000)
        #expect(trigger.conditionMet(atMs: 11_000))
        #expect(!trigger.readyToFire(atMs: 15_999), "防抖 5 秒未过")
        #expect(trigger.readyToFire(atMs: 16_000))
    }

    @Test("实时预设：闲置 30 秒 + 1 片段触发")
    func livePresetIdleTimeout() {
        var trigger = AnalysisTrigger.liveRecording
        trigger.noteNewSegment(atMs: 1_000)
        trigger.noteSuccess(atMs: 10_000)
        trigger.noteNewSegment(atMs: 20_000)
        #expect(!trigger.conditionMet(atMs: 39_000), "距成功 29 秒未到")
        #expect(trigger.readyToFire(atMs: 41_000), "闲置超 30 秒且防抖已过")
    }

    @Test("实时预设：失败退避仍为 30 秒（防热循环红线不放松）")
    func livePresetKeepsFailureBackoff() {
        var trigger = AnalysisTrigger.liveRecording
        trigger.noteNewSegment(atMs: 1_000)
        trigger.noteNewSegment(atMs: 2_000)
        #expect(trigger.readyToFire(atMs: 7_001))
        trigger.noteFailure(atMs: 7_001)
        #expect(!trigger.readyToFire(atMs: 30_000))
        #expect(trigger.readyToFire(atMs: 37_002))
    }
}
