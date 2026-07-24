import Foundation
import Testing
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

    @Test("来源标签三分支")
    func sourceLabels() {
        #expect(ProjectHomeSupport.sourceLabel(for: .liveRecording) == "现场录音")
        #expect(ProjectHomeSupport.sourceLabel(for: .importedAudio) == "导入音频")
        #expect(ProjectHomeSupport.sourceLabel(for: .importedVideo) == "导入视频")
    }
}
