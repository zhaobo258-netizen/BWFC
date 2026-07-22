import Foundation

/// Obsidian 归档状态（产品文档 03 号 §8.5）。
/// 记录项目与 vault 的关联与同步游标；本阶段仅定义结构，归档实现在后续阶段。
struct ArchiveState: Codable, Sendable, Hashable {
    /// vault 安全书签 ID
    var vaultBookmarkId: String?
    /// vault 内项目相对路径
    var projectRelativePath: String?
    /// 最近一次同步时间
    var lastSyncedAt: Date?
    /// 最近一次同步的清单哈希（用于变更检测）
    var lastManifestHash: String?
    /// 是否存在待同步变更
    var hasPendingChanges: Bool

    init(
        vaultBookmarkId: String? = nil,
        projectRelativePath: String? = nil,
        lastSyncedAt: Date? = nil,
        lastManifestHash: String? = nil,
        hasPendingChanges: Bool = false
    ) {
        self.vaultBookmarkId = vaultBookmarkId
        self.projectRelativePath = projectRelativePath
        self.lastSyncedAt = lastSyncedAt
        self.lastManifestHash = lastManifestHash
        self.hasPendingChanges = hasPendingChanges
    }
}
