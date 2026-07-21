import Foundation
import AVFoundation

// 《帮我分析》无人值守稳定性运行器（阶段 6）。
// 用合成音频源驱动录音管线 N 秒：连续写文件、模拟周期暂停、按窗口提取分片，
// 结束后校验：输出文件帧数连续完整（不丢音频）、分片提取无失败、
// 时间线换算自洽、内存无异常增长。
//
// 用法：BangWoFenXiSoak [音频秒数，默认 180] [速率倍率，默认 4]
//   音频秒数：模拟的录音时长（帧数按此计），60 分钟完整跑传 3600。
//   速率倍率：相对实时的速度（4 = 4 倍速，只影响墙钟耗时，不影响帧数校验）。

let args = CommandLine.arguments
let durationSeconds: Double = args.count > 1 ? Double(args[1]) ?? 180 : 180
let rate: Double = max(1, args.count > 2 ? Double(args[2]) ?? 4 : 4)

let sampleRate: Double = 44_100
let bufferFrames: AVAudioFrameCount = 4096
let bufferDuration = Double(bufferFrames) / sampleRate

let workDir = FileManager.default.temporaryDirectory
    .appending(path: "BangWoFenXiSoak-\(UUID().uuidString)", directoryHint: .isDirectory)

var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

func currentRSS() -> UInt64 {
    var info = task_basic_info_64()
    var count = mach_msg_type_number_t(MemoryLayout<task_basic_info_64>.stride / MemoryLayout<integer_t>.stride)
    let kerr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO_64), $0, &count)
        }
    }
    return kerr == KERN_SUCCESS ? info.resident_size : 0
}

func makeSineBuffer(format: AVAudioFormat, frameOffset: Int) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrames) else {
        return nil
    }
    buffer.frameLength = bufferFrames
    for frame in 0..<Int(bufferFrames) {
        buffer.floatChannelData![0][frame] =
            sin(2 * Float.pi * 440 * Float(frame + frameOffset) / Float(sampleRate)) * 0.3
    }
    return buffer
}

// MARK: - 运行

print("==> 稳定性运行：音频 \(Int(durationSeconds))s，\(Int(rate))x 速率")
print("==> 工作目录：\(workDir.path)")

do {
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    let meetingID = UUID()
    let fileStore = MeetingFileStore(baseDirectory: workDir)
    try fileStore.ensureMeetingDirectory(for: meetingID)
    try fileStore.ensureChunksDirectory(for: meetingID)
    let audioURL = fileStore.meetingDirectory(for: meetingID)
        .appending(path: MeetingFileStore.recordingFileName)

    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
        print("SOAK FAIL: 无法创建音频格式")
        exit(1)
    }

    let file = try AVAudioFile(
        forWriting: audioURL,
        settings: AudioRecordingSettings.fileSettings(for: format)
    )

    let rssStart = currentRSS()
    let reference = Date()
    var timeline = RecordingTimeline(startedAt: reference)
    let planner = ChunkPlanner()

    let targetAudioMs = Int64(durationSeconds * 1000)
    var audioMsWritten: Int64 = 0
    var framesWritten: Int64 = 0
    var nextChunkIndex = 0
    var chunksExtracted = 0
    var chunkFailures = 0
    var frameOffset = 0
    var totalPausedSoFarMs: Int64 = 0
    var nextPauseAtMs: Int64 = 45_000 // 每 45 秒音频暂停一次（3 秒墙钟）

    while audioMsWritten < targetAudioMs {
        // 模拟暂停：暂停期间不写文件，并记录暂停区间
        if audioMsWritten >= nextPauseAtMs {
            // 合成墙钟：墙钟 = 音频时间 + 此前累计暂停
            let pauseStart = reference.addingTimeInterval(
                Double(audioMsWritten + totalPausedSoFarMs) / 1000
            )
            try timeline.beginPause(at: pauseStart)
            Thread.sleep(forTimeInterval: 3.0 / rate)
            _ = try timeline.endPause(at: pauseStart.addingTimeInterval(3))
            totalPausedSoFarMs += 3_000
            nextPauseAtMs += 45_000
        }

        guard let buffer = makeSineBuffer(format: format, frameOffset: frameOffset) else {
            failures.append("缓冲生成失败（audioMs=\(audioMsWritten)）")
            break
        }
        try file.write(from: buffer)
        frameOffset += Int(bufferFrames)
        framesWritten += Int64(bufferFrames)
        // 音频时间从帧数精确折算（避免每缓冲毫秒截断造成的累计漂移）
        audioMsWritten = framesWritten * 1_000 / Int64(sampleRate)

        // 分片：窗口闭合即提取（读取仍在写入的文件，与阶段 3 会中路径一致）
        let windows = planner.pendingWindows(uptoAudioMs: audioMsWritten, nextIndex: nextChunkIndex)
        for window in windows {
            let chunkURL = fileStore.chunksDirectory(for: meetingID)
                .appending(path: MeetingFileStore.chunkFileName(index: window.index))
            do {
                _ = try AudioChunkExtractor.extract(
                    from: audioURL,
                    startMs: window.audioStartMs,
                    endMs: window.audioEndMs,
                    to: chunkURL
                )
                chunksExtracted += 1
            } catch {
                chunkFailures += 1
            }
            nextChunkIndex = window.index + 1
        }

        // 速率控制
        Thread.sleep(forTimeInterval: bufferDuration / rate)
    }

    let rssEnd = currentRSS()

    // MARK: - 校验

    // 1) 文件帧数连续完整（不丢音频）
    let readBack = try AVAudioFile(forReading: audioURL)
    check(readBack.length == framesWritten,
          "文件帧数不一致：写入 \(framesWritten)，读回 \(readBack.length)")

    // 2) 分片提取无失败，数量与规划一致
    check(chunkFailures == 0, "分片提取失败 \(chunkFailures) 次")
    let expectedChunks = planner.pendingWindows(uptoAudioMs: targetAudioMs, nextIndex: 0).count
    check(chunksExtracted == expectedChunks,
          "分片数量不符：提取 \(chunksExtracted)，规划 \(expectedChunks)")

    // 3) 分片内容帧数正确（抽验首个完整分片 = 20 秒）
    let firstChunk = try AVAudioFile(forReading: fileStore.chunksDirectory(for: meetingID)
        .appending(path: MeetingFileStore.chunkFileName(index: 0)))
    check(firstChunk.length == 20 * Int64(sampleRate),
          "首个分片帧数异常：\(firstChunk.length)")

    // 4) 时间线自洽：暂停段数符合预期，音频时长等于写入帧折算时长
    let pauseCount = timeline.intervals.count
    let totalPausedMs = timeline.intervals.reduce(Int64(0)) { $0 + $1.durationMs }
    // 45s 整倍数的暂停点落在结尾时不触发（循环已结束）
    let expectedPauses = Int((targetAudioMs - 1) / 45_000)
    check(pauseCount == expectedPauses,
          "暂停次数异常：\(pauseCount)，预期 \(expectedPauses)")
    check(totalPausedMs == Int64(pauseCount) * 3_000,
          "累计暂停异常：\(totalPausedMs)")
    let durationDrift = abs(framesWritten * 1_000 / Int64(sampleRate) - targetAudioMs)
    check(durationDrift < Int64(bufferDuration * 1000) + 1,
          "音频时长异常：漂移 \(durationDrift)ms")
    print("==> 暂停 \(pauseCount) 段，累计 \(totalPausedMs)ms（暂停期间未写文件）")

    // 5) 内存无异常增长
    let growthMB = Double(Int64(bitPattern: rssEnd &- rssStart)) / 1_048_576.0
    print(String(format: "==> 内存 RSS：%.1f MB → %.1f MB（增长 %.1f MB）",
                 Double(rssStart) / 1_048_576.0,
                 Double(rssEnd) / 1_048_576.0, growthMB))
    check(growthMB < 128, "内存异常增长：\(String(format: "%.1f", growthMB)) MB")

    print("==> 写入 \(framesWritten) 帧（\(String(format: "%.1f", Double(framesWritten) / sampleRate))s 音频），提取分片 \(chunksExtracted) 个")
} catch {
    failures.append("运行异常：\(error.localizedDescription)")
}

try? FileManager.default.removeItem(at: workDir)

if failures.isEmpty {
    print("SOAK PASS")
    exit(0)
} else {
    for failure in failures {
        print("SOAK FAIL: \(failure)")
    }
    exit(1)
}
