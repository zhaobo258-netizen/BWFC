import Foundation

/// 右栏笔记控制器（阶段 B）：Markdown 自由输入 + 防抖自动保存到 Project.note。
///
/// 可靠性合同（03 文档 §4.2）：输入后 1 秒内进入本地安全存储；
/// 保存失败如实显示（不静默丢失）；异常退出后内容可从 projectStore 恢复。
/// 用户笔记与 AI 内容分离：本控制器只写 Project.note，不触碰分析与片段。
@MainActor
@Observable
final class NoteController {
    /// 编辑器绑定文本。仅在用户编辑时触发自动保存调度；
    /// loadFromProject() 的初始化赋值不会触发（避免打开即写库）。
    private(set) var markdown: String
    /// 最近一次成功保存时间（状态条显示「已自动保存 HH:mm:ss」）
    private(set) var lastSavedAt: Date?
    /// 最近一次保存失败的真实描述（保存失败 edge case：如实显示，不掩盖）
    private(set) var saveError: String?
    /// 可观察的摘入记录，让收起笔记时的归结卡也能即时刷新。
    private(set) var insertedSummaryIDs: [UUID]

    private let project: Project
    private let persist: (Project) throws -> Void
    private let debounce: Duration
    private var autosaveTask: Task<Void, Never>?
    /// loadFromProject 期间屏蔽自动保存
    private var isLoading = false

    /// - Parameters:
    ///   - project: 目标项目（引用语义，保存时原地更新 note）
    ///   - persist: 持久化入口（生产只合并 Project.note；测试注入模拟）
    ///   - debounce: 防抖窗口，默认 0.8s（满足 1 秒内落盘合同）
    init(
        project: Project,
        persist: @escaping (Project) throws -> Void,
        debounce: Duration = .milliseconds(800)
    ) {
        self.project = project
        self.persist = persist
        self.debounce = debounce
        self.markdown = project.note.markdown
        self.insertedSummaryIDs = project.note.insertedSummaryIDs
        self.lastSavedAt = nil
    }

    /// 用户编辑入口：更新文本并调度防抖自动保存
    func update(markdown newValue: String) {
        guard !isLoading else { return }
        markdown = newValue
        scheduleAutosave()
    }

    /// 从项目重新加载（打开工作台 / 外部变更时），不触发自动保存
    func loadFromProject() {
        isLoading = true
        markdown = project.note.markdown
        insertedSummaryIDs = project.note.insertedSummaryIDs
        isLoading = false
    }

    @discardableResult
    func insertSummary(_ summary: NoteDocument.ConversationSummary) -> NoteExcerptInsertion.Result {
        var nextMarkdown = markdown
        var nextIDs = insertedSummaryIDs
        let result = NoteExcerptInsertion.insert(summary: summary, into: &nextMarkdown, insertedIDs: &nextIDs)
        guard case .inserted = result else { return result }
        insertedSummaryIDs = nextIDs
        update(markdown: nextMarkdown)
        saveNow()
        return result
    }

    /// 立即保存（视图消失、结束录音、返回首页前等时机调用）。
    /// - Returns: 保存成功为 true；失败为 false（saveError 同步更新，调用方据此决定是否允许导航）
    @discardableResult
    func saveNow() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        writeThrough()
        return saveError == nil
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.writeThrough()
        }
    }

    private func writeThrough() {
        project.note.markdown = markdown
        project.note.insertedSummaryIDs = insertedSummaryIDs
        project.note.updatedAt = Date()
        do {
            try persist(project)
            lastSavedAt = Date()
            saveError = nil
        } catch {
            // 保存失败：如实记录错误类别（不吞掉、不伪装成功）；正文与路径不进日志
            saveError = String(describing: type(of: error))
            AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent("note_save_failed", error: String(describing: type(of: error))))
        }
    }
}

/// 「摘入笔记」的纯逻辑（M2）：按稳定 ID 去重，只追加本次摘入的内容，
/// 不覆盖后续手写输入，也不创建假撤销入口。
enum NoteExcerptInsertion {
    enum Result: Equatable {
        case inserted(UUID)
        case duplicate
        case emptySummary
    }

    static func insert(
        summary: NoteDocument.ConversationSummary,
        into markdown: inout String,
        insertedIDs: inout [UUID],
        now: Date = Date()
    ) -> Result {
        let trimmed = summary.markdown.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return .emptySummary }
        guard !insertedIDs.contains(summary.id) else { return .duplicate }
        let dateText = now.formatted(date: .abbreviated, time: .shortened)
        let content = "> **AI 归结摘入**（\(dateText)，轮次 \(summary.id.uuidString.prefix(8))）\n\n\(trimmed)\n"
        // 只追加：不删除、不 trim 既有正文的任何字符
        let isEmptyNote = markdown.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        markdown += (isEmptyNote ? "" : "\n\n---\n\n") + content
        insertedIDs.append(summary.id)
        return .inserted(summary.id)
    }
}
