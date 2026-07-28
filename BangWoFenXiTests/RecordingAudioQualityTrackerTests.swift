import Testing
@testable import BangWoFenXi

@Suite("录音声音质量")
struct RecordingAudioQualityTrackerTests {
    @Test("持续低电平达到观察窗口后提示")
    func warnsForPersistentlyLowInput() {
        var tracker = RecordingAudioQualityTracker()
        for _ in 0..<18 {
            tracker.observe(0.04)
        }
        #expect(tracker.isPersistentlyLow)
    }

    @Test("正常说话电平不会误报")
    func acceptsUsableInput() {
        var tracker = RecordingAudioQualityTracker()
        for index in 0..<30 {
            tracker.observe(index.isMultiple(of: 3) ? 0.04 : 0.22)
        }
        #expect(!tracker.isPersistentlyLow)
        tracker.reset()
        #expect(!tracker.isPersistentlyLow)
    }
}
