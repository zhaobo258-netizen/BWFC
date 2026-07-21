import Foundation

/// 会议录音编排服务（阶段 1）：
/// 把 AudioCaptureServicing、MeetingFileStore、RecordingTimeline 与会议状态机串起来。
/// 全部运行在 MainActor；硬件细节由协议隔离，单元测试用 Mock 驱动。
@MainActor
@Observable
final class MeetingRecordingService {
    private let capture: any AudioCaptureServicing
    private let fileStore: MeetingFileStore

    /// 当前会议（开始录音后非空）
    private(set) var activeMeeting: Meeting?
    /// 录音时间线（暂停区间与文件时长换算）
    private(set) var timeline: RecordingTimeline?
    /// 设备中断标记：麦克风拔出后置为 true，等待用户选择新设备
    private(set) var deviceInterrupted = false
    /// 最近一次操作的脱敏错误描述（用于界面提示）
    private(set) var lastErrorDescription: String?

    init(capture: any AudioCaptureServicing, fileStore: MeetingFileStore) {
        self.capture = capture
        self.fileStore = fileStore
        self.capture.onDeviceDisconnected = { [weak self] in
            Task { @MainActor in
                self?.handleDeviceDisconnected()
            }
        }
    }

    /// 会议时间轴毫秒（供界面计时显示）
    func elapsedWallMs(at date: Date = Date()) -> Int64 {
        timeline?.wallMs(at: date) ?? 0
    }

    /// 当前使用中的麦克风名称（顶部状态栏显示）
    var activeMicrophoneName: String? {
        capture.activeDeviceName
    }

    /// 开始录音：ready → recording。
    /// 先启动采集再转换状态，采集失败时会议状态保持不变。
    /// - Parameters:
    ///   - meeting: 处于 ready 状态的会议
    ///   - deviceID: 输入设备（nil = 系统默认；通常取会议表单保存的选择）
    func startRecording(for meeting: Meeting, deviceID: String?) throws {
        guard meeting.status == .ready else {
            throw MeetingRecordingError.wrongStatus("开始录音", current: meeting.status)
        }
        do {
            try capture.selectInputDevice(id: deviceID)
            try fileStore.ensureMeetingDirectory(for: meeting.id)
            let relativePath = fileStore.relativeAudioPath(for: meeting.id)
            let fileURL = try fileStore.absoluteURL(forRelativePath: relativePath)
            try capture.startCapture(fileURL: fileURL)

            try meeting.transition(to: .recording)
            meeting.audioRelativePath = relativePath
            timeline = RecordingTimeline(startedAt: meeting.startedAt ?? Date())
            activeMeeting = meeting
            deviceInterrupted = false
            lastErrorDescription = nil
        } catch {
            // 失败回滚：不留下半开状态；只保留脱敏错误类型
            capture.stopCapture()
            lastErrorDescription = error.localizedDescription
            AppLog.audio.error("\(LogSanitizer.formatEvent("recording_start_failed", error: String(describing: type(of: error))))")
            throw error
        }
    }

    /// 暂停录音：recording → paused。暂停期间不写文件。
    func pauseRecording() throws {
        guard let meeting = activeMeeting else {
            throw MeetingRecordingError.noActiveMeeting
        }
        guard meeting.status == .recording else {
            throw MeetingRecordingError.wrongStatus("暂停录音", current: meeting.status)
        }
        capture.pauseCapture()
        try timeline?.beginPause(at: Date())
        try meeting.transition(to: .paused)
    }

    /// 继续录音：paused → recording，闭合一个暂停区间。
    func resumeRecording() throws {
        guard let meeting = activeMeeting else {
            throw MeetingRecordingError.noActiveMeeting
        }
        guard meeting.status == .paused else {
            throw MeetingRecordingError.wrongStatus("继续录音", current: meeting.status)
        }
        try capture.resumeCapture()
        if let interval = try timeline?.endPause(at: Date()) {
            meeting.pauseIntervals.append(interval)
        }
        try meeting.transition(to: .recording)
        deviceInterrupted = false
    }

    /// 结束录音：recording/paused → finalizing → completed。
    /// 阶段 1 没有待处理分片，直接完成收尾；关闭文件并记录结束时间。
    func finishRecording() throws {
        guard let meeting = activeMeeting else {
            throw MeetingRecordingError.noActiveMeeting
        }
        guard meeting.status == .recording || meeting.status == .paused else {
            throw MeetingRecordingError.wrongStatus("结束录音", current: meeting.status)
        }
        // 暂停中结束：先闭合暂停区间（不再写文件）
        if meeting.status == .paused, timeline?.isPaused == true {
            if let interval = try? timeline?.endPause(at: Date()) {
                meeting.pauseIntervals.append(interval)
            }
        }
        capture.stopCapture()
        try meeting.transition(to: .finalizing)
        try meeting.transition(to: .completed)
        activeMeeting = nil
    }

    /// 设备拔出 / 配置变化（实施计划 11.2：立即提示并暂停录音，允许选择新设备继续）
    func handleDeviceDisconnected() {
        guard let meeting = activeMeeting else { return }
        if meeting.status == .recording {
            try? pauseRecording()
        }
        if meeting.status == .paused || meeting.status == .recording {
            deviceInterrupted = true
            AppLog.audio.warning("\(LogSanitizer.formatEvent("capture_device_disconnected"))")
        }
    }

    /// 设备中断后选择新设备（之后由用户点击「继续」恢复录音）
    func switchInputDevice(to deviceID: String) throws {
        try capture.selectInputDevice(id: deviceID)
        deviceInterrupted = false
    }

    /// 放弃当前会话状态（会议被删除等场景使用）
    func discardSession() {
        capture.stopCapture()
        activeMeeting = nil
        timeline = nil
        deviceInterrupted = false
    }
}

/// 录音编排错误
enum MeetingRecordingError: Error, Equatable {
    /// 当前状态不允许该操作
    case wrongStatus(String, current: MeetingStatus)
    /// 没有进行中的录音会话
    case noActiveMeeting
}

extension MeetingRecordingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .wrongStatus(let action, let current):
            return "当前状态（\(current.displayName)）不允许「\(action)」"
        case .noActiveMeeting:
            return "没有进行中的录音会话"
        }
    }
}
