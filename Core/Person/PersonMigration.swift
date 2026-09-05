import Foundation

/// 仅首次迁移旧声纹身份；新声纹通过显式创建路径接入人物库。
enum PersonMigrationCoordinator {
    struct Marker: Codable, Equatable {
        var completedAt: Date
        var migratedProfileCount: Int
        var personCount: Int
        var schemaVersion: Int
    }

    struct Outcome: Equatable {
        var createdPersonCount: Int
        var backfilledSpeakers: [(projectID: UUID, speakerID: UUID)]
        var markerExisted: Bool

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.createdPersonCount == rhs.createdPersonCount
                && lhs.backfilledSpeakers.map { "\($0.projectID):\($0.speakerID)" }
                    == rhs.backfilledSpeakers.map { "\($0.projectID):\($0.speakerID)" }
                && lhs.markerExisted == rhs.markerExisted
        }
    }

    static func markerURL(in baseDirectory: URL) -> URL {
        baseDirectory.appending(path: "persons-migration-v1.json", directoryHint: .notDirectory)
    }

    static func migrateIfNeeded(
        personStore: PersonLibraryStore,
        profileStore: SpeakerVoiceProfileStore,
        projectStore: any ProjectStoring,
        baseDirectory: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        markerWriter: (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) throws -> Outcome {
        let markerURL = Self.markerURL(in: baseDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if fileManager.fileExists(atPath: markerURL.path) {
            let marker = try decoder.decode(Marker.self, from: Data(contentsOf: markerURL))
            guard marker.schemaVersion == 1 else { throw PersonLibraryStoreError.undoConflict }
            guard fileManager.fileExists(atPath: baseDirectory.appending(path: "persons.json").path) else {
                throw PersonLibraryStoreError.personNotFound
            }
            _ = try personStore.load()
            return Outcome(createdPersonCount: 0, backfilledSpeakers: [], markerExisted: true)
        }

        let profiles = try profileStore.loadForManagement()
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw PersonLibraryStoreError.conflictingVoiceProfile
        }
        let originalPersons = try personStore.load()
        let originalProjects = try projectStore.loadProjects()
        var persons = originalPersons
        let projects = try decoder.decode([Project].self, from: encoder.encode(originalProjects))
        let personFile = baseDirectory.appending(path: "persons.json")
        let originalPersonData = fileManager.fileExists(atPath: personFile.path)
            ? try Data(contentsOf: personFile) : nil
        var created = 0
        for profile in profiles {
            if persons.contains(where: { $0.voiceProfileIDs.contains(profile.id) }) { continue }
            guard !persons.contains(where: { $0.id == profile.id }) else {
                throw PersonLibraryStoreError.conflictingVoiceProfile
            }
            persons.append(Person(
                id: profile.id, displayName: profile.displayName, role: profile.role,
                colorToken: profile.colorToken, backgroundContext: profile.backgroundContext,
                isCurrentUser: profile.isCurrentUser == true,
                linkedVoiceProfileID: profile.id, createdAt: profile.createdAt, updatedAt: now
            ))
            created += 1
        }
        try PersonLibraryStore.validate(persons)
        var personIDByProfile: [UUID: UUID] = [:]
        for person in persons {
            for profileID in person.voiceProfileIDs { personIDByProfile[profileID] = person.id }
        }
        var backfilled: [(UUID, UUID)] = []
        for project in projects {
            for speaker in project.speakers {
                if speaker.personId == nil, let profileID = speaker.voiceProfileId,
                   let personID = personIDByProfile[profileID] {
                    speaker.personId = personID
                    backfilled.append((project.id, speaker.id))
                }
                guard let personID = speaker.personId else { continue }
                guard let index = persons.firstIndex(where: { $0.id == personID }) else {
                    throw PersonLibraryStoreError.personNotFound
                }
                if !persons[index].speakerLinks.contains(where: {
                    $0.projectID == project.id && $0.speakerID == speaker.id
                }) {
                    persons[index].speakerLinks.append(PersonSpeakerLink(
                        projectID: project.id, speakerID: speaker.id,
                        speakerDisplayName: speaker.displayName, linkedAt: now
                    ))
                }
                speaker.isCurrentUser = persons[index].isCurrentUser
            }
        }

        var personsAttempted = false
        var projectsAttempted = false
        do {
            personsAttempted = true
            try personStore.replaceAll(persons)
            projectsAttempted = true
            try projectStore.saveProjects(projects)
            let marker = Marker(
                completedAt: now, migratedProfileCount: profiles.count,
                personCount: persons.count, schemaVersion: 1
            )
            try markerWriter(encoder.encode(marker), markerURL)
        } catch {
            let originalError = error
            var rollbackFailed = false
            if projectsAttempted {
                do { try projectStore.saveProjects(originalProjects) }
                catch { rollbackFailed = true }
            }
            if personsAttempted {
                do {
                    if let originalPersonData {
                        try originalPersonData.write(to: personFile, options: .atomic)
                    } else if fileManager.fileExists(atPath: personFile.path) {
                        try fileManager.removeItem(at: personFile)
                    }
                } catch { rollbackFailed = true }
            }
            if fileManager.fileExists(atPath: markerURL.path) {
                do { try fileManager.removeItem(at: markerURL) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed { throw PersonLibraryStoreError.rollbackFailed }
            throw originalError
        }
        return Outcome(createdPersonCount: created, backfilledSpeakers: backfilled, markerExisted: false)
    }
}
