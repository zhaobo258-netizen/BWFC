import Foundation

/// 分片窗口（音频流时间轴，毫秒）
struct ChunkWindow: Equatable, Sendable {
    /// 分片序号（从 0 开始）
    var index: Int
    /// 音频流起始毫秒
    var audioStartMs: Int64
    /// 音频流结束毫秒
    var audioEndMs: Int64
}

/// 上传分片规划（纯逻辑，实施计划 7.4）：
/// 约 20 秒分片、相邻分片 2 秒重叠（防止切断一句话）；
/// 只在窗口完整闭合后才产出（结束会议时的尾部残缺窗口由 finalWindow 处理）。
struct ChunkPlanner: Sendable {
    /// 分片长度（毫秒）
    var chunkLengthMs: Int64 = 20_000
    /// 相邻重叠（毫秒）
    var overlapMs: Int64 = 2_000

    /// 相邻分片起点间距
    var strideMs: Int64 { chunkLengthMs - overlapMs }

    init(chunkLengthMs: Int64 = 20_000, overlapMs: Int64 = 2_000) {
        self.chunkLengthMs = chunkLengthMs
        self.overlapMs = overlapMs
    }

    /// 第 index 个分片的完整窗口
    func window(forIndex index: Int) -> ChunkWindow {
        let start = Int64(index) * strideMs
        return ChunkWindow(index: index, audioStartMs: start, audioEndMs: start + chunkLengthMs)
    }

    /// 已产出到的分片序号（下一个待产出分片的 index）→ 在音频进度达到 uptoAudioMs 时，
    /// 应新产出的完整窗口列表（只含已闭合窗口）。
    /// - Parameters:
    ///   - uptoAudioMs: 当前音频进度（毫秒）
    ///   - nextIndex: 下一个待产出分片序号
    func pendingWindows(uptoAudioMs: Int64, nextIndex: Int) -> [ChunkWindow] {
        var result: [ChunkWindow] = []
        var index = max(0, nextIndex)
        while true {
            let window = window(forIndex: index)
            guard window.audioEndMs <= uptoAudioMs else { break }
            result.append(window)
            index += 1
        }
        return result
    }

    /// 结束会议时的尾部窗口：从 nextIndex 起到 uptoAudioMs 的残缺片段。
    /// 不足 1 秒的尾巴不产生。
    func finalWindow(uptoAudioMs: Int64, nextIndex: Int) -> ChunkWindow? {
        let start = Int64(max(0, nextIndex)) * strideMs
        guard uptoAudioMs - start >= 1_000 else { return nil }
        return ChunkWindow(index: max(0, nextIndex), audioStartMs: start, audioEndMs: uptoAudioMs)
    }
}
