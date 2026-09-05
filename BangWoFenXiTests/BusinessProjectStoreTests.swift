import Foundation
import Testing
@testable import BangWoFenXi

@Suite("轻 CRM 业务项目存储", .serialized)
struct BusinessProjectStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-biz-tests-中文 100%-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("创建、更新与重名拒绝")
    func createAndUpdate() throws {
        let store = BusinessProjectStore(baseDirectory: try temporaryDirectory())
        let created = try store.create(
            name: "满分便利店翻牌",
            goalStatement: "完成 100 家翻牌",
            participantPersonIDs: [UUID()],
            linkedProjectIDs: [UUID()]
        )
        #expect(created.status == .active)
        #expect(throws: BusinessProjectStoreError.duplicateName) {
            _ = try store.create(name: "满分便利店翻牌")
        }
        var updated = created
        updated.goalStatement = "完成 120 家翻牌"
        _ = try store.update(updated)
        #expect(try store.load().first?.goalStatement == "完成 120 家翻牌")
    }

    @Test("中文、空格与百分号目录中二次写入和重开保留业务项目")
    func encodedDirectoryPreservesBusinessProjects() throws {
        let directory = try temporaryDirectory()
        let store = BusinessProjectStore(baseDirectory: directory)
        let first = try store.create(name: "合成业务甲")
        let followUp = FollowUp(title: "保留的跟进")
        _ = try store.replaceFollowUps(businessProjectID: first.id, followUps: [followUp])
        let second = try store.create(name: "合成业务乙")
        let reopened = BusinessProjectStore(baseDirectory: directory)
        let projects = try reopened.load()
        #expect(Set(projects.map(\.id)) == [first.id, second.id])
        #expect(projects.first { $0.id == first.id }?.followUps.map(\.id) == [followUp.id])
    }

    @Test("跟进闭环：待跟进 → 进行中 → 完成需记录结果")
    func followUpLifecycle() throws {
        let store = BusinessProjectStore(baseDirectory: try temporaryDirectory())
        let project = try store.create(name: "DSCM 品类项目")
        let followUp = FollowUp(
            title: "与品牌方确认数据口径",
            ownerDisplayText: nil,
            dueDate: nil,
            source: FollowUpSourceReference(
                recordingID: UUID(), segmentID: UUID(), snippet: "下周口径对齐"
            ),
            confirmationStatus: .confirmed,
            handlingStatus: .pending
        )
        _ = try store.replaceFollowUps(
            businessProjectID: project.id,
            followUps: [followUp]
        )
        var current = try store.load().first
        #expect(current?.openFollowUps.count == 1)

        var updated = current!
        updated.followUps[0].handlingStatus = .inProgress
        _ = try store.replaceFollowUps(
            businessProjectID: project.id,
            followUps: updated.followUps
        )
        current = try store.load().first
        #expect(current?.openFollowUps.count == 1)

        updated = current!
        updated.followUps[0].handlingStatus = .completed
        updated.followUps[0].resultNote = "品牌方 9 月 3 日确认按新口径执行"
        updated.followUps[0].completedAt = Date()
        _ = try store.replaceFollowUps(
            businessProjectID: project.id,
            followUps: updated.followUps
        )
        let final = try store.load().first
        #expect(final?.openFollowUps.isEmpty == true)
        #expect(final?.followUps[0].resultNote?.contains("确认") == true)
    }

    @Test("关联录音去重、参与人物去重")
    func linkedIDsDeduplicated() throws {
        let store = BusinessProjectStore(baseDirectory: try temporaryDirectory())
        let project = try store.create(name: "P1")
        let recordingID = UUID()
        let personID = UUID()
        _ = try store.setLinkedProjects(
            businessProjectID: project.id,
            projectIDs: [recordingID, recordingID]
        )
        _ = try store.setParticipants(
            businessProjectID: project.id,
            personIDs: [personID, personID]
        )
        let loaded = try store.load().first
        #expect(loaded?.linkedProjectIDs.count == 1)
        #expect(loaded?.participantPersonIDs.count == 1)
    }

    @Test("归组建议：只列未关联录音的业务分类，同名不自动认定")
    func groupingSuggestions() throws {
        let store = BusinessProjectStore(baseDirectory: try temporaryDirectory())
        _ = try store.create(name: "已建项目", linkedProjectIDs: [UUID()])

        var p1 = Project(title: "录音1", businessCategory: "满分", sourceType: .liveRecording)
        var p2 = Project(title: "录音2", businessCategory: "满分", sourceType: .liveRecording)
        var p3 = Project(title: "录音3", businessCategory: "塔盟", sourceType: .importedAudio)
        var p4 = Project(title: "合并分析", businessCategory: "满分", sourceType: .combinedRecordings)
        var p5 = Project(title: "录音5", businessCategory: "满分", sourceType: .liveRecording)
        _ = p1; _ = p2; _ = p3; _ = p4; _ = p5
        let suggestions = BusinessProjectStore.groupingSuggestions(
            recordings: [p1, p2, p3, p4, p5],
            existingBusinessProjects: try store.load()
        )
        // “满分”4 条中排除合并分析 → 3 条；塔盟 1 条
        let manfen = suggestions.first { $0.name == "满分" }
        let tameng = suggestions.first { $0.name == "塔盟" }
        #expect(manfen?.projectIDs.count == 3)
        #expect(tameng?.projectIDs.count == 1)
        // 无分类录音不进建议
        #expect(suggestions.contains { $0.name.isEmpty } == false)
    }

    @Test("跟进逾期与开放集合")
    func overdueDetection() throws {
        let store = BusinessProjectStore(baseDirectory: try temporaryDirectory())
        let project = try store.create(name: "P")
        let overdue = FollowUp(
            title: "过期跟进",
            dueDate: Date(timeIntervalSinceNow: -86_400),
            handlingStatus: .pending
        )
        let upcoming = FollowUp(
            title: "未到期",
            dueDate: Date(timeIntervalSinceNow: 86_400),
            handlingStatus: .inProgress
        )
        let done = FollowUp(
            title: "已完成",
            dueDate: Date(timeIntervalSinceNow: -86_400),
            handlingStatus: .completed,
            resultNote: "完成",
            completedAt: Date()
        )
        _ = try store.replaceFollowUps(
            businessProjectID: project.id,
            followUps: [overdue, upcoming, done]
        )
        let loaded = try store.load().first
        #expect(loaded?.openFollowUps.count == 2)
        #expect(loaded?.overdueFollowUps.map(\.title) == ["过期跟进"])
    }
}
