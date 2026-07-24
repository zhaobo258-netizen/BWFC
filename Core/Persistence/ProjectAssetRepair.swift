import Foundation

/// 录音资产缺失的安全恢复（Codex 审计补强）。
///
/// 背景：阶段 B 初版 applyRuntime 未回写 audioRelativePath，导致部分
/// liveRecording 项目 runtimeAssetRelativePath=nil，但录音文件真实存在于
/// 标准相对路径 Meetings/<projectID>/recording.caf。
///
/// 恢复规则（全部满足才补写）：
/// 1. sourceType == .liveRecording；
/// 2. runtimeAssetRelativePath 为空（已有非空路径的项目绝不覆盖）；
/// 3. 标准相对路径的文件存在且非空（大小 > 0）。
/// 只写 projects.json 中的路径字段；不移动、不改写任何录音文件；幂等。
enum ProjectAssetRepair {

    /// 纯判定：项目是否满足补写条件（可单测）
    static func needsRepair(_ project: Project, fileStore: MeetingFileStore) -> Bool {
        guard project.sourceType == .liveRecording,
              project.runtimeAssetRelativePath?.isEmpty != false else {
            return false
        }
        let relativePath = fileStore.relativeAudioPath(for: project.id)
        guard let url = try? fileStore.absoluteURL(forRelativePath: relativePath),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return false
        }
        return size > 0
    }

    /// 对项目数组执行补写（原地修改传入的 Project 对象），返回补写数量。
    static func repair(_ projects: [Project], fileStore: MeetingFileStore) -> Int {
        var repairedCount = 0
        for project in projects where needsRepair(project, fileStore: fileStore) {
            project.runtimeAssetRelativePath = fileStore.relativeAudioPath(for: project.id)
            repairedCount += 1
        }
        return repairedCount
    }

    /// 便捷入口：读取 → 补写 → 仅在确有变化时写回，返回补写数量（幂等）。
    @discardableResult
    static func repairIfNeeded(store: any ProjectStoring, fileStore: MeetingFileStore) throws -> Int {
        let projects = try store.loadProjects()
        let repairedCount = repair(projects, fileStore: fileStore)
        if repairedCount > 0 {
            try store.saveProjects(projects)
        }
        return repairedCount
    }
}
