import Foundation

/// 本地分人引擎（sherpa-onnx 独立进程）的 `DiarizationServicing` 实现。
/// v1 只做整场识别（`transcribeRecording`）；会中 20 秒分片由
/// `DiarizationController.isProviderConfigured` 保持未配置态，不进入队列。
/// 合同：仓库父目录 13/14 号文档（20260913）。
struct LocalSherpaDiarizationService: DiarizationServicing {
    private let configuration: LocalSherpaSupport.EngineConfiguration

    init(configuration: LocalSherpaSupport.EngineConfiguration) {
        self.configuration = configuration
    }

    var knownSpeakerMatchingCapability: KnownSpeakerMatchingCapability {
        .supported(maximumSpeakers: KnownSpeakerReference.maximumCount)
    }

    var recordingLimits: DiarizationRecordingLimits? {
        DiarizationRecordingLimits(
            maximumBytes: LocalSherpaSupport.maximumBytes,
            maximumDurationMs: LocalSherpaSupport.maximumDurationMs
        )
    }

    func transcribeRecording(
        at audioURL: URL,
        knownSpeakers: [KnownSpeakerReference]
    ) async throws -> DiarizationChunkResult {
        guard knownSpeakers.count <= KnownSpeakerReference.maximumCount else {
            throw DiarizationAPIError.tooManyKnownSpeakers(
                maximum: KnownSpeakerReference.maximumCount,
                actual: knownSpeakers.count
            )
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.engineURL.path) else {
            throw LocalSherpaEngineError.engineNotExecutable(path: configuration.engineURL.path).apiError
        }
        let status = LocalSherpaSupport.modelsStatus(modelsDirectory: configuration.modelsDirectory)
        if case .notInstalled(let missing) = status {
            throw LocalSherpaSupport.makeAPIError(code: "model_missing", message: missing.joined(separator: "、"))
        }
        if case .invalid(let reason) = status {
            throw LocalSherpaSupport.makeAPIError(code: "model_invalid", message: reason)
        }

        let workDirectory = FileManager.default.temporaryDirectory.appending(
            path: "帮我分析 本地分人 % \(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        var arguments = [
            "--mode", "diarize",
            "--models", configuration.modelsDirectory.path,
            "--wav", audioURL.path,
            "--quiet",
        ]
        if !knownSpeakers.isEmpty {
            let referencesURL = workDirectory.appending(path: "references.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let dto = knownSpeakers.map { ReferenceDTO(alias: $0.alias, wav: $0.sampleURL.path) }
            try encoder.encode(dto).write(to: referencesURL, options: .atomic)
            arguments += ["--references", referencesURL.path]
        }

        let execution = try await EngineProcess.run(
            executableURL: configuration.engineURL,
            arguments: arguments
        )
        if let errorLine = LocalSherpaSupport.parseErrorLine(execution.stderr) {
            throw LocalSherpaSupport.makeAPIError(code: errorLine.code, message: errorLine.message)
        }
        guard execution.status == 0 else {
            throw LocalSherpaEngineError.engineError(
                code: "internal", message: "本地分人引擎异常退出（\(execution.status)）"
            ).apiError
        }
        let output = try LocalSherpaSupport.parseOutput(execution.stdout)
        return LocalSherpaSupport.makeChunkResult(output)
    }

    func transcribeChunk(
        at chunkURL: URL,
        knownSpeakers: [KnownSpeakerReference]
    ) async throws -> DiarizationChunkResult {
        // v1 产品决策：本地引擎不做会中分片；该分支仅作为兜底，
        // 正常路径由 DiarizationController 的未配置门禁拦截。
        throw DiarizationAPIError.providerError(
            code: "live_unsupported",
            message: "本地引擎只支持整场识别，不支持会中分片。"
        )
    }

    /// 设置页"检测模型"：加载级自检（selfcheck），只返回可用/不可用。
    func testConnection() async throws -> Bool {
        guard FileManager.default.isExecutableFile(atPath: configuration.engineURL.path) else {
            throw LocalSherpaEngineError.engineNotExecutable(path: configuration.engineURL.path).apiError
        }
        let execution = try await EngineProcess.run(
            executableURL: configuration.engineURL,
            arguments: ["--mode", "selfcheck", "--models", configuration.modelsDirectory.path, "--quiet"]
        )
        if let errorLine = LocalSherpaSupport.parseErrorLine(execution.stderr) {
            throw LocalSherpaSupport.makeAPIError(code: errorLine.code, message: errorLine.message)
        }
        guard execution.status == 0 else {
            throw LocalSherpaEngineError.engineError(
                code: "internal", message: "本地分人引擎异常退出（\(execution.status)）"
            ).apiError
        }
        _ = try LocalSherpaSupport.parseOutput(execution.stdout)
        return true
    }
}

extension LocalSherpaDiarizationService {
    struct ReferenceDTO: Codable, Sendable {
        var alias: String
        var wav: String
    }
}

/// 引擎子进程执行：后台队列阻塞执行、捕获 stdout/stderr、取消即终止子进程。
/// Swift 6 并发下通过锁盒共享非 Sendable 的 Foundation 进程对象。
private final class EngineProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var didCancel = false

    static func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> (stdout: Data, stderr: String, status: Int32) {
        let run = EngineProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queue = DispatchQueue(label: "bwfx.localdiarization.engine", qos: .userInitiated)
                queue.async {
                    if run.cancelled() {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let process = Process()
                    process.executableURL = executableURL
                    process.arguments = arguments
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    run.setProcess(process)
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: LocalSherpaEngineError.engineNotExecutable(
                            path: executableURL.path
                        ))
                        return
                    }
                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if run.cancelled() || process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: (
                        stdoutData,
                        String(data: stderrData, encoding: .utf8) ?? "",
                        process.terminationStatus
                    ))
                }
            }
        } onCancel: {
            run.cancelActive()
        }
    }

    private func setProcess(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    private func cancelActive() {
        lock.lock()
        didCancel = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func cancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
    }
}
