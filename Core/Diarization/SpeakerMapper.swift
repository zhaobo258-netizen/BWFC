import Foundation

/// 说话人映射（纯逻辑，实施计划 7.5）：
/// 云端返回的说话人标签 → 本地参会人 或「人物 1/2（待识别）」。
/// 已知参会人通过云端代号（p_01…p_04）匹配；未知标签按出现顺序稳定分配本场编号。
///
/// 并发与渲染安全（血泪教训）：
/// resolve 必须是**非 mutating 纯函数**——此前 mutating 版本在 @Observable
/// 控制器的存储属性上被视图求值路径调用时，每次调用都经修改访问器触发
/// 变更通知 → 视图失效 → 再次求值 → 再次调用，形成自激更新死循环。
/// 未知标签的编号分配改由 register 在模型层显式完成。
struct SpeakerMapper: Sendable {
    /// 云端代号 → 参会人 ID
    private let participantByAlias: [String: UUID]
    /// 未知标签 → 本场展示编号
    private var unknownLabelNumbers: [String: Int] = [:]
    /// 用户手工指认：未知标签 → 参会人 ID（09 号计划需求 2；
    /// 参会人列表变化重建 mapper 时由调用方回灌，避免指认丢失）
    private var manualLabelAssignments: [String: UUID] = [:]

    init(participants: [Participant]) {
        var map: [String: UUID] = [:]
        for participant in participants where !participant.cloudAlias.isEmpty {
            map[participant.cloudAlias] = participant.id
        }
        self.participantByAlias = map
    }

    /// 只在该代号确实作为 known_speaker_names 发送时使用。
    /// 调用方必须用本次请求的已发送代号集合先做限定。
    func participantId(forKnownAlias alias: String) -> UUID? {
        participantByAlias[alias]
    }

    /// provider 的 generic speaker label 只在单次音频请求内有意义。
    /// 按分片加上稳定作用域，防止下一个分片的同名 label 被当成同一人。
    static func scopedRemoteLabel(_ remoteLabel: String, chunkIndex: Int) -> String {
        "chunk:\(chunkIndex):\(remoteLabel)"
    }

    /// 相邻分片对同一段重叠发言给出足够证据时，沿用上一分片的
    /// 本地稳定标签。这个标签一旦被人工指认，历史回填和后续分片都可复用。
    static func stitchedRemoteLabels(
        for segments: [DiarizationChunkResult.Segment],
        chunkIndex: Int,
        wallStartMs: Int64,
        existingSegments: [TranscriptSegment]
    ) -> [String: String] {
        let rawLabels = Set(segments.compactMap { segment in
            segment.speakerLabel?.isEmpty == false ? segment.speakerLabel : nil
        })
        guard !rawLabels.isEmpty else { return [:] }

        let candidates = existingSegments.filter {
            $0.source == .cloud
                && $0.remoteSpeakerLabel?.isEmpty == false
                && $0.endMs >= wallStartMs - 2_500
        }
        var proposals: [String: String] = [:]
        for rawLabel in rawLabels {
            var matchingStableLabels = Set<String>()
            for incoming in segments where incoming.speakerLabel == rawLabel {
                let incomingStart = wallStartMs + incoming.startMs
                let incomingEnd = wallStartMs + incoming.endMs
                for existing in candidates {
                    guard let stableLabel = existing.remoteSpeakerLabel else { continue }
                    let overlap = TranscriptReconciler.overlapMs(
                        startA: incomingStart, endA: incomingEnd,
                        startB: existing.startMs, endB: existing.endMs
                    )
                    guard overlap > 0 else { continue }
                    let shorter = max(1, min(incomingEnd - incomingStart, existing.endMs - existing.startMs))
                    let overlapRatio = Double(overlap) / Double(shorter)
                    let similarity = TranscriptText.similarity(incoming.text, existing.text)
                    if overlapRatio >= 0.35, similarity >= 0.45 {
                        matchingStableLabels.insert(stableLabel)
                    }
                }
            }
            if matchingStableLabels.count == 1 {
                proposals[rawLabel] = matchingStableLabels.first
            }
        }
        let claimCounts = Dictionary(grouping: proposals.values, by: { $0 }).mapValues(\.count)
        var resolved: [String: String] = [:]
        for rawLabel in rawLabels {
            if let proposed = proposals[rawLabel], claimCounts[proposed] == 1 {
                resolved[rawLabel] = proposed
            } else {
                // 重叠证据有冲突时保持独立组，不按字母顺序把其中一人认成旧人。
                resolved[rawLabel] = scopedRemoteLabel(rawLabel, chunkIndex: chunkIndex)
            }
        }
        return resolved
    }

    /// 解析结果
    enum Resolution: Equatable, Sendable {
        /// 已映射到参会人
        case known(participantId: UUID)
        /// 未识别：展示标签（如「人物 1（待识别）」；未登记标签显示「待识别」）
        case unknown(displayName: String)
    }

    /// 纯解析（不修改内部状态，可在视图求值期间安全调用）。
    /// 未登记的未知标签返回通用「待识别」；登记后返回稳定编号。
    func resolve(remoteLabel: String?) -> Resolution {
        guard let remoteLabel, !remoteLabel.isEmpty else {
            return .unknown(displayName: "识别中")
        }
        if let participantId = participantByAlias[remoteLabel] {
            return .known(participantId: participantId)
        }
        if let participantId = manualLabelAssignments[remoteLabel] {
            return .known(participantId: participantId)
        }
        if let number = unknownLabelNumbers[remoteLabel] {
            return .unknown(displayName: "人物 \(number)（待识别）")
        }
        return .unknown(displayName: "待识别")
    }

    /// 显式登记未知标签并分配编号（仅允许在模型层处理云端结果时调用，
    /// 不得在视图求值/布局期间调用）。
    mutating func register(remoteLabel: String?) {
        guard let remoteLabel, !remoteLabel.isEmpty,
              participantByAlias[remoteLabel] == nil,
              unknownLabelNumbers[remoteLabel] == nil else {
            return
        }
        unknownLabelNumbers[remoteLabel] = unknownLabelNumbers.count + 1
    }

    /// 手工指认一个云端标签属于某参会人（09 号计划需求 2）。
    /// generic label 由调用方按 chunk 加作用域，手工指认不会误传到后续独立请求。
    /// 代号已能匹配的标签不需要也不允许指认（以云端代号为准）。
    mutating func assign(remoteLabel: String, to participantId: UUID) {
        guard participantByAlias[remoteLabel] == nil else { return }
        manualLabelAssignments[remoteLabel] = participantId
    }

    var registeredUnknownLabels: Set<String> { Set(unknownLabelNumbers.keys) }

    /// 当前全部手工指认（重建 mapper 时回灌用）
    var manualAssignments: [String: UUID] { manualLabelAssignments }

    /// 回灌手工指认（参会人列表变化后重建 mapper 时调用；
    /// 已能按代号匹配的标签跳过，指向已不存在参会人的条目由调用方过滤）
    mutating func restoreManualAssignments(_ assignments: [String: UUID]) {
        for (label, participantId) in assignments where participantByAlias[label] == nil {
            manualLabelAssignments[label] = participantId
        }
    }

    /// 当前已分配的未知标签数量
    var unknownCount: Int { unknownLabelNumbers.count }

}
