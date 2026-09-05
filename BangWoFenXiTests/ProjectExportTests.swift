import Foundation
import Testing
@testable import BangWoFenXi

@Suite("项目资料包导出")
struct ProjectExportTests {
    @Test("仅有 AI 归结也可作为项目笔记导出")
    func exportsConversationNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(title: "合成笔记", sourceType: .liveRecording,
            note: NoteDocument(conversationSummaries: [
                .init(id: UUID(), markdown: "- AI 建议：先核对数量。", createdAt: Date())
            ]))
        let service = ProjectExportService()
        #expect(service.availableContents(project: project, recordingURL: nil).contains(.projectNote))
        let result = try service.export(project: project, recordingURL: nil, contents: [.projectNote], to: root)
        let files = try FileManager.default.contentsOfDirectory(at: result, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let text = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(text.contains("AI 对话归结"))
        #expect(text.contains("AI 建议：先核对数量。"))
    }

    @Test("按勾选项分别导出录音、转写和分析")
    func selectedContentsOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bwfx-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = root.appendingPathComponent("source.caf")
        try Data("audio".utf8).write(to: audio)
        let speaker = Speaker(cloudAlias: "p_01", displayName: "赵总")
        let segment = TranscriptSegment(
            startMs: 1_000,
            endMs: 2_000,
            text: "这是确认后的转写。",
            participantId: speaker.id,
            source: .cloud,
            state: .final
        )
        let snapshot = ConversationAnalysisSnapshot(
            version: 1,
            analyzedThroughMs: 2_000,
            headline: "讨论了导出功能",
            items: [
                AnalysisItem(
                    category: .summary,
                    text: "需要按内容选择导出。",
                    epistemicStatus: .explicit,
                    confidence: .high,
                    evidenceSegmentIds: [segment.id]
                )
            ]
        )
        let project = Project(
            title: "导出/测试",
            sourceType: .liveRecording,
            status: .ready,
            speakers: [speaker],
            segments: [segment],
            analysisSnapshots: [snapshot]
        )

        let result = try ProjectExportService().export(
            project: project,
            recordingURL: audio,
            contents: [.recording, .transcript, .liveSummary],
            to: root,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: result.path)

        #expect(files.sorted() == ["原始录音.caf", "实时总结.md", "完整转写.md"].sorted())
        let transcript = try String(contentsOf: result.appendingPathComponent("完整转写.md"), encoding: .utf8)
        #expect(transcript.contains("[00:01] **赵总**：这是确认后的转写。"))
        let summary = try String(contentsOf: result.appendingPathComponent("实时总结.md"), encoding: .utf8)
        #expect(summary.contains("讨论了导出功能"))
        #expect(summary.contains("需要按内容选择导出"))
        #expect(summary.contains("明确表达 · 置信度高"))
        #expect(summary.contains("证据 [00:01 赵总]：这是确认后的转写。"))
        #expect(!files.contains("动机与目的.md"))
        #expect(!result.lastPathComponent.contains("/"))
    }

    @Test("完成项目已有转写时不再显示语言资源下载横幅")
    func completedProjectHidesAssetBanner() {
        let project = Project(
            title: "已完成",
            sourceType: .liveRecording,
            status: .ready,
            segments: [TranscriptSegment(startMs: 0, endMs: 1_000, text: "完成", source: .local, state: .final)]
        )
        #expect(!ProjectAssetBannerPolicy.shouldShow(project: project))

        project.segments = []
        #expect(ProjectAssetBannerPolicy.shouldShow(project: project))
    }

    @Test("只有无活动采集器的实时录音项目可续录")
    func recordingContinuationPolicy() {
        let project = Project(
            title: "已完成录音",
            sourceType: .liveRecording,
            status: .ready
        )
        #expect(ProjectRecordingContinuationPolicy.canContinue(
            project: project,
            meetingStatus: .completed,
            hasLiveRecorder: false
        ))
        #expect(!ProjectRecordingContinuationPolicy.canContinue(
            project: project,
            meetingStatus: .completed,
            hasLiveRecorder: true
        ))

        project.sourceType = .importedAudio
        #expect(!ProjectRecordingContinuationPolicy.canContinue(
            project: project,
            meetingStatus: .completed,
            hasLiveRecorder: false
        ))
    }
}
