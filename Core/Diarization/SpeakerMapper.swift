import Foundation

/// 说话人映射（纯逻辑，实施计划 7.5）：
/// 云端返回的说话人标签 → 本地参会人 或「待识别 A/B」。
/// 已知参会人通过云端代号（p_01…p_04）匹配；未知标签按出现顺序稳定分配字母。
struct SpeakerMapper: Sendable {
    /// 云端代号 → 参会人 ID
    private let participantByAlias: [String: UUID]
    /// 未知标签 → 展示用字母
    private var unknownLabelLetters: [String: String] = [:]

    init(participants: [Participant]) {
        var map: [String: UUID] = [:]
        for participant in participants where !participant.cloudAlias.isEmpty {
            map[participant.cloudAlias] = participant.id
        }
        self.participantByAlias = map
    }

    /// 解析结果
    enum Resolution: Equatable, Sendable {
        /// 已映射到参会人
        case known(participantId: UUID)
        /// 未识别：展示标签（如「待识别 A」）
        case unknown(displayName: String)
    }

    /// 解析一个云端说话人标签（可重复调用，同一未知标签得到同一展示名）
    mutating func resolve(remoteLabel: String?) -> Resolution {
        guard let remoteLabel, !remoteLabel.isEmpty else {
            return .unknown(displayName: "识别中")
        }
        if let participantId = participantByAlias[remoteLabel] {
            return .known(participantId: participantId)
        }
        // 云端可能会直接返回已知代号之外的标签（如 speaker_1 或云端自定义名）
        if let letter = unknownLabelLetters[remoteLabel] {
            return .unknown(displayName: "待识别 \(letter)")
        }
        let letter = Self.letter(forIndex: unknownLabelLetters.count)
        unknownLabelLetters[remoteLabel] = letter
        return .unknown(displayName: "待识别 \(letter)")
    }

    /// 当前已分配的未知标签数量
    var unknownCount: Int { unknownLabelLetters.count }

    /// 0 → A, 1 → B, …, 25 → Z, 26 → AA
    static func letter(forIndex index: Int) -> String {
        var index = index
        var result = ""
        repeat {
            let scalarValue = UInt8(ascii: "A") + UInt8(index % 26)
            result = String(UnicodeScalar(scalarValue)) + result
            index = index / 26 - 1
        } while index >= 0
        return result
    }
}
