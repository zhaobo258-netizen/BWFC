import Foundation

/// 会前准备表单状态（阶段 1）。
/// 与 SwiftUI 解耦：全部字段与校验逻辑可单元测试；
/// 视图只负责绑定与展示。
@MainActor
@Observable
final class MeetingSetupFormModel {
    // MARK: - 基本信息（实施计划 5.2）
    var title: String = ""
    var background: String = ""
    var ourGoal: String = ""
    var ourBottomLine: String = ""
    var counterpartContext: String = ""

    // MARK: - 专业词汇
    var glossary: [String] = []

    // MARK: - 参会人
    var participants: [Participant] = []

    // MARK: - 麦克风与确认
    var selectedInputDeviceID: String?
    var consentGiven: Bool = false

    /// 首版最多 4 名实名识别参会人（实施计划 7.5：云端接口上限）
    static let maxParticipants = 4

    /// 可选显示颜色令牌（参会人标注用）
    static let colorTokens: [(token: String, displayName: String)] = [
        ("blue", "蓝"), ("orange", "橙"), ("green", "绿"),
        ("purple", "紫"), ("red", "红"), ("gray", "灰")
    ]

    /// 正在编辑的会议 ID（nil = 新建）
    private(set) var editingMeetingID: UUID?
    /// 已记录的云端处理告知确认时间
    private var existingConsentAt: Date?

    // MARK: - 载入 / 应用到模型

    /// 从既有会议载入（编辑草稿）；新建则传 nil
    func load(from meeting: Meeting?) {
        guard let meeting else { return }
        editingMeetingID = meeting.id
        title = meeting.title
        background = meeting.background
        ourGoal = meeting.ourGoal
        ourBottomLine = meeting.ourBottomLine
        counterpartContext = meeting.counterpartContext
        glossary = meeting.glossary
        participants = meeting.participants
        selectedInputDeviceID = meeting.preferredInputDeviceID
        consentGiven = meeting.audioUploadConsentAt != nil
        existingConsentAt = meeting.audioUploadConsentAt
    }

    /// 把表单内容写回会议模型（保持 draft 状态与既有 id）
    func apply(to meeting: Meeting) {
        meeting.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.background = background
        meeting.ourGoal = ourGoal
        meeting.ourBottomLine = ourBottomLine
        meeting.counterpartContext = counterpartContext
        meeting.glossary = glossary
        meeting.participants = participants
        meeting.preferredInputDeviceID = selectedInputDeviceID
        if consentGiven, meeting.audioUploadConsentAt == nil {
            // 首次勾选时记录确认时间（实施计划 4.1 / 12.1）
            meeting.audioUploadConsentAt = Date()
        } else if !consentGiven {
            meeting.audioUploadConsentAt = nil
        } else {
            meeting.audioUploadConsentAt = existingConsentAt ?? meeting.audioUploadConsentAt
        }
    }

    /// 基于表单创建新会议
    func makeMeeting() -> Meeting {
        let meeting = Meeting(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        apply(to: meeting)
        return meeting
    }

    // MARK: - 专业词汇

    /// 添加词条（去重、去空白）；返回是否成功
    @discardableResult
    func addGlossaryTerm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !glossary.contains(trimmed) else { return false }
        glossary.append(trimmed)
        return true
    }

    /// 删除词条
    func removeGlossaryTerm(_ term: String) {
        glossary.removeAll { $0 == term }
    }

    // MARK: - 参会人

    /// 是否已达 4 人上限
    var participantLimitReached: Bool {
        participants.count >= Self.maxParticipants
    }

    /// 添加参会人；超过上限时拒绝并返回 nil
    @discardableResult
    func addParticipant(displayName: String, side: ParticipantSide, role: String, colorToken: String) -> Participant? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !participantLimitReached else { return nil }
        let participant = Participant(
            cloudAlias: nextCloudAlias(),
            displayName: trimmed,
            side: side,
            role: role.trimmingCharacters(in: .whitespacesAndNewlines),
            colorToken: colorToken
        )
        participants.append(participant)
        return participant
    }

    /// 更新参会人
    func updateParticipant(_ participant: Participant) {
        guard let index = participants.firstIndex(where: { $0.id == participant.id }) else { return }
        participants[index] = participant
    }

    /// 删除参会人
    func removeParticipant(id: UUID) {
        participants.removeAll { $0.id == id }
    }

    /// 分配下一个云端代号（p_01…p_04，云端只见代号，实施计划 7.5）
    func nextCloudAlias() -> String {
        let used = Set(participants.map(\.cloudAlias))
        for index in 1...Self.maxParticipants {
            let alias = String(format: "p_%02d", index)
            if !used.contains(alias) { return alias }
        }
        return String(format: "p_%02d", participants.count + 1)
    }

    // MARK: - 校验

    /// 表单校验问题（空数组 = 可保存并可进入会中）
    var validationIssues: [String] {
        var issues: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("请填写会议名称")
        }
        if !consentGiven {
            issues.append("请确认所有参会人已知晓录音，且会议音频会分段发送至云端进行说话人识别")
        }
        return issues
    }

    /// 是否可以保存草稿（仅要求有名称）
    var canSaveDraft: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否可以进入会中（draft → ready）
    var canProceedToLive: Bool {
        validationIssues.isEmpty
    }
}
