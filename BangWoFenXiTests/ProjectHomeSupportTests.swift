import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BangWoFenXi

/// 首页列表纯逻辑测试（阶段 B）：排序、摘要优先级与来源标签。
@Suite("首页项目列表")
final class ProjectHomeSupportTests {

    private func makeProject(title: String, lastActivityAt: Date) -> Project {
        Project(title: title, sourceType: .liveRecording, status: .ready,
                createdAt: lastActivityAt, lastActivityAt: lastActivityAt)
    }

    @Test("最近项目按最后活动时间倒序")
    func sortedByLastActivity() {
        let old = makeProject(title: "旧", lastActivityAt: Date(timeIntervalSince1970: 100))
        let mid = makeProject(title: "中", lastActivityAt: Date(timeIntervalSince1970: 200))
        let new = makeProject(title: "新", lastActivityAt: Date(timeIntervalSince1970: 300))
        let sorted = ProjectHomeSupport.sortedForDisplay([old, new, mid])
        #expect(sorted.map(\.title) == ["新", "中", "旧"])
    }

    @Test("摘要优先级：最新议题 > 最近确认片段 > 暂无内容")
    func summaryPriority() {
        // 有议题：优先议题
        let withTopic = makeProject(title: "议题项目", lastActivityAt: Date())
        let snapshot = AnalysisSnapshot(version: 1, analyzedThroughMs: 1000, currentTopicTitle: "年度量能")
        withTopic.legacySnapshots = [snapshot]
        withTopic.segments = [TranscriptSegment(startMs: 0, endMs: 500, text: "片段正文",
                                                source: .local, state: .final)]
        #expect(ProjectHomeSupport.summary(for: withTopic) == "年度量能")

        // 无议题：取最近一条非临时片段
        let withSegment = makeProject(title: "片段项目", lastActivityAt: Date())
        withSegment.segments = [
            TranscriptSegment(startMs: 0, endMs: 500, text: "临时半句", source: .local, state: .provisional),
            TranscriptSegment(startMs: 0, endMs: 400, text: "已确认的正文", source: .local, state: .final)
        ]
        #expect(ProjectHomeSupport.summary(for: withSegment) == "已确认的正文")

        // 都没有
        let empty = makeProject(title: "空项目", lastActivityAt: Date())
        #expect(ProjectHomeSupport.summary(for: empty) == "暂无内容")
    }

    @Test("超长摘要截断为 60 字")
    func summaryTruncated() {
        let project = makeProject(title: "长文项目", lastActivityAt: Date())
        let longText = String(repeating: "很长的正文", count: 30)
        project.segments = [TranscriptSegment(startMs: 0, endMs: 500, text: longText,
                                              source: .local, state: .final)]
        #expect(ProjectHomeSupport.summary(for: project).count == 60)
    }

    @Test("来源标签四分支")
    func sourceLabels() {
        #expect(ProjectHomeSupport.sourceLabel(for: .liveRecording) == "现场录音")
        #expect(ProjectHomeSupport.sourceLabel(for: .importedAudio) == "导入音频")
        #expect(ProjectHomeSupport.sourceLabel(for: .importedVideo) == "导入视频")
        #expect(ProjectHomeSupport.sourceLabel(for: .combinedRecordings) == "跨录音分析")
    }

    @Test("业务项目归组：同名归一组，未分组收在最后")
    func businessGrouping() {
        let a1 = makeProject(title: "A1", lastActivityAt: Date(timeIntervalSince1970: 100))
        a1.businessCategory = "  河北文旅  "
        let a2 = makeProject(title: "A2", lastActivityAt: Date(timeIntervalSince1970: 300))
        a2.businessCategory = "河北文旅"
        let b = makeProject(title: "B", lastActivityAt: Date(timeIntervalSince1970: 200))
        b.businessCategory = "经销商培训"
        let loose = makeProject(title: "未分组", lastActivityAt: Date(timeIntervalSince1970: 400))

        let groups = ProjectHomeSupport.groupedForDisplay([a1, loose, b, a2])

        #expect(groups.map(\.title) == ["河北文旅", "经销商培训", "未分组录音"])
        #expect(groups[0].projects.map(\.title) == ["A2", "A1"])
        #expect(ProjectHomeSupport.normalizedBusinessCategory("  ") == nil)
    }

    @Test("跨录音合并保持顺序、来源、原始时间戳与独立副本")
    func combinedAnalysisKeepsProvenance() throws {
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let secondDate = Date(timeIntervalSince1970: 2_000)
        let first = makeProject(title: "下午第一段", lastActivityAt: firstDate)
        first.businessCategory = "客户 A"
        first.startedAt = firstDate
        first.durationMs = 10_000
        first.segments = [TranscriptSegment(
            startMs: 2_000,
            endMs: 4_000,
            text: "第一段内容",
            source: .local,
            state: .final
        )]
        let second = makeProject(title: "下午第二段", lastActivityAt: secondDate)
        second.businessCategory = "客户 A"
        second.startedAt = secondDate
        second.durationMs = 8_000
        second.segments = [TranscriptSegment(
            startMs: 500,
            endMs: 2_000,
            text: "第二段内容",
            source: .local,
            state: .edited
        )]

        let combined = try ProjectHomeSupport.makeCombinedAnalysisProject(
            from: [second, first],
            at: Date(timeIntervalSince1970: 3_000)
        )

        #expect(combined.sourceType == .combinedRecordings)
        #expect(combined.businessCategory == "客户 A")
        #expect(combined.sourceRecordings.map(\.projectID) == [first.id, second.id])
        #expect(combined.segments.map(\.text) == ["第一段内容", "第二段内容"])
        #expect(combined.segments[0].sourceAssetId == first.id)
        #expect(combined.segments[1].sourceAssetId == second.id)
        #expect(ProjectHomeSupport.sourceRelativeStartMs(
            for: combined.segments[1],
            in: combined
        ) == 500)

        combined.segments[0].text = "汇总副本修改"
        #expect(first.segments[0].text == "第一段内容")
    }

    @Test("跨业务项目的录音拒绝合并")
    func combinedAnalysisRejectsMixedCategories() {
        let a = makeProject(title: "A", lastActivityAt: Date())
        a.businessCategory = "业务 A"
        a.segments = [TranscriptSegment(
            startMs: 0, endMs: 1_000, text: "A", source: .local, state: .final
        )]
        let b = makeProject(title: "B", lastActivityAt: Date())
        b.businessCategory = "业务 B"
        b.segments = [TranscriptSegment(
            startMs: 0, endMs: 1_000, text: "B", source: .local, state: .final
        )]

        #expect(throws: ProjectHomeSupport.RecordingMergeError.spansBusinessCategories) {
            try ProjectHomeSupport.makeCombinedAnalysisProject(from: [a, b])
        }
    }

    @Test("录音场景按产品顺序展示")
    func recordingScenarioOrder() {
        #expect(ProjectHomeSupport.recordingScenarioOrder == [
            .clientVisit,
            .internalMeeting,
            .journalistInterview,
            .classLearning,
            .freeform
        ])
    }

    @Test("自动场景创建项目时不冒充人工选择")
    func automaticRecordingProject() {
        let date = Date(timeIntervalSince1970: 1_000)
        let project = ProjectHomeSupport.makeRecordingProject(at: date, scenario: nil)
        #expect(project.sourceType == .liveRecording)
        #expect(project.scenario == nil)
        #expect(!project.scenarioWasUserSelected)
        #expect(project.status == .creating)
        #expect(project.createdAt == date)
        #expect(project.lastActivityAt == date)
    }

    @Test("人工场景创建项目时保存选择来源")
    func manuallyClassifiedRecordingProject() {
        let project = ProjectHomeSupport.makeRecordingProject(
            at: Date(timeIntervalSince1970: 1_000),
            scenario: .internalMeeting
        )
        #expect(project.scenario == .internalMeeting)
        #expect(project.scenarioWasUserSelected)
    }

    // MARK: - 状态显示口径（界面 1、2）

    @Test("本次运行中真在录的项目仍显示「录音中」")
    func liveRecordingKeepsRecordingLabel() {
        let project = Project(title: "在录", sourceType: .liveRecording, status: .recording)
        let display = ProjectHomeSupport.displayStatus(
            for: project, liveProjectIDs: [project.id]
        )
        #expect(display == .liveRecording(.recording))
        #expect(display.text == "录音中")
    }

    @Test("未登记的 recording 是崩溃残留，显示「未正常结束」")
    func leftoverRecordingShowsAbnormalLabel() {
        let project = Project(title: "崩了", sourceType: .liveRecording, status: .recording)
        let display = ProjectHomeSupport.displayStatus(
            for: project, liveProjectIDs: []
        )
        #expect(display == .abnormalLeftover(.recording))
        #expect(display.text == "未正常结束")
    }

    @Test(
        "processing / paused 残留同样归入未正常结束",
        arguments: [ProjectStatus.paused, .processing]
    )
    func leftoverCoversAllRecoverableStatuses(status: ProjectStatus) {
        let project = Project(title: "残留", sourceType: .liveRecording, status: status)
        let display = ProjectHomeSupport.displayStatus(
            for: project, liveProjectIDs: []
        )
        #expect(display == .abnormalLeftover(status))
    }

    @Test("正常状态不受运行时登记影响")
    func normalStatusUnaffected() {
        let project = Project(title: "就绪", sourceType: .liveRecording, status: .ready)
        #expect(ProjectHomeSupport.displayStatus(for: project, liveProjectIDs: [project.id])
                == .normal(.ready))
        #expect(ProjectHomeSupport.displayStatus(for: project, liveProjectIDs: [])
                == .normal(.ready))
    }

    @Test("横幅只统计残留项目，活跃录音不计入")
    func leftoverListExcludesLiveRecording() {
        let live = Project(title: "在录", sourceType: .liveRecording, status: .recording)
        let crashed = Project(title: "崩了", sourceType: .liveRecording, status: .recording)
        let ready = Project(title: "就绪", sourceType: .liveRecording, status: .ready)

        let leftover = ProjectHomeSupport.leftoverProjects(
            in: [live, crashed, ready],
            liveProjectIDs: [live.id]
        )
        #expect(leftover.map(\.title) == ["崩了"])
    }

    @Test("「全部标记结束」后不再有残留项目")
    func markingAllLeftoverClearsTheBanner() throws {
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)
        let projects = [
            Project(title: "崩了 1", sourceType: .liveRecording, status: .recording,
                    startedAt: startedAt),
            Project(title: "崩了 2", sourceType: .liveRecording, status: .processing,
                    startedAt: startedAt)
        ]

        for project in ProjectHomeSupport.leftoverProjects(in: projects, liveProjectIDs: []) {
            try MeetingRecovery.markResolvedAfterAbnormalExit(
                project, at: startedAt.addingTimeInterval(60)
            )
        }

        #expect(ProjectHomeSupport.leftoverProjects(in: projects, liveProjectIDs: []).isEmpty)
        #expect(projects.allSatisfy { $0.status == .ready })
        #expect(projects.allSatisfy { $0.durationMs == 60_000 })
    }

    // MARK: - 拖放校验（Bug 6）

    @Test("拖放类型判定：音视频接受，文本/图片/文件夹拒绝")
    func acceptsContentType() {
        #expect(ProjectHomeSupport.acceptsContentType(.mpeg4Movie))
        #expect(ProjectHomeSupport.acceptsContentType(.mp3))
        #expect(ProjectHomeSupport.acceptsContentType(.wav))
        #expect(ProjectHomeSupport.acceptsContentType(.mpeg4Audio))
        #expect(ProjectHomeSupport.acceptsContentType(.quickTimeMovie))
        #expect(!ProjectHomeSupport.acceptsContentType(.plainText))
        #expect(!ProjectHomeSupport.acceptsContentType(.png))
        #expect(!ProjectHomeSupport.acceptsContentType(.pdf))
        #expect(!ProjectHomeSupport.acceptsContentType(.folder))
        #expect(!ProjectHomeSupport.acceptsContentType(.directory))
    }

    @Test("落点预判：登记了具体类型时按类型放行或拒绝，只有 file-url 时放行交给落地校验")
    func acceptsDropByRegisteredTypes() {
        #expect(ProjectHomeSupport.acceptsDrop(registeredContentTypes: [.mpeg4Audio, .fileURL]))
        #expect(!ProjectHomeSupport.acceptsDrop(registeredContentTypes: [.plainText, .fileURL]))
        #expect(!ProjectHomeSupport.acceptsDrop(registeredContentTypes: [.folder, .fileURL]))
        #expect(ProjectHomeSupport.acceptsDrop(registeredContentTypes: [.fileURL]))
        #expect(ProjectHomeSupport.acceptsDrop(registeredContentTypes: []))
    }

    @Test("落地校验：真实音频文件接受，文本文件与文件夹拒绝")
    func acceptsDroppedFileOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "drop-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audio = directory.appending(path: "a.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audio)
        let text = directory.appending(path: "note.txt")
        try Data("hi".utf8).write(to: text)
        let missing = directory.appending(path: "missing.wav")

        #expect(ProjectHomeSupport.acceptsDroppedFile(at: audio))
        #expect(!ProjectHomeSupport.acceptsDroppedFile(at: text))
        #expect(!ProjectHomeSupport.acceptsDroppedFile(at: directory))
        #expect(!ProjectHomeSupport.acceptsDroppedFile(at: missing))
        #expect(!ProjectHomeSupport.acceptsDroppedFile(
            at: URL(string: "https://example.com/a.wav")!))
    }

    // MARK: - 重命名与在 Finder 中显示（Bug 7 最小版）

    @Test("重命名清洗：去首尾空白，纯空白视为无效")
    func normalizedTitleTrimsAndRejectsBlank() {
        #expect(ProjectHomeSupport.normalizedTitle("  客户走访  ") == "客户走访")
        #expect(ProjectHomeSupport.normalizedTitle("客户走访") == "客户走访")
        #expect(ProjectHomeSupport.normalizedTitle("") == nil)
        #expect(ProjectHomeSupport.normalizedTitle("   ") == nil)
        #expect(ProjectHomeSupport.normalizedTitle("\n\t ") == nil)
    }

    @Test("Finder 定位目标：项目目录优先，其次根目录，都不存在时返回 nil")
    func finderRevealTargetFallsBackToBaseDirectory() {
        let base = URL(fileURLWithPath: "/tmp/BangWoFenXi")
        let project = base.appending(path: "Meetings/abc")

        #expect(ProjectHomeSupport.finderRevealTarget(
            projectDirectory: project,
            baseDirectory: base,
            fileExists: { _ in true }
        ) == project)

        #expect(ProjectHomeSupport.finderRevealTarget(
            projectDirectory: project,
            baseDirectory: base,
            fileExists: { $0 == base }
        ) == base)

        #expect(ProjectHomeSupport.finderRevealTarget(
            projectDirectory: project,
            baseDirectory: base,
            fileExists: { _ in false }
        ) == nil)
    }

    // MARK: - 删除项目

    @Test("正在录音的项目拒绝删除")
    func deletionBlockedWhileLiveRecording() {
        let project = makeProject(title: "在录", lastActivityAt: Date())
        project.status = .recording
        #expect(ProjectHomeSupport.deletionBlock(
            for: project,
            liveProjectIDs: [project.id],
            importProcessingProjectID: nil
        ) == .liveRecording)
    }

    @Test("导入流水线正在处理的项目拒绝删除")
    func deletionBlockedWhileImportProcessing() {
        let project = makeProject(title: "导入中", lastActivityAt: Date())
        project.status = .processing
        #expect(ProjectHomeSupport.deletionBlock(
            for: project,
            liveProjectIDs: [],
            importProcessingProjectID: project.id
        ) == .importProcessing)
    }

    @Test("崩溃残留的 recording/paused/processing 允许删除——否则坏项目永远清不掉")
    func deletionAllowedForAbnormalLeftover() {
        for status in [ProjectStatus.recording, .paused, .processing] {
            let project = makeProject(title: "残留", lastActivityAt: Date())
            project.status = status
            #expect(ProjectHomeSupport.deletionBlock(
                for: project,
                liveProjectIDs: [],
                importProcessingProjectID: nil
            ) == nil)
        }
    }

    @Test("别的项目在录音或导入，不影响删除当前项目")
    func deletionAllowedWhenOtherProjectIsBusy() {
        let project = makeProject(title: "就绪", lastActivityAt: Date())
        let other = makeProject(title: "别的", lastActivityAt: Date())
        #expect(ProjectHomeSupport.deletionBlock(
            for: project,
            liveProjectIDs: [other.id],
            importProcessingProjectID: other.id
        ) == nil)
    }

    @Test("删除确认逐项列明内容，导入项目额外提示原件副本")
    func deletionSummaryListsContents() {
        let project = makeProject(title: "客户拜访", lastActivityAt: Date())
        project.segments = [
            TranscriptSegment(startMs: 0, endMs: 1000, text: "一",
                              source: .local, state: .final),
            TranscriptSegment(startMs: 1000, endMs: 2000, text: "二",
                              source: .local, state: .final)
        ]
        let live = ProjectHomeSupport.deletionSummary(for: project)
        #expect(live.contains("客户拜访"))
        #expect(live.contains("2 条转写"))
        #expect(live.contains("不可恢复"))
        #expect(!live.contains("原始文件副本"))

        project.sourceType = .importedVideo
        #expect(ProjectHomeSupport.deletionSummary(for: project).contains("原始文件副本"))
    }
}
