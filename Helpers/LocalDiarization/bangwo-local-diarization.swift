// bangwo-local-diarization — 《帮我分析》本地分人/认人引擎（评测版 v0.1）
// 依赖 sherpa-onnx v1.13.8 no-tts 共享库（C API），Apache-2.0。
// 合同见 ../14_帮我分析_本地分人认人_技术开发文档_20260913.md §3.1。
import Foundation

// MARK: - 错误合同

enum EngineError: String {
    case usage = "usage"
    case modelMissing = "model_missing"
    case modelInvalid = "model_invalid"
    case audioUnreadable = "audio_unreadable"
    case tooLong = "too_long"
    case internalError = "internal"

    var exitCode: Int32 {
        switch self {
        case .usage: return 2
        case .modelMissing: return 3
        case .modelInvalid: return 4
        case .audioUnreadable: return 5
        case .tooLong: return 6
        case .internalError: return 1
        }
    }
}

func fail(_ code: EngineError, _ message: String) -> Never {
    FileHandle.standardError.write(Data("error|\(code.rawValue)|\(message)\n".utf8))
    exit(code.exitCode)
}

// MARK: - 参数

struct Reference {
    var alias: String
    var wav: String
}

struct Arguments {
    var mode = ""
    var wav = ""
    var modelsDir = ""
    var references: [Reference] = []
    var threshold: Float = 0.5
    var numSpeakers = 0
    var clusterThreshold: Float = 0.5
    var maxDurationMs: Int64 = 7_200_000
    var quiet = false
}

func parseArguments() -> Arguments {
    var args = Arguments()
    var rest = Array(CommandLine.arguments.dropFirst())[...]
    func value(_ flag: String) -> String {
        guard let v = rest.first else { fail(.usage, "缺少 \(flag) 的值") }
        rest = rest.dropFirst()
        return v
    }
    while let flag = rest.first {
        rest = rest.dropFirst()
        switch flag {
        case "--mode": args.mode = value(flag)
        case "--wav": args.wav = value(flag)
        case "--models": args.modelsDir = value(flag)
        case "--references":
            let path = value(flag)
            struct DTO: Decodable { var alias: String; var wav: String }
            guard let data = FileManager.default.contents(atPath: path) else {
                fail(.usage, "无法读取 references 文件 \(path)")
            }
            do {
                args.references = try JSONDecoder().decode([DTO].self, from: data)
                    .map { Reference(alias: $0.alias, wav: $0.wav) }
            } catch {
                fail(.usage, "references 文件格式错误：\(error.localizedDescription)")
            }
        case "--threshold":
            guard let v = Float(value(flag)) else { fail(.usage, "--threshold 非法") }
            args.threshold = v
        case "--num-speakers":
            guard let v = Int(value(flag)) else { fail(.usage, "--num-speakers 非法") }
            args.numSpeakers = v
        case "--cluster-threshold":
            guard let v = Float(value(flag)) else { fail(.usage, "--cluster-threshold 非法") }
            args.clusterThreshold = v
        case "--max-duration-ms":
            guard let v = Int64(value(flag)) else { fail(.usage, "--max-duration-ms 非法") }
            args.maxDurationMs = v
        case "--quiet": args.quiet = true
        default: fail(.usage, "未知参数 \(flag)")
        }
    }
    return args
}

// MARK: - C API 薄封装

private func cstr(_ s: String) -> UnsafePointer<CChar>! { UnsafePointer(strdup(s)) }

struct Wave {
    var samples: [Float]
    var sampleRate: Int32
    var durationMs: Int64 { Int64(Double(samples.count) / Double(sampleRate) * 1000) }

    static func read(_ path: String) -> Wave {
        guard FileManager.default.fileExists(atPath: path) else {
            fail(.audioUnreadable, "文件不存在：\(path)")
        }
        guard let wave = SherpaOnnxReadWave(cstr(path)) else {
            fail(.audioUnreadable, "只支持单声道 16-bit PCM WAV：\(path)")
        }
        let samples = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
        let rate = wave.pointee.sample_rate
        SherpaOnnxFreeWave(wave)
        return Wave(samples: samples, sampleRate: rate)
    }
}

final class EmbeddingExtractor {
    private let pointer: OpaquePointer
    let dim: Int32

    init?(modelPath: String, numThreads: Int32 = 2) {
        var config = SherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: cstr(modelPath), num_threads: numThreads, debug: 0, provider: cstr("cpu"))
        guard let p = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config) else { return nil }
        pointer = p
        dim = SherpaOnnxSpeakerEmbeddingExtractorDim(p)
    }

    /// 对一段音频计算声纹向量。音频过短（<0.5 秒）返回 nil。
    func embedding(samples: [Float], sampleRate: Int32) -> [Float]? {
        embedding(in: samples, ranges: [0..<samples.count], sampleRate: sampleRate)
    }

    /// 按 slices 顺序把原始采样切片喂给同一条流（不做数组拼接拷贝）。
    /// 总时长超过 capSeconds 时只取靠前的片段（说话人向量不需要超长音频）。
    func embedding(in samples: [Float], ranges: [Range<Int>], sampleRate: Int32,
                   capSeconds: Int = 120) -> [Float]? {
        let cap = Int(sampleRate) * capSeconds
        var fed = 0
        let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(pointer)
        outer: for range in ranges {
            let clamped = range.clamped(to: 0..<samples.count)
            guard clamped.lowerBound < clamped.upperBound else { continue }
            let remaining = cap - fed
            if remaining <= 0 { break }
            let end = min(clamped.upperBound, clamped.lowerBound + remaining)
            samples.withUnsafeBufferPointer { buffer in
                SherpaOnnxOnlineStreamAcceptWaveform(
                    stream, sampleRate, buffer.baseAddress! + clamped.lowerBound, Int32(end - clamped.lowerBound))
            }
            fed += end - clamped.lowerBound
            if fed >= cap { break outer }
        }
        guard fed >= sampleRate / 2 else {
            SherpaOnnxDestroyOnlineStream(stream)
            return nil
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(pointer, stream) == 1 else {
            SherpaOnnxDestroyOnlineStream(stream)
            return nil
        }
        let raw = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(pointer, stream)
        let vector = Array(UnsafeBufferPointer(start: raw, count: Int(dim)))
        SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(raw)
        SherpaOnnxDestroyOnlineStream(stream)
        return vector
    }

    deinit {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(pointer)
    }
}

struct ModelPaths {
    var segmentation: String
    var embedding: String

    static func resolve(modelsDir: String) -> ModelPaths {
        let fm = FileManager.default
        let segCandidates = [
            modelsDir + "/segmentation-3-0/model.onnx",
            modelsDir + "/sherpa-onnx-pyannote-segmentation-3-0/model.onnx",
        ]
        guard let seg = segCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
            fail(.modelMissing, "未找到分人模型：\(segCandidates.joined(separator: " 或 "))")
        }
        let embCandidates = [
            modelsDir + "/campplus-3dspeaker/model.onnx",
            modelsDir + "/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx",
        ]
        guard let emb = embCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
            fail(.modelMissing, "未找到声纹模型：\(embCandidates.joined(separator: " 或 "))")
        }
        return ModelPaths(segmentation: seg, embedding: emb)
    }
}

final class DiarizationEngine {
    private let pointer: OpaquePointer
    let sampleRate: Int32

    init?(paths: ModelPaths, numSpeakers: Int, clusterThreshold: Float, numThreads: Int32 = 2) {
        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        config.segmentation.pyannote.model = cstr(paths.segmentation)
        config.segmentation.pyannote.window_shift_ratio = 0.1
        config.segmentation.num_threads = numThreads
        config.segmentation.provider = cstr("cpu")
        config.embedding.model = cstr(paths.embedding)
        config.embedding.num_threads = numThreads
        config.embedding.provider = cstr("cpu")
        config.clustering.num_clusters = Int32(numSpeakers)
        config.clustering.threshold = clusterThreshold
        config.clustering.compute_confidence = 1
        config.min_duration_on = 0.2
        config.min_duration_off = 0.2
        guard let p = SherpaOnnxCreateOfflineSpeakerDiarization(&config) else { return nil }
        pointer = p
        sampleRate = SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(p)
    }

    struct Segment {
        var startMs: Int
        var endMs: Int
        var cluster: Int32
        var confidence: Float
    }

    func process(samples: [Float], quiet: Bool) -> [Segment] {
        let callback: SherpaOnnxOfflineSpeakerDiarizationProgressCallbackNoArg = { done, total in
            if total > 0 {
                FileHandle.standardError.write(Data("progress|\(done * 100 / total)\n".utf8))
            }
            return 0
        }
        let result = samples.withUnsafeBufferPointer { buffer -> OpaquePointer? in
            if quiet {
                return SherpaOnnxOfflineSpeakerDiarizationProcess(pointer, buffer.baseAddress, Int32(samples.count))
            }
            return SherpaOnnxOfflineSpeakerDiarizationProcessWithCallbackNoArg(
                pointer, buffer.baseAddress, Int32(samples.count), callback)
        }
        guard let result else { return [] }
        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        let sorted = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result)
        var segments: [Segment] = []
        if let sorted {
            let typed = UnsafeRawPointer(sorted)!
                .assumingMemoryBound(to: SherpaOnnxOfflineSpeakerDiarizationSegment.self)
            for i in 0..<count {
                let s = typed[i]
                segments.append(Segment(
                    startMs: Int(s.start * 1000), endMs: Int(s.end * 1000),
                    cluster: s.speaker, confidence: s.confidence))
            }
            SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sorted)
        }
        SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result)
        return segments
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(pointer)
    }
}

// MARK: - 认人（注册 + 聚类级搜索）

struct ClusterMatch { var alias: String; var similarity: Float }

func matchClusters(
    _ segments: [DiarizationEngine.Segment],
    samples: [Float],
    sampleRate: Int32,
    extractor: EmbeddingExtractor,
    references: [Reference],
    threshold: Float
) -> [Int32: ClusterMatch] {
    guard !references.isEmpty else { return [:] }
    guard let manager = SherpaOnnxCreateSpeakerEmbeddingManager(extractor.dim) else { return [:] }
    defer { SherpaOnnxDestroySpeakerEmbeddingManager(manager) }

    for reference in references {
        let wave = Wave.read(reference.wav)
        guard wave.sampleRate == sampleRate else {
            fail(.audioUnreadable, "注册样本 \(reference.wav) 采样率 \(wave.sampleRate) ≠ \(sampleRate)")
        }
        guard let vector = extractor.embedding(samples: wave.samples, sampleRate: sampleRate) else {
            FileHandle.standardError.write(Data("warn|\(reference.alias) 注册样本过短，已跳过\n".utf8))
            continue
        }
        let ok = vector.withUnsafeBufferPointer { buffer in
            SherpaOnnxSpeakerEmbeddingManagerAdd(manager, cstr(reference.alias), buffer.baseAddress)
        }
        if ok != 1 {
            fail(.modelInvalid, "注册声纹失败：\(reference.alias)")
        }
    }

    var matches: [Int32: ClusterMatch] = [:]
    for cluster in Set(segments.map(\.cluster)).sorted() {
        // 聚类向量：按时间顺序把该聚类的片段切片直接喂给同一条流（不拼接整段数组），
        // 引擎内部封顶 120 秒，避免长会议下聚类级缓存放大内存。
        var ranges: [Range<Int>] = []
        for segment in segments where segment.cluster == cluster {
            let start = min(segment.startMs * Int(sampleRate) / 1000, samples.count)
            let end = min(segment.endMs * Int(sampleRate) / 1000, samples.count)
            guard start < end else { continue }
            ranges.append(start..<end)
        }
        guard let vector = extractor.embedding(in: samples, ranges: ranges, sampleRate: sampleRate) else { continue }
        let best = vector.withUnsafeBufferPointer { buffer in
            SherpaOnnxSpeakerEmbeddingManagerGetBestMatches(manager, buffer.baseAddress, threshold, 1)
        }
        if let best, best.pointee.count > 0 {
            let match = best.pointee.matches[0]
            matches[cluster] = ClusterMatch(alias: String(cString: match.name), similarity: match.score)
            SherpaOnnxSpeakerEmbeddingManagerFreeBestMatches(best)
        }
    }
    return matches
}

// MARK: - 输出

struct Output: Encodable {
    var durationMs: Int
    var segments: [SegmentDTO]
    var engine: EngineInfo

    struct SegmentDTO: Encodable {
        var startMs: Int
        var endMs: Int
        var speakerLabel: String
        var clusterConfidence: Float
        var matchAlias: String?
        var matchSimilarity: Float?
    }

    struct EngineInfo: Encodable {
        var mode: String
        var segmentationModel: String
        var embeddingModel: String
        var embeddingDim: Int?
        var clusters: Int
        var elapsedMs: Int
    }
}

enum JSONPrinter {
    static func print<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            fail(.internalError, "结果序列化失败")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// MARK: - 主流程

func run() {
    let args = parseArguments()
    guard ["selfcheck", "diarize", "embed"].contains(args.mode) else {
        fail(.usage, "--mode 必须是 selfcheck | diarize | embed")
    }
    let paths = ModelPaths.resolve(modelsDir: args.modelsDir)
    let startedAt = Date()

    switch args.mode {
    case "selfcheck":
        guard let engine = DiarizationEngine(paths: paths, numSpeakers: 2, clusterThreshold: args.clusterThreshold) else {
            fail(.modelInvalid, "分人模型存在但无法加载（文件损坏或版本不符）")
        }
        guard let extractor = EmbeddingExtractor(modelPath: paths.embedding) else {
            fail(.modelInvalid, "声纹模型无法加载")
        }
        JSONPrinter.print(Output(
            durationMs: 0, segments: [],
            engine: .init(mode: "selfcheck", segmentationModel: paths.segmentation,
                          embeddingModel: paths.embedding, embeddingDim: Int(extractor.dim),
                          clusters: 0, elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000))))
        _ = engine.sampleRate

    case "embed":
        let wave = Wave.read(args.wav)
        guard let extractor = EmbeddingExtractor(modelPath: paths.embedding) else {
            fail(.modelInvalid, "声纹模型无法加载")
        }
        guard let vector = extractor.embedding(samples: wave.samples, sampleRate: wave.sampleRate) else {
            fail(.audioUnreadable, "音频过短，无法计算声纹（至少 0.5 秒）")
        }
        struct EmbeddingOutput: Encodable { var dim: Int; var vector: [Float] }
        JSONPrinter.print(EmbeddingOutput(dim: Int(extractor.dim), vector: vector))

    case "diarize":
        let wave = Wave.read(args.wav)
        guard wave.sampleRate == 16000 else {
            fail(.audioUnreadable, "采样率必须为 16000Hz（当前 \(wave.sampleRate)），请先重采样")
        }
        guard wave.durationMs <= args.maxDurationMs else {
            fail(.tooLong, "音频 \(wave.durationMs)ms 超过引擎上限 \(args.maxDurationMs)ms")
        }
        guard let engine = DiarizationEngine(
            paths: paths, numSpeakers: args.numSpeakers,
            clusterThreshold: args.numSpeakers > 0 ? 0.5 : args.clusterThreshold) else {
            fail(.modelInvalid, "分人模型无法加载")
        }
        let segments = engine.process(samples: wave.samples, quiet: args.quiet)
        guard let extractor = EmbeddingExtractor(modelPath: paths.embedding) else {
            fail(.modelInvalid, "声纹模型无法加载")
        }
        let matches = matchClusters(segments, samples: wave.samples, sampleRate: engine.sampleRate,
                                    extractor: extractor, references: args.references,
                                    threshold: args.threshold)
        var localNumber: [Int32: Int] = [:]
        var output = Output(durationMs: Int(wave.durationMs), segments: [], engine: .init(
            mode: "diarize", segmentationModel: paths.segmentation,
            embeddingModel: paths.embedding, embeddingDim: Int(extractor.dim),
            clusters: Set(segments.map(\.cluster)).count,
            elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000)))
        for segment in segments {
            let match = matches[segment.cluster]
            let label: String
            if let match {
                label = match.alias
            } else {
                if localNumber[segment.cluster] == nil {
                    localNumber[segment.cluster] = localNumber.count + 1
                }
                label = "local:\(localNumber[segment.cluster]!)"
            }
            output.segments.append(.init(
                startMs: segment.startMs, endMs: segment.endMs,
                speakerLabel: label, clusterConfidence: segment.confidence,
                matchAlias: match?.alias, matchSimilarity: match?.similarity))
        }
        JSONPrinter.print(output)
    default:
        break
    }
}

run()
