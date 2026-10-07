import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// 音频输入设备描述
struct AudioInputDevice: Hashable, Sendable {
    /// 系统设备唯一标识（AVCaptureDevice.uniqueID）
    let id: String
    /// 显示名称（如「MacBook Pro 麦克风」）
    let name: String
}

/// 音频采集服务协议（实施计划 7.2：AudioCaptureService）。
/// 协议隔离硬件，便于测试替换（实施计划第 8 节）。
///
/// 会话模型：
/// - `startCapture(fileURL:)`：打开录音文件并开始写缓冲（此前可选定设备）；
/// - `pauseCapture` / `resumeCapture`：暂停期间不写文件，文件保持打开；
/// - `stopCapture`：关闭文件并停止引擎；
/// - `startLevelMonitoring` / `stopLevelMonitoring`：5 秒电平测试专用，不写文件。
protocol AudioCaptureServicing: AnyObject, Sendable {
    /// 输入电平回调（RMS 0…1，约 10Hz；在后台线程触发）
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    /// 当前使用中的设备被拔出 / 失效回调（在后台线程触发）
    var onDeviceDisconnected: (@Sendable () -> Void)? { get set }
    /// 连续写文件失败达到阈值后的单次回调（派发到主线程触发）
    var onWriteFailure: (@Sendable () -> Void)? { get set }
    /// 当前缓冲回调的归属令牌（无回调时为 nil）
    var bufferHandlerToken: UUID? { get }

    /// 登记原始缓冲回调（阶段 2：同时送入录音文件与 SpeechAnalyzer；
    /// 仅在「录音中」状态时触发，暂停期间不触发；在实时线程触发，不得阻塞）。
    ///
    /// 采集服务是单例，多个视图都会登记回调。token 标明归属：
    /// 新会话登记后旧会话的清理不会误伤新回调，旧闭包也不会继续收到音频。
    func setBufferHandler(
        token: UUID,
        _ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    )

    /// 仅当当前归属为该 token 时清空回调；token 不匹配时什么都不做
    func clearBufferHandler(token: UUID)

    /// 列出可用输入设备
    func inputDevices() -> [AudioInputDevice]
    /// 当前实际使用的设备 ID（nil 表示系统默认）
    var activeDeviceID: String? { get }
    /// 当前实际使用的设备显示名
    var activeDeviceName: String? { get }

    /// 选定输入设备（nil = 系统默认）；引擎运行中切换可能抛错
    func selectInputDevice(id: String?) throws
    /// 打开文件并开始采集写入
    func startCapture(fileURL: URL) throws
    /// 从已有录音文件末尾继续写入；返回续录前的媒体时长
    func startAppendingCapture(fileURL: URL) throws -> Int64
    /// 暂停采集：不写文件，文件保持打开
    func pauseCapture()
    /// 继续采集
    func resumeCapture() throws
    /// 停止采集并关闭文件
    func stopCapture()
    /// 开始电平监听（不写文件，用于 5 秒测试）
    func startLevelMonitoring() throws
    /// 停止电平监听
    func stopLevelMonitoring()
}

/// 音频采集错误
enum AudioCaptureError: Error, Equatable {
    /// 指定的设备不存在
    case deviceNotFound(String)
    /// 设备格式与已打开文件不一致，无法继续写入
    case incompatibleDeviceFormat
    /// 引擎启动失败
    case engineStartFailed(String)
}

/// 实时音频通路专用：把非 Sendable 的 PCM 缓冲送入并发域的盒子。
/// 安全性说明：tap 回调交付后缓冲由接收方独占使用，采集侧不再读写。
struct SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

final class AudioPacketAppendWriter: @unchecked Sendable {
    private let audioFileID: AudioFileID
    private let bytesPerPacket: UInt32
    private var nextPacket: Int64

    init(audioFileID: AudioFileID, bytesPerPacket: UInt32, nextPacket: Int64) {
        self.audioFileID = audioFileID
        self.bytesPerPacket = bytesPerPacket
        self.nextPacket = nextPacket
    }

    deinit {
        AudioFileClose(audioFileID)
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard buffer.audioBufferList.pointee.mNumberBuffers == 1,
              let data = audioBuffer.mData else {
            throw AudioCaptureError.incompatibleDeviceFormat
        }
        var packetCount = UInt32(buffer.frameLength)
        let expectedBytes = packetCount * bytesPerPacket
        guard audioBuffer.mDataByteSize >= expectedBytes else {
            throw AudioCaptureError.incompatibleDeviceFormat
        }
        let status = AudioFileWritePackets(
            audioFileID,
            false,
            expectedBytes,
            nil,
            nextPacket,
            &packetCount,
            data
        )
        guard status == noErr, packetCount == buffer.frameLength else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        nextPacket += Int64(packetCount)
    }
}

extension AudioCaptureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let id): return "找不到音频输入设备（\(id)）"
        case .incompatibleDeviceFormat: return "新设备的音频格式与当前录音不兼容"
        case .engineStartFailed(let reason): return "音频引擎启动失败：\(reason)"
        }
    }
}

/// 录音文件设置（共享给采集服务与单元测试，确保格式约定一致）。
/// 直接采用采集硬件格式写 PCM .caf：不重采样、不压缩，保证阶段 1「录音绝不丢」。
enum AudioRecordingSettings {
    static func fileSettings(for hardwareFormat: AVAudioFormat) -> [String: Any] {
        hardwareFormat.settings
    }
}

struct AudioWriteFailureEvent: Equatable, Sendable {
    let shouldNotify: Bool
    let errorType: String
}

struct AudioWriteFailureTracker {
    private let threshold: Int
    private var consecutiveFailures = 0
    private var didNotify = false

    init(threshold: Int = 5) {
        self.threshold = threshold
    }

    mutating func attempt(_ write: () throws -> Void) -> AudioWriteFailureEvent? {
        do {
            try write()
            consecutiveFailures = 0
            return nil
        } catch {
            consecutiveFailures += 1
            let shouldNotify = !didNotify && consecutiveFailures >= threshold
            if shouldNotify {
                didNotify = true
            }
            return AudioWriteFailureEvent(
                shouldNotify: shouldNotify,
                errorType: String(describing: type(of: error))
            )
        }
    }

    mutating func reset() {
        consecutiveFailures = 0
        didNotify = false
    }
}

/// 隔离引擎生命周期，允许用合成 tap 验证停机与回调的并发关系，无需打开麦克风。
protocol AudioCaptureEngine: AnyObject, Sendable {
    var inputFormat: AVAudioFormat { get }
    var inputAudioUnit: AudioUnit? { get }
    var notificationObject: AnyObject { get }
    func installTap(format: AVAudioFormat, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
    func prepare()
    func start() throws
    func pause()
    /// 返回前停止并排空正在执行的 tap 回调。
    func stop()
}

private final class SystemAudioCaptureEngine: AudioCaptureEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }
    var inputAudioUnit: AudioUnit? { engine.inputNode.audioUnit }
    var notificationObject: AnyObject { engine }

    func installTap(format: AVAudioFormat, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            handler(buffer)
        }
    }

    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func pause() { engine.pause() }
    func stop() { engine.stop() }
}

/// 基于 AVAudioEngine 的真实采集实现（阶段 1）。
/// 线程安全：tap 回调在实时线程执行，内部状态由锁保护；
/// 电平与断连回调均在后台线程触发，接收方需自行切换 actor。
final class AVAudioCaptureService: AudioCaptureServicing, @unchecked Sendable {
    private static let writeFailureLogQueue = DispatchQueue(
        label: "com.zhaobo.BangWoFenXi.audio-write-log",
        qos: .utility
    )

    private let engine: any AudioCaptureEngine
    /// 只序列化设备/引擎控制；tap 永不获取此锁。
    private let lifecycleLock = NSLock()
    /// 仅保护 tap 所需的短状态访问，持有时严禁调用引擎生命周期方法。
    private let lock = NSLock()
    private let writeFailureLock = NSLock()

    /// 当前打开的录音文件
    private var audioFile: AVAudioFile?
    /// 单声道 PCM CAF 续录时的原地追加写入器
    private var packetAppendWriter: AudioPacketAppendWriter?
    /// 是否写文件（暂停 / 电平监听时为 false）
    private var writingEnabled = false
    /// 是否已安装 tap
    private var tapInstalled = false
    /// 打开文件时的格式（用于设备切换后的兼容性检查）
    private var fileFormat: AVAudioFormat?
    /// 用户选定的设备 ID（nil = 系统默认）
    private var selectedDeviceID: String?
    /// 电平节流：每 N 个缓冲回调一次
    private var bufferCountSinceLevel = 0
    private var writeFailureTracker = AudioWriteFailureTracker()

    var onLevel: (@Sendable (Float) -> Void)?
    var onDeviceDisconnected: (@Sendable () -> Void)?
    var onWriteFailure: (@Sendable () -> Void)?

    /// 缓冲回调与其归属令牌；tap 在实时线程读取，统一由 bufferLock 保护
    private let bufferLock = NSLock()
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var bufferToken: UUID?

    var bufferHandlerToken: UUID? {
        bufferLock.withLock { bufferToken }
    }

    func setBufferHandler(
        token: UUID,
        _ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) {
        bufferLock.withLock {
            bufferHandler = handler
            bufferToken = handler == nil ? nil : token
        }
    }

    func clearBufferHandler(token: UUID) {
        bufferLock.withLock {
            guard bufferToken == token else { return }
            bufferHandler = nil
            bufferToken = nil
        }
    }

    private var disconnectObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?

    init(engine: any AudioCaptureEngine = SystemAudioCaptureEngine()) {
        self.engine = engine
        // 监听当前设备断开与引擎配置变化（实施计划 11.2：麦克风拔出）
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let device = notification.object as? AVCaptureDevice else { return }
            let currentID = self.activeCurrentDeviceID()
            // 只关心当前正在使用的设备
            if currentID == nil || currentID == device.uniqueID {
                self.onDeviceDisconnected?()
            }
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.notificationObject,
            queue: nil
        ) { [weak self] _ in
            // 引擎配置变化（默认设备切换、采样率变化等）时按同样路径处理
            self?.onDeviceDisconnected?()
        }
    }

    deinit {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        if let configChangeObserver { NotificationCenter.default.removeObserver(configChangeObserver) }
    }

    // MARK: - 设备枚举与选择

    func inputDevices() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    var activeDeviceID: String? {
        activeCurrentDeviceID()
    }

    var activeDeviceName: String? {
        let id = activeDeviceID
        if let id, let device = inputDevices().first(where: { $0.id == id }) {
            return device.name
        }
        return AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// 当前实际设备 ID：用户已选则返回选定值，否则返回系统默认设备 ID（无设备时为 nil）
    private func activeCurrentDeviceID() -> String? {
        lock.withLock { selectedDeviceID } ?? AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    func selectInputDevice(id: String?) throws {
        if let id, !inputDevices().contains(where: { $0.id == id }) {
            throw AudioCaptureError.deviceNotFound(id)
        }
        try lifecycleLock.withLock {
            if let id {
                try applyDeviceToEngine(uniqueID: id)
            }
            lock.withLock { selectedDeviceID = id }
        }
    }

    /// 把指定 uniqueID 的设备设置为引擎输入（AUHAL CurrentDevice）
    private func applyDeviceToEngine(uniqueID: String) throws {
        let deviceID = try Self.audioDeviceID(forUniqueID: uniqueID)
        var mutableDeviceID = deviceID
        guard let audioUnit = engine.inputAudioUnit else {
            throw AudioCaptureError.engineStartFailed("音频输入单元不可用")
        }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.stride)
        )
        guard status == noErr else {
            throw AudioCaptureError.engineStartFailed("设置输入设备失败（OSStatus \(status)）")
        }
    }

    /// uniqueID → AudioDeviceID 映射
    private static func audioDeviceID(forUniqueID uniqueID: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.stride)
        var uid = uniqueID as CFString
        let status = withUnsafePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.stride),
                uidPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != 0 else {
            throw AudioCaptureError.deviceNotFound(uniqueID)
        }
        return deviceID
    }

    // MARK: - 采集会话

    func startCapture(fileURL: URL) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopCaptureDuringTransition()
        let format = engine.inputFormat
        installTapDuringTransition(format: format)
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: AudioRecordingSettings.fileSettings(for: format)
        )
        lock.withLock {
            audioFile = file
            packetAppendWriter = nil
        }
        try prepareCaptureDuringTransition(format: format)
    }

    func startAppendingCapture(fileURL: URL) throws -> Int64 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopCaptureDuringTransition()
        let format = engine.inputFormat
        installTapDuringTransition(format: format)

        let existingDurationMs: Int64
        if FileManager.default.fileExists(atPath: fileURL.path),
           let prepared = try Self.preparePacketAppendWriter(
                fileURL: fileURL,
                format: format
           ) {
            lock.withLock {
                audioFile = nil
                packetAppendWriter = prepared.writer
            }
            existingDurationMs = prepared.existingDurationMs
        } else {
            let prepared = try Self.prepareAppendingFile(fileURL: fileURL, format: format)
            lock.withLock {
                audioFile = prepared.file
                packetAppendWriter = nil
            }
            existingDurationMs = prepared.existingDurationMs
        }
        try prepareCaptureDuringTransition(format: format)
        return existingDurationMs
    }

    static func preparePacketAppendWriter(
        fileURL: URL,
        format: AVAudioFormat
    ) throws -> (writer: AudioPacketAppendWriter, existingDurationMs: Int64)? {
        guard format.channelCount == 1 else { return nil }

        var audioFileID: AudioFileID?
        let openStatus = AudioFileOpenURL(
            fileURL as CFURL,
            .readWritePermission,
            0,
            &audioFileID
        )
        guard openStatus == noErr, let audioFileID else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(openStatus))
        }

        var shouldClose = true
        defer {
            if shouldClose { AudioFileClose(audioFileID) }
        }

        var fileFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioFileGetProperty(
            audioFileID,
            kAudioFilePropertyDataFormat,
            &formatSize,
            &fileFormat
        )
        guard formatStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(formatStatus))
        }

        let clientFormat = format.streamDescription.pointee
        guard fileFormat.mFormatID == kAudioFormatLinearPCM,
              fileFormat.mChannelsPerFrame == 1,
              fileFormat.mFramesPerPacket == 1,
              fileFormat.mBytesPerPacket == clientFormat.mBytesPerFrame,
              fileFormat.mSampleRate == clientFormat.mSampleRate else {
            return nil
        }

        var packetCount: UInt64 = 0
        var packetCountSize = UInt32(MemoryLayout<UInt64>.size)
        let countStatus = AudioFileGetProperty(
            audioFileID,
            kAudioFilePropertyAudioDataPacketCount,
            &packetCountSize,
            &packetCount
        )
        guard countStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(countStatus))
        }

        shouldClose = false
        let durationMs = fileFormat.mSampleRate > 0
            ? Int64((Double(packetCount) / fileFormat.mSampleRate * 1_000).rounded())
            : 0
        return (
            AudioPacketAppendWriter(
                audioFileID: audioFileID,
                bytesPerPacket: fileFormat.mBytesPerPacket,
                nextPacket: Int64(packetCount)
            ),
            durationMs
        )
    }

    static func prepareAppendingFile(
        fileURL: URL,
        format: AVAudioFormat
    ) throws -> (file: AVAudioFile, existingDurationMs: Int64) {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let existingFile = try AVAudioFile(
                forReading: fileURL,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            let existingFormat = existingFile.processingFormat
            guard existingFormat.sampleRate == format.sampleRate,
                  existingFormat.channelCount == format.channelCount else {
                throw AudioCaptureError.incompatibleDeviceFormat
            }
            let sampleRate = existingFile.fileFormat.sampleRate
            let existingDurationMs = sampleRate > 0
                ? Int64((Double(existingFile.length) / sampleRate * 1_000).rounded())
                : 0

            let temporaryURL = fileURL.deletingLastPathComponent()
                .appending(path: ".recording-append-\(UUID().uuidString).caf")
            do {
                let appendedFile = try AVAudioFile(
                    forWriting: temporaryURL,
                    settings: AudioRecordingSettings.fileSettings(for: format),
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: existingFormat,
                    frameCapacity: 16_384
                ) else {
                    throw AudioCaptureError.incompatibleDeviceFormat
                }
                while existingFile.framePosition < existingFile.length {
                    let remaining = existingFile.length - existingFile.framePosition
                    let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
                    try existingFile.read(into: buffer, frameCount: frames)
                    guard buffer.frameLength > 0 else { break }
                    try appendedFile.write(from: buffer)
                }
                _ = try FileManager.default.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL
                )
                return (appendedFile, existingDurationMs)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
        return (
            try AVAudioFile(
                forWriting: fileURL,
                settings: AudioRecordingSettings.fileSettings(for: format)
            ),
            0
        )
    }

    private func prepareCaptureDuringTransition(format: AVAudioFormat) throws {
        writeFailureLock.withLock {
            writeFailureTracker.reset()
        }
        lock.withLock {
            fileFormat = format
            writingEnabled = true
        }
        do {
            try startEngineDuringTransition()
        } catch {
            stopCaptureDuringTransition()
            throw error
        }
    }

    func pauseCapture() {
        lifecycleLock.withLock {
            engine.pause()
            lock.withLock { writingEnabled = false }
        }
    }

    func resumeCapture() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        // 设备切换后格式可能变化：与已打开文件不一致则拒绝继续，避免写出损坏文件
        let currentFormat = engine.inputFormat
        if let fileFormat = lock.withLock({ fileFormat }),
           currentFormat.sampleRate != fileFormat.sampleRate || currentFormat.channelCount != fileFormat.channelCount {
            throw AudioCaptureError.incompatibleDeviceFormat
        }
        writeFailureLock.withLock {
            writeFailureTracker.reset()
        }
        lock.withLock { writingEnabled = true }
        do {
            try startEngineDuringTransition()
        } catch {
            engine.stop()
            lock.withLock { writingEnabled = false }
            throw error
        }
    }

    func stopCapture() {
        lifecycleLock.withLock {
            stopCaptureDuringTransition()
        }
    }

    /// AVAudioEngine.stop 会等待 tap 完成。先在状态锁外停机，允许尾帧继续落盘；
    /// 停机返回后才释放文件，且整个过程由 lifecycleLock 阻止新会话插入。
    private func stopCaptureDuringTransition() {
        engine.stop()
        lock.withLock {
            writingEnabled = false
            audioFile = nil // 关闭文件句柄
            packetAppendWriter = nil
            fileFormat = nil
        }
        writeFailureLock.withLock {
            writeFailureTracker.reset()
        }
    }

    func startLevelMonitoring() throws {
        try lifecycleLock.withLock {
            engine.stop()
            lock.withLock { writingEnabled = false }
            installTapDuringTransition(format: engine.inputFormat)
            try startEngineDuringTransition()
        }
    }

    func stopLevelMonitoring() {
        lifecycleLock.withLock {
            engine.stop()
            lock.withLock { writingEnabled = false }
        }
    }

    // MARK: - 引擎与 tap（仅持 lifecycleLock，不能持 tap 状态锁）

    private func installTapDuringTransition(format: AVAudioFormat) {
        guard !tapInstalled else { return }
        engine.installTap(format: format) { [weak self] buffer in
            self?.processTapBuffer(buffer)
        }
        tapInstalled = true
    }

    private func startEngineDuringTransition() throws {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    /// tap 实时回调：写文件 + 分发缓冲 + 计算 RMS 电平（节流约 10Hz）
    private func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        let (file, packetWriter, shouldWrite) = lock.withLock {
            (audioFile, packetAppendWriter, writingEnabled)
        }
        if shouldWrite, file != nil || packetWriter != nil {
            let failure = writeFailureLock.withLock {
                writeFailureTracker.attempt {
                    if let file {
                        try file.write(from: buffer)
                    } else if let packetWriter {
                        try packetWriter.write(buffer)
                    }
                }
            }
            if let failure {
                Self.writeFailureLogQueue.async {
                    AppLog.logWarning(AppLog.audio, LogSanitizer.formatEvent(
                        "audio_write_failed",
                        error: failure.errorType
                    ))
                }
                if failure.shouldNotify, let onWriteFailure {
                    DispatchQueue.main.async {
                        onWriteFailure()
                    }
                }
            }
        }
        // 阶段 2：录音中把缓冲同时分发给语音分析（暂停期间不分发）
        if shouldWrite {
            // 先在锁内取出闭包再调用，避免在实时线程持锁执行下游逻辑
            let handler = bufferLock.withLock { bufferHandler }
            if let handler {
                PerfCounters.increment(.bufferFed)
                handler(buffer)
            }
        }
        // 电平：约每 8 个缓冲上报一次（4096 帧 @44.1kHz ≈ 93ms）
        bufferCountSinceLevel += 1
        guard bufferCountSinceLevel >= 8 else { return }
        bufferCountSinceLevel = 0
        let rms = Self.rmsLevel(of: buffer)
        PerfCounters.increment(.levelCallback)
        onLevel?(rms)
    }

    /// 计算缓冲 RMS（0…1），支持 float32 / int16 常见格式
    static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        if let channelData = buffer.floatChannelData {
            let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
            var sum: Float = 0
            for sample in samples { sum += sample * sample }
            return min(1, sqrt(sum / Float(frameLength)) * 4) // 适当放大便于显示
        }
        if let channelData = buffer.int16ChannelData {
            let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
            var sum: Float = 0
            for sample in samples {
                let normalized = Float(sample) / Float(Int16.max)
                sum += normalized * normalized
            }
            return min(1, sqrt(sum / Float(frameLength)) * 4)
        }
        return 0
    }
}
