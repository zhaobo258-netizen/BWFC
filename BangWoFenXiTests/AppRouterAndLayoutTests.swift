import Foundation
import Testing
@testable import BangWoFenXi

/// 设置返回路由与三栏联合约束测试（Codex 审计补强）。
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

/// 三栏联合约束：任何占比与拖动顺序下 left+center+right+handles == total
@Suite("三栏联合约束")
final class ThreeColumnLayoutTests {

    private func assertInvariant(total: CGFloat, left: Double, right: Double) -> ThreeColumnMetrics.Widths {
        let widths = ThreeColumnMetrics.solve(total: total, leftFraction: left, rightFraction: right)
        #expect(widths.left + widths.center + widths.right + 2 == total,
                "left+center+right+handles 必须等于可用宽度")
        return widths
    }

    @Test("1280 与 1440 默认占比：恒等式成立且满足最小宽度")
    func standardWindowsSatisfyMinimums() {
        for total: CGFloat in [1280, 1440] {
            let widths = assertInvariant(total: total, left: 0.34, right: 0.25)
            #expect(widths.left >= ThreeColumnMetrics.minLeft)
            #expect(widths.center >= ThreeColumnMetrics.minCenter)
            #expect(widths.right >= ThreeColumnMetrics.minRight)
        }
    }

    @Test("极端历史占比（双 0.95）：恒等式成立，中栏与右栏守住最小宽度")
    func extremeFractionsClampedJointly() {
        let widths = assertInvariant(total: 1280, left: 0.95, right: 0.95)
        #expect(widths.right == ThreeColumnMetrics.minRight)
        #expect(widths.center == ThreeColumnMetrics.minCenter)
        #expect(widths.left == 1280 - 2 - ThreeColumnMetrics.minCenter - ThreeColumnMetrics.minRight)
    }

    @Test("极小占比（双 0.01）：左右各守最小宽度，中栏取余量")
    func tinyFractionsUseMinimums() {
        let widths = assertInvariant(total: 1280, left: 0.01, right: 0.01)
        #expect(widths.left == ThreeColumnMetrics.minLeft)
        #expect(widths.right == ThreeColumnMetrics.minRight)
        #expect(widths.center == 1280 - 2 - ThreeColumnMetrics.minLeft - ThreeColumnMetrics.minRight)
    }

    @Test("连续拖动两条分隔线：每次求解后恒等式都成立")
    func consecutiveDragsKeepInvariant() {
        // 模拟先拖左栏到 50%，再拖右栏到 40%，再把左栏拖回 20%
        let step1 = assertInvariant(total: 1440, left: 0.50, right: 0.25)
        #expect(step1.left == 0.5 * (1440 - 2)) // 占比驱动且不受最小值钳制
        let step2 = assertInvariant(total: 1440, left: 0.50, right: 0.40)
        #expect(step2.center >= ThreeColumnMetrics.minCenter)
        let step3 = assertInvariant(total: 1440, left: 0.20, right: 0.40)
        #expect(step3.left >= ThreeColumnMetrics.minLeft)
        #expect(step3.center >= ThreeColumnMetrics.minCenter)
    }

    @Test("总宽不足三栏最小值：等比收缩且恒等式仍成立")
    func belowMinimumTotalDegradesGracefully() {
        let widths = assertInvariant(total: 800, left: 0.5, right: 0.3)
        #expect(widths.left >= 0)
        #expect(widths.center >= 0)
        #expect(widths.right >= 0)
    }

    @Test("键盘调整：步进 2% 且钳制在最小宽度")
    func keyboardAdjustmentClamped() {
        let total: CGFloat = 1280
        // 左栏增大 2%
        let widened = ThreeColumnMetrics.adjustedFraction(
            current: 0.34, delta: 0.02, total: total,
            minWidth: ThreeColumnMetrics.minLeft,
            reservedOthers: ThreeColumnMetrics.minCenter + ThreeColumnMetrics.minRight)
        #expect(abs(widened - 0.36) < 0.001)
        // 收缩到最小值后不再变小
        let floored = ThreeColumnMetrics.adjustedFraction(
            current: 0.26, delta: -0.5, total: total,
            minWidth: ThreeColumnMetrics.minLeft,
            reservedOthers: ThreeColumnMetrics.minCenter + ThreeColumnMetrics.minRight)
        #expect(abs(floored - Double(ThreeColumnMetrics.minLeft / (total - 2))) < 0.001)
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

    @Test("1182 紧凑窗口三栏满足紧凑最小宽度")
    func compactWindowKeepsThreeColumnsUsable() {
        let widths = ThreeColumnMetrics.solve(
            total: 1_182,
            minimums: .compact,
            leftFraction: 0.34,
            rightFraction: 0.25
        )
        #expect(widths.left + widths.center + widths.right + 2 == 1_182)
        #expect(widths.left >= ThreeColumnMetrics.Minimums.compact.left)
        #expect(widths.center >= ThreeColumnMetrics.Minimums.compact.center)
        #expect(widths.right >= ThreeColumnMetrics.Minimums.compact.right)
    }

    @Test("960 窄窗口双栏满足最小宽度并守住总宽")
    func narrowWindowKeepsTwoColumnsUsable() {
        let widths = TwoColumnMetrics.solve(total: 960, leftFraction: 0.34)
        #expect(widths.left + widths.center + 2 == 960)
        #expect(widths.left >= TwoColumnMetrics.minLeft)
        #expect(widths.center >= TwoColumnMetrics.minCenter)
        #expect(WorkspaceLayoutMode.narrow.usesNotesInspector)
        #expect(!WorkspaceLayoutMode.compact.usesNotesInspector)
    }
}

@Suite("项目侧栏")
@MainActor
final class ProjectSidebarTests {

    @Test("1280 最小窗口展开侧栏后，文稿、分析、笔记仍满足最小宽度")
    func minimumWindowKeepsWorkspaceUsable() {
        let workspaceWidth = 1280 - ProjectWorkspaceView.projectSidebarWidth - 1
        let widths = ThreeColumnMetrics.solve(
            total: workspaceWidth,
            leftFraction: 0.34,
            rightFraction: 0.25
        )

        #expect(widths.left >= ThreeColumnMetrics.minLeft)
        #expect(widths.center >= ThreeColumnMetrics.minCenter)
        #expect(widths.right >= ThreeColumnMetrics.minRight)
    }

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
