import Foundation
import AVFoundation

/// 分片提取器：从完整录音文件中按音频时间窗口提取分片为 .wav。
/// 纯文件操作（无需硬件），可单测。
enum AudioChunkExtractor {
    struct Clip: Sendable, Equatable {
        var sourceURL: URL
        var startMs: Int64
        var endMs: Int64
    }

    /// 提取错误
    enum ExtractError: Error, Equatable {
        case sourceMissing
        case emptyWindow
        case incompatibleFormat
    }

    /// 提取 [startMs, endMs) 音频窗口到目标文件（超出源时长的部分自动截断）。
    /// - Parameters:
    ///   - sourceURL: 完整录音文件（.caf PCM）
    ///   - startMs/endMs: 音频流时间窗口（毫秒）
    ///   - destinationURL: 输出 .wav 文件
    /// - Returns: 实际写出的帧数
    @discardableResult
    static func extract(
        from sourceURL: URL,
        startMs: Int64,
        endMs: Int64,
        to destinationURL: URL
    ) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ExtractError.sourceMissing
        }
        guard endMs > startMs else {
            throw ExtractError.emptyWindow
        }

        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        let sampleRate = format.sampleRate

        let startFrame = Int64(Double(startMs) / 1000 * sampleRate)
        let endFrame = min(Int64(Double(endMs) / 1000 * sampleRate), source.length)
        let frameCount = endFrame - startFrame
        guard frameCount > 0 else {
            throw ExtractError.emptyWindow
        }

        source.framePosition = startFrame
        // 单次 read 可能被底层限量：循环读取直到凑满或 EOF
        guard let output = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw ExtractError.emptyWindow
        }
        guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw ExtractError.emptyWindow
        }
        let channels = Int(format.channelCount)
        var totalRead = 0
        while totalRead < Int(frameCount) {
            let want = min(16_384, Int(frameCount) - totalRead)
            do {
                try source.read(into: scratch, frameCount: AVAudioFrameCount(want))
            } catch {
                break
            }
            let got = Int(scratch.frameLength)
            if got == 0 { break }
            if let src = scratch.floatChannelData, let dst = output.floatChannelData {
                for channel in 0..<channels {
                    memcpy(dst[channel] + totalRead, src[channel], got * MemoryLayout<Float>.stride)
                }
            } else if let src = scratch.int16ChannelData, let dst = output.int16ChannelData {
                for channel in 0..<channels {
                    memcpy(dst[channel] + totalRead, src[channel], got * MemoryLayout<Int16>.stride)
                }
            }
            totalRead += got
        }
        guard totalRead > 0 else {
            throw ExtractError.emptyWindow
        }
        output.frameLength = AVAudioFrameCount(totalRead)

        // 输出为 .wav（云端接口通用格式；保持源 PCM 参数）
        let destination = try AVAudioFile(
            forWriting: destinationURL,
            settings: AudioRecordingSettings.fileSettings(for: format)
        )
        try destination.write(from: output)
        return Int64(totalRead)
    }

    /// 把多段已人工确认的单人发言按顺序拼成一份 WAV 声纹样本。
    /// 输入必须是同一录音链路产生的 PCM 格式；不兼容时明确失败，避免静默转码污染声纹。
    @discardableResult
    static func concatenate(clips: [Clip], to destinationURL: URL) throws -> Int64 {
        guard let firstClip = clips.first else { throw ExtractError.emptyWindow }
        for clip in clips {
            guard clip.endMs > clip.startMs,
                  FileManager.default.fileExists(atPath: clip.sourceURL.path) else {
                throw FileManager.default.fileExists(atPath: clip.sourceURL.path)
                    ? ExtractError.emptyWindow
                    : ExtractError.sourceMissing
            }
        }

        let first = try AVAudioFile(forReading: firstClip.sourceURL)
        let outputFormat = first.processingFormat
        let files = try clips.map { try AVAudioFile(forReading: $0.sourceURL) }
        guard files.allSatisfy({ compatible($0.processingFormat, outputFormat) }) else {
            throw ExtractError.incompatibleFormat
        }

        let requestedFrames = zip(clips, files).reduce(Int64(0)) { total, pair in
            let (clip, file) = pair
            let start = Int64(Double(clip.startMs) / 1_000 * outputFormat.sampleRate)
            let end = min(
                Int64(Double(clip.endMs) / 1_000 * outputFormat.sampleRate),
                file.length
            )
            return total + max(0, end - start)
        }
        guard requestedFrames > 0,
              requestedFrames <= Int64(AVAudioFrameCount.max),
              let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(requestedFrames)
              ),
              let scratch = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 16_384
              ) else {
            throw ExtractError.emptyWindow
        }

        let channels = Int(outputFormat.channelCount)
        var totalRead = 0
        for (clip, file) in zip(clips, files) {
            let startFrame = Int64(Double(clip.startMs) / 1_000 * outputFormat.sampleRate)
            let endFrame = min(
                Int64(Double(clip.endMs) / 1_000 * outputFormat.sampleRate),
                file.length
            )
            var remaining = max(0, Int(endFrame - startFrame))
            guard remaining > 0 else { continue }
            file.framePosition = startFrame
            while remaining > 0 {
                let wanted = min(16_384, remaining)
                scratch.frameLength = 0
                try file.read(into: scratch, frameCount: AVAudioFrameCount(wanted))
                let got = Int(scratch.frameLength)
                guard got > 0 else { break }
                if let source = scratch.floatChannelData,
                   let destination = output.floatChannelData {
                    for channel in 0..<channels {
                        memcpy(
                            destination[channel] + totalRead,
                            source[channel],
                            got * MemoryLayout<Float>.stride
                        )
                    }
                } else if let source = scratch.int16ChannelData,
                          let destination = output.int16ChannelData {
                    for channel in 0..<channels {
                        memcpy(
                            destination[channel] + totalRead,
                            source[channel],
                            got * MemoryLayout<Int16>.stride
                        )
                    }
                } else {
                    throw ExtractError.incompatibleFormat
                }
                totalRead += got
                remaining -= got
            }
        }
        guard totalRead > 0 else { throw ExtractError.emptyWindow }
        output.frameLength = AVAudioFrameCount(totalRead)
        let destination = try AVAudioFile(
            forWriting: destinationURL,
            settings: AudioRecordingSettings.fileSettings(for: outputFormat)
        )
        try destination.write(from: output)
        return Int64(totalRead)
    }

    /// 转换为讯飞声纹和实时语音接口的标准 WAV：16kHz、16bit、单声道 PCM。
    @discardableResult
    static func convertToIFlytekVoiceprintWAV(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ExtractError.sourceMissing
        }
        let source = try AVAudioFile(forReading: sourceURL)
        guard source.length > 0,
              source.length <= Int64(AVAudioFrameCount.max),
              let input = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat,
                frameCapacity: AVAudioFrameCount(source.length)
              ),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
              ),
              let inputChannels = input.floatChannelData,
              let scratch = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat,
                frameCapacity: 16_384
              ) else {
            throw ExtractError.incompatibleFormat
        }
        let channelCount = Int(source.processingFormat.channelCount)
        var totalRead = 0
        while totalRead < Int(source.length) {
            let wanted = min(16_384, Int(source.length) - totalRead)
            scratch.frameLength = 0
            try source.read(into: scratch, frameCount: AVAudioFrameCount(wanted))
            let received = Int(scratch.frameLength)
            guard received > 0, let scratchChannels = scratch.floatChannelData else { break }
            for channel in 0..<channelCount {
                memcpy(
                    inputChannels[channel] + totalRead,
                    scratchChannels[channel],
                    received * MemoryLayout<Float>.stride
                )
            }
            totalRead += received
        }
        input.frameLength = AVAudioFrameCount(totalRead)
        guard totalRead > 0, source.processingFormat.sampleRate > 0 else {
            throw ExtractError.incompatibleFormat
        }

        let inputFrameCount = totalRead
        let sourceRate = source.processingFormat.sampleRate
        let outputFrameCount = Int(
            (Double(inputFrameCount) * outputFormat.sampleRate / sourceRate).rounded()
        )
        guard outputFrameCount > 0,
              outputFrameCount <= Int(AVAudioFrameCount.max),
              let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(outputFrameCount)
              ),
              let destinationSamples = output.int16ChannelData?.pointee else {
            throw ExtractError.incompatibleFormat
        }

        let sourceStep = sourceRate / outputFormat.sampleRate
        for outputIndex in 0..<outputFrameCount {
            let sourcePosition = min(
                Double(outputIndex) * sourceStep,
                Double(inputFrameCount - 1)
            )
            let lowerIndex = Int(sourcePosition)
            let upperIndex = min(lowerIndex + 1, inputFrameCount - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            var monoSample: Float = 0
            for channel in 0..<channelCount {
                let lower = inputChannels[channel][lowerIndex]
                let upper = inputChannels[channel][upperIndex]
                monoSample += lower + (upper - lower) * fraction
            }
            monoSample /= Float(channelCount)
            destinationSamples[outputIndex] = Int16(
                (max(-1, min(1, monoSample)) * Float(Int16.max)).rounded()
            )
        }
        output.frameLength = AVAudioFrameCount(outputFrameCount)
        let destination = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try destination.write(from: output)
        return Int64(outputFrameCount)
    }

    static func exportRecordingWAV(from sourceURL: URL, to destinationURL: URL) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        guard source.length > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_384),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw ExtractError.incompatibleFormat
        }
        let destination = try AVAudioFile(forWriting: destinationURL, settings: format.settings,
                                          commonFormat: .pcmFormatInt16, interleaved: true)
        let reader = RecordingConversionInput(source: source, input: input)
        var written: Int64 = 0
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                reader.read(requested: requested, status: inputStatus)
            }
            if let readError = reader.failure { throw readError }
            if let conversionError { throw conversionError }
            if output.frameLength > 0 {
                try destination.write(from: output)
                written += Int64(output.frameLength)
            }
            if status == .endOfStream { break }
            guard status != .error, output.frameLength > 0 else {
                throw ExtractError.incompatibleFormat
            }
        }
        guard written > 0, reader.finished else {
            throw ExtractError.incompatibleFormat
        }
    }

    // AVAudioConverter 同步消费返回的缓冲；此对象只属于一次转换，文件、缓冲和错误的访问由同一把锁串行化。
    private final class RecordingConversionInput: @unchecked Sendable {
        private let lock = NSLock()
        private let source: AVAudioFile
        private let input: AVAudioPCMBuffer
        private var readError: Error?

        init(source: AVAudioFile, input: AVAudioPCMBuffer) {
            self.source = source
            self.input = input
        }

        var failure: Error? { lock.withLock { readError } }
        var finished: Bool { lock.withLock { source.framePosition == source.length } }

        func read(requested: AVAudioPacketCount,
                  status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.withLock {
                if source.framePosition >= source.length || readError != nil {
                    status.pointee = .endOfStream
                    return nil
                }
                do {
                    input.frameLength = 0
                    try source.read(into: input, frameCount: min(requested, input.frameCapacity))
                    guard input.frameLength > 0 else { throw ExtractError.incompatibleFormat }
                    status.pointee = .haveData
                    return input
                } catch {
                    readError = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
        }
    }

    /// 音频文件时长（毫秒）
    static func durationMs(of url: URL) throws -> Int64 {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else { return 0 }
        return Int64(Double(file.length) / file.processingFormat.sampleRate * 1000)
    }

    private static func compatible(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

}
