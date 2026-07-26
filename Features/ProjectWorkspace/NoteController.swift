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
        isLoading = false
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
