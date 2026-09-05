import Foundation
import Testing
@testable import BangWoFenXi

@Suite("语音外放（AI 回答朗读）")
struct AnswerSpeechTests {
    private final class MockPlayer: AnswerSpeechPlaying, @unchecked Sendable {
        private(set) var started: [(text: String, identifier: String)] = []
        private(set) var stopCount = 0
        @MainActor var onPlaybackEnded: (@MainActor @Sendable (String) -> Void)?
        @MainActor var shouldFail = false

        @MainActor func startSpeaking(text: String, identifier: String) throws {
            if shouldFail { throw AnswerSpeechError.voiceUnavailable }
            started.append((text, identifier))
        }

        @MainActor func stopSpeaking() {
            stopCount += 1
        }
    }

    @Test("朗读文本清理：去来源角标与 Markdown 噪声")
    func textPreparation() {
        let reply = """
        ### 结论
        这是**重点**，参见【web_1】。详见 [官网说明](https://example.com)。
        后续待确认。
        """
        let readable = AnswerSpeechTextPreparation.readableText(from: reply)
        #expect(!readable.contains("【web_1】"))
        #expect(!readable.contains("**"))
        #expect(!readable.contains("###"))
        #expect(!readable.contains("https://"))
        #expect(readable.contains("官网说明"))
        #expect(readable.contains("这是重点"))
        #expect(AnswerSpeechTextPreparation.readableText(from: "  \n  ").isEmpty)
    }

    @Test("朗读文本长度封顶")
    func textLengthCap() {
        let long = String(repeating: "字", count: AnswerSpeechTextPreparation.maximumCharacters + 500)
        #expect(
            AnswerSpeechTextPreparation.readableText(from: long).count
                == AnswerSpeechTextPreparation.maximumCharacters
        )
    }

    @Test("点击播放/停止：同一消息切换、换消息先停旧")
    @MainActor
    func togglePlayback() {
        let player = MockPlayer()
        let controller = AnswerSpeechController(player: player)
        controller.togglePlayback(messageID: "m1", reply: "第一条回答")
        #expect(controller.speakingMessageID == "m1")
        #expect(player.started.count == 1)
        #expect(player.stopCount == 1) // 换条播放前先停旧（幂等）
        // 换消息：先停止旧的再播新的
        controller.togglePlayback(messageID: "m2", reply: "第二条回答")
        #expect(controller.speakingMessageID == "m2")
        #expect(player.stopCount == 2)
        #expect(player.started.count == 2)
        // 再点同一条：停止
        controller.togglePlayback(messageID: "m2", reply: "第二条回答")
        #expect(controller.speakingMessageID == nil)
        #expect(player.stopCount == 3)
        // 空文本不播
        controller.togglePlayback(messageID: "m3", reply: "  ")
        #expect(controller.speakingMessageID == nil)
        #expect(player.started.count == 2)
    }

    @Test("离开页面停止朗读")
    @MainActor
    func disappearStops() {
        let player = MockPlayer()
        let controller = AnswerSpeechController(player: player)
        controller.togglePlayback(messageID: "m1", reply: "回答")
        controller.handleDisappear()
        #expect(controller.speakingMessageID == nil)
        #expect(player.stopCount == 2) // 1 次换条前停旧 + 1 次显式停止
        // 已停止时再消失不重复计数
        controller.handleDisappear()
        #expect(player.stopCount == 2)
    }

    @Test("自然结束后状态复位，同一条回答一次点击即可重播")
    @MainActor
    func naturalCompletionAllowsReplay() {
        let player = MockPlayer()
        let controller = AnswerSpeechController(player: player)
        controller.togglePlayback(messageID: "m1", reply: "回答")
        player.onPlaybackEnded?(player.started[0].identifier)
        #expect(controller.speakingMessageID == nil)
        controller.togglePlayback(messageID: "m1", reply: "回答")
        #expect(player.started.count == 2)
        #expect(controller.speakingMessageID == "m1")
    }

    @Test("取消旧朗读的迟到回调不清除新朗读，同消息重播亦隔离")
    @MainActor
    func staleCompletionDoesNotStopReplacement() {
        let player = MockPlayer()
        let controller = AnswerSpeechController(player: player)
        controller.togglePlayback(messageID: "m1", reply: "回答")
        let first = player.started[0].identifier
        controller.stop()
        controller.togglePlayback(messageID: "m1", reply: "回答")
        let second = player.started[1].identifier
        #expect(first != second)
        player.onPlaybackEnded?(first)
        #expect(controller.speakingMessageID == "m1")
        player.onPlaybackEnded?(second)
        #expect(controller.speakingMessageID == nil)
    }

    @Test("启动失败展示原因且不假装朗读，再试成功清除错误")
    @MainActor
    func startFailureIsRecoverable() {
        let player = MockPlayer()
        player.shouldFail = true
        let controller = AnswerSpeechController(player: player)
        controller.togglePlayback(messageID: "m1", reply: "回答")
        #expect(controller.speakingMessageID == nil)
        #expect(controller.errorMessage?.contains("中文") == true)
        player.shouldFail = false
        controller.togglePlayback(messageID: "m1", reply: "回答")
        #expect(controller.speakingMessageID == "m1")
        #expect(controller.errorMessage == nil)
    }
}

@Suite("Project 持久化扩展字段")
struct ProjectMemoryCandidatePersistenceTests {
    @Test("旧 JSON 无新字段可解码（向后兼容）")
    func decodingLegacyJSON() throws {
        // 仅含旧字段的 Project JSON 片段
        let legacy = """
        {
          "schemaVersion": 2,
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "旧项目",
          "sourceType": "liveRecording",
          "sourceRecordings": [],
          "status": "ready",
          "createdAt": "2026-08-01T00:00:00Z",
          "lastActivityAt": "2026-08-01T00:00:00Z",
          "durationMs": 60000,
          "pauseIntervals": [],
          "note": {"markdown": "", "updatedAt": "2026-08-01T00:00:00Z"},
          "processingJobs": [],
          "archive": {"hasPendingChanges": false}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(legacy.utf8))
        #expect(project.businessMemoryCandidates.isEmpty)
        #expect(project.followUpCandidates.isEmpty)
        #expect(project.speakers.isEmpty)
    }

    @Test("Speaker.personId 编解码往返")
    func speakerPersonIdRoundTrip() throws {
        let personID = UUID()
        let speaker = Speaker(
            cloudAlias: "p_01",
            displayName: "王总",
            voiceProfileId: UUID(),
            personId: personID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(speaker)
        let restored = try decoder.decode(Speaker.self, from: data)
        #expect(restored.personId == personID)
        // 旧 JSON（无 personId 键）解码为 nil
        let legacyJSON = """
        {"id": "\(UUID().uuidString)", "cloudAlias": "p_01", "displayName": "旧说话人",
         "colorToken": "gray", "isUserConfirmed": false}
        """
        let legacySpeaker = try decoder.decode(Speaker.self, from: Data(legacyJSON.utf8))
        #expect(legacySpeaker.personId == nil)
    }

    @Test("字段级合并：memoryCandidates 所有权只写自己字段")
    func fieldOwnershipMerge() {
        let project = Project(title: "P", sourceType: .liveRecording)
        project.status = .recording
        project.businessMemoryCandidates = [
            BusinessMemoryCandidate(
                targetPersonID: nil,
                targetPersonDisplayName: nil,
                kind: .terminology,
                statement: "候选",
                scopeDescription: "人物",
                reason: "",
                evidenceSegmentID: UUID(),
                evidenceSnippet: "x"
            )
        ]
        project.followUpCandidates = []
        var stored = project
        stored.status = .ready
        stored.businessMemoryCandidates = []
        var projects = [project]
        ProjectPersistence.upsert(stored, into: &projects, fields: .memoryCandidates)
        // memoryCandidates 被覆盖为 stored 的空数组，status 不被这个所有权动
        #expect(projects[0].businessMemoryCandidates.isEmpty)
        #expect(projects[0].followUpCandidates.isEmpty)
    }
}
