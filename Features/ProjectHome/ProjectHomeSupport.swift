import Foundation

/// 首页列表的纯逻辑（可单测）：排序与一行摘要。
enum ProjectHomeSupport {
    /// 最近项目按最近活动时间倒序
    static func sortedForDisplay(_ projects: [Project]) -> [Project] {
        projects.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// 一行摘要：优先最新分析快照的当前议题，其次最近一条已确认片段正文；
    /// 都没有时返回「暂无内容」。摘要最长 60 字。
    static func summary(for project: Project) -> String {
        if let topic = project.legacySnapshots
            .max(by: { $0.version < $1.version })?.currentTopicTitle,
           !topic.isEmpty {
            return String(topic.prefix(60))
        }
        if let text = project.segments
            .filter({ $0.state != .provisional })
            .last?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return String(text.prefix(60))
        }
        return "暂无内容"
    }

    /// 来源类型的中文标签
    static func sourceLabel(for sourceType: ProjectSourceType) -> String {
        switch sourceType {
        case .liveRecording: return "现场录音"
        case .importedAudio: return "导入音频"
        case .importedVideo: return "导入视频"
        }
    }
}
