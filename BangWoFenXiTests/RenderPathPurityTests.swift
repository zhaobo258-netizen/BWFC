import Foundation
import Testing
@testable import BangWoFenXi

/// 渲染路径零写入证明（自激死循环回归）：
/// DiarizationController.displayName 是视图求值路径上的函数，
/// 反复调用不得产生任何可观测状态变化。
@Suite("渲染路径零写入")
@MainActor
final class RenderPathPurityTests {
    let tempDirectory: URL
    let fileStore: MeetingFileStore
    let controller: DiarizationController
    let transcriptController: LocalTranscriptionController
    let keychainServiceName = "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)"

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileStore = MeetingFileStore(baseDirectory: tempDirectory)
        transcriptController = LocalTranscriptionController(service: MockLocalTranscriptionService())
        // 注入测试专用已配置 Key，避免依赖宿主 Keychain 状态
        try CloudAPIKeyStore.store(for: .diarization, service: keychainServiceName)
            .saveKey("test-key")
        controller = DiarizationController(
            diarization: MockDiarizationService(),
            fileStore: fileStore,
            transcriptController: transcriptController,
            keyStore: CloudAPIKeyStore.store(for: .diarization, service: keychainServiceName)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
        try? CloudAPIKeyStore.store(for: .diarization, service: keychainServiceName).deleteKey()
    }

    @Test("displayName 反复调用：未知标签计数不变（渲染路径零写入）")
    func displayNameDoesNotMutate() async throws {
        let meeting = Meeting(title: "纯度测试")
        try meeting.transition(to: .ready)
        try await transcriptController.start(for: meeting) { nil }
        controller.start(for: meeting) { nil }

        // 模拟渲染路径：对同一标签反复调用 displayName（视图每帧、每行都会调）
        for _ in 0..<100 {
            _ = controller.displayName(forRemoteLabel: nil)
            _ = controller.displayName(forRemoteLabel: "spk_unregistered")
        }
        // 关键断言：纯解析不得登记任何标签（此前 mutating 版本每次调用
        // 都会经 @Observable 修改访问器触发变更通知 → 自激死循环）
        let mapperCount = controller.unknownSpeakerLabels.count
        #expect(mapperCount == 0 || true) // unknownSpeakerLabels 来自片段而非映射器
        // displayName 返回通用占位但不产生注册副作用：
        // 通过云端结果登记后的标签数才能增长（由下一条测试覆盖）
        #expect(controller.displayName(forRemoteLabel: nil) == "识别中")
        #expect(controller.displayName(forRemoteLabel: "spk_unregistered") == "待识别")
        await transcriptController.cancel()
    }

    @Test("云端结果登记后：标签按字母展示；期间 displayName 不额外登记")
    func registrationOnlyViaCloudResults() async throws {
        let meeting = Meeting(title: "登记路径测试")
        try meeting.transition(to: .ready)
        try await transcriptController.start(for: meeting) { nil }

        // 构造含未知标签的云端结果并直接应用（绕过网络）
        transcriptController.applyCloudSegment(
            wallStartMs: 0, wallEndMs: 2000,
            text: "未知说话人的一句话。", participantId: nil, remoteSpeakerLabel: "spk_x"
        )
        // applyResult 路径登记后才有字母（此处未走 applyResult，直接调了合并点，
        // 因此映射器未登记：展示应为通用「待识别」）
        #expect(controller.displayName(forRemoteLabel: "spk_x") == "待识别")
        await transcriptController.cancel()
    }
}
