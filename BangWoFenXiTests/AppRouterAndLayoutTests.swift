import Foundation
import Testing
@testable import BangWoFenXi

/// 设置返回路由与工作台自适应布局测试。
@Suite("设置返回路由")
@MainActor
final class AppRouterTests {

    @Test("从首页进入设置：返回首页")
    func homeToSettingsAndBack() {
        let router = AppRouter()
        router.showProjectHome()
        router.showSettings()
        #expect(router.isSettingsPresented)
        #expect(router.route == .projectHome)
        router.closeSettings()
        #expect(!router.isSettingsPresented)
        #expect(router.route == .projectHome)
    }

    @Test("从工作台进入设置：返回原工作台（含 autoStart 参数）")
    func workspaceToSettingsAndBack() {
        let router = AppRouter()
        let id = UUID()
        router.showProjectWorkspace(id, autoStart: true)
        router.showSettings()
        #expect(router.isSettingsPresented)
        router.closeSettings()
        #expect(!router.isSettingsPresented)
        #expect(router.route == .projectWorkspace(id, autoStart: true))
    }

    @Test("从旧页面进入设置：返回旧页面")
    func legacyPagesToSettingsAndBack() {
        let router = AppRouter()
        let id = UUID()

        router.showMeetingList()
        router.showSettings()
        router.closeSettings()
        #expect(router.route == .meetingList)

        router.showLiveMeeting(id)
        router.showSettings()
        router.closeSettings()
        #expect(router.route == .liveMeeting(id))

        router.showMeetingReview(id)
        router.showSettings()
        router.closeSettings()
        #expect(router.route == .meetingReview(id))
    }

    @Test("设置页内重复进入设置：不覆盖原始来源路由")
    func reenteringSettingsKeepsOriginalReturnRoute() {
        let router = AppRouter()
        router.showProjectHome()
        router.showSettings()
        router.showSettings() // 重复进入
        #expect(router.isSettingsPresented)
        router.closeSettings()
        #expect(!router.isSettingsPresented)
        #expect(router.route == .projectHome)
        // 返回后再次关闭：缺省回首页且不崩溃
        router.closeSettings()
        #expect(router.route == .projectHome)
    }

    @Test("完整总结通知可定向打开项目且请求只消费一次")
    func finalReportDeepLink() {
        let router = AppRouter()
        let id = UUID()
        router.showProjectFinalReport(id)
        #expect(router.route == .projectWorkspace(id, autoStart: false))
        #expect(router.consumeFinalReportRequest(for: id))
        #expect(!router.consumeFinalReportRequest(for: id))
    }

    @Test("历史人物库是独立一级路由")
    @MainActor
    func peopleLibraryRoute() {
        let router = AppRouter()
        router.showPeopleLibrary()
        #expect(router.route == .peopleLibrary)
        router.showProjectHome()
        #expect(router.route == .projectHome)
    }
}

@Suite("工作台自适应布局")
final class WorkspaceResponsiveLayoutTests {

    @Test("窗口宽度在 960/1080/1182/1280/1440 选择固定布局模式")
    func fixedBreakpoints() {
        #expect(WorkspaceLayoutMode.resolve(totalWidth: 960) == .narrow)
        #expect(WorkspaceLayoutMode.resolve(totalWidth: 1_079) == .narrow)
        #expect(WorkspaceLayoutMode.resolve(totalWidth: 1_080) == .compact)
        #expect(WorkspaceLayoutMode.resolve(totalWidth: 1_182) == .compact)
        #expect(WorkspaceLayoutMode.resolve(totalWidth: 1_279) == .compact)
        #expect(WorkspaceLayoutMode.resolve(totalWidth: 1_280) == .wide)
        #expect(WorkspaceLayoutMode.resolve(totalWidth: 1_440) == .wide)
    }

    @Test("自动收起只影响紧凑与窄屏，不改写宽屏偏好语义")
    func persistentSidebarOnlyOnWideScreens() {
        #expect(!WorkspaceLayoutMode.narrow.showsPersistentSidebar(preference: true))
        #expect(!WorkspaceLayoutMode.compact.showsPersistentSidebar(preference: true))
        #expect(WorkspaceLayoutMode.wide.showsPersistentSidebar(preference: true))
        #expect(!WorkspaceLayoutMode.wide.showsPersistentSidebar(preference: false))
    }
}

@Suite("存储路径显示")
@MainActor
final class StoragePathDisplayTests {

    @Test("本机保存路径用波浪号隐藏用户目录，外部路径保持原样")
    func storagePathDisplay() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let appData = URL(
            fileURLWithPath: "/Users/example/Library/Application Support/BangWoFenXi",
            isDirectory: true
        )
        let external = URL(fileURLWithPath: "/Volumes/Archive/BangWoFenXi", isDirectory: true)

        #expect(ProjectWorkspaceView.displayStoragePath(
            baseDirectory: appData,
            homeDirectory: home
        ) == "~/Library/Application Support/BangWoFenXi")
        #expect(ProjectWorkspaceView.displayStoragePath(
            baseDirectory: external,
            homeDirectory: home
        ) == "/Volumes/Archive/BangWoFenXi")
    }
}
