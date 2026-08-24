import Foundation
import Testing
@testable import BangWoFenXi

/// Project ⇄ 运行时 Meeting 桥接测试（阶段 B）：
/// 状态映射、字段还原、深拷贝隔离、回写一致性与往返稳定。
@Suite("Project 运行时桥接")
@MainActor
final class ProjectRuntimeSessionTests {

    /// 造一个字段齐全的 Project
    private func makeProject(status: ProjectStatus = .ready) -> Project {
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)
        let endedAt = Date(timeIntervalSince1970: 1_753_003_600)
        let speaker = Speaker(
            id: UUID(), cloudAlias: "p_01", displayName: "对方", role: "采购",
            colorToken: "blue", isUserConfirmed: true, legacySide: "counterpart",
            legacyVoiceReferencePath: "Meetings/x/samples/y.wav",
            legacyVoiceReferenceDurationMs: 4_200
        )
        let segment = TranscriptSegment(
            startMs: 1_000, endMs: 5_000, text: "原话",
            participantId: speaker.id, source: .cloud, state: .final,
            createdAt: startedAt, updatedAt: startedAt
        )
        let snapshot = AnalysisSnapshot(version: 1, createdAt: startedAt, analyzedThroughMs: 5_000)
        return Project(
            id: UUID(), title: "桥接项目", sourceType: .liveRecording,
            status: status, createdAt: startedAt, startedAt: startedAt, endedAt: endedAt,
            lastActivityAt: endedAt,
            runtimeAssetRelativePath: "Meetings/x/recording.caf",
            durationMs: 3_600_000, preferredInputDeviceID: "device-1",
            pauseIntervals: [PauseInterval(startMs: 60_000, endMs: 90_000)],
            speakers: [speaker], segments: [segment], legacySnapshots: [snapshot],
            legacyMetadata: LegacyMeetingMetadata(
                background: "背景", ourGoal: "目标", ourBottomLine: "底线",
                counterpartContext: "对方背景", glossary: ["返点"],
                audioUploadConsentAt: startedAt, lastAnalyzedSegmentEndMs: 5_000
            )
        )
    }

    @Test("运行时状态映射：creating→ready、processing→finalizing、ready 族→completed")
    func runtimeStatusMapping() {
        #expect(ProjectRuntimeSession.runtimeStatus(for: .creating) == .ready)
        #expect(ProjectRuntimeSession.runtimeStatus(for: .recording) == .recording)
        #expect(ProjectRuntimeSession.runtimeStatus(for: .paused) == .paused)
        #expect(ProjectRuntimeSession.runtimeStatus(for: .processing) == .finalizing)
        #expect(ProjectRuntimeSession.runtimeStatus(for: .ready) == .completed)
        #expect(ProjectRuntimeSession.runtimeStatus(for: .readyWithWarnings) == .completed)
        #expect(ProjectRuntimeSession.runtimeStatus(for: .failed) == .completed)
    }

    @Test("底部录音条：仅在本次会话真的持有录音器时出现")
    func recordBarRequiresLiveRecorder() {
        #expect(ProjectRuntimeSession.showsRecordBar(status: .recording, hasLiveRecorder: true))
        #expect(ProjectRuntimeSession.showsRecordBar(status: .paused, hasLiveRecorder: true))
        // 崩溃遗留：状态仍是 recording/paused，但进程重启后没有 activeMeeting，
        // 露出录音条只会让人按到必然抛错的暂停键
        #expect(!ProjectRuntimeSession.showsRecordBar(status: .recording, hasLiveRecorder: false))
        #expect(!ProjectRuntimeSession.showsRecordBar(status: .paused, hasLiveRecorder: false))
        // 非录音态即使持有录音器也不显示
        for status in [MeetingStatus.ready, .finalizing, .completed] {
            #expect(!ProjectRuntimeSession.showsRecordBar(status: status, hasLiveRecorder: true))
        }
    }

    @Test("水合：参与者、legacy 字段与状态完整还原，片段深拷贝隔离")
    func rehydrateRestoresFields() throws {
        let project = makeProject(status: .ready)
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)

        #expect(meeting.id == project.id)
        #expect(meeting.title == "桥接项目")
        #expect(meeting.status == .completed) // ready → completed
        #expect(meeting.background == "背景")
        #expect(meeting.ourGoal == "目标")
        #expect(meeting.ourBottomLine == "底线")
        #expect(meeting.counterpartContext == "对方背景")
        #expect(meeting.glossary == ["返点"])
        #expect(meeting.audioRelativePath == "Meetings/x/recording.caf")
        #expect(meeting.preferredInputDeviceID == "device-1")
        #expect(meeting.pauseIntervals == [PauseInterval(startMs: 60_000, endMs: 90_000)])
        #expect(meeting.lastAnalyzedSegmentEndMs == 5_000)

        #expect(meeting.participants.count == 1)
        let participant = try #require(meeting.participants.first)
        #expect(participant.id == project.speakers[0].id)
        #expect(participant.side == .counterpart)
        #expect(participant.role == "采购")
        #expect(participant.voiceReferencePath == "Meetings/x/samples/y.wav")
        #expect(participant.voiceReferenceDurationMs == 4_200)

        #expect(meeting.segments.count == 1)
        #expect(meeting.segments[0].id == project.segments[0].id)
        #expect(meeting.snapshots.count == 1)

        // 深拷贝隔离：改运行时不影响 Project
        meeting.segments[0].text = "被运行时改写"
        #expect(project.segments[0].text == "原话")
    }

    @Test("无 legacyMetadata 的新 V2 项目：水合回退默认，不报错")
    func rehydrateWithoutLegacyMetadata() throws {
        let project = Project(title: "纯 V2 项目", sourceType: .liveRecording, status: .creating)
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        #expect(meeting.status == .ready)
        #expect(meeting.background == "")
        #expect(meeting.participants.isEmpty)
        #expect(meeting.segments.isEmpty)
    }

    @Test("回写：状态、时间轴、片段、快照与游标同步进 Project")
    func applyRuntimeWritesBack() throws {
        let project = makeProject(status: .creating)
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        let now = Date(timeIntervalSince1970: 1_754_000_000)

        // 模拟录音进行：状态、暂停区间、新片段、新快照、分析游标
        try meeting.transition(to: .recording)
        meeting.pauseIntervals.append(PauseInterval(startMs: 120_000, endMs: 150_000))
        let newSegment = TranscriptSegment(startMs: 6_000, endMs: 9_000, text: "新句",
                                           source: .local, state: .final)
        meeting.segments.append(newSegment)
        meeting.snapshots.append(AnalysisSnapshot(version: 2, analyzedThroughMs: 9_000))
        meeting.lastAnalyzedSegmentEndMs = 9_000

        try ProjectRuntimeSession.applyRuntime(meeting, to: project, at: now)

        #expect(project.status == .recording)
        #expect(project.pauseIntervals.count == 2)
        #expect(project.segments.count == 2)
        #expect(project.segments[1].id == newSegment.id)
        #expect(project.legacySnapshots.count == 2)
        #expect(project.legacyMetadata?.lastAnalyzedSegmentEndMs == 9_000)
        #expect(project.lastActivityAt == now)

        // 回写同样是深拷贝：继续改运行时不影响已回写内容
        meeting.segments[1].text = "再次改写"
        #expect(project.segments[1].text == "新句")
    }

    @Test("回写状态映射与迁移器全分支一致，无两套口径")
    func applyRuntimeMappingConsistentWithMigrator() {
        for status in MeetingStatus.allCases {
            #expect(ProjectRuntimeSession.projectStatus(for: status)
                    == MeetingToProjectMigrator.projectStatus(for: status))
        }
    }

    @Test("往返：Project → 运行时 → 回写 → 关键字段保持稳定")
    func roundTripStable() throws {
        let project = makeProject(status: .ready)
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        let now = Date(timeIntervalSince1970: 1_754_000_000)
        try ProjectRuntimeSession.applyRuntime(meeting, to: project, at: now)

        #expect(project.status == .ready) // completed → ready
        #expect(project.startedAt == meeting.startedAt)
        #expect(project.endedAt == meeting.endedAt)
        #expect(project.durationMs == 3_600_000)
        #expect(project.pauseIntervals == [PauseInterval(startMs: 60_000, endMs: 90_000)])
        #expect(project.segments.map(\.id) == [project.segments[0].id])
        #expect(project.segments[0].text == "原话")
        #expect(project.legacySnapshots.count == 1)
        #expect(project.legacyMetadata?.background == "背景")
        #expect(project.lastActivityAt == now)
    }

    @Test("录音资产关联：水合带入、回写写出并经 projectStore 持久化")
    func audioAssetRoundTrip() throws {
        // 水合：project.runtimeAssetRelativePath → meeting.audioRelativePath
        let project = makeProject(status: .ready)
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        #expect(meeting.audioRelativePath == "Meetings/x/recording.caf")

        // 回写：meeting.audioRelativePath → project.runtimeAssetRelativePath
        meeting.audioRelativePath = "Meetings/\(project.id.uuidString)/recording.caf"
        try ProjectRuntimeSession.applyRuntime(meeting, to: project)
        #expect(project.runtimeAssetRelativePath == meeting.audioRelativePath)

        // 持久化往返：写入 JSONProjectStore 重读仍在
        let tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "BangWoFenXiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let store = try JSONProjectStore(directory: tempDirectory)
        try store.saveProjects([project])
        let reread = try JSONProjectStore(directory: tempDirectory)
        #expect(try reread.loadProjects().first?.runtimeAssetRelativePath
                == "Meetings/\(project.id.uuidString)/recording.caf")
    }

    @Test("连续最终片段在窗口内合并为一次落盘")
    func finalSegmentsAreBatched() async throws {
        let project = Project(
            title: "连续转写",
            sourceType: .liveRecording,
            status: .creating
        )
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        var persistCount = 0
        let controller = ProjectRuntimePersistenceController(
            meeting: meeting,
            project: project,
            persist: { _ in persistCount += 1 },
            debounce: .milliseconds(50)
        )

        for index in 0..<20 {
            meeting.segments.append(TranscriptSegment(
                startMs: Int64(index * 1_000),
                endMs: Int64((index + 1) * 1_000),
                text: "片段 \(index)",
                source: .local,
                state: .final
            ))
            controller.schedule()
        }

        await waitUntil { persistCount == 1 && !controller.hasPendingChanges }

        #expect(persistCount == 1)
        #expect(persistCount < meeting.segments.count)
        #expect(project.segments.count == 20)
        #expect(project.segments.last?.text == "片段 19")
    }

    @Test("结束录音强制落盘防抖窗口内的最后片段")
    func finishFlushesLastSegment() throws {
        let project = Project(
            title: "结束落盘",
            sourceType: .liveRecording,
            status: .creating
        )
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        try meeting.transition(to: .recording)
        var persistCount = 0
        let controller = ProjectRuntimePersistenceController(
            meeting: meeting,
            project: project,
            persist: { _ in persistCount += 1 },
            debounce: .seconds(60)
        )

        meeting.segments.append(TranscriptSegment(
            startMs: 0,
            endMs: 2_000,
            text: "结束前最后一句",
            source: .local,
            state: .final
        ))
        controller.schedule()
        try meeting.transition(to: .finalizing)

        #expect(persistCount == 0)
        #expect(controller.flush(force: true))
        #expect(persistCount == 1)
        #expect(project.status == .processing)
        #expect(project.segments.last?.text == "结束前最后一句")
        #expect(!controller.hasPendingChanges)
    }

    // MARK: - 时长兜底（Bug 2）

    @Test("录音中回写：无片段无暂停时 durationMs 用墙钟兜底，不归零")
    func durationFallsBackToWallClockWhileRecording() throws {
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)
        let project = Project(
            title: "未命名录音", sourceType: .liveRecording, status: .recording,
            startedAt: startedAt, durationMs: 0
        )
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        meeting.startedAt = startedAt
        meeting.endedAt = nil
        meeting.segments = []
        meeting.pauseIntervals = []

        try ProjectRuntimeSession.applyRuntime(
            meeting, to: project, at: startedAt.addingTimeInterval(94)
        )

        #expect(project.durationMs == 94_000)
    }

    @Test("已结束会议仍按 endedAt - startedAt，口径不变")
    func durationUsesEndedAtWhenAvailable() throws {
        let project = makeProject(status: .ready)
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)

        try ProjectRuntimeSession.applyRuntime(meeting, to: project)

        #expect(project.durationMs == 3_600_000)
    }

    @Test("墙钟兜底取 max：片段/暂停末端更大时不被 now 拉低")
    func wallClockTakesMaxOfTimelineAndElapsed() {
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)
        let elapsedWins = ProjectRuntimeSession.wallClockDurationMs(
            startedAt: startedAt, endedAt: nil,
            segmentEndMs: 5_000, pauseEndMs: 0,
            now: startedAt.addingTimeInterval(60)
        )
        #expect(elapsedWins == 60_000)

        let timelineWins = ProjectRuntimeSession.wallClockDurationMs(
            startedAt: startedAt, endedAt: nil,
            segmentEndMs: 120_000, pauseEndMs: 0,
            now: startedAt.addingTimeInterval(60)
        )
        #expect(timelineWins == 120_000)
    }

    @Test("startedAt 缺失时退回片段/暂停末端与已有值，不凭空造数")
    func wallClockWithoutStartedAt() {
        let value = ProjectRuntimeSession.wallClockDurationMs(
            startedAt: nil, endedAt: nil,
            segmentEndMs: 0, pauseEndMs: 8_000,
            fallbackDurationMs: 3_000
        )
        #expect(value == 8_000)

        let noSignal = ProjectRuntimeSession.wallClockDurationMs(
            startedAt: nil, endedAt: nil, segmentEndMs: 0, pauseEndMs: 0
        )
        #expect(noSignal == 0)
    }

    // MARK: - 落盘竞态与失败重试（Bug 4）

    @Test("重复 flush 不产生重复写盘")
    func repeatedFlushWritesOnce() throws {
        let project = Project(
            title: "重复落盘", sourceType: .liveRecording, status: .creating
        )
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        var persistCount = 0
        let controller = ProjectRuntimePersistenceController(
            meeting: meeting, project: project,
            persist: { _ in persistCount += 1 },
            debounce: .milliseconds(20)
        )

        meeting.segments.append(TranscriptSegment(
            startMs: 0, endMs: 1_000, text: "一句",
            source: .local, state: .final
        ))
        controller.schedule()
        controller.flush()
        controller.flush()
        controller.flush()

        #expect(persistCount == 1)
        #expect(controller.writeAttemptCount == 1)
        #expect(!controller.hasPendingChanges)
    }

    @Test("防抖任务在 flush 之后失去写盘资格，不再补写一次")
    func inFlightTaskDoesNotWriteAfterFlush() async throws {
        let project = Project(
            title: "竞态", sourceType: .liveRecording, status: .creating
        )
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        var persistCount = 0
        let controller = ProjectRuntimePersistenceController(
            meeting: meeting, project: project,
            persist: { _ in persistCount += 1 },
            debounce: .milliseconds(30)
        )

        meeting.segments.append(TranscriptSegment(
            startMs: 0, endMs: 1_000, text: "一句",
            source: .local, state: .final
        ))
        controller.schedule()
        controller.flush()
        // 等过原防抖窗口，确认在途任务不会再写第二次
        try? await Task.sleep(for: .milliseconds(120))

        #expect(persistCount == 1)
        #expect(controller.writeAttemptCount == 1)
    }

    @Test("写失败后自动退避重试，成功后清除错误")
    func failedWriteRetriesUntilSuccess() async throws {
        let project = Project(
            title: "写失败重试", sourceType: .liveRecording, status: .creating
        )
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        var attempts = 0
        let controller = ProjectRuntimePersistenceController(
            meeting: meeting, project: project,
            persist: { _ in
                attempts += 1
                if attempts == 1 { throw MeetingStoreError.directoryUnavailable }
            },
            debounce: .milliseconds(10)
        )

        meeting.segments.append(TranscriptSegment(
            startMs: 0, endMs: 1_000, text: "一句",
            source: .local, state: .final
        ))
        controller.schedule()

        await waitUntil { attempts >= 1 && controller.saveError != nil }
        #expect(controller.hasPendingChanges)
        #expect(controller.retryCount >= 1)

        // 重试排在 1 秒退避后；不再依赖新的 schedule() 触发
        await waitUntil({
            attempts >= 2 && controller.saveError == nil
        }, timeout: .seconds(5))
        #expect(attempts >= 2)
        #expect(controller.saveError == nil)
        #expect(!controller.hasPendingChanges)
    }

    @Test("持续写失败达上限后停止重试并保留错误")
    func retriesStopAtLimit() async throws {
        let project = Project(
            title: "持续失败", sourceType: .liveRecording, status: .creating
        )
        let meeting = try ProjectRuntimeSession.makeRuntimeMeeting(from: project)
        let controller = ProjectRuntimePersistenceController(
            meeting: meeting, project: project,
            persist: { _ in throw MeetingStoreError.directoryUnavailable },
            debounce: .milliseconds(10)
        )

        meeting.segments.append(TranscriptSegment(
            startMs: 0, endMs: 1_000, text: "一句",
            source: .local, state: .final
        ))
        controller.schedule()

        await waitUntil({
            controller.retryCount >= ProjectRuntimePersistenceController.maxRetryAttempts
        }, timeout: .seconds(20))
        #expect(controller.retryCount == ProjectRuntimePersistenceController.maxRetryAttempts)
        // 失败如实暴露，未保存的变更不被静默丢弃
        #expect(controller.saveError != nil)
        #expect(controller.hasPendingChanges)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(10)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
