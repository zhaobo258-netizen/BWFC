import Foundation
import Testing
@testable import BangWoFenXi

/// 笔记控制器测试（阶段 B，03 §4.2：输入后 1 秒内进入本地安全存储、
/// 异常退出后可恢复、保存失败如实可见、AI 重分析不覆盖用户笔记）。
/// 每个用例独立临时目录（套件内并行执行，共享目录会互相覆盖 projects.json）。
@Suite("笔记自动保存")
@MainActor
final class NoteControllerTests {
    let tempRoot: URL

    init() {
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// 每个用例一个独立临时目录 + 一个已落库的项目
    private func makeStoreAndProject(_ name: String) throws -> (store: JSONProjectStore, project: Project, directory: URL) {
        let directory = tempRoot.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try JSONProjectStore(directory: directory)
        let project = Project(title: "笔记项目", sourceType: .liveRecording, status: .recording)
        try store.saveProjects([project])
        return (store, project, directory)
    }

    /// 轮询等待条件达成（异步防抖保存需要；上限后由断言如实判定）。
    /// 默认 10 秒上限：全量并行高负载时主 Actor 上的 50ms 防抖任务也可能被推迟数秒。
    private func waitUntil(_ condition: () -> Bool, timeoutMs: Int = 10_000) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("防抖后自动保存到 Project.note")
    func autosaveAfterDebounce() async throws {
        let (store, project, directory) = try makeStoreAndProject("debounce")
        let controller = NoteController(project: project, persist: { try store.saveProjects([$0]) },
                                        debounce: .milliseconds(50))

        controller.update(markdown: "# 要点\n- 第一条")
        await waitUntil { controller.lastSavedAt != nil }

        let reread = try JSONProjectStore(directory: directory)
        let saved = try #require(reread.loadProjects().first)
        #expect(saved.note.markdown == "# 要点\n- 第一条")
        #expect(controller.saveError == nil)
    }

    @Test("快速连续编辑合并为少量落盘")
    func rapidEditsCoalesce() async throws {
        let (store, project, _) = try makeStoreAndProject("coalesce")
        var saveCount = 0
        let controller = NoteController(
            project: project,
            persist: { project in saveCount += 1; try store.saveProjects([project]) },
            debounce: .milliseconds(80)
        )

        for index in 0..<10 {
            controller.update(markdown: "第 \(index) 版")
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.saveNow()

        #expect(saveCount <= 2, "10 次快速编辑应合并为少量落盘，实际 \(saveCount) 次")
        #expect(project.note.markdown == "第 9 版")
    }

    @Test("保存失败：错误如实可见，内容保留，恢复后重试成功")
    func saveFailureVisibleAndRecoverable() async throws {
        let (store, project, _) = try makeStoreAndProject("failure")
        var shouldFail = true
        let controller = NoteController(
            project: project,
            persist: { project in
                if shouldFail { throw ProjectStoreError.directoryUnavailable }
                try store.saveProjects([project])
            },
            debounce: .milliseconds(50)
        )

        controller.update(markdown: "不能丢的内容")
        await waitUntil { controller.saveError != nil }

        // 失败如实显示，编辑区内容不丢，不落假数据
        #expect(controller.saveError != nil)
        #expect(controller.markdown == "不能丢的内容")
        let saved = try #require(store.loadProjects().first)
        #expect(saved.note.markdown == "")

        // 故障恢复后重试成功
        shouldFail = false
        #expect(controller.saveNow() == true)
        #expect(controller.saveError == nil)
        #expect(controller.lastSavedAt != nil)
        #expect(try store.loadProjects().first?.note.markdown == "不能丢的内容")
    }

    @Test("异常退出恢复：重新打开后笔记内容仍在")
    func recoveryAfterCrash() async throws {
        let (store, project, directory) = try makeStoreAndProject("recovery")
        let controller = NoteController(project: project, persist: { try store.saveProjects([$0]) },
                                        debounce: .milliseconds(50))
        controller.update(markdown: "崩溃前写下的要点")
        controller.saveNow() // 模拟退出前的落盘

        // 模拟异常退出后重启：从库里重新读项目、重建控制器
        let reloadedStore = try JSONProjectStore(directory: directory)
        let reloadedProject = try #require(reloadedStore.loadProjects().first)
        let newController = NoteController(project: reloadedProject,
                                           persist: { try reloadedStore.saveProjects([$0]) })
        #expect(newController.markdown == "崩溃前写下的要点")
    }

    @Test("saveNow 立即落盘，不等待防抖窗口")
    func saveNowFlushesImmediately() throws {
        let (store, project, _) = try makeStoreAndProject("now")
        let controller = NoteController(project: project, persist: { try store.saveProjects([$0]) },
                                        debounce: .seconds(60))
        controller.update(markdown: "立即保存")
        #expect(controller.saveNow() == true)
        #expect(try store.loadProjects().first?.note.markdown == "立即保存")
    }

    @Test("loadFromProject 不触发自动保存（打开即写库会污染 updatedAt）")
    func loadDoesNotAutosave() async throws {
        let (store, project, _) = try makeStoreAndProject("load")
        var saveCount = 0
        let controller = NoteController(
            project: project,
            persist: { project in saveCount += 1; try store.saveProjects([project]) },
            debounce: .milliseconds(50)
        )
        controller.loadFromProject()
        try await Task.sleep(for: .milliseconds(200))
        #expect(saveCount == 0)
    }

    @Test("保存失败不得导航、重试成功后才能离开（saveNow 结果 + 导航门禁）")
    func navigationBlockedUntilNoteSaved() throws {
        let (store, project, _) = try makeStoreAndProject("gate")
        var shouldFail = true
        let controller = NoteController(
            project: project,
            persist: { project in
                if shouldFail { throw ProjectStoreError.directoryUnavailable }
                try store.saveProjects([project])
            },
            debounce: .seconds(60)
        )

        controller.update(markdown: "必须落盘才能走的内容")

        // 保存失败：saveNow 返回 false，导航门禁拒绝离开
        #expect(controller.saveNow() == false)
        #expect(controller.saveError != nil)
        #expect(ProjectWorkspaceView.canNavigateHome(afterNoteSave: false) == false)

        // 重试成功：saveNow 返回 true，门禁放行
        shouldFail = false
        #expect(controller.saveNow() == true)
        #expect(ProjectWorkspaceView.canNavigateHome(afterNoteSave: true) == true)
        #expect(
            ProjectWorkspaceView.canNavigateHome(
                afterNoteSave: true,
                afterCoCreateDraftSave: false
            ) == false
        )
        #expect(try store.loadProjects().first?.note.markdown == "必须落盘才能走的内容")
    }
}
