import Foundation
import AVFoundation
import Speech
import CoreMedia

/// 本地转写可用性报告（实施计划 11.2：Apple 中文模型不可用时
/// 阻止开始并显示真实原因，不静默走云端全量录音）。
struct TranscriptionAvailability: Equatable, Sendable {
    /// 语言资源状态
    enum AssetState: String, Equatable, Sendable {
        case installed              // 已安装
        case downloading            // 下载中
        case supportedNotInstalled  // 支持但未安装
        case unsupported            // 不支持
    }

    /// SpeechTranscriber 在本设备可用
    var transcriberAvailable: Bool
    /// 支持普通话（zh-Hans）
    var mandarinSupported: Bool
    /// 中文语言资源状态
    var assetState: AssetState

    /// 是否可以直接开始转写
    var isReady: Bool {
        transcriberAvailable && mandarinSupported && assetState == .installed
    }

    /// 真实原因列表（空 = 无问题）
    var issues: [String]

    /// 汇总为一段中文说明（界面展示用）
    var issueSummary: String? {
        issues.isEmpty ? nil : issues.joined(separator: "\n")
    }
}

/// 本地转写结果（音频流时间轴毫秒，不含暂停；会议时间轴由 RecordingTimeline 逆映射）
struct LocalTranscriptResult: Equatable, Sendable {
    var startAudioMs: Int64
    var endAudioMs: Int64
    var text: String
    /// true = 最终（不再变化）；false = 临时（会被后续结果替换）
    var isFinal: Bool
}

/// 本地转写错误
enum LocalTranscriptionError: Error, Equatable {
    /// 不满足转写条件（附真实原因）
    case notReady([String])
    /// 会话未启动
    case sessionNotStarted
    /// 会话已在运行
    case sessionAlreadyRunning
    /// 无法确定分析所需音频格式
    case noCompatibleAudioFormat
}

extension LocalTranscriptionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notReady(let issues): return "本地转写不可用：\(issues.joined(separator: "；"))"
        case .sessionNotStarted: return "转写会话未启动"
        case .sessionAlreadyRunning: return "转写会话已在运行"
        case .noCompatibleAudioFormat: return "找不到与语音识别兼容的音频格式"
        }
    }
}

/// 本地转写服务协议（实施计划 7.3：Apple Speech 设备端即时转写）。
/// 协议隔离 SpeechAnalyzer，便于测试替换（实施计划第 8 节）。
protocol LocalTranscriptionServicing: AnyObject, Sendable {
    /// 结果流（临时 + 最终，按产生顺序）
    var results: AsyncStream<LocalTranscriptResult> { get }
    /// 检查普通话转写可用性（不静默降级；返回真实原因）
    func checkMandarinAvailability() async -> TranscriptionAvailability
    /// 启动转写会话
    /// - Parameter contextualStrings: 上下文词汇（专业词汇、参会人姓名等；
    ///   仅用于改善识别，不改写原意）
    func startSession(contextualStrings: [String]) async throws
    /// 送入一个采集缓冲（调用方负责格式；内部按需转换）
    func feed(_ buffer: AVAudioPCMBuffer) async
    /// 结束会话：停止送入并等待剩余结果产出
    func finishSession() async
    /// 立即取消会话
    func cancelSession() async
}

/// 基于 Apple SpeechAnalyzer / SpeechTranscriber 的本地转写实现（阶段 2）。
/// 使用带时间范围的渐进式转写 preset（timeIndexedProgressiveTranscription），
/// 临时结果与最终结果都带 CMTimeRange。
final class AppleSpeechTranscriptionService: LocalTranscriptionServicing, @unchecked Sendable {
    /// 目标语言：简体中文（普通话）
    static let mandarinLocale = Locale(identifier: "zh-Hans-CN")

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var collectorTask: Task<Void, Never>?
    private var running = false

    private var resultsContinuation: AsyncStream<LocalTranscriptResult>.Continuation?
    let results: AsyncStream<LocalTranscriptResult>

    init() {
        var continuation: AsyncStream<LocalTranscriptResult>.Continuation!
        self.results = AsyncStream { continuation = $0 }
        self.resultsContinuation = continuation
    }

    // MARK: - 可用性检查（不静默降级）

    func checkMandarinAvailability() async -> TranscriptionAvailability {
        var issues: [String] = []

        let transcriberAvailable = SpeechTranscriber.isAvailable
        if !transcriberAvailable {
            issues.append("本设备不支持 Apple 语音识别（SpeechTranscriber 不可用）")
        }

        var mandarinSupported = false
        if await SpeechTranscriber.supportedLocale(equivalentTo: Self.mandarinLocale) != nil {
            mandarinSupported = true
        } else {
            issues.append("Apple 语音识别不支持简体中文（zh-Hans）")
        }

        var assetState: TranscriptionAvailability.AssetState = .unsupported
        if mandarinSupported {
            let probe = SpeechTranscriber(locale: Self.mandarinLocale, preset: .timeIndexedProgressiveTranscription)
            let status = await AssetInventory.status(forModules: [probe])
            switch status {
            case .installed:
                assetState = .installed
            case .downloading:
                assetState = .downloading
                issues.append("中文语言资源正在下载，请稍后重试")
            case .supported:
                assetState = .supportedNotInstalled
                issues.append("中文语言资源尚未安装（可在系统设置中下载，或联网后重试）")
            case .unsupported:
                assetState = .unsupported
                issues.append("本设备缺少可用的中文语言资源")
            default:
                issues.append("中文语言资源状态未知")
            }
        }

        return TranscriptionAvailability(
            transcriberAvailable: transcriberAvailable,
            mandarinSupported: mandarinSupported,
            assetState: assetState,
            issues: issues
        )
    }

    /// 尝试触发中文语言资源下载（用户主动点击「下载资源」时调用）。
    /// 返回是否成功发起/完成安装；失败时抛出真实错误。
    @discardableResult
    func requestMandarinAssetInstallation() async throws -> Bool {
        guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: Self.mandarinLocale) else {
            return false
        }
        _ = try await AssetInventory.reserve(locale: matched)
        let probe = SpeechTranscriber(locale: matched, preset: .timeIndexedProgressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) else {
            return true // 无需安装（可能已就绪）
        }
        try await request.downloadAndInstall()
        return true
    }

    // MARK: - 会话

    func startSession(contextualStrings: [String]) async throws {
        let alreadyRunning = lock.withLock { running }
        guard !alreadyRunning else { throw LocalTranscriptionError.sessionAlreadyRunning }

        // 启动前再次确认可用性：不满足则带真实原因失败（不静默切换）
        let availability = await checkMandarinAvailability()
        guard availability.isReady else {
            throw LocalTranscriptionError.notReady(availability.issues)
        }

        let transcriber = SpeechTranscriber(
            locale: Self.mandarinLocale,
            preset: .timeIndexedProgressiveTranscription
        )
        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            // 专业词汇与参会人姓名：仅用于改善识别上下文，不改写原意
            context.contextualStrings = [.general: contextualStrings]
        }

        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation!
        let inputStream = AsyncStream<AnalyzerInput> { inputContinuation = $0 }

        // init(inputSequence:) 会立即开始消费输入序列
        let analyzer = SpeechAnalyzer(
            inputSequence: inputStream,
            modules: [transcriber],
            analysisContext: context
        )

        lock.withLock {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.inputContinuation = inputContinuation
            self.converter = nil
            self.targetFormat = nil
            self.running = true
        }

        // 收集转写结果 → LocalTranscriptResult 流
        collectorTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    guard result.range.isValid,
                          result.range.start.isNumeric,
                          result.range.duration.isNumeric else {
                        continue
                    }
                    let startSeconds = result.range.start.seconds
                    let endSeconds = startSeconds + result.range.duration.seconds
                    let text = String(result.text.characters)
                    self.resultsContinuation?.yield(
                        LocalTranscriptResult(
                            startAudioMs: Int64(startSeconds * 1000),
                            endAudioMs: Int64(endSeconds * 1000),
                            text: text,
                            isFinal: result.isFinal
                        )
                    )
                }
            } catch {
                // 结果流异常：只记录脱敏错误类型
                AppLog.transcription.error("\(LogSanitizer.formatEvent("transcriber_results_failed", error: String(describing: type(of: error))))")
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) async {
        guard let input = lock.withLock({ inputContinuation }) else { return }

        // 首个缓冲到达时确定目标格式并按需建立转换器
        if lock.withLock({ targetFormat == nil }),
           let transcriber = lock.withLock({ self.transcriber }),
           let best = await SpeechAnalyzer.bestAvailableAudioFormat(
               compatibleWith: [transcriber],
               considering: buffer.format
           ) {
            lock.withLock {
                self.targetFormat = best
                if best != buffer.format {
                    self.converter = AVAudioConverter(from: buffer.format, to: best)
                }
            }
        }

        let (target, activeConverter) = lock.withLock { (targetFormat, converter) }
        var outputBuffer = buffer
        if let target, target != buffer.format {
            guard let activeConverter,
                  let converted = Self.convert(buffer, using: activeConverter) else {
                return
            }
            outputBuffer = converted
        }
        input.yield(AnalyzerInput(buffer: outputBuffer))
    }

    /// 格式转换（采集硬件格式 → 分析所需格式）
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let targetFormat = converter.outputFormat
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        // 输入回调为 @Sendable 闭包：用 Sendable 盒子持有缓冲与消费标记，避免直接捕获
        let inputBox = ConversionInputBox(buffer: buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, outStatus in
            if inputBox.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputBox.consumed = true
            outStatus.pointee = .haveData
            return inputBox.buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// AVAudioConverter 输入回调的 Sendable 盒子（实时音频路径专用）
    private final class ConversionInputBox: @unchecked Sendable {
        var consumed = false
        let buffer: AVAudioPCMBuffer
        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    func finishSession() async {
        let input = lock.withLock { inputContinuation }
        let analyzer = lock.withLock { self.analyzer }
        let collectTask = lock.withLock { collectorTask }
        input?.finish()
        // 输入流结束后让分析器收尾，结果流随之结束
        if let analyzer {
            try? await analyzer.finish(after: CMTime.positiveInfinity)
        }
        if let collectTask {
            await collectTask.value
        }
        cleanup()
    }

    func cancelSession() async {
        let analyzer = lock.withLock { self.analyzer }
        await analyzer?.cancelAndFinishNow()
        cleanup()
    }

    private func cleanup() {
        lock.withLock {
            inputContinuation = nil
            analyzer = nil
            transcriber = nil
            converter = nil
            targetFormat = nil
            collectorTask = nil
            running = false
        }
    }
}
