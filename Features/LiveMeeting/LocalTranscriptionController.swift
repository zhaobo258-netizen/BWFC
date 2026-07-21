import Foundation
import AVFoundation

/// 本地同声转写控制器（阶段 2）：
/// 驱动 LocalTranscriptionServicing，把结果流经 TranscriptReconciler 合并为
/// 无重复的片段序列；会议时间轴由 RecordingTimeline 逆映射得到。
/// 临时片段只用于界面展示，不写库；最终片段写入会议并触发持久化。
@MainActor
@Observable
final class LocalTranscriptionController {
    /// 转写运行状态
    enum RunState: Equatable {
        case idle
        case running
        case unavailable(String) // 附真实原因
    }

    private let service: any LocalTranscriptionServicing

    /// 可用性检查结果（界面展示与开始拦截共用）
    private(set) var availability: TranscriptionAvailability?
    private(set) var runState: RunState = .idle
    /// 当前片段序列（最终 + 尾部临时）
    private(set) var segments: [TranscriptSegment] = []
    /// 脱敏错误描述（界面提示）
    private(set) var lastErrorDescription: String?

    private var reconciler = TranscriptReconciler()
    private var collectTask: Task<Void, Never>?
    private var timelineProvider: (() -> RecordingTimeline?)?
    private weak var meeting: Meeting?
    /// 最终片段入库回调（由视图层注入持久化）
    var onFinalSegment: (() -> Void)?

    init(service: any LocalTranscriptionServicing) {
        self.service = service
    }

    /// 检查普通话可用性（会中界面 onAppear 与开始录音前调用）
    @discardableResult
    func checkAvailability() async -> TranscriptionAvailability {
        let result = await service.checkMandarinAvailability()
        availability = result
        if !result.isReady, runState == .idle {
            runState = .unavailable(result.issueSummary ?? "本地转写不可用")
        }
        return result
    }

    /// 开始转写（录音已启动后调用）。
    /// 上下文词汇 = 专业词汇 + 参会人姓名与角色（仅改善识别，不改写原意）。
    func start(
        for meeting: Meeting,
        timelineProvider: @escaping () -> RecordingTimeline?
    ) async throws {
        let current: TranscriptionAvailability
        if let availability {
            current = availability
        } else {
            current = await checkAvailability()
        }
        guard current.isReady else {
            let reason = current.issueSummary ?? "本地转写不可用"
            runState = .unavailable(reason)
            throw LocalTranscriptionError.notReady(current.issues)
        }

        self.meeting = meeting
        self.timelineProvider = timelineProvider
        reconciler.reset()
        segments = []

        let contextual = meeting.glossary
            + meeting.participants.map(\.displayName)
            + meeting.participants.map(\.role).filter { !$0.isEmpty }
        do {
            try await service.startSession(contextualStrings: contextual)
        } catch {
            lastErrorDescription = error.localizedDescription
            runState = .unavailable(error.localizedDescription)
            AppLog.transcription.error("\(LogSanitizer.formatEvent("transcription_start_failed", error: String(describing: type(of: error))))")
            throw error
        }

        runState = .running
        collectTask = Task { [weak self] in
            guard let self else { return }
            for await result in service.results {
                self.consume(result)
            }
        }
    }

    /// 送入一个采集缓冲（非隔离入口：采集实时线程直接调用，
    /// 经 Sendable 盒子转发给转写服务；服务无会话时自动丢弃）。
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        let boxed = SendableAudioBuffer(buffer)
        Task { [service] in
            await service.feed(boxed.buffer)
        }
    }

    /// 结束转写：丢弃尾部临时片段（最终片段已即时入库）
    func finish() async {
        collectTask?.cancel()
        collectTask = nil
        await service.finishSession()
        reconciler.dropProvisional()
        segments = reconciler.allSegments
        runState = .idle
    }

    /// 立即取消（录音异常中止等场景）
    func cancel() async {
        collectTask?.cancel()
        collectTask = nil
        await service.cancelSession()
        reconciler.reset()
        segments = []
        runState = .idle
    }

    // MARK: - 结果消费

    private func consume(_ result: LocalTranscriptResult) {
        // 音频流时间 → 会议时间轴（含暂停区间的还原）
        let timeline = timelineProvider?()
        let startWallMs = timeline?.wallMs(forEffectiveAudioMs: result.startAudioMs) ?? result.startAudioMs
        let endWallMs = timeline?.wallMs(forEffectiveAudioMs: result.endAudioMs) ?? result.endAudioMs

        if result.isFinal {
            let outcome = reconciler.applyFinal(
                startMs: startWallMs,
                endMs: endWallMs,
                text: result.text
            )
            if case .inserted(let segment) = outcome {
                meeting?.segments.append(segment)
                onFinalSegment?()
            }
        } else {
            _ = reconciler.upsertProvisional(
                startMs: startWallMs,
                endMs: endWallMs,
                text: result.text
            )
        }
        segments = reconciler.allSegments
    }
}
