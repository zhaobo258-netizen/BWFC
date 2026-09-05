import Foundation
import AVFoundation

/// 导入文件的整篇转写执行器（阶段 C）：
/// 读取提取好的 PCM 音频文件，按块喂入 LocalTranscriptionServicing，
/// 结果流经 TranscriptReconciler 合并去重，只保留最终片段。
///
/// 与实时链路的差异：没有暂停区间（时间轴 = 音频时间轴），
/// 不发布临时片段（无实时 UI 跟读需求），进度按已读帧数报告。
/// 复用纪律：与 LocalTranscriptionController 相同的 reconciler 纯逻辑，
/// 保证导入与实时两条链路的去重口径一致。
struct FileTranscriptionRunner: Sendable {
    struct Failure: Error {
        var cause: LocalTranscriptionError
        var partialResults: [LocalTranscriptResult]
    }
    /// 每次喂入的帧块大小（约 0.68 秒 @48kHz；与实时采集缓冲同数量级）
    static let chunkFrameCount: AVAudioFrameCount = 32_768

    let service: any LocalTranscriptionServicing
    var readAudio: @Sendable (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void = {
        try $0.read(into: $1, frameCount: $2)
    }

    /// 执行整篇转写。
    /// - Parameters:
    ///   - audioURL: 提取好的 PCM 音频（Meetings/<id>/recording.caf）
    ///   - contextualStrings: 上下文词汇（仅改善识别，不改写原意）
    ///   - onProgress: 喂入进度（0…1，按帧数；模型尾部产出不计入）
    /// - Returns: 最终片段（时间升序，state=final，source=local，说话人未定）
    func run(audioURL: URL,
             contextualStrings: [String] = [],
             onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TranscriptSegment] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            throw AudioImportError.undecodable
        }
        let totalFrames = file.length
        guard totalFrames > 0 else { throw AudioImportError.zeroDuration }

        try await service.startSession(contextualStrings: contextualStrings)

        // 结果收集与喂入并行：喂完 finishSession 后流自然结束。
        // 收集器只存 Sendable 的原始结果；reconciler 在流结束后统一套用（同一线程，无竞争）
        let collector = ResultBox()
        let collectTask = Task {
            for await result in service.results where result.isFinal {
                await collector.append(result)
            }
        }

        do {
            try await withTaskCancellationHandler {
                let format = file.processingFormat
                var framesRead: AVAudioFramePosition = 0
                while framesRead < totalFrames {
                    try Task.checkCancellation()
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: Self.chunkFrameCount
                    ) else {
                        throw AudioImportError.extractionFailed
                    }
                    try readAudio(file, buffer, buffer.frameCapacity)
                    guard buffer.frameLength > 0 else {
                        throw AudioImportError.undecodable
                    }
                    framesRead += AVAudioFramePosition(buffer.frameLength)
                    await service.feed(buffer)
                    if let error = service.sessionError { throw error }
                    onProgress(
                        min(Double(framesRead) / Double(totalFrames), 1.0)
                    )
                }
                await service.finishSession()
                _ = await collectTask.value
                try Task.checkCancellation()
                if let error = service.sessionError { throw error }
            } onCancel: {
                collectTask.cancel()
                Task {
                    await service.cancelSession()
                }
            }
        } catch is CancellationError {
            collectTask.cancel()
            _ = await collectTask.value
            throw CancellationError()
        } catch {
            await service.cancelSession()
            collectTask.cancel()
            _ = await collectTask.value
            if let error = error as? LocalTranscriptionError {
                throw Failure(cause: error, partialResults: await collector.all())
            }
            throw error
        }

        onProgress(1.0)

        return Self.reconciledSegments(from: await collector.all())
    }

    static func reconciledSegments(from results: [LocalTranscriptResult]) -> [TranscriptSegment] {
        var reconciler = TranscriptReconciler()
        var segments: [TranscriptSegment] = []
        for result in results {
            let outcome = reconciler.applyFinal(
                startMs: result.startAudioMs,
                endMs: result.endAudioMs,
                text: result.text
            )
            if case .inserted(let segment) = outcome {
                segments.append(segment)
            }
        }
        return segments.sorted { $0.startMs < $1.startMs }
    }

    /// 最终结果暂存（actor 隔离，避免与喂入任务的数据竞争；只存 Sendable 值）
    private actor ResultBox {
        private var finals: [LocalTranscriptResult] = []

        func append(_ result: LocalTranscriptResult) {
            finals.append(result)
        }

        func all() -> [LocalTranscriptResult] {
            finals
        }
    }
}
