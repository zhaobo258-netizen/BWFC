import Foundation
import Testing
@testable import BangWoFenXi

@Suite("本地分人引擎（sherpa-onnx）", .serialized)
final class LocalSherpaDiarizationTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-local-sherpa-tests % \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeStubEngine(in directory: URL) throws -> URL {
        let url = directory.appending(path: "stub-engine.sh")
        let body = """
        #!/bin/sh
        if [ -n "$DUMP_ARGS" ]; then printf '%s\\n' "$@" > "$DUMP_ARGS"; fi
        prev=""
        for a in "$@"; do
          if [ "$prev" = "--references" ] && [ -n "$STUB_REFS_OUT" ]; then cp "$a" "$STUB_REFS_OUT"; fi
          prev="$a"
        done
        case "$STUB_MODE" in
          error)
            echo "error|too_long|录音超过本地引擎 2 小时上限" >&2
            exit 6 ;;
          crash)
            echo "引擎段错误" >&2
            exit 3 ;;
          missing_model)
            echo "error|model_missing|未找到分人模型" >&2
            exit 3 ;;
        esac
        if [ -n "$STUB_JSON" ]; then cat "$STUB_JSON"; fi
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func writeJSON(_ text: String, to url: URL) throws -> URL {
        try text.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }

    private func makeReadyModelsDirectory() throws -> URL {
        let directory = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory.appending(path: "segmentation-3-0"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "campplus-3dspeaker"), withIntermediateDirectories: true)
        try Data("# dummy".utf8).write(
            to: directory.appending(path: "segmentation-3-0/model.onnx"), options: .atomic)
        try Data("# dummy".utf8).write(
            to: directory.appending(path: "campplus-3dspeaker/model.onnx"), options: .atomic)
        return directory
    }

    private func makeService(
        engineURL: URL,
        modelsDirectory: URL
    ) -> LocalSherpaDiarizationService {
        LocalSherpaDiarizationService(
            configuration: LocalSherpaSupport.EngineConfiguration(
                engineURL: engineURL,
                modelsDirectory: modelsDirectory
            )
        )
    }

    // MARK: - 模型状态

    @Test("模型三态：未下载 / 就绪 / 异常")
    func modelsStatusTriState() throws {
        let fileManager = FileManager.default
        let empty = try makeTemporaryDirectory()
        guard case .notInstalled(let missing) = LocalSherpaSupport.modelsStatus(modelsDirectory: empty) else {
            Issue.record("空目录应判定为未下载")
            return
        }
        #expect(missing.count == 2)

        let ready = try makeReadyModelsDirectory()
        guard case .ready(let segmentation, let embedding) = LocalSherpaSupport.modelsStatus(modelsDirectory: ready) else {
            Issue.record("完整目录应判定为就绪")
            return
        }
        #expect(fileManager.fileExists(atPath: segmentation))
        #expect(fileManager.fileExists(atPath: embedding))

        let partial = try makeTemporaryDirectory()
        try fileManager.createDirectory(
            at: partial.appending(path: "segmentation-3-0"), withIntermediateDirectories: true)
        try Data("# dummy".utf8).write(
            to: partial.appending(path: "segmentation-3-0/model.onnx"), options: .atomic)
        guard case .invalid = LocalSherpaSupport.modelsStatus(modelsDirectory: partial) else {
            Issue.record("只缺声纹模型应判定为异常")
            return
        }
    }

    // MARK: - stdout JSON 合同

    @Test("stdout 合同解析：别名/local 标签/证据字段")
    func parseOutputContract() throws {
        let json = """
        {
          "durationMs": 64163,
          "segments": [
            {"startMs": 30, "endMs": 5262, "speakerLabel": "p_01", "clusterConfidence": 0.88,
             "matchAlias": "p_01", "matchSimilarity": 0.97},
            {"startMs": 5262, "endMs": 9953, "speakerLabel": "local:1", "clusterConfidence": 0.83}
          ],
          "engine": {"mode": "diarize", "clusters": 2, "elapsedMs": 7602}
        }
        """
        let output = try LocalSherpaSupport.parseOutput(Data(json.utf8))
        #expect(output.durationMs == 64163)
        #expect(output.segments.count == 2)
        #expect(output.segments[0].speakerLabel == "p_01")
        #expect(output.segments[0].matchAlias == "p_01")
        #expect(output.segments[1].speakerLabel == "local:1")
        #expect(output.segments[1].matchAlias == nil)

        let result = LocalSherpaSupport.makeChunkResult(output)
        #expect(result.durationMs == 64163)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speakerLabel == "p_01")
        #expect(result.segments[0].startMs == 30)
        #expect(result.segments[1].text == "")
    }

    @Test("stdout 合同拒绝非法输出")
    func parseOutputRejectsInvalid() throws {
        #expect(throws: LocalSherpaEngineError.invalidOutput) {
            try LocalSherpaSupport.parseOutput(Data("不是 JSON".utf8))
        }
        let badTimeRange = """
        {"durationMs": 1, "segments": [{"startMs": 500, "endMs": 100, "speakerLabel": "p_01"}],
         "engine": {"clusters": 1, "elapsedMs": 1}}
        """
        #expect(throws: LocalSherpaEngineError.invalidOutput) {
            try LocalSherpaSupport.parseOutput(Data(badTimeRange.utf8))
        }
        let emptyLabel = """
        {"durationMs": 1, "segments": [{"startMs": 0, "endMs": 100, "speakerLabel": ""}],
         "engine": {"clusters": 1, "elapsedMs": 1}}
        """
        #expect(throws: LocalSherpaEngineError.invalidOutput) {
            try LocalSherpaSupport.parseOutput(Data(emptyLabel.utf8))
        }
    }

    // MARK: - 错误映射

    @Test("stderr 错误合同与 API 错误映射")
    func errorLineMapping() {
        let parsed = LocalSherpaSupport.parseErrorLine(
            "progress|50\nerror|model_missing|未找到分人模型\n")
        #expect(parsed?.code == "model_missing")

        guard case .providerError(let code, let message) =
            LocalSherpaSupport.makeAPIError(code: "model_missing", message: "x") else {
            Issue.record("model_missing 应映射为 providerError")
            return
        }
        #expect(code == "model_missing")
        #expect(message.contains("设置"))

        guard case .providerError(let tooLongCode, let tooLongMessage) =
            LocalSherpaSupport.makeAPIError(code: "too_long", message: "x") else {
            Issue.record("too_long 应映射为 providerError")
            return
        }
        #expect(tooLongCode == "too_long")
        #expect(tooLongMessage.contains("2 小时"))

        #expect(LocalSherpaSupport.parseErrorLine("progress|10\n") == nil)
    }

    // MARK: - 服务行为（stub 引擎端到端）

    @Test("整场识别成功：参数、refs.json 与结果标签")
    func transcribeRecordingSuccess() async throws {
        let work = try makeTemporaryDirectory()
        let cannedOutput = try writeJSON("""
        {"durationMs": 1000, "segments": [{"startMs": 0, "endMs": 900, "speakerLabel": "p_02"}],
         "engine": {"clusters": 1, "elapsedMs": 5}}
        """, to: work.appending(path: "out.json"))
        let engineURL = try writeStubEngine(in: work)
        let modelsDirectory = try makeReadyModelsDirectory()
        let sample = work.appending(path: "sample.wav")
        try Data("# wav".utf8).write(to: sample, options: .atomic)

        let dumpURL = work.appending(path: "args.txt")
        let refsCaptureURL = work.appending(path: "captured-references.json")
        // 通过注入环境变量指导 stub 行为：测试进程环境会被子进程继承。
        // refs.json 由服务在返回前清理，必须在引擎运行期间由 stub 复制出来。
        setenv("DUMP_ARGS", dumpURL.path, 1)
        setenv("STUB_JSON", cannedOutput.path, 1)
        setenv("STUB_MODE", "ok", 1)
        setenv("STUB_REFS_OUT", refsCaptureURL.path, 1)
        defer {
            unsetenv("DUMP_ARGS")
            unsetenv("STUB_JSON")
            unsetenv("STUB_MODE")
            unsetenv("STUB_REFS_OUT")
        }

        let service = makeService(engineURL: engineURL, modelsDirectory: modelsDirectory)
        let result = try await service.transcribeRecording(
            at: sample,
            knownSpeakers: [KnownSpeakerReference(alias: "p_02", sampleURL: sample)]
        )
        #expect(result.durationMs == 1000)
        #expect(result.segments.map(\.speakerLabel) == ["p_02"])

        let arguments = try String(contentsOf: dumpURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.contains("--mode"))
        #expect(arguments.contains("diarize"))
        #expect(arguments.contains(modelsDirectory.path))
        #expect(arguments.contains(sample.path))
        #expect(arguments.contains("--references"))
        #expect(FileManager.default.fileExists(atPath: refsCaptureURL.path))
        let references = try JSONDecoder().decode(
            [LocalSherpaDiarizationService.ReferenceDTO].self, from: Data(contentsOf: refsCaptureURL)
        )
        #expect(references.map { $0.alias } == ["p_02"])
        #expect(references.map { $0.wav } == [sample.path])
    }

    @Test("引擎错误码透传为 providerError")
    func transcribeRecordingEngineError() async throws {
        let work = try makeTemporaryDirectory()
        let engineURL = try writeStubEngine(in: work)
        let modelsDirectory = try makeReadyModelsDirectory()
        let sample = work.appending(path: "sample.wav")
        try Data("# wav".utf8).write(to: sample, options: .atomic)

        setenv("STUB_MODE", "error", 1)
        defer { unsetenv("STUB_MODE") }

        let service = makeService(engineURL: engineURL, modelsDirectory: modelsDirectory)
        do {
            _ = try await service.transcribeRecording(at: sample, knownSpeakers: [])
            Issue.record("stub error 模式应抛错")
        } catch let error as DiarizationAPIError {
            guard case .providerError(let code, _) = error else {
                Issue.record("应为 providerError，实际 \(error)")
                return
            }
            #expect(code == "too_long")
        }
    }

    @Test("引擎异常退出且无错误行时映射为 internal")
    func transcribeRecordingCrash() async throws {
        let work = try makeTemporaryDirectory()
        let engineURL = try writeStubEngine(in: work)
        let modelsDirectory = try makeReadyModelsDirectory()
        let sample = work.appending(path: "sample.wav")
        try Data("# wav".utf8).write(to: sample, options: .atomic)

        setenv("STUB_MODE", "crash", 1)
        defer { unsetenv("STUB_MODE") }

        let service = makeService(engineURL: engineURL, modelsDirectory: modelsDirectory)
        do {
            _ = try await service.transcribeRecording(at: sample, knownSpeakers: [])
            Issue.record("stub crash 模式应抛错")
        } catch let error as DiarizationAPIError {
            guard case .providerError(let code, let message) = error else {
                Issue.record("应为 providerError，实际 \(error)")
                return
            }
            #expect(code == "internal")
            #expect(message.contains("3"))
        }
    }

    @Test("模型未就绪时整场识别给出指引错误")
    func transcribeRecordingModelsMissing() async throws {
        let work = try makeTemporaryDirectory()
        let engineURL = try writeStubEngine(in: work)
        let emptyModels = try makeTemporaryDirectory()
        let sample = work.appending(path: "sample.wav")
        try Data("# wav".utf8).write(to: sample, options: .atomic)

        let service = makeService(engineURL: engineURL, modelsDirectory: emptyModels)
        do {
            _ = try await service.transcribeRecording(at: sample, knownSpeakers: [])
            Issue.record("模型缺失应抛错")
        } catch let error as DiarizationAPIError {
            guard case .providerError(let code, let message) = error else {
                Issue.record("应为 providerError，实际 \(error)")
                return
            }
            #expect(code == "model_missing")
            #expect(message.contains("设置"))
        }
    }

    @Test("引擎缺失时给出安装指引错误")
    func transcribeRecordingEngineMissing() async throws {
        let work = try makeTemporaryDirectory()
        let modelsDirectory = try makeReadyModelsDirectory()
        let sample = work.appending(path: "sample.wav")
        try Data("# wav".utf8).write(to: sample, options: .atomic)

        let service = makeService(
            engineURL: work.appending(path: "不存在的引擎"),
            modelsDirectory: modelsDirectory
        )
        do {
            _ = try await service.transcribeRecording(at: sample, knownSpeakers: [])
            Issue.record("引擎缺失应抛错")
        } catch let error as DiarizationAPIError {
            guard case .providerError(let code, _) = error else {
                Issue.record("应为 providerError，实际 \(error)")
                return
            }
            #expect(code == "engine_missing")
        }
    }

    @Test("会中分片被明确拒绝且超过 4 人显式报错")
    func chunkAndLimits() async throws {
        let work = try makeTemporaryDirectory()
        let engineURL = try writeStubEngine(in: work)
        let modelsDirectory = try makeReadyModelsDirectory()
        let service = makeService(engineURL: engineURL, modelsDirectory: modelsDirectory)

        do {
            _ = try await service.transcribeChunk(at: work.appending(path: "chunk.wav"), knownSpeakers: [])
            Issue.record("会中分片应被拒绝")
        } catch let error as DiarizationAPIError {
            guard case .providerError(let code, _) = error else {
                Issue.record("应为 providerError，实际 \(error)")
                return
            }
            #expect(code == "live_unsupported")
        }

        let limits = try #require(service.recordingLimits)
        #expect(limits.maximumDurationMs == LocalSherpaSupport.maximumDurationMs)
        #expect(limits.maximumBytes == LocalSherpaSupport.maximumBytes)

        let speakers = (0..<5).map {
            KnownSpeakerReference(alias: "p_0\($0)", sampleURL: work.appending(path: "\($0).wav"))
        }
        do {
            _ = try await service.transcribeRecording(at: work, knownSpeakers: speakers)
            Issue.record("超过 4 人应显式报错")
        } catch DiarizationAPIError.tooManyKnownSpeakers {
            // 预期路径
        }
    }

    @Test("selfcheck：stub 成功返回 true，错误码抛出")
    func testConnectionWithStub() async throws {
        let work = try makeTemporaryDirectory()
        let engineURL = try writeStubEngine(in: work)
        let modelsDirectory = try makeReadyModelsDirectory()
        let cannedOutput = try writeJSON("""
        {"durationMs": 0, "segments": [], "engine": {"mode": "selfcheck", "clusters": 0, "elapsedMs": 1}}
        """, to: work.appending(path: "selfcheck.json"))
        let service = makeService(engineURL: engineURL, modelsDirectory: modelsDirectory)

        setenv("STUB_JSON", cannedOutput.path, 1)
        defer { unsetenv("STUB_JSON") }
        #expect(try await service.testConnection())

        setenv("STUB_MODE", "missing_model", 1)
        defer { unsetenv("STUB_MODE") }
        do {
            _ = try await service.testConnection()
            Issue.record("missing_model 模式应抛错")
        } catch let error as DiarizationAPIError {
            guard case .providerError(let code, _) = error else {
                Issue.record("应为 providerError，实际 \(error)")
                return
            }
            #expect(code == "model_missing")
        }
    }

    // MARK: - Provider 配置与工厂

    @Test("本地 provider：显示名、旧配置解码兼容与工厂构造")
    func providerConfigurationCompatibility() throws {
        #expect(DiarizationProvider.localSherpaOnnx.displayName == "本地（实验）")

        // 旧版本写入的 JSON（无新枚举值）必须继续解码
        let legacy = Data("{\"selectedProvider\":\"openAICompatible\"}".utf8)
        let decoded = try JSONDecoder().decode(DiarizationProviderConfiguration.self, from: legacy)
        #expect(decoded.selectedProvider == .openAICompatible)

        let roundTrip = try JSONEncoder().encode(
            DiarizationProviderConfiguration(selectedProvider: .localSherpaOnnx))
        let restored = try JSONDecoder().decode(DiarizationProviderConfiguration.self, from: roundTrip)
        #expect(restored.selectedProvider == .localSherpaOnnx)
        #expect(restored.isValid)

        let service = DiarizationServiceFactory.make(
            configuration: DiarizationProviderConfiguration(selectedProvider: .localSherpaOnnx),
            localEngineConfiguration: LocalSherpaSupport.EngineConfiguration(
                engineURL: URL(fileURLWithPath: "/tmp/engine"),
                modelsDirectory: URL(fileURLWithPath: "/tmp/models")
            )
        )
        #expect(service is LocalSherpaDiarizationService)
    }
}
