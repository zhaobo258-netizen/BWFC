import Foundation

struct RecordingAudioQualityTracker {
    private(set) var samples: [Float] = []

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    mutating func observe(_ level: Float) {
        samples.append(max(0, min(1, level)))
        if samples.count > 30 {
            samples.removeFirst(samples.count - 30)
        }
    }

    var isPersistentlyLow: Bool {
        guard samples.count >= 18 else { return false }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2] < 0.08
    }
}
