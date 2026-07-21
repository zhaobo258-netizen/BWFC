import Foundation

/// 声音样本录制控制器（阶段 3，实施计划 7.5）：
/// 每位核心参会人 2–10 秒样本录制、校验（时长 + 有效音量）、重录。
/// 试听复用 AudioPlaybackController。
@MainActor
@Observable
final class VoiceSampleController {
    /// 录制状态
    enum Phase: Equatable {
        case idle
        case recording(participantID: UUID)
    }

    /// 录制产出的样本元数据
    struct SampleResult: Equatable {
        var participantID: UUID
        var relativePath: String
        var durationMs: Int64
        var verdict: VoiceSampleValidator.Verdict
    }

    private let capture: any AudioCaptureServicing
    private let fileStore: MeetingFileStore

    private(set) var phase: Phase = .idle
    /// 录制中的实时电平
    private(set) var liveLevel: Float = 0
    /// 最近一次校验结果（按参会人 ID）
    private(set) var verdicts: [UUID: VoiceSampleValidator.Verdict] = [:]
    /// 脱敏错误提示
    private(set) var lastErrorDescription: String?

    private var peakLevel: Float = 0
    private var currentMeetingID: UUID?
    private var currentParticipantID: UUID?
    private var currentFileURL: URL?

    init(capture: any AudioCaptureServicing, fileStore: MeetingFileStore) {
        self.capture = capture
        self.fileStore = fileStore
    }

    /// 是否正在录制指定参会人的样本
    func isRecording(participantID: UUID) -> Bool {
        phase == .recording(participantID: participantID)
    }

    /// 开始录制样本（会覆盖同参会人的旧样本）
    func startRecording(meetingID: UUID, participantID: UUID, deviceID: String?) throws {
        guard phase == .idle else { return }
        let relativePath = fileStore.relativeVoiceSamplePath(
            meetingID: meetingID,
            participantID: participantID
        )
        let url = try fileStore.absoluteURL(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        peakLevel = 0
        liveLevel = 0
        currentMeetingID = meetingID
        currentParticipantID = participantID
        currentFileURL = url

        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.phase != .idle else { return }
                self.liveLevel = level
                self.peakLevel = max(self.peakLevel, level)
            }
        }
        do {
            try capture.selectInputDevice(id: deviceID)
            try capture.startCapture(fileURL: url)
            phase = .recording(participantID: participantID)
            lastErrorDescription = nil
        } catch {
            capture.onLevel = nil
            currentMeetingID = nil
            currentParticipantID = nil
            currentFileURL = nil
            lastErrorDescription = error.localizedDescription
            AppLog.audio.error("\(LogSanitizer.formatEvent("voice_sample_start_failed", error: String(describing: type(of: error))))")
            throw error
        }
    }

    /// 停止录制并校验样本；不在录制中返回 nil
    @discardableResult
    func stopRecording() -> SampleResult? {
        guard case .recording(let participantID) = phase,
              let meetingID = currentMeetingID,
              let url = currentFileURL else {
            return nil
        }
        capture.stopCapture()
        capture.onLevel = nil
        phase = .idle

        let durationMs = (try? AudioChunkExtractor.durationMs(of: url)) ?? 0
        let verdict = VoiceSampleValidator.validate(durationMs: durationMs, peakLevel: peakLevel)
        verdicts[participantID] = verdict

        let result = SampleResult(
            participantID: participantID,
            relativePath: fileStore.relativeVoiceSamplePath(
                meetingID: meetingID,
                participantID: participantID
            ),
            durationMs: durationMs,
            verdict: verdict
        )
        currentMeetingID = nil
        currentParticipantID = nil
        currentFileURL = nil
        liveLevel = 0
        return result
    }

    /// 取消录制（删除半成品）
    func cancelRecording() {
        guard case .recording = phase else { return }
        capture.stopCapture()
        capture.onLevel = nil
        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        phase = .idle
        currentMeetingID = nil
        currentParticipantID = nil
        currentFileURL = nil
        liveLevel = 0
    }
}
