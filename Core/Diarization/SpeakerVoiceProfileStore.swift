import Foundation

struct SpeakerVoiceProfile: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var displayName: String
    var role: String?
    var colorToken: String
    var sampleRelativePath: String
    var sampleDurationMs: Int64
    var isAutoEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
}

enum SpeakerVoiceProfileStoreError: Error, Equatable {
    case invalidSample
    case autoRecognitionLimitReached
    case profileNotFound
}

final class SpeakerVoiceProfileStore: @unchecked Sendable {
    static let maximumAutoEnabledProfiles = 4

    private enum SampleValidation {
        case none
        case structure
        case health
    }

    private let baseDirectory: URL
    private let fileURL: URL
    private let profilesDirectory: URL
    private let fileManager: FileManager
    private let indexWriter: (Data, URL) throws -> Void
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        indexWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        let baseDirectory = baseDirectory.standardizedFileURL
        self.baseDirectory = baseDirectory
        self.fileURL = baseDirectory.appending(
            path: "speaker-profiles.json",
            directoryHint: .notDirectory
        )
        self.profilesDirectory = baseDirectory.appending(
            path: "VoiceProfiles",
            directoryHint: .isDirectory
        )
        self.fileManager = fileManager
        self.indexWriter = indexWriter
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> [SpeakerVoiceProfile] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(sampleValidation: .health)
    }

    func loadForManagement() throws -> [SpeakerVoiceProfile] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(sampleValidation: .structure)
    }

    func enroll(
        profileID: UUID? = nil,
        displayName: String,
        role: String?,
        colorToken: String,
        sourceSampleURL: URL,
        durationMs: Int64,
        now: Date = Date()
    ) throws -> SpeakerVoiceProfile {
        guard Self.validDurationRange.contains(durationMs) else {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }
        _ = try validatedAudioDuration(at: sourceSampleURL, declaredDurationMs: durationMs)

        lock.lock()
        defer { lock.unlock() }

        try ensureBaseDirectory()
        var profiles = try loadUnlocked(sampleValidation: .structure)
        let existingIndex = profileID.flatMap { id in profiles.firstIndex { $0.id == id } }
        if profileID != nil, existingIndex == nil {
            throw SpeakerVoiceProfileStoreError.profileNotFound
        }

        let id = existingIndex.map { profiles[$0].id } ?? UUID()
        let relativePath = Self.sampleRelativePath(for: id)
        let destination = try absoluteURL(forRelativePath: relativePath)
        let profileDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        _ = try absoluteURL(forRelativePath: relativePath)

        let transactionID = UUID().uuidString
        let staged = profileDirectory.appending(
            path: ".reference-\(transactionID).staged.wav",
            directoryHint: .notDirectory
        )
        let backup = profileDirectory.appending(
            path: ".reference-\(transactionID).backup.wav",
            directoryHint: .notDirectory
        )
        var preserveBackup = false
        defer {
            try? fileManager.removeItem(at: staged)
            if !preserveBackup {
                try? fileManager.removeItem(at: backup)
            }
            removeDirectoryIfEmpty(profileDirectory)
            removeDirectoryIfEmpty(profilesDirectory)
        }

        do {
            try fileManager.copyItem(at: sourceSampleURL, to: staged)
        } catch {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }
        let measuredDurationMs = try validatedAudioDuration(
            at: staged,
            declaredDurationMs: durationMs
        )

        let autoEnabled = existingIndex.map { profiles[$0].isAutoEnabled }
            ?? (profiles.filter { $0.isAutoEnabled }.count < Self.maximumAutoEnabledProfiles)
        let createdAt = existingIndex.map { profiles[$0].createdAt } ?? now
        let profile = SpeakerVoiceProfile(
            id: id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            colorToken: colorToken,
            sampleRelativePath: relativePath,
            sampleDurationMs: measuredDurationMs,
            isAutoEnabled: autoEnabled,
            createdAt: createdAt,
            updatedAt: now
        )
        if let existingIndex {
            profiles[existingIndex] = profile
        } else {
            profiles.append(profile)
        }

        var installedNewSample = false
        var backedUpOldSample = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                backedUpOldSample = true
            }
            try fileManager.moveItem(at: staged, to: destination)
            installedNewSample = true
            try saveUnlocked(profiles)
        } catch {
            if installedNewSample {
                try? fileManager.removeItem(at: destination)
            }
            if backedUpOldSample {
                do {
                    try fileManager.moveItem(at: backup, to: destination)
                } catch {
                    preserveBackup = true
                    throw error
                }
            }
            throw error
        }
        return profile
    }

    func updateMetadata(
        profileID: UUID,
        displayName: String,
        role: String?,
        colorToken: String,
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var profiles = try loadUnlocked(sampleValidation: .structure)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw SpeakerVoiceProfileStoreError.profileNotFound
        }
        profiles[index].displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].role = role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        profiles[index].colorToken = colorToken
        profiles[index].updatedAt = now
        try saveUnlocked(profiles)
    }

    func setAutoEnabled(_ enabled: Bool, profileID: UUID, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        var profiles = try loadUnlocked(sampleValidation: .structure)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw SpeakerVoiceProfileStoreError.profileNotFound
        }
        if enabled,
           !profiles[index].isAutoEnabled,
           profiles.filter({ $0.isAutoEnabled }).count >= Self.maximumAutoEnabledProfiles {
            throw SpeakerVoiceProfileStoreError.autoRecognitionLimitReached
        }
        if enabled {
            try validateStoredSample(for: profiles[index])
        }
        profiles[index].isAutoEnabled = enabled
        profiles[index].updatedAt = now
        try saveUnlocked(profiles)
    }

    func delete(profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        var profiles = try loadUnlocked(sampleValidation: .none)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw SpeakerVoiceProfileStoreError.profileNotFound
        }
        let originalIndex = try indexSnapshotUnlocked()
        profiles.remove(at: index)

        try ensureBaseDirectory()
        let ownedSampleURL = try absoluteURL(
            forRelativePath: Self.sampleRelativePath(for: profileID)
        )
        let ownedDirectory = ownedSampleURL.deletingLastPathComponent()
        let quarantine = try absoluteURL(
            forRelativePath: ".speaker-profile-delete-\(UUID().uuidString)"
        )
        var movedDirectory = false
        if fileManager.fileExists(atPath: ownedDirectory.path) {
            try fileManager.moveItem(at: ownedDirectory, to: quarantine)
            movedDirectory = true
        }

        do {
            try saveUnlocked(profiles)
        } catch {
            if movedDirectory {
                do {
                    try fileManager.moveItem(at: quarantine, to: ownedDirectory)
                } catch {
                    throw error
                }
            }
            throw error
        }

        guard movedDirectory else { return }
        do {
            try fileManager.removeItem(at: quarantine)
            removeDirectoryIfEmpty(profilesDirectory)
        } catch let deletionError {
            do {
                try fileManager.moveItem(at: quarantine, to: ownedDirectory)
            } catch {
                throw error
            }
            do {
                try restoreIndexUnlocked(originalIndex)
            } catch {
                throw error
            }
            throw deletionError
        }
    }

    func automaticSpeakers() throws -> [Speaker] {
        try load()
            .filter { $0.isAutoEnabled }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maximumAutoEnabledProfiles)
            .enumerated()
            .map { index, profile in
                Speaker(
                    cloudAlias: String(format: "p_%02d", index + 1),
                    displayName: profile.displayName,
                    role: profile.role,
                    colorToken: profile.colorToken,
                    isUserConfirmed: true,
                    voiceSamplePath: profile.sampleRelativePath,
                    voiceSampleDurationMs: profile.sampleDurationMs,
                    voiceProfileId: profile.id
                )
            }
    }

    private static var validDurationRange: ClosedRange<Int64> {
        VoiceSampleValidator.minDurationMs...VoiceSampleValidator.maxDurationMs
    }

    private static func sampleRelativePath(for profileID: UUID) -> String {
        "VoiceProfiles/\(profileID.uuidString)/reference.wav"
    }

    private func loadUnlocked(sampleValidation: SampleValidation) throws -> [SpeakerVoiceProfile] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let profiles = try decoder.decode(
            [SpeakerVoiceProfile].self,
            from: Data(contentsOf: fileURL)
        )
        for profile in profiles {
            switch sampleValidation {
            case .none:
                break
            case .structure:
                try validateStoredProfileStructure(profile)
            case .health:
                try validateStoredSample(for: profile)
            }
        }
        return profiles
    }

    private func validateStoredProfileStructure(_ profile: SpeakerVoiceProfile) throws {
        guard profile.sampleRelativePath == Self.sampleRelativePath(for: profile.id),
              Self.validDurationRange.contains(profile.sampleDurationMs) else {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }
        _ = try absoluteURL(forRelativePath: profile.sampleRelativePath)
    }

    private func validateStoredSample(for profile: SpeakerVoiceProfile) throws {
        try validateStoredProfileStructure(profile)
        let sampleURL = try absoluteURL(forRelativePath: profile.sampleRelativePath)
        _ = try validatedAudioDuration(
            at: sampleURL,
            declaredDurationMs: profile.sampleDurationMs
        )
    }

    private func validatedAudioDuration(
        at url: URL,
        declaredDurationMs: Int64
    ) throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard Self.validDurationRange.contains(declaredDurationMs),
              fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path) else {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }
        let measuredDurationMs: Int64
        do {
            measuredDurationMs = try AudioChunkExtractor.durationMs(of: url)
        } catch {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }
        guard Self.validDurationRange.contains(measuredDurationMs) else {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }
        return measuredDurationMs
    }

    private func saveUnlocked(_ profiles: [SpeakerVoiceProfile]) throws {
        try ensureBaseDirectory()
        let data = try encoder.encode(profiles)
        let snapshot = try indexSnapshotUnlocked()
        do {
            try indexWriter(data, fileURL)
        } catch let writeError {
            do {
                try restoreIndexUnlocked(snapshot)
            } catch {
                throw error
            }
            throw writeError
        }
    }

    private func indexSnapshotUnlocked() throws -> Data? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    private func restoreIndexUnlocked(_ snapshot: Data?) throws {
        if let snapshot {
            try snapshot.write(to: fileURL, options: .atomic)
        } else if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func ensureBaseDirectory() throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: baseDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }
    }

    private func absoluteURL(forRelativePath relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }
        let candidate = baseDirectory.appending(
            path: relativePath,
            directoryHint: .notDirectory
        ).standardizedFileURL
        guard isDescendant(candidate, of: baseDirectory) else {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }

        let resolvedBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        var existingAncestor = candidate
        while !fileManager.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != baseDirectory.path {
            let parent = existingAncestor.deletingLastPathComponent().standardizedFileURL
            guard parent.path != existingAncestor.path else {
                throw SpeakerVoiceProfileStoreError.invalidSample
            }
            existingAncestor = parent
        }
        let resolvedAncestor = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedAncestor.path == resolvedBase.path
                || isDescendant(resolvedAncestor, of: resolvedBase) else {
            throw SpeakerVoiceProfileStoreError.invalidSample
        }
        if fileManager.fileExists(atPath: candidate.path) {
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(resolvedCandidate, of: resolvedBase) else {
                throw SpeakerVoiceProfileStoreError.invalidSample
            }
        }
        return candidate
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    private func removeDirectoryIfEmpty(_ directory: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ), contents.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
