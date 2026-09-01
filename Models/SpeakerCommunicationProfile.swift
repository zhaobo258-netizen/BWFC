import Foundation

/// 跨会议人物档案中的“表达与沟通画像”。只记录可由原话观察到的沟通模式，
/// 不用于心理诊断、敏感属性推断或声称掌握当事人的真实内心。
struct SpeakerCommunicationProfile: Codable, Sendable, Equatable {
    struct Observation: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var title: String
        var observation: String
        var evidenceSegmentIds: [UUID]

        init(
            id: UUID = UUID(),
            title: String,
            observation: String,
            evidenceSegmentIds: [UUID]
        ) {
            self.id = id
            self.title = title
            self.observation = observation
            self.evidenceSegmentIds = evidenceSegmentIds
        }
    }

    var summary: String
    var observations: [Observation]
    var sourceProjectId: UUID
    var updatedAt: Date
}
