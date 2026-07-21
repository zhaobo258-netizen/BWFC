import Foundation
import AVFoundation

/// 分片提取器：从完整录音文件中按音频时间窗口提取分片为 .wav。
/// 纯文件操作（无需硬件），可单测。
enum AudioChunkExtractor {
    /// 提取错误
    enum ExtractError: Error, Equatable {
        case sourceMissing
        case emptyWindow
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

    /// 音频文件时长（毫秒）
    static func durationMs(of url: URL) throws -> Int64 {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else { return 0 }
        return Int64(Double(file.length) / file.processingFormat.sampleRate * 1000)
    }
}
