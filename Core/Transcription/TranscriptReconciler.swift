import Foundation

/// 转写文本工具：规范化与相似度（纯逻辑，可单测）。
/// 合并去重时以「规范化文本」比较，忽略大小写、空白与中英文标点差异。
enum TranscriptText {
    /// 规范化：去空白、去标点、小写化
    static func normalized(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    /// 字符二元组（bigram）Jaccard 相似度（0…1）。
    /// 极短文本（不足 2 个字符）退化为包含判断。
    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalized(a)
        let nb = normalized(b)
        guard !na.isEmpty, !nb.isEmpty else { return na == nb ? 1 : 0 }
        if na == nb { return 1 }
        if na.count < 3 || nb.count < 3 {
            // 短文本：互相包含视为相似
            return (na.contains(nb) || nb.contains(na)) ? 1 : 0
        }
        let bigramsA = bigrams(of: na)
        let bigramsB = bigrams(of: nb)
        let intersection = bigramsA.intersection(bigramsB).count
        let union = bigramsA.union(bigramsB).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private static func bigrams(of text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count >= 2 else { return [text] }
        var result = Set<String>()
        for index in 0..<(chars.count - 1) {
            result.insert(String(chars[index...index + 1]))
        }
        return result
    }
}

/// 本地转写合并器（纯逻辑，实施计划 7.4 的本地阶段）：
/// 把「临时 / 最终」结果流维护成按时间排序、无重复的片段序列。
///
/// 去重原则（与阶段 3 云端合并同一套规则）：
/// - 时间范围为主：重叠率 ≥ 50% 才可能是重复；
/// - 规范化文本相似度为辅：重叠且相似度 ≥ 0.8 判重；
/// - 完全相同的文本出现在 ±2 秒抖动窗口内也判重（引擎重发）。
/// 重叠但文本明显不同的内容必须保留（宁可保留也不丢内容）。
/// 注：仅在 MainActor 使用（片段为引用类型模型），不做 Sendable 声明。
struct TranscriptReconciler {
    /// 判重的最小时间重叠率
    static let duplicateOverlapRatio: Double = 0.5
    /// 判重的最小文本相似度
    static let duplicateTextSimilarity: Double = 0.8
    /// 同文本判重的时间抖动窗口（毫秒）
    static let sameTextJitterWindowMs: Int64 = 2_000

    /// 已确认片段（按 startMs 升序）
    private(set) var finalized: [TranscriptSegment] = []
    /// 当前临时片段（最多一个，随新临时结果更新；被最终结果取代）
    private(set) var provisional: TranscriptSegment?

    init() {}

    /// 全部片段（最终 + 尾部临时），供 UI 展示
    var allSegments: [TranscriptSegment] {
        var result = finalized
        if let provisional {
            result.append(provisional)
        }
        return result.sorted { $0.startMs < $1.startMs }
    }

    /// 更新临时片段：同一个片段就地替换文字（不新增、不拼接，避免重复句）
    @discardableResult
    mutating func upsertProvisional(startMs: Int64, endMs: Int64, text: String) -> TranscriptSegment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let current = provisional {
            current.startMs = startMs
            current.endMs = endMs
            current.text = trimmed
            current.updatedAt = Date()
            return current
        }
        let segment = TranscriptSegment(
            startMs: startMs,
            endMs: endMs,
            text: trimmed,
            source: .local,
            state: .provisional
        )
        provisional = segment
        return segment
    }

    /// 应用最终结果：去重后按时间插入；同时清掉被覆盖的临时片段。
    /// - Returns: 处理结果（插入 / 判重 / 空文本丢弃）
    @discardableResult
    mutating func applyFinal(
        startMs: Int64,
        endMs: Int64,
        text: String,
        participantId: UUID? = nil
    ) -> ApplyOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .discardedEmpty }

        // 1) 与既有最终片段判重
        if let existing = findDuplicate(newStart: startMs, newEnd: endMs, newText: trimmed) {
            return .duplicate(existing: existing)
        }

        // 2) 清除被该最终结果覆盖的临时片段
        clearProvisionalCoveredBy(startMs: startMs, endMs: endMs)

        // 3) 按时间序插入
        let segment = TranscriptSegment(
            startMs: startMs,
            endMs: endMs,
            text: trimmed,
            participantId: participantId,
            source: .local,
            state: .final
        )
        let insertIndex = finalized.firstIndex { $0.startMs > startMs } ?? finalized.count
        finalized.insert(segment, at: insertIndex)
        return .inserted(segment)
    }

    /// 找出与新结果重复的既有片段；无重复返回 nil
    private func findDuplicate(
        newStart: Int64, newEnd: Int64, newText: String
    ) -> TranscriptSegment? {
        finalized.first { isDuplicate(newStart: newStart, newEnd: newEnd, newText: newText, of: $0) }
    }

    /// 判定新结果与既有片段是否重复
    private func isDuplicate(
        newStart: Int64, newEnd: Int64, newText: String,
        of existing: TranscriptSegment
    ) -> Bool {
        let newNormalized = TranscriptText.normalized(newText)
        let existingNormalized = TranscriptText.normalized(existing.text)

        // 规则 1：完全相同文本出现在 ±2 秒抖动窗口内
        if newNormalized == existingNormalized {
            let startDelta = abs(newStart - existing.startMs)
            if startDelta <= Self.sameTextJitterWindowMs {
                return true
            }
        }

        // 规则 2：时间重叠率 ≥ 50% 且文本相似度 ≥ 0.8
        let overlap = overlapMs(
            startA: newStart, endA: newEnd,
            startB: existing.startMs, endB: existing.endMs
        )
        guard overlap > 0 else { return false }
        let shorterDuration = max(1, min(newEnd - newStart, existing.endMs - existing.startMs))
        let overlapRatio = Double(overlap) / Double(shorterDuration)
        guard overlapRatio >= Self.duplicateOverlapRatio else { return false }
        return TranscriptText.similarity(newText, existing.text) >= Self.duplicateTextSimilarity
    }

    /// 清空（会话结束/重新开始）
    mutating func reset() {
        finalized = []
        provisional = nil
    }

    /// 丢弃尾部临时片段（会话停止时调用）
    mutating func dropProvisional() {
        provisional = nil
    }

    // MARK: - 阶段 3：云端确认片段合并

    /// 应用云端确认片段（实施计划 7.4 合并规则）：
    /// - 与「人工已修订」片段重叠 → 跳过（人工结果优先，不被后续云端结果覆盖）；
    /// - 与本地最终片段重复 → 用云端内容就地更新（ID 稳定），来源转为 cloud；
    /// - 与云端片段重复 → 判重跳过；
    /// - 覆盖临时片段 → 清除临时，插入新片段（source: cloud, state: final）。
    @discardableResult
    mutating func applyCloudFinal(
        startMs: Int64,
        endMs: Int64,
        text: String,
        participantId: UUID?,
        remoteSpeakerLabel: String?
    ) -> CloudApplyOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .discardedEmpty }

        // 1) 人工保护：与人工已修订片段重叠则跳过
        for existing in finalized where existing.state == .edited || existing.source == .manual {
            let overlap = Self.overlapMs(startA: startMs, endA: endMs,
                                         startB: existing.startMs, endB: existing.endMs)
            guard overlap > 0 else { continue }
            let shorter = max(1, min(endMs - startMs, existing.endMs - existing.startMs))
            if Double(overlap) / Double(shorter) >= Self.duplicateOverlapRatio {
                return .skippedManual(existing)
            }
        }

        // 2) 判重
        if let existing = findDuplicate(newStart: startMs, newEnd: endMs, newText: trimmed) {
            switch (existing.source, existing.state) {
            case (.manual, _), (_, .edited):
                return .skippedManual(existing)
            case (.cloud, _):
                return .duplicate(existing: existing)
            default:
                // 本地片段被云端确认：就地更新，ID 稳定
                existing.text = trimmed
                existing.participantId = participantId ?? existing.participantId
                existing.remoteSpeakerLabel = remoteSpeakerLabel ?? existing.remoteSpeakerLabel
                existing.source = .cloud
                existing.state = .final
                existing.updatedAt = Date()
                return .updated(existing)
            }
        }

        // 3) 清除被覆盖的临时片段
        clearProvisionalCoveredBy(startMs: startMs, endMs: endMs)

        // 4) 按时间序插入
        let segment = TranscriptSegment(
            startMs: startMs,
            endMs: endMs,
            text: trimmed,
            participantId: participantId,
            remoteSpeakerLabel: remoteSpeakerLabel,
            source: .cloud,
            state: .final
        )
        let insertIndex = finalized.firstIndex { $0.startMs > startMs } ?? finalized.count
        finalized.insert(segment, at: insertIndex)
        return .inserted(segment)
    }

    /// 清除被指定时间范围覆盖的临时片段
    private mutating func clearProvisionalCoveredBy(startMs: Int64, endMs: Int64) {
        guard let current = provisional else { return }
        let overlap = Self.overlapMs(
            startA: startMs, endA: endMs,
            startB: current.startMs, endB: current.endMs
        )
        let provisionalDuration = max(1, current.endMs - current.startMs)
        let coveredByTime = Double(overlap) / Double(provisionalDuration) >= Self.duplicateOverlapRatio
        let coveredByOrder = current.startMs >= startMs
        if coveredByTime || coveredByOrder {
            provisional = nil
        }
    }

    enum ApplyOutcome {
        case inserted(TranscriptSegment)
        case duplicate(existing: TranscriptSegment)
        case discardedEmpty
    }

    enum CloudApplyOutcome {
        case inserted(TranscriptSegment)
        case updated(TranscriptSegment)
        case skippedManual(TranscriptSegment)
        case duplicate(existing: TranscriptSegment)
        case discardedEmpty
    }

    /// 两个闭区间的重叠毫秒数（0 = 不重叠）
    static func overlapMs(startA: Int64, endA: Int64, startB: Int64, endB: Int64) -> Int64 {
        max(0, min(endA, endB) - max(startA, startB))
    }

    private func overlapMs(startA: Int64, endA: Int64, startB: Int64, endB: Int64) -> Int64 {
        Self.overlapMs(startA: startA, endA: endA, startB: startB, endB: endB)
    }
}

// ApplyOutcome 的 Equatable 需要 TranscriptSegment 可比较：按 id 比较
extension TranscriptReconciler.ApplyOutcome: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.inserted(a), .inserted(b)): return a.id == b.id
        case let (.duplicate(a), .duplicate(b)): return a.id == b.id
        case (.discardedEmpty, .discardedEmpty): return true
        default: return false
        }
    }
}
