import Foundation

/// 本地分人引擎（sherpa-onnx 独立进程）的定位、模型状态、JSON 合同与错误映射。
/// 纯逻辑 + 文件检查，不启动进程；进程执行在 `LocalSherpaDiarizationService`。
/// 产品与实施合同：仓库父目录 13/14 号文档（20260913）。
enum LocalSherpaSupport {
    static let engineBinaryName = "bangwo-local-diarization"
    /// v1 合同上限：2 小时（引擎侧同样护栏，超限报 too_long）。
    static let maximumDurationMs: Int64 = 7_200_000
    /// 16kHz 单声道 Int16 = 32 字节/毫秒 + 容器余量。
    static var maximumBytes: Int64 { maximumDurationMs * 32 + 4_096 }

    // MARK: - 定位

    struct EngineConfiguration: Equatable, Sendable {
        var engineURL: URL
        var modelsDirectory: URL
    }

    /// 默认模型目录：Application Support/帮我分析/LocalDiarizationModels（模型不入 Vault、不入仓库）。
    static func defaultModelsDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appending(path: "帮我分析", directoryHint: .isDirectory)
            .appending(path: "LocalDiarizationModels", directoryHint: .isDirectory)
    }

    /// 引擎默认与 .app 同目录（make_app.sh 放入 Contents/MacOS）。
    /// 未找到时仍返回配置——由服务在执行时给出明确的 engine_missing 错误。
    static func defaultConfiguration(bundle: Bundle = .main) -> EngineConfiguration {
        let directory = bundle.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: "/Applications/帮我分析.app/Contents/MacOS")
        return EngineConfiguration(
            engineURL: directory.appending(path: engineBinaryName, directoryHint: .notDirectory),
            modelsDirectory: defaultModelsDirectory()
        )
    }

    // MARK: - 模型状态（设置页与工作台门禁共用；只做文件检查，不启动进程）

    enum ModelsStatus: Equatable, Sendable {
        /// 未下载：missing 为给人看的缺失清单
        case notInstalled(missing: [String])
        case ready(segmentationPath: String, embeddingPath: String)
        case invalid(reason: String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    static func modelsStatus(
        modelsDirectory: URL,
        fileManager: FileManager = .default
    ) -> ModelsStatus {
        let segmentationCandidates = [
            "sherpa-onnx-pyannote-segmentation-3-0/model.onnx",
            "segmentation-3-0/model.onnx",
        ]
        let embeddingCandidates = [
            "campplus-3dspeaker/model.onnx",
            "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx",
        ]
        let segmentation = segmentationCandidates.first {
            fileManager.fileExists(atPath: modelsDirectory.appending(path: $0).path)
        }
        let embedding = embeddingCandidates.first {
            fileManager.fileExists(atPath: modelsDirectory.appending(path: $0).path)
        }
        var missing: [String] = []
        if segmentation == nil { missing.append(segCandidatesDescription) }
        if embedding == nil { missing.append(embeddingCandidatesDescription) }
        if let segmentation, let embedding {
            return .ready(
                segmentationPath: modelsDirectory.appending(path: segmentation).path,
                embeddingPath: modelsDirectory.appending(path: embedding).path
            )
        }
        return missing.count == 2
            ? .notInstalled(missing: missing)
            : .invalid(reason: "模型目录缺少 \(missing.joined(separator: "、"))，请重新按指引放置。")
    }

    static var segCandidatesDescription: String {
        "分人模型（sherpa-onnx-pyannote-segmentation-3-0/model.onnx）"
    }

    static var embeddingCandidatesDescription: String {
        "声纹模型（campplus-3dspeaker/model.onnx）"
    }

    // MARK: - stdout JSON 合同

    struct Output: Decodable, Equatable, Sendable {
        var durationMs: Int
        var segments: [Segment]
        var engine: EngineInfo

        struct Segment: Decodable, Equatable, Sendable {
            var startMs: Int
            var endMs: Int
            var speakerLabel: String
            var clusterConfidence: Float?
            var matchAlias: String?
            var matchSimilarity: Float?
        }

        struct EngineInfo: Decodable, Equatable, Sendable {
            var clusters: Int
            var elapsedMs: Int
        }
    }

    static func parseOutput(_ data: Data) throws -> Output {
        do {
            let output = try JSONDecoder().decode(Output.self, from: data)
            guard output.durationMs >= 0 else { throw LocalSherpaEngineError.invalidOutput }
            for segment in output.segments {
                guard segment.startMs >= 0,
                      segment.endMs > segment.startMs,
                      !segment.speakerLabel.isEmpty else {
                    throw LocalSherpaEngineError.invalidOutput
                }
            }
            return output
        } catch let error as LocalSherpaEngineError {
            throw error
        } catch {
            throw LocalSherpaEngineError.invalidOutput
        }
    }

    static func makeChunkResult(_ output: Output) -> DiarizationChunkResult {
        DiarizationChunkResult(
            durationMs: Int64(output.durationMs),
            segments: output.segments.map { segment in
                DiarizationChunkResult.Segment(
                    startMs: Int64(segment.startMs),
                    endMs: Int64(segment.endMs),
                    text: "",
                    speakerLabel: segment.speakerLabel
                )
            }
        )
    }

    // MARK: - stderr 错误合同（`error|<code>|<message>`）

    static func parseErrorLine(_ stderr: String) -> (code: String, message: String)? {
        for line in stderr.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "error" else { continue }
            return (String(parts[1]), String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func makeAPIError(code: String, message: String) -> DiarizationAPIError {
        switch code {
        case "model_missing":
            return .providerError(
                code: code,
                message: "本地分人模型未下载。请到 设置 → 录音与说话人 → 本地（实验） 按指引下载模型。"
            )
        case "model_invalid":
            return .providerError(
                code: code,
                message: "本地分人模型损坏或版本不符，请删除后重新按指引下载。\(message)"
            )
        case "too_long":
            return .providerError(
                code: code,
                message: "录音超过本地引擎 2 小时上限，本次未做整场识别；原文与人工标注已保留。"
            )
        case "audio_unreadable":
            return .providerError(code: code, message: "本地引擎无法读取转换后的音频：\(message)")
        case "engine_missing":
            return .providerError(
                code: code,
                message: "本地分人引擎缺失，请重新安装应用后再试。"
            )
        default:
            return .providerError(code: code, message: message)
        }
    }
}

/// 引擎进程失败与输出违约的统一错误。
enum LocalSherpaEngineError: Error, Equatable, Sendable {
    case engineNotExecutable(path: String)
    case engineError(code: String, message: String)
    case invalidOutput
}

extension LocalSherpaEngineError {
    var apiError: DiarizationAPIError {
        switch self {
        case .engineNotExecutable(let path):
            return LocalSherpaSupport.makeAPIError(code: "engine_missing", message: path)
        case .engineError(let code, let message):
            return LocalSherpaSupport.makeAPIError(code: code, message: message)
        case .invalidOutput:
            return .invalidResponse
        }
    }
}
