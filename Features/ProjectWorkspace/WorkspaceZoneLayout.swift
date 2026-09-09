import SwiftUI

/// A 版双区布局模式（M2）：在工作台正文内容宽度上判定，
/// 与旧 WorkspaceLayoutMode（窄/紧凑/宽，三栏与 inspector 语义）解耦。
///
/// - `.dual`: 左「理解与回看」/ 右「笔记与 AI」两区并存。
/// - `.single`: 一区独占，由用户在两个区之间切换。
enum WorkspaceZoneMode: Equatable {
    case dual
    case single
}

/// 双区宽度求解（纯逻辑，可单测）。
/// 常量对齐产品 A 版：常驻项目侧栏宽度由调用方在传入 usableWidth 前扣除；
/// 这里只消费真正可用的正文宽度。
enum WorkspaceDualZonePolicy {
    /// 扣除项目侧栏后的最小双区宽度
    static let minimumDualZoneWidth: CGFloat = 800
    /// 左「理解与回看」最小宽度
    static let leftMinimum: CGFloat = 400
    /// 右「笔记与 AI」最小宽度
    static let rightMinimum: CGFloat = 360
    /// 两区之间的留白（分隔条等效间距）
    static let gap: CGFloat = 12
    /// 默认左右占比（58/42）
    static let leftFraction: Double = 0.58

    struct Widths: Equatable {
        var left: CGFloat
        var right: CGFloat

        static let zero = Widths(left: 0, right: 0)
    }

    /// 依据实际可用宽度判定双区/单区。
    /// 双区需要：宽度 ≥ 800，且左/右最小宽度 + 留白能被容纳。
    static func mode(for usableWidth: CGFloat) -> WorkspaceZoneMode {
        let canFitMinimums = (usableWidth - gap) >= (leftMinimum + rightMinimum)
        if usableWidth >= minimumDualZoneWidth && canFitMinimums {
            return .dual
        }
        return .single
    }

    /// 双区宽度：左区占比 58%（钳制在最小值），右区取余量。
    /// 返回的宽度必须满足 left + right + gap == usableWidth（总宽不足时等比收缩，不产生负宽）。
    static func solve(
        usableWidth: CGFloat,
        fraction: Double = leftFraction
    ) -> Widths {
        let available = max(0, usableWidth - gap)
        let minimumSum = leftMinimum + rightMinimum
        if available < minimumSum {
            let scale = available / minimumSum
            let left = max(0, (leftMinimum * scale).rounded(.down))
            return Widths(left: left, right: max(0, available - left))
        }
        let left = min(
            max(available * CGFloat(fraction), leftMinimum),
            available - rightMinimum
        )
        return Widths(left: left, right: max(0, available - left))
    }
}

/// 单区模式下当前展示的区（与双区共用同一份数据源）
enum WorkspaceSingleZoneSelection: Equatable {
    case understanding // 理解与回看
    case notesAndAI    // 笔记与 AI

    mutating func toggle() {
        self = self == .understanding ? .notesAndAI : .understanding
    }
}

/// 项目侧栏常驻时对正文可用宽度的扣除（纯计算，供布局测试与工作台使用）。
enum ProjectSidebarWidthAccounting {
    /// 常驻项目侧栏宽度 + 与正文之间的分隔线
    static func contentWidth(totalWindowWidth: CGFloat,
                             sidebarShown: Bool) -> CGFloat {
        guard sidebarShown else { return totalWindowWidth }
        let sidebar = ProjectWorkspaceView.projectSidebarWidth + 1
        return max(0, totalWindowWidth - sidebar)
    }

    /// 双区在当前窗口宽度与侧栏状态下是否可用。
    static func zoneMode(totalWindowWidth: CGFloat,
                         sidebarShown: Bool) -> WorkspaceZoneMode {
        WorkspaceDualZonePolicy.mode(
            for: contentWidth(totalWindowWidth: totalWindowWidth,
                              sidebarShown: sidebarShown)
        )
    }
}
