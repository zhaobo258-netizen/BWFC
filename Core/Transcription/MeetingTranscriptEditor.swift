import Foundation

/// 转写片段人工编辑（实施计划 4.1 / 6.5）：
/// 修改说话人、修改文字、加星标。
/// 人工修改后的片段置为「人工已修订」（state: edited, source: manual），
/// 后续云端结果不得覆盖（由 TranscriptReconciler.applyCloudFinal 保证）。
enum MeetingTranscriptEditor {
    /// 修改说话人（含把「待识别」映射为已知参会人）
    static func assignSpeaker(_ segment: TranscriptSegment, to participant: Participant) {
        segment.participantId = participant.id
        // 保留云端原始标签用于审计，但来源转为人工
        segment.source = .manual
        segment.state = .edited
        segment.updatedAt = Date()
    }

    /// 清除说话人映射（回到待识别）
    static func clearSpeaker(_ segment: TranscriptSegment) {
        segment.participantId = nil
        segment.source = .manual
        segment.state = .edited
        segment.updatedAt = Date()
    }

    /// 修改转写文字
    static func editText(_ segment: TranscriptSegment, to newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segment.text = trimmed
        segment.source = .manual
        segment.state = .edited
        segment.updatedAt = Date()
    }

    /// 切换星标（不改变来源与状态）
    static func toggleStar(_ segment: TranscriptSegment) {
        segment.isStarred.toggle()
        segment.updatedAt = Date()
    }
}
