import Foundation
import AVFoundation
import Testing
@testable import BangWoFenXi

@Suite("永久声纹库")
struct SpeakerVoiceProfileStoreTests {
    private enum InjectedFailure: Error {
        case indexWrite
    }

    private final class IndexWriteGate: @unchecked Sendable {
        var shouldFail = false
        var writesBeforeFailure = false

        func write(_ data: Data, to url: URL) throws {
            if shouldFail {
                if writesBeforeFailure {
                    try data.write(to: url, options: .atomic)
                }
                throw InjectedFailure.indexWrite
            }
            try data.write(to: url, options: .atomic)
        }
    }

    private func temporaryDirectory(prefix: String = "bwfx-profile-tests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sample(
        in directory: URL,
        name: String = UUID().uuidString,
        durationMs: Int64 = 3_000,
        frequency: Float = 220
    ) throws -> URL {
        let url = directory.appending(path: "\(name).wav", directoryHint: .notDirectory)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let frameCount = AVAudioFrameCount(
            (Double(durationMs) / 1_000 * format.sampleRate).rounded()
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            channel[frame] = sin(
                2 * Float.pi * frequency * Float(frame) / Float(format.sampleRate)
            ) * 0.2
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioRecordingSettings.fileSettings(for: format)
        )
        try file.write(from: buffer)
        return url
    }

    private func writeProfiles(_ profiles: [SpeakerVoiceProfile], to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(
            to: root.appending(path: "speaker-profiles.json"),
            options: .atomic
        )
    }

    private func storedSampleURL(for profile: SpeakerVoiceProfile, root: URL) -> URL {
        root.appending(path: profile.sampleRelativePath, directoryHint: .notDirectory)
    }

    private func transactionArtifacts(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            let name = $0.lastPathComponent
            return name.contains(".staged.")
                || name.contains(".backup.")
                || name.hasPrefix(".speaker-profile-delete-")
        }
    }

    @Test("确认样本复制进独立目录，删除会议目录不影响跨会议复用")
    func enrollmentOwnsIndependentCopy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = root.appending(path: "Meetings/test", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let source = try sample(in: meeting, durationMs: 4_000)
        let store = SpeakerVoiceProfileStore(baseDirectory: root)

        let profile = try store.enroll(
            displayName: "王总", role: "负责人", colorToken: "blue",
            sourceSampleURL: source, durationMs: 4_000
        )
        try FileManager.default.removeItem(at: meeting)

        let speaker = try #require(store.automaticSpeakers().first)
        #expect(speaker.displayName == "王总")
        #expect(speaker.role == "负责人")
        #expect(speaker.voiceProfileId == profile.id)
        let copied = root.appending(path: try #require(speaker.voiceSamplePath))
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try AudioChunkExtractor.durationMs(of: copied) == 4_000)
    }

    @Test("只允许四个永久声纹自动参加新会议，第五个明确拒绝启用")
    func autoEnabledLimitIsExplicit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerVoiceProfileStore(baseDirectory: root)
        var profiles: [SpeakerVoiceProfile] = []
        for index in 0..<5 {
            profiles.append(try store.enroll(
                displayName: "说话人\(index)", role: nil, colorToken: "gray",
                sourceSampleURL: try sample(in: root), durationMs: 3_000
            ))
        }
        #expect(profiles.prefix(4).filter { $0.isAutoEnabled }.count == 4)
        #expect(profiles[4].isAutoEnabled == false)
        #expect(try store.automaticSpeakers().count == 4)
        #expect(throws: SpeakerVoiceProfileStoreError.autoRecognitionLimitReached) {
            try store.setAutoEnabled(true, profileID: profiles[4].id)
        }
    }

    @Test("录入同时校验声明时长与音频真实时长")
    func enrollmentRejectsUnsafeSamples() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerVoiceProfileStore(baseDirectory: root)
        let valid = try sample(in: root)
        let tooShort = try sample(in: root, durationMs: 1_000)

        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try store.enroll(
                displayName: "甲", role: nil, colorToken: "blue",
                sourceSampleURL: valid, durationMs: 11_000
            )
        }
        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try store.enroll(
                displayName: "乙", role: nil, colorToken: "blue",
                sourceSampleURL: tooShort, durationMs: 3_000
            )
        }
        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try store.enroll(
                displayName: "丙", role: nil, colorToken: "blue",
                sourceSampleURL: root.appending(path: "missing.wav"), durationMs: 3_000
            )
        }
    }

    @Test("加载与自动带入对丢失、损坏和非法元数据给出明确错误")
    func loadValidatesStoredSamples() throws {
        let missingRoot = try temporaryDirectory()
        let corruptRoot = try temporaryDirectory()
        let metadataRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: missingRoot)
            try? FileManager.default.removeItem(at: corruptRoot)
            try? FileManager.default.removeItem(at: metadataRoot)
        }

        let missingStore = SpeakerVoiceProfileStore(baseDirectory: missingRoot)
        let missingProfile = try missingStore.enroll(
            displayName: "甲", role: nil, colorToken: "blue",
            sourceSampleURL: try sample(in: missingRoot), durationMs: 3_000
        )
        try FileManager.default.removeItem(
            at: storedSampleURL(for: missingProfile, root: missingRoot)
        )
        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try missingStore.load()
        }
        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try missingStore.automaticSpeakers()
        }

        let corruptStore = SpeakerVoiceProfileStore(baseDirectory: corruptRoot)
        let corruptProfile = try corruptStore.enroll(
            displayName: "乙", role: nil, colorToken: "green",
            sourceSampleURL: try sample(in: corruptRoot), durationMs: 3_000
        )
        try Data([1, 2, 3, 4]).write(
            to: storedSampleURL(for: corruptProfile, root: corruptRoot)
        )
        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try corruptStore.load()
        }

        let metadataStore = SpeakerVoiceProfileStore(baseDirectory: metadataRoot)
        var metadataProfile = try metadataStore.enroll(
            displayName: "丙", role: nil, colorToken: "orange",
            sourceSampleURL: try sample(in: metadataRoot), durationMs: 3_000
        )
        metadataProfile.sampleDurationMs = 1_000
        try writeProfiles([metadataProfile], to: metadataRoot)
        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try metadataStore.load()
        }
    }

    @Test("坏样本仍可管理且不阻塞指定 profile 更新")
    func damagedSamplesRemainRecoverable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerVoiceProfileStore(baseDirectory: root)
        let damaged = try store.enroll(
            displayName: "损坏条目", role: nil, colorToken: "red",
            sourceSampleURL: try sample(in: root), durationMs: 3_000
        )
        let healthy = try store.enroll(
            displayName: "正常条目", role: nil, colorToken: "blue",
            sourceSampleURL: try sample(in: root), durationMs: 3_000
        )
        try FileManager.default.removeItem(at: storedSampleURL(for: damaged, root: root))

        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try store.automaticSpeakers()
        }
        #expect(try store.loadForManagement().map(\.id) == [damaged.id, healthy.id])

        let updatedHealthy = try store.enroll(
            profileID: healthy.id,
            displayName: "已更新", role: "负责人", colorToken: "green",
            sourceSampleURL: try sample(in: root, durationMs: 4_000),
            durationMs: 4_000
        )
        #expect(updatedHealthy.displayName == "已更新")

        _ = try store.enroll(
            profileID: damaged.id,
            displayName: damaged.displayName,
            role: damaged.role,
            colorToken: damaged.colorToken,
            sourceSampleURL: try sample(in: root),
            durationMs: 3_000
        )
        #expect(try store.load().count == 2)
    }

    @Test("拒绝相对路径越界及样本 symlink 逃逸")
    func rejectsEscapingSamplePaths() throws {
        let traversalRoot = try temporaryDirectory()
        let symlinkRoot = try temporaryDirectory()
        let outsideRoot = try temporaryDirectory(prefix: "bwfx-profile-outside")
        defer {
            try? FileManager.default.removeItem(at: traversalRoot)
            try? FileManager.default.removeItem(at: symlinkRoot)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        let now = Date()
        let traversalProfile = SpeakerVoiceProfile(
            id: UUID(),
            displayName: "越界",
            role: nil,
            colorToken: "red",
            sampleRelativePath: "../outside.wav",
            sampleDurationMs: 3_000,
            isAutoEnabled: true,
            createdAt: now,
            updatedAt: now
        )
        try writeProfiles([traversalProfile], to: traversalRoot)
        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try SpeakerVoiceProfileStore(baseDirectory: traversalRoot).load()
        }

        let profileID = UUID()
        let ownedDirectory = symlinkRoot
            .appending(path: "VoiceProfiles", directoryHint: .isDirectory)
            .appending(path: profileID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: ownedDirectory,
            withIntermediateDirectories: true
        )
        let outsideSample = try sample(in: outsideRoot)
        try FileManager.default.createSymbolicLink(
            at: ownedDirectory.appending(path: "reference.wav"),
            withDestinationURL: outsideSample
        )
        let symlinkProfile = SpeakerVoiceProfile(
            id: profileID,
            displayName: "链接",
            role: nil,
            colorToken: "purple",
            sampleRelativePath: "VoiceProfiles/\(profileID.uuidString)/reference.wav",
            sampleDurationMs: 3_000,
            isAutoEnabled: true,
            createdAt: now,
            updatedAt: now
        )
        try writeProfiles([symlinkProfile], to: symlinkRoot)
        #expect(throws: SpeakerVoiceProfileStoreError.invalidSample) {
            try SpeakerVoiceProfileStore(baseDirectory: symlinkRoot).load()
        }
    }

    @Test("新录入索引失败时删除新音频并清理事务文件")
    func newEnrollmentRollsBackWhenIndexWriteFails() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = IndexWriteGate()
        gate.shouldFail = true
        gate.writesBeforeFailure = true
        let store = SpeakerVoiceProfileStore(
            baseDirectory: root,
            indexWriter: { try gate.write($0, to: $1) }
        )

        #expect(throws: InjectedFailure.indexWrite) {
            try store.enroll(
                displayName: "甲", role: nil, colorToken: "blue",
                sourceSampleURL: try sample(in: root), durationMs: 3_000
            )
        }
        gate.shouldFail = false
        #expect(try store.load().isEmpty)
        #expect(transactionArtifacts(in: root).isEmpty)
        let profilesDirectory = root.appending(path: "VoiceProfiles")
        #expect(!FileManager.default.fileExists(atPath: profilesDirectory.path))
    }

    @Test("更新音频或元数据索引失败时恢复旧音频与旧索引")
    func updatesRollBackWhenIndexWriteFails() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = IndexWriteGate()
        let store = SpeakerVoiceProfileStore(
            baseDirectory: root,
            indexWriter: { try gate.write($0, to: $1) }
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let original = try store.enroll(
            displayName: "原姓名", role: "原角色", colorToken: "blue",
            sourceSampleURL: try sample(in: root, frequency: 220), durationMs: 3_000,
            now: now
        )
        let storedURL = storedSampleURL(for: original, root: root)
        let originalAudio = try Data(contentsOf: storedURL)

        gate.shouldFail = true
        gate.writesBeforeFailure = true
        #expect(throws: InjectedFailure.indexWrite) {
            try store.enroll(
                profileID: original.id,
                displayName: "新姓名",
                role: "新角色",
                colorToken: "red",
                sourceSampleURL: try sample(
                    in: root,
                    durationMs: 4_000,
                    frequency: 440
                ),
                durationMs: 4_000
            )
        }
        #expect(throws: InjectedFailure.indexWrite) {
            try store.updateMetadata(
                profileID: original.id,
                displayName: "另一个姓名",
                role: nil,
                colorToken: "green"
            )
        }

        gate.shouldFail = false
        let restored = try #require(store.load().first)
        #expect(restored == original)
        #expect(try Data(contentsOf: storedURL) == originalAudio)
        #expect(transactionArtifacts(in: root).isEmpty)
    }

    @Test("删除同时移除索引和独立音频")
    func deletionRemovesIndexAndAudio() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerVoiceProfileStore(baseDirectory: root)
        let profile = try store.enroll(
            displayName: "待删除", role: nil, colorToken: "gray",
            sourceSampleURL: try sample(in: root), durationMs: 3_000
        )
        let storedURL = storedSampleURL(for: profile, root: root)

        try store.delete(profileID: profile.id)

        #expect(try store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storedURL.path))
        #expect(transactionArtifacts(in: root).isEmpty)
    }

    @Test("删除索引失败时恢复 profile 与音频并清理隔离目录")
    func deletionRollsBackWhenIndexWriteFails() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = IndexWriteGate()
        let store = SpeakerVoiceProfileStore(
            baseDirectory: root,
            indexWriter: { try gate.write($0, to: $1) }
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let profile = try store.enroll(
            displayName: "保留", role: "负责人", colorToken: "orange",
            sourceSampleURL: try sample(in: root), durationMs: 3_000,
            now: now
        )
        let storedURL = storedSampleURL(for: profile, root: root)
        let originalAudio = try Data(contentsOf: storedURL)

        gate.shouldFail = true
        gate.writesBeforeFailure = true
        #expect(throws: InjectedFailure.indexWrite) {
            try store.delete(profileID: profile.id)
        }
        gate.shouldFail = false

        #expect(try store.load() == [profile])
        #expect(try Data(contentsOf: storedURL) == originalAudio)
        #expect(transactionArtifacts(in: root).isEmpty)
    }
}
