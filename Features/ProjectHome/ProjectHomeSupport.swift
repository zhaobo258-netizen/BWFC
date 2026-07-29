import Foundation
import UniformTypeIdentifiers

/// 首页列表的纯逻辑（可单测）：排序与一行摘要。
enum ProjectHomeSupport {
    static let recordingScenarioOrder: [ProjectScenario] = [
        .clientVisit,
        .internalMeeting,
        .journalistInterview,
        .classLearning,
        .freeform
    ]

    static func makeRecordingProject(
        at date: Date,
        scenario: ProjectScenario?
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
            lastActivityAt: date
        )
    }

    /// 最近项目按最近活动时间倒序
    static func sortedForDisplay(_ projects: [Project]) -> [Project] {
        projects.sorted { $0.lastActivityAt > $1.lastActivityAt }
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
        if project.sourceType != .liveRecording {
            // 留档的原始导入文件也在项目目录里，一起没了；用户自己选的那份原件不受影响。
            lines.append("· 导入时留档的原始文件副本（你自己磁盘上的原件不受影响）")
        }
        return """
        将永久删除「\(project.title)」的以下全部内容，且不可恢复：
        \(lines.joined(separator: "\n"))

        已导出到应用外的文件与已同步到 Obsidian 的内容不受影响。
        """
    }
}
