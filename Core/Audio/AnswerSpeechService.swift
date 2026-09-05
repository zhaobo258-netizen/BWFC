import AVFoundation
import Foundation

/// 语音外放（产品文档 12 号 §10 首个语音回答形态）：
/// “老板主动提问 → 生成可读答案 → 点击播放”；可取消的朗读队列，保留对应答案版本。
/// 边界：外放声音可能被同场录音拾取（回声污染），阶段 E 实测前不在录音同时默认开启。
protocol AnswerSpeechPlaying: AnyObject, Sendable {
    @MainActor var onPlaybackEnded: (@MainActor @Sendable (String) -> Void)? { get set }
    @MainActor func startSpeaking(text: String, identifier: String) throws
    @MainActor func stopSpeaking()
}

/// 纯逻辑：朗读文本准备（去 Markdown 噪声、长度上限），可单测。
enum AnswerSpeechTextPreparation {
    static let maximumCharacters = 20_000

    /// 把 AI 回答整理成适合朗读的文本：去掉 Markdown 标记、来源角标与多余空白。
    static func readableText(from reply: String) -> String {
        var text = reply
        // 去掉【web_N】来源标记
        text = text.replacingOccurrences(
            of: #"\【web_\d+\】"#,
            with: "",
            options: .regularExpression
        )
        // 去掉 Markdown 强调与标题标记
        for token in ["**", "__", "### ", "## ", "# ", "`"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        // 去掉 Markdown 链接，保留文字部分 [text](url)
        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        // 压缩连续空白
        text = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumCharacters))
    }
}

/// AVSpeechSynthesizer 薄壳：只在主线程使用；优先中文语音。
@MainActor
final class SystemAnswerSpeechPlayer: NSObject, AnswerSpeechPlaying, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onPlaybackEnded: (@MainActor @Sendable (String) -> Void)?
    private var activeUtterance: ObjectIdentifier?
    private var activeIdentifier: String?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func startSpeaking(text: String, identifier: String) throws {
        stopSpeaking()
        guard let voice = Self.preferredChineseVoice() else {
            throw AnswerSpeechError.voiceUnavailable
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0
        activeUtterance = ObjectIdentifier(utterance)
        activeIdentifier = identifier
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        activeUtterance = nil
        activeIdentifier = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    static func preferredChineseVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("zh") }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.didEnd(key) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.didEnd(key) }
    }

    private func didEnd(_ key: ObjectIdentifier) {
        guard activeUtterance == key, let identifier = activeIdentifier else { return }
        activeUtterance = nil
        activeIdentifier = nil
        onPlaybackEnded?(identifier)
    }
}

enum AnswerSpeechError: LocalizedError {
    case voiceUnavailable

    var errorDescription: String? {
        "本机没有可用的中文朗读声音，请在系统设置中下载中文声音后重试。"
    }
}

/// 朗读状态控制器（@Observable 驱动 UI 播放/停止按钮）。
@MainActor
@Observable
final class AnswerSpeechController {
    /// 正在朗读的消息 ID（nil = 未在朗读）
    private(set) var speakingMessageID: String?
    private(set) var errorMessage: String?
    private let player: any AnswerSpeechPlaying
    private var playbackIdentifier: String?

    init(player: any AnswerSpeechPlaying) {
        self.player = player
        player.onPlaybackEnded = { [weak self] identifier in
            guard let self, self.playbackIdentifier == identifier else { return }
            self.playbackIdentifier = nil
            self.speakingMessageID = nil
        }
    }

    /// 点击某条消息的播放按钮：正在读它则停止；否则切换到读它。
    func togglePlayback(messageID: String, reply: String) {
        if speakingMessageID == messageID {
            stop()
            return
        }
        let readable = AnswerSpeechTextPreparation.readableText(from: reply)
        guard !readable.isEmpty else { return }
        // 换条播放前先停旧（幂等；实现方无需隐式处理）
        playbackIdentifier = nil
        player.stopSpeaking()
        errorMessage = nil
        let identifier = UUID().uuidString
        playbackIdentifier = identifier
        speakingMessageID = messageID
        do {
            try player.startSpeaking(text: readable, identifier: identifier)
        } catch {
            playbackIdentifier = nil
            speakingMessageID = nil
            errorMessage = "朗读未开始：\(error.localizedDescription)"
        }
    }

    func stop() {
        guard speakingMessageID != nil else { return }
        playbackIdentifier = nil
        speakingMessageID = nil
        player.stopSpeaking()
    }

    /// 切换项目/关闭页面时停止，避免上一场的回答继续外放。
    func handleDisappear() {
        stop()
        errorMessage = nil
    }
}
