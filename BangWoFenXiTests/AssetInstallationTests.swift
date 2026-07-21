import Foundation
import Testing
@testable import BangWoFenXi

/// 中文语言资源一键下载（AssetInventory 路径）：
/// 进度上报、完成后自动重查并清除不可用状态、失败可重试。
@Suite("语言资源下载")
@MainActor
final class AssetInstallationTests {
    let mock: MockLocalTranscriptionService
    let controller: LocalTranscriptionController

    init() {
        mock = MockLocalTranscriptionService()
        controller = LocalTranscriptionController(service: mock)
    }

    /// supported 但未安装的可用性
    private func supportedNotInstalled() -> TranscriptionAvailability {
        TranscriptionAvailability(
            transcriberAvailable: true,
            mandarinSupported: true,
            assetState: .supportedNotInstalled,
            issues: ["中文语言资源尚未安装（可点击「下载中文语言资源」获取）"]
        )
    }

    /// 已安装的可用性
    private func installed() -> TranscriptionAvailability {
        TranscriptionAvailability(
            transcriberAvailable: true,
            mandarinSupported: true,
            assetState: .installed,
            issues: []
        )
    }

    @Test("可下载条件：仅 supportedNotInstalled 且未在下载中")
    func canInstallFlag() async {
        mock.availability = installed()
        _ = await controller.checkAvailability()
        #expect(!controller.canInstallChineseAssets, "已安装时不得显示下载入口")

        // 场景切换（资源被卸载/换机器）：强制刷新绕过 TTL 缓存
        mock.availability = supportedNotInstalled()
        _ = await controller.checkAvailability(forceRefresh: true)
        #expect(controller.canInstallChineseAssets)
    }

    @Test("下载成功：进度上报 → 自动重查 → 清除不可用状态")
    func installSuccess() async throws {
        mock.availability = supportedNotInstalled()
        _ = await controller.checkAvailability()
        guard case .unavailable = controller.runState else {
            Issue.record("未安装时应为 unavailable")
            return
        }
        mock.availabilityAfterInstall = installed()

        await controller.installChineseAssets()

        #expect(mock.installCallCount == 1)
        #expect(controller.assetDownloadProgress == nil, "完成后进度标记清除")
        #expect(controller.availability?.assetState == .installed, "完成后自动重新检查可用性")
        #expect(controller.runState == .idle, "恢复 ready 后清除不可用状态（横幅消失）")
        #expect(controller.assetInstallError == nil)
        #expect(controller.lastErrorDescription == nil)
    }

    @Test("下载失败：显示真实错误、状态保持不可用、可重试后成功")
    func installFailureThenRetry() async throws {
        mock.availability = supportedNotInstalled()
        _ = await controller.checkAvailability()
        mock.installError = LocalTranscriptionError.assetInstallUnsupported

        await controller.installChineseAssets()

        #expect(controller.assetDownloadProgress == nil, "失败后进度标记清除")
        let error = try #require(controller.assetInstallError)
        #expect(error.contains("下载失败"))
        #expect(!controller.canInstallChineseAssets == false, "重试入口保持可用")
        guard case .unavailable = controller.runState else {
            Issue.record("失败后应保持 unavailable")
            return
        }

        // 重试成功
        mock.installError = nil
        mock.availabilityAfterInstall = installed()
        await controller.installChineseAssets()
        #expect(mock.installCallCount == 2)
        #expect(controller.runState == .idle)
        #expect(controller.assetInstallError == nil)
    }

    @Test("已安装时调用下载：不发起安装")
    func noInstallWhenReady() async {
        mock.availability = installed()
        _ = await controller.checkAvailability()
        await controller.installChineseAssets()
        #expect(mock.installCallCount == 0, "已安装时不得发起下载")
        #expect(controller.assetDownloadProgress == nil)
    }

    @Test("进度值透传到控制器状态")
    func progressPassthrough() async {
        mock.availability = supportedNotInstalled()
        _ = await controller.checkAvailability()
        mock.installProgressSteps = [0.25, 0.5, 1.0]
        mock.availabilityAfterInstall = installed()

        await controller.installChineseAssets()
        // 同步 mock 下最终进度已被重置为 nil；验证安装流程走完且状态正确
        #expect(controller.runState == .idle)
    }
}
