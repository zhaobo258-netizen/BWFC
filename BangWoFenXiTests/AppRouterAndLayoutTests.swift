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
        #expect(router.route == .settings)
        router.closeSettings()
        #expect(router.route == .projectHome)
    }

    @Test("从工作台进入设置：返回原工作台（含 autoStart 参数）")
    func workspaceToSettingsAndBack() {
        let router = AppRouter()
        let id = UUID()
        router.showProjectWorkspace(id, autoStart: true)
        router.showSettings()
        router.closeSettings()
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
        router.closeSettings()
        #expect(router.route == .projectHome)
        // 返回后再次关闭：缺省回首页且不崩溃
        router.closeSettings()
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
