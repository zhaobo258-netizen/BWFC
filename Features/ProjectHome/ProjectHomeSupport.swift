import Foundation
import UniformTypeIdentifiers

/// 首页列表的纯逻辑（可单测）：排序与一行摘要。
enum ProjectHomeSupport {
    struct BusinessCategoryOption: Identifiable, Equatable {
        let name: String
        let projectCount: Int
        let lastActivityAt: Date

        var id: String { name.localizedLowercase }
    }

    struct DisplayGroup: Identifiable {
        let businessCategory: String?
        let projects: [Project]

        var id: String { businessCategory ?? "__ungrouped__" }
        var title: String { businessCategory ?? "未分组录音" }
    }

    enum RecordingMergeError: LocalizedError, Equatable {
        case notEnoughRecordings
        case containsDerivedAnalysis
        case recordingNotReady(String)
        case recordingHasNoTranscript(String)
        case spansBusinessCategories

        var errorDescription: String? {
            switch self {
            case .notEnoughRecordings:
                return "至少选择 2 段录音才能合并分析。"
            case .containsDerivedAnalysis:
                return "已生成的合并分析不能再当作原始录音合并。"
            case .recordingNotReady(let title):
                return "「\(title)」还没有处理完，暂时不能参与合并。"
            case .recordingHasNoTranscript(let title):
                return "「\(title)」还没有可用的最终文稿。"
            case .spansBusinessCategories:
                return "一次只能合并同一业务项目下的录音；请先完成归组。"
            }
        }
    }

    static let recordingScenarioOrder: [ProjectScenario] = [
        .clientVisit,
        .internalMeeting,
        .journalistInterview,
        .classLearning,
        .freeform
    ]

    static func makeRecordingProject(
        at date: Date,
        scenario: ProjectScenario?,
        speakers: [Speaker] = []
    ) -> Project {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return Project(
            title: "未命名录音 · \(formatter.string(from: date))",
            sourceType: .liveRecording,
            scenario: scenario,
            scenarioWasUserSelected: scenario != nil,
            status: .creating,
            createdAt: date,
            lastActivityAt: date,
            speakers: speakers
        )
    }

    /// 最近项目按最近活动时间倒序
    static func sortedForDisplay(_ projects: [Project]) -> [Project] {
        projects.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// 首页先按业务项目归类，组内仍按最近活动时间排序。
    /// 已分组项目按各组最近活动时间排在前面，未分组收在最后。
    static func groupedForDisplay(_ projects: [Project]) -> [DisplayGroup] {
        let grouped = Dictionary(grouping: projects) {
            normalizedBusinessCategory($0.businessCategory)
        }
        let named = grouped.compactMap { key, values -> DisplayGroup? in
            guard let key else { return nil }
            return DisplayGroup(
                businessCategory: key,
                projects: sortedForDisplay(values)
            )
        }
        .sorted {
            let left = $0.projects.map(\.lastActivityAt).max() ?? .distantPast
            let right = $1.projects.map(\.lastActivityAt).max() ?? .distantPast
            return left == right ? $0.title < $1.title : left > right
        }
        guard let ungrouped = grouped[nil], !ungrouped.isEmpty else {
            return named
        }
        return named + [DisplayGroup(
            businessCategory: nil,
            projects: sortedForDisplay(ungrouped)
        )]
    }

    static func normalizedBusinessCategory(_ raw: String?) -> String? {
        let trimmed = raw?
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    static func businessCategoryOptions(
        from projects: [Project],
        search: String = ""
    ) -> [BusinessCategoryOption] {
        let grouped = Dictionary(grouping: projects.compactMap { project in
            normalizedBusinessCategory(project.businessCategory).map {
                (name: $0, project: project)
            }
        }) { $0.name.localizedLowercase }
        let query = search.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return grouped.compactMap { _, values in
            guard let displayName = values
                .max(by: { $0.project.lastActivityAt < $1.project.lastActivityAt })?
                .name else { return nil }
            guard query.isEmpty
                    || displayName.localizedStandardContains(query) else {
                return nil
            }
            return BusinessCategoryOption(
                name: displayName,
                projectCount: values.count,
                lastActivityAt: values.map(\.project.lastActivityAt).max()
                    ?? .distantPast
            )
        }
        .sorted {
            $0.lastActivityAt == $1.lastActivityAt
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.lastActivityAt > $1.lastActivityAt
        }
    }

    static func canonicalBusinessCategory(
        _ raw: String?,
        projects: [Project]
    ) -> String? {
        guard let normalized = normalizedBusinessCategory(raw) else {
            return nil
        }
        return businessCategoryOptions(from: projects).first {
            $0.name.compare(
                normalized,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }?.name ?? normalized
    }

    static func isEligibleForMerge(_ project: Project) -> Bool {
        guard !project.sourceType.isCombinedAnalysis,
              project.status == .ready || project.status == .readyWithWarnings else {
            return false
        }
        return project.segments.contains {
            ($0.state == .final || $0.state == .edited)
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 用原始录音的最终/人工修订文稿生成一个自包含的派生项目。
    /// 原始项目不被修改；每条片段用 sourceAssetId 保留来源录音。
    static func makeCombinedAnalysisProject(
        from candidates: [Project],
        at date: Date = Date()
    ) throws -> Project {
        let unique = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        let ordered = unique.sorted {
            recordingDate($0) == recordingDate($1)
                ? $0.id.uuidString < $1.id.uuidString
                : recordingDate($0) < recordingDate($1)
        }
        guard ordered.count >= 2 else { throw RecordingMergeError.notEnoughRecordings }
        guard ordered.allSatisfy({ !$0.sourceType.isCombinedAnalysis }) else {
            throw RecordingMergeError.containsDerivedAnalysis
        }
        for project in ordered {
            guard project.status == .ready || project.status == .readyWithWarnings else {
                throw RecordingMergeError.recordingNotReady(project.title)
            }
            guard isEligibleForMerge(project) else {
                throw RecordingMergeError.recordingHasNoTranscript(project.title)
            }
        }

        let categories = Set(ordered.compactMap {
            normalizedBusinessCategory($0.businessCategory)
        })
        let hasUngrouped = ordered.contains {
            normalizedBusinessCategory($0.businessCategory) == nil
        }
        guard categories.count <= 1,
              !(hasUngrouped && !categories.isEmpty) else {
            throw RecordingMergeError.spansBusinessCategories
        }
        let businessCategory = categories.first

        var references: [SourceRecordingReference] = []
        var segments: [TranscriptSegment] = []
        var speakerByID: [UUID: Speaker] = [:]
        var canonicalIDByProfile: [UUID: UUID] = [:]
        var timelineOffset: Int64 = 0
        for source in ordered {
            let accepted = source.segments.filter {
                ($0.state == .final || $0.state == .edited)
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let sourceDuration = max(
                source.durationMs,
                accepted.map(\.endMs).max() ?? 0
            )
            references.append(SourceRecordingReference(
                projectID: source.id,
                title: source.title,
                recordedAt: recordingDate(source),
                timelineOffsetMs: timelineOffset,
                durationMs: sourceDuration
            ))
            var canonicalIDBySpeaker: [UUID: UUID] = [:]
            for speaker in source.speakers {
                if let profileID = speaker.voiceProfileId,
                   let canonicalID = canonicalIDByProfile[profileID] {
                    canonicalIDBySpeaker[speaker.id] = canonicalID
                } else {
                    canonicalIDBySpeaker[speaker.id] = speaker.id
                    if speakerByID[speaker.id] == nil {
                        speakerByID[speaker.id] = copy(speaker)
                    }
                    if let profileID = speaker.voiceProfileId {
                        canonicalIDByProfile[profileID] = speaker.id
                    }
                }
            }
            for segment in accepted {
                let combinedSegment = copy(
                    segment,
                    sourceProjectID: source.id,
                    timelineOffsetMs: timelineOffset
                )
                if let speakerID = segment.participantId {
                    combinedSegment.participantId = canonicalIDBySpeaker[speakerID] ?? speakerID
                }
                segments.append(combinedSegment)
            }
            timelineOffset += sourceDuration + 1_000
        }
        let speakers = speakerByID.values
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for (index, speaker) in speakers.enumerated() {
            speaker.cloudAlias = String(format: "p_%02d", index + 1)
        }

        let commonScenario = Set(ordered.compactMap { $0.scenario?.rawValue }).count == 1
            ? ordered.compactMap(\.scenario).first
            : nil
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let titlePrefix = businessCategory ?? "跨录音"
        return Project(
            title: "\(titlePrefix) · 合并分析 · \(formatter.string(from: date))",
            businessCategory: businessCategory,
            sourceType: .combinedRecordings,
            sourceRecordings: references,
            scenario: commonScenario,
            scenarioWasUserSelected: false,
            status: .ready,
            createdAt: date,
            startedAt: references.first?.recordedAt,
            endedAt: references.last.map { $0.recordedAt.addingTimeInterval(Double($0.durationMs) / 1_000) },
            lastActivityAt: date,
            durationMs: max(0, timelineOffset - 1_000),
            speakers: speakers,
            segments: segments.sorted {
                $0.startMs == $1.startMs
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.startMs < $1.startMs
            }
        )
    }

    static func sourceRecording(
        for segment: TranscriptSegment,
        in project: Project
    ) -> SourceRecordingReference? {
        guard let sourceID = segment.sourceAssetId else { return nil }
        return project.sourceRecordings.first { $0.projectID == sourceID }
    }

    static func sourceRelativeStartMs(
        for segment: TranscriptSegment,
        in project: Project
    ) -> Int64 {
        guard let source = sourceRecording(for: segment, in: project) else {
            return segment.startMs
        }
        return max(0, segment.startMs - source.timelineOffsetMs)
    }

    private static func recordingDate(_ project: Project) -> Date {
        project.startedAt ?? project.createdAt
    }

    private static func copy(
        _ segment: TranscriptSegment,
        sourceProjectID: UUID,
        timelineOffsetMs: Int64
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: segment.id,
            startMs: timelineOffsetMs + segment.startMs,
            endMs: timelineOffsetMs + segment.endMs,
            text: segment.text,
            participantId: segment.participantId,
            remoteSpeakerLabel: segment.remoteSpeakerLabel,
            source: segment.source,
            state: segment.state,
            isStarred: segment.isStarred,
            createdAt: segment.createdAt,
            updatedAt: segment.updatedAt,
            speakerConfidence: segment.speakerConfidence,
            languageCode: segment.languageCode,
            sourceAssetId: sourceProjectID,
            textWasUserEdited: segment.textWasUserEdited,
            speakerWasUserConfirmed: segment.speakerWasUserConfirmed
        )
    }

    private static func copy(_ speaker: Speaker) -> Speaker {
        Speaker(
            id: speaker.id,
            cloudAlias: speaker.cloudAlias,
            displayName: speaker.displayName,
            role: speaker.role,
            colorToken: speaker.colorToken,
            isUserConfirmed: speaker.isUserConfirmed,
            legacySide: speaker.legacySide,
            legacyVoiceReferencePath: speaker.legacyVoiceReferencePath,
            legacyVoiceReferenceDurationMs: speaker.legacyVoiceReferenceDurationMs,
            voiceSamplePath: speaker.voiceSamplePath,
            voiceSampleDurationMs: speaker.voiceSampleDurationMs,
            voiceProfileId: speaker.voiceProfileId,
            iflytekFeatureID: speaker.iflytekFeatureID,
            backgroundContext: speaker.backgroundContext,
            communicationProfile: speaker.communicationProfile,
            isCurrentUser: speaker.isCurrentUser
        )
    }

    /// 一行摘要：优先最新分析快照的当前议题，其次最近一条已确认片段正文；
    /// 都没有时返回「暂无内容」。摘要最长 60 字。
    static func summary(for project: Project) -> String {
        if let topic = project.legacySnapshots
            .max(by: { $0.version < $1.version })?.currentTopicTitle,
           !topic.isEmpty {
            return String(topic.prefix(60))
        }
        if let text = project.segments
            .filter({ $0.state != .provisional })
            .last?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return String(text.prefix(60))
        }
        return "暂无内容"
    }

    /// 首页列表要显示的状态口径。
    /// 磁盘上的 `.recording` 有两种来路：此刻真在录，或上次异常退出留下的残留。
    /// 只有运行时登记能区分，所以未登记的可恢复状态一律显示成「未正常结束」。
    enum DisplayStatus: Equatable {
        /// 正常状态，按项目自身状态显示
        case normal(ProjectStatus)
        /// 本次运行期间真正活跃的录音/暂停
        case liveRecording(ProjectStatus)
        /// 上次未正常结束的残留状态
        case abnormalLeftover(ProjectStatus)

        var text: String {
            switch self {
            case .normal(let status), .liveRecording(let status):
                return status.displayName
            case .abnormalLeftover:
                return "未正常结束"
            }
        }
    }

    static func displayStatus(
        for project: Project,
        liveProjectIDs: Set<UUID>
    ) -> DisplayStatus {
        if project.status == .processing, project.hasFailedProcessingJobs {
            return .normal(project.status)
        }
        guard project.status.isAbnormalIfAppRelaunched else {
            return .normal(project.status)
        }
        return liveProjectIDs.contains(project.id)
            ? .liveRecording(project.status)
            : .abnormalLeftover(project.status)
    }

    /// 需要提示「上次未正常结束」的项目（排除本次运行中真正活跃的）
    static func leftoverProjects(
        in projects: [Project],
        liveProjectIDs: Set<UUID>
    ) -> [Project] {
        projects.filter {
            displayStatus(for: $0, liveProjectIDs: liveProjectIDs) == .abnormalLeftover($0.status)
        }
    }

    /// 来源类型的中文标签
    static func sourceLabel(for sourceType: ProjectSourceType) -> String {
        switch sourceType {
        case .liveRecording: return "现场录音"
        case .importedAudio: return "导入音频"
        case .importedVideo: return "导入视频"
        case .combinedRecordings: return "跨录音分析"
        }
    }

    // MARK: - 拖放导入校验

    /// 与 NSOpenPanel 的 allowedContentTypes 保持一致：只接受音频与影片。
    static let importContentTypes: [UTType] = [.audio, .movie]

    /// 拖入的文件是否可以接受。目录、快捷方式与非音视频类型一律拒绝，
    /// 让 `.onDrop` 返回 false，系统直接给出「不接受」光标而不是先接受再弹错。
    static func acceptsDroppedFile(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { return false }
        guard let type = values?.contentType else { return false }
        return acceptsContentType(type)
    }

    /// 只按 UTType 判定，便于单测覆盖真实文件之外的类型组合。
    static func acceptsContentType(_ type: UTType) -> Bool {
        importContentTypes.contains { type.conforms(to: $0) }
    }

    /// 拖放落点上的同步预判：NSItemProvider 通常同时登记具体文件类型与 public.file-url，
    /// 据此可以在 `.onDrop` 返回前就拒绝文件夹和不支持的类型。
    /// 只登记了 file-url、拿不到具体类型时放行，由落地后的 `acceptsDroppedFile` 兜底。
    static func acceptsDrop(registeredContentTypes: [UTType]) -> Bool {
        let concrete = registeredContentTypes.filter { $0 != .fileURL && $0 != .url }
        guard !concrete.isEmpty else { return true }
        return concrete.contains { acceptsContentType($0) }
    }

    /// 拖入不支持内容时的提示文案
    static let unsupportedDropMessage = "只支持音频或视频文件（m4a / mp3 / wav / mp4），文件夹和其他类型无法导入。"

    // MARK: - 重命名与在 Finder 中显示

    /// 重命名的标题清洗：去首尾空白，空标题视为无效（返回 nil，调用方保持原标题）。
    /// 与工作台 TitleField 同一口径，避免两处出现不同的「什么算合法标题」。
    static func normalizedTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 「在 Finder 中显示」要选中的目录：项目目录存在就选它，否则退回根目录；
    /// 根目录也不存在（尚未落盘任何数据）时返回 nil，由调用方提示而不是静默无反应。
    static func finderRevealTarget(
        projectDirectory: URL,
        baseDirectory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        if fileExists(projectDirectory) { return projectDirectory }
        if fileExists(baseDirectory) { return baseDirectory }
        return nil
    }

    /// 本机目录尚未创建时的提示文案
    static let missingStorageDirectoryMessage = "本机保存目录尚未创建。"

    // MARK: - 删除项目

    /// 为什么不「移到废纸篓」：App Sandbox 下 `trashItem` 落到容器自己的
    /// `.Trash` 里，Finder 看不见、用户捞不回来、磁盘也不释放——那是假的安全网。
    /// 所以照 V1 整场删除的口径做永久删除，安全感由「逐项列明 + 二次确认 +
    /// 状态守卫」提供，而不是靠一个用户永远打不开的回收站。
    enum ProjectDeletionBlock: Equatable {
        /// 此刻真正在录音/暂停（本次运行登记过 recorder）
        case liveRecording
        /// 导入流水线正在处理这个项目
        case importProcessing

        var message: String {
            switch self {
            case .liveRecording:
                return "这个项目正在录音，先结束录音再删除。"
            case .importProcessing:
                return "这个项目的导入处理还在进行，先等它结束或失败再删除。"
            }
        }
    }

    /// 删除前的拒绝理由；nil 表示可以删。
    /// 崩溃残留的 recording/paused/processing **不拦** —— 它们本来就是用户最想清掉的垃圾，
    /// 拦住等于让磁盘上的坏项目永远删不掉。只拦此刻真有进程在写这些文件的情况，
    /// 否则会一边删目录、一边有任务往里写，得到半删状态。
    static func deletionBlock(
        for project: Project,
        liveProjectIDs: Set<UUID>,
        importProcessingProjectID: UUID?
    ) -> ProjectDeletionBlock? {
        if liveProjectIDs.contains(project.id) { return .liveRecording }
        if importProcessingProjectID == project.id { return .importProcessing }
        return nil
    }

    /// 删除确认文案：逐项列明将消失的内容（与 V1 `deletionSummary` 同一口径）。
    static func deletionSummary(for project: Project) -> String {
        let sampleCount = project.speakers.filter {
            $0.voiceSamplePath != nil || $0.legacyVoiceReferencePath != nil
        }.count
        var lines = [
            "· 本地完整录音与提取音轨",
            "· \(sampleCount) 份声音样本、全部临时分片与队列状态",
            "· \(project.segments.count) 条转写、\(project.analysisSnapshots.count) 版分析与"
                + "\(project.finalReportSnapshots.count) 版完整总结",
            "· 项目笔记与 \(project.aiChatMessages.count) 条共创记录"
        ]
        if project.sourceType.isImportedMedia {
            // 留档的原始导入文件也在项目目录里，一起没了；用户自己选的那份原件不受影响。
            lines.append("· 导入时留档的原始文件副本（你自己磁盘上的原件不受影响）")
        }
        if project.sourceType.isCombinedAnalysis {
            lines.append("· 涉及 \(project.sourceRecordings.count) 段录音的汇总文稿（原始录音不受影响）")
        }
        return """
        将永久删除「\(project.title)」的以下全部内容，且不可恢复：
        \(lines.joined(separator: "\n"))

        已导出到应用外的文件与已同步到 Obsidian 的内容不受影响。
        """
    }
}
