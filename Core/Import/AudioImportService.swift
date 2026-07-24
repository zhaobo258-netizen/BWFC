import Foundation
import AVFoundation

/// 导入媒体的检查结果（产品文档 03 号 §9.1）
struct ImportedMediaInfo: Equatable, Sendable {
    /// 媒体时长（毫秒）
    let durationMs: Int64
    /// 是否含视频轨（决定 sourceType：importedVideo / importedAudio）
    let hasVideoTrack: Bool
    /// 原文件名（含扩展名）
    let fileName: String
    /// 原文件大小（字节）
    let fileSizeBytes: Int64
}

/// 导入失败的明确错误（03 §16 阶段 C 验收：无音轨、损坏文件、权限失效、重复导入有明确错误）
enum AudioImportError: Error, Equatable, Sendable {
    /// 文件不存在或不可读（含权限失效）
    case fileNotReadable
    /// 文件没有可解析的音轨（含纯画面视频）
    case noAudioTrack
    /// 有音轨但时长为 0
    case zeroDuration
    /// 文件损坏或 AVFoundation 无法解码
    case undecodable
    /// 音轨提取中断或写出失败
    case extractionFailed

    /// 面向用户的中文描述（不包含文件路径等敏感信息）
    var userMessage: String {
        switch self {
        case .fileNotReadable: return "文件不存在或没有读取权限"
        case .noAudioTrack: return "文件中没有可解析的音轨"
        case .zeroDuration: return "音轨时长为 0，无法处理"
        case .undecodable: return "文件已损坏或格式不受系统支持"
        case .extractionFailed: return "音轨提取失败，可重试"
        }
    }
}

/// 音视频导入服务协议（产品文档 03 号 §9.1）。
/// 相对 03 文档增加 onProgress 回调：§6.2 要求每个阶段独立显示进度。
protocol AudioImportServicing: Sendable {
    /// 检查文件：存在、可读、有可解析音轨且时长大于 0
    func inspect(url: URL) async throws -> ImportedMediaInfo
    /// 复制原文件到项目运行目录并提取标准化音轨；
    /// 返回提取音频的绝对 URL（标准相对路径 Meetings/<id>/recording.caf）。
    /// 绝不修改来源文件；重试时不重复复制已存在的原件副本。
    func prepareAudio(from url: URL, for projectID: UUID,
                      onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

extension AudioImportServicing {
    /// 无进度回调的便捷入口（与 03 §9.1 协议签名一致）
    func prepareAudio(from url: URL, for projectID: UUID) async throws -> URL {
        try await prepareAudio(from: url, for: projectID, onProgress: { _ in })
    }
}

/// AVFoundation 实现（阶段 C）：
/// - inspect 用 AVURLAsset 真实加载音轨与时长，不按扩展名猜测；
/// - prepareAudio 复制原件到 Meetings/<id>/source-original.<ext> 留档，
///   再用 AVAssetReader 把音轨解码为 48kHz 单声道 Float32 PCM，
///   写入与实时录音相同的标准路径 Meetings/<id>/recording.caf——
///   回放、删除、资产修复与转写全部复用既有链路，零特殊分支。
struct AVFoundationAudioImportService: AudioImportServicing {
    /// 原件副本文件名前缀（扩展名保留原样）
    static let sourceCopyBaseName = "source-original"
    /// 提取输出采样率（与转写/回放兼容的通用值）
    static let outputSampleRate: Double = 48_000

    let fileStore: MeetingFileStore

    // MARK: - 检查

    func inspect(url: URL) async throws -> ImportedMediaInfo {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw AudioImportError.fileNotReadable
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let sizeBytes = (attributes?[.size] as? Int64) ?? 0

        let asset = AVURLAsset(url: url)
        let audioTracks: [AVAssetTrack]
        let videoTracks: [AVAssetTrack]
        let duration: CMTime
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            duration = try await asset.load(.duration)
        } catch {
            // AVFoundation 无法解析容器：按损坏/不支持处理（真实错误类别进日志由调用方负责）
            throw AudioImportError.undecodable
        }
        guard !audioTracks.isEmpty else {
            throw AudioImportError.noAudioTrack
        }
        let durationMs = Int64((duration.seconds * 1000).rounded())
        guard durationMs > 0 else {
            throw AudioImportError.zeroDuration
        }
        return ImportedMediaInfo(
            durationMs: durationMs,
            hasVideoTrack: !videoTracks.isEmpty,
            fileName: url.lastPathComponent,
            fileSizeBytes: sizeBytes
        )
    }

    // MARK: - 复制与提取

    func prepareAudio(from url: URL, for projectID: UUID,
                      onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let directory = try fileStore.ensureMeetingDirectory(for: projectID)

        // 1. 复制原件（重试时已存在则跳过，不重复复制；绝不修改来源文件）
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let sourceCopy = directory.appending(path: "\(Self.sourceCopyBaseName).\(ext)")
        if !FileManager.default.fileExists(atPath: sourceCopy.path) {
            do {
                try FileManager.default.copyItem(at: url, to: sourceCopy)
            } catch {
                throw AudioImportError.fileNotReadable
            }
        }

        // 2. 从原件副本提取音轨（读副本而非来源，避免提取期间外部盘拔出等失效）
        let outputURL = try fileStore.absoluteURL(forRelativePath: fileStore.relativeAudioPath(for: projectID))
        try await Self.extractAudio(from: sourceCopy, to: outputURL, onProgress: onProgress)
        return outputURL
    }

    /// AVAssetReader 音轨 → 48kHz 单声道 Float32 PCM .caf。
    /// 输出文件先写临时名，成功后原子替换，避免半成品被误认为完整音频。
    private static func extractAudio(from sourceURL: URL, to outputURL: URL,
                                     onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks: [AVAssetTrack]
        let duration: CMTime
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw AudioImportError.undecodable
        }
        guard !audioTracks.isEmpty else { throw AudioImportError.noAudioTrack }
        let totalSeconds = max(duration.seconds, .leastNonzeroMagnitude)

        // 解码输出：Float32 交错单声道 48kHz（AVAssetReaderAudioMixOutput 负责混轨与重采样）
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioImportError.undecodable
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioImportError.extractionFailed }
        reader.add(output)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: outputSampleRate,
                                         channels: 1, interleaved: false) else {
            throw AudioImportError.extractionFailed
        }
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appending(path: "extracting-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            let file = try AVAudioFile(forWriting: temporaryURL, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard reader.startReading() else { throw AudioImportError.extractionFailed }
            var writtenSeconds: Double = 0
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer, format: format) else {
                    continue
                }
                try file.write(from: pcmBuffer)
                writtenSeconds += Double(pcmBuffer.frameLength) / outputSampleRate
                onProgress(min(writtenSeconds / totalSeconds, 1.0))
            }
            if reader.status == .failed {
                throw AudioImportError.extractionFailed
            }
        } catch let error as AudioImportError {
            reader.cancelReading()
            throw error
        } catch is CancellationError {
            reader.cancelReading()
            throw CancellationError()
        } catch {
            reader.cancelReading()
            throw AudioImportError.extractionFailed
        }

        // 3. 原子落位：成功才替换标准路径
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
        } catch {
            throw AudioImportError.extractionFailed
        }
        onProgress(1.0)
    }

    /// CMSampleBuffer（交错 Float32）→ AVAudioPCMBuffer（非交错单声道）
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer,
                                      format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let dataPointer,
              let channelData = pcmBuffer.floatChannelData else {
            return nil
        }
        let expectedBytes = frameCount * MemoryLayout<Float>.size
        guard totalLength >= expectedBytes else { return nil }
        dataPointer.withMemoryRebound(to: Float.self, capacity: frameCount) { source in
            channelData[0].update(from: source, count: frameCount)
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        return pcmBuffer
    }
}
