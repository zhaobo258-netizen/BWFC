import Foundation
import Testing
@testable import BangWoFenXi

/// 会前准备表单模型测试：词汇增删、参会人 CRUD 与 4 人上限、校验逻辑
@Suite("会前准备表单")
@MainActor
struct MeetingSetupFormModelTests {

    // MARK: - 专业词汇

    @Test("词汇：添加、去重、去空白、删除")
    func glossaryEditing() {
        let form = MeetingSetupFormModel()
        #expect(form.addGlossaryTerm("返点"))
        #expect(form.addGlossaryTerm("账期"))
        #expect(!form.addGlossaryTerm("返点"), "重复词条应被拒绝")
        #expect(!form.addGlossaryTerm("   "), "空白词条应被拒绝")
        #expect(form.glossary == ["返点", "账期"])

        form.removeGlossaryTerm("返点")
        #expect(form.glossary == ["账期"])
    }

    // MARK: - 参会人

    @Test("参会人：添加并自动分配云端代号 p_01…p_04")
    func participantAliasAssignment() {
        let form = MeetingSetupFormModel()
        let p1 = form.addParticipant(displayName: "张总", side: .counterpart, role: "采购", colorToken: "blue")
        let p2 = form.addParticipant(displayName: "赵总", side: .ours, role: "销售", colorToken: "green")
        #expect(p1?.cloudAlias == "p_01")
        #expect(p2?.cloudAlias == "p_02")
        #expect(form.participants.count == 2)
    }

    @Test("参会人：删除后代号可被复用")
    func aliasReusedAfterRemoval() {
        let form = MeetingSetupFormModel()
        let p1 = form.addParticipant(displayName: "甲", side: .ours, role: "", colorToken: "blue")
        _ = form.addParticipant(displayName: "乙", side: .counterpart, role: "", colorToken: "red")
        form.removeParticipant(id: p1!.id)
        let p3 = form.addParticipant(displayName: "丙", side: .neutral, role: "", colorToken: "gray")
        #expect(p3?.cloudAlias == "p_01", "空出的最小代号应被复用")
    }

    @Test("参会人：最多 4 名，超过拒绝并触发上限标记")
    func participantLimit() {
        let form = MeetingSetupFormModel()
        for index in 1...4 {
            #expect(form.addParticipant(displayName: "成员\(index)", side: .ours, role: "", colorToken: "blue") != nil)
        }
        #expect(form.participantLimitReached)
        #expect(form.addParticipant(displayName: "成员5", side: .ours, role: "", colorToken: "blue") == nil,
                "第 5 名参会人必须被拒绝（实施计划 7.5）")
        #expect(form.participants.count == 4)
    }

    @Test("参会人：空姓名拒绝；编辑与删除生效")
    func participantValidationAndEditing() {
        let form = MeetingSetupFormModel()
        #expect(form.addParticipant(displayName: "  ", side: .ours, role: "", colorToken: "blue") == nil)

        let participant = form.addParticipant(displayName: "张总", side: .counterpart, role: "采购", colorToken: "blue")
        let updated = Participant(
            id: participant!.id,
            cloudAlias: participant!.cloudAlias,
            displayName: "张总（改）",
            side: .counterpart,
            role: "采购总监",
            colorToken: "orange"
        )
        form.updateParticipant(updated)
        #expect(form.participants.first?.displayName == "张总（改）")
        #expect(form.participants.first?.role == "采购总监")

        form.removeParticipant(id: participant!.id)
        #expect(form.participants.isEmpty)
    }

    // MARK: - 校验

    @Test("校验：未填名称或未勾选确认时不得进入会中")
    func validation() {
        let form = MeetingSetupFormModel()
        #expect(!form.canSaveDraft)
        #expect(!form.canProceedToLive)
        #expect(form.validationIssues.count == 2)

        form.title = "年度谈判"
        #expect(form.canSaveDraft)
        #expect(!form.canProceedToLive, "未勾选录音与云端处理告知不得开始")

        form.consentGiven = true
        #expect(form.canProceedToLive)
        #expect(form.validationIssues.isEmpty)
    }

    // MARK: - 与 Meeting 模型互转

    @Test("应用到会议：首次勾选记录确认时间")
    func applyRecordsConsentTime() {
        let form = MeetingSetupFormModel()
        form.title = "年度谈判"
        form.consentGiven = true
        form.glossary = ["返点"]

        let meeting = form.makeMeeting()
        #expect(meeting.title == "年度谈判")
        #expect(meeting.glossary == ["返点"])
        #expect(meeting.audioUploadConsentAt != nil, "首次勾选必须记录确认时间（实施计划 12.1）")

        // 再次载入并保存：保留原确认时间
        let form2 = MeetingSetupFormModel()
        form2.load(from: meeting)
        let originalConsentAt = meeting.audioUploadConsentAt
        form2.apply(to: meeting)
        #expect(meeting.audioUploadConsentAt == originalConsentAt)

        // 取消勾选：清除确认时间
        form2.consentGiven = false
        form2.apply(to: meeting)
        #expect(meeting.audioUploadConsentAt == nil)
    }

    @Test("载入既有会议：字段完整回填")
    func loadFromMeeting() {
        let meeting = Meeting(
            title: "编辑测试",
            background: "背景",
            ourGoal: "目标",
            ourBottomLine: "底线",
            counterpartContext: "对方",
            glossary: ["SKU"],
            preferredInputDeviceID: "device-1"
        )
        meeting.participants.append(
            Participant(cloudAlias: "p_01", displayName: "张总", side: .counterpart, role: "采购")
        )

        let form = MeetingSetupFormModel()
        form.load(from: meeting)
        #expect(form.title == "编辑测试")
        #expect(form.background == "背景")
        #expect(form.ourGoal == "目标")
        #expect(form.ourBottomLine == "底线")
        #expect(form.counterpartContext == "对方")
        #expect(form.glossary == ["SKU"])
        #expect(form.participants.count == 1)
        #expect(form.selectedInputDeviceID == "device-1")
        #expect(!form.consentGiven)
    }
}
