import SwiftUI

enum WorkspaceLayoutMode: Equatable {
    case narrow
    case compact
    case wide

    static func resolve(totalWidth: CGFloat) -> Self {
        if totalWidth >= 1280 {
            return .wide
        }
        if totalWidth >= 1080 {
            return .compact
        }
        return .narrow
    }

    func showsPersistentSidebar(preference: Bool) -> Bool {
        self == .wide && preference
    }

    var usesNotesInspector: Bool {
        self == .narrow
    }
}

/// 三栏宽度联合求解（Codex 审计补强）。
/// 左、中、右宽度来自同一个求解结果，任何拖动顺序下恒有：
/// left + center + right + handles == availableWidth。
enum ThreeColumnMetrics {
    struct Minimums: Equatable {
        var left: CGFloat
        var center: CGFloat
        var right: CGFloat

        static let wide = Self(left: 320, center: 420, right: 280)
        static let compact = Self(left: 280, center: 400, right: 240)
    }

    static let minLeft = Minimums.wide.left
    static let minCenter = Minimums.wide.center
    static let minRight = Minimums.wide.right

    /// 三栏宽度结果
    struct Widths: Equatable {
        var left: CGFloat
        var center: CGFloat
        var right: CGFloat
    }

    /// 联合求解：给定可用总宽与左右占比，产出三栏宽度。
    /// 不变量：left + center + right == total - handles；center 恒为余量（≥ minCenter，除非总宽不足兜底）。
    static func solve(total: CGFloat, handles: CGFloat = 2,
                      minimums: Minimums = .wide,
                      leftFraction: Double, rightFraction: Double) -> Widths {
        let available = max(0, total - handles)

        // 总宽不足三栏最小值时等比收缩兜底，仍严格满足恒等式
        let minSum = minimums.left + minimums.center + minimums.right
        if available < minSum {
            let scale = available / minSum
            let left = max(0, minimums.left * scale).rounded(.down)
            let right = max(0, minimums.right * scale).rounded(.down)
            let center = available - left - right
            return Widths(left: left, center: center, right: right)
        }

        // 左栏：占比驱动，钳制在 [minLeft, 给中右留足最小值]
        let maxLeft = available - minimums.center - minimums.right
        let left = min(max(CGFloat(leftFraction) * available, minimums.left), maxLeft)

        // 右栏：占比驱动，钳制在 [minRight, 给左中留足最小值]
        let maxRight = available - left - minimums.center
        let right = min(max(CGFloat(rightFraction) * available, minimums.right), maxRight)

        // 中栏恒取余量：保证三栏之和严格等于 available
        let center = available - left - right
        return Widths(left: left, center: center, right: right)
    }

    /// 键盘/辅助调整后的新占比（步进 2%，经联合求解反推安全区间）
    static func adjustedFraction(current: Double, delta: Double, total: CGFloat,
                                 minWidth: CGFloat, reservedOthers: CGFloat) -> Double {
        let available = max(1, total - 2)
        let maxWidth = available - reservedOthers
        let currentWidth = CGFloat(current) * available
        let newWidth = min(max(currentWidth + delta * available, minWidth), max(minWidth, maxWidth))
        return Double(newWidth / available)
    }
}

/// 三栏布局（阶段 B 工作台骨架，03 文档 §6.3）：
/// 左文稿 / 中分析 / 右 AI 共创笔记，宽度可拖动调整并经 @AppStorage 记忆；
/// 宽度由 ThreeColumnMetrics.solve 统一求解（联合约束）；
/// 分隔条带可访问标签与键盘调整能力（方向键 ±2%）。
struct ThreeColumnLayout<Left: View, Center: View, Right: View>: View {
    /// 左栏宽度占比（持久化记忆）
    @AppStorage("bwfx.workspace.leftFraction") private var leftFraction: Double = 0.34
    /// 右栏宽度占比（持久化记忆）；中栏取剩余
    @AppStorage("bwfx.workspace.rightFraction") private var rightFraction: Double = 0.25

    let minimums: ThreeColumnMetrics.Minimums
    @ViewBuilder let left: () -> Left
    @ViewBuilder let center: () -> Center
    @ViewBuilder let right: () -> Right

    /// 拖动中的临时位移（结束时写入占比记忆）
    @State private var leftDragDelta: CGFloat = 0
    @State private var rightDragDelta: CGFloat = 0

    init(
        minimums: ThreeColumnMetrics.Minimums = .wide,
        @ViewBuilder left: @escaping () -> Left,
        @ViewBuilder center: @escaping () -> Center,
        @ViewBuilder right: @escaping () -> Right
    ) {
        self.minimums = minimums
        self.left = left
        self.center = center
        self.right = right
    }

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            // 拖动中预览：把位移折算进占比后仍走同一联合求解
            let effectiveLeft = ThreeColumnMetrics.adjustedFraction(
                current: leftFraction, delta: leftDragDelta / max(1, total),
                total: total, minWidth: minimums.left,
                reservedOthers: minimums.center + minimums.right)
            let effectiveRight = ThreeColumnMetrics.adjustedFraction(
                current: rightFraction, delta: -rightDragDelta / max(1, total),
                total: total, minWidth: minimums.right,
                reservedOthers: minimums.left + minimums.center)
            let widths = ThreeColumnMetrics.solve(
                total: total,
                minimums: minimums,
                leftFraction: effectiveLeft,
                rightFraction: effectiveRight
            )

            HStack(spacing: 0) {
                left()
                    .frame(width: widths.left)
                ColumnDragHandle(
                    label: "调整文稿栏宽度",
                    fraction: effectiveLeft,
                    onChanged: { value in leftDragDelta = value },
                    onEnded: { value in
                        leftFraction = ThreeColumnMetrics.adjustedFraction(
                            current: leftFraction, delta: value / max(1, total),
                            total: total, minWidth: minimums.left,
                            reservedOthers: minimums.center + minimums.right)
                        leftDragDelta = 0
                    },
                    onKeyboard: { step in
                        leftFraction = ThreeColumnMetrics.adjustedFraction(
                            current: leftFraction, delta: step,
                            total: total, minWidth: minimums.left,
                            reservedOthers: minimums.center + minimums.right)
                    }
                )
                center()
                    .frame(width: widths.center)
                ColumnDragHandle(
                    label: "调整 AI 共创笔记栏宽度",
                    fraction: effectiveRight,
                    onChanged: { value in rightDragDelta = value },
                    onEnded: { value in
                        rightFraction = ThreeColumnMetrics.adjustedFraction(
                            current: rightFraction, delta: -value / max(1, total),
                            total: total, minWidth: minimums.right,
                            reservedOthers: minimums.left + minimums.center)
                        rightDragDelta = 0
                    },
                    onKeyboard: { step in
                        rightFraction = ThreeColumnMetrics.adjustedFraction(
                            current: rightFraction, delta: -step,
                            total: total, minWidth: minimums.right,
                            reservedOthers: minimums.left + minimums.center)
                    }
                )
                right()
                    .frame(width: widths.right)
            }
        }
    }
}

enum TwoColumnMetrics {
    static let minLeft: CGFloat = 240
    static let minCenter: CGFloat = 360

    struct Widths: Equatable {
        var left: CGFloat
        var center: CGFloat
    }

    static func solve(
        total: CGFloat,
        handle: CGFloat = 2,
        leftFraction: Double
    ) -> Widths {
        let available = max(0, total - handle)
        let minimumSum = minLeft + minCenter
        if available < minimumSum {
            let scale = available / minimumSum
            let left = max(0, minLeft * scale).rounded(.down)
            return Widths(left: left, center: available - left)
        }
        let left = min(
            max(CGFloat(leftFraction) * available, minLeft),
            available - minCenter
        )
        return Widths(left: left, center: available - left)
    }

    static func adjustedFraction(
        current: Double,
        delta: Double,
        total: CGFloat
    ) -> Double {
        let available = max(1, total - 2)
        let currentWidth = CGFloat(current) * available
        let newWidth = min(
            max(currentWidth + delta * available, minLeft),
            max(minLeft, available - minCenter)
        )
        return Double(newWidth / available)
    }
}

struct TwoColumnLayout<Left: View, Center: View>: View {
    @AppStorage("bwfx.workspace.leftFraction") private var leftFraction: Double = 0.34

    @ViewBuilder let left: () -> Left
    @ViewBuilder let center: () -> Center

    @State private var leftDragDelta: CGFloat = 0

    init(
        @ViewBuilder left: @escaping () -> Left,
        @ViewBuilder center: @escaping () -> Center
    ) {
        self.left = left
        self.center = center
    }

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let effectiveLeft = TwoColumnMetrics.adjustedFraction(
                current: leftFraction,
                delta: leftDragDelta / max(1, total),
                total: total
            )
            let widths = TwoColumnMetrics.solve(
                total: total,
                leftFraction: effectiveLeft
            )

            HStack(spacing: 0) {
                left()
                    .frame(width: widths.left)
                ColumnDragHandle(
                    label: "调整文稿栏宽度",
                    fraction: effectiveLeft,
                    onChanged: { leftDragDelta = $0 },
                    onEnded: { value in
                        leftFraction = TwoColumnMetrics.adjustedFraction(
                            current: leftFraction,
                            delta: value / max(1, total),
                            total: total
                        )
                        leftDragDelta = 0
                    },
                    onKeyboard: { step in
                        leftFraction = TwoColumnMetrics.adjustedFraction(
                            current: leftFraction,
                            delta: step,
                            total: total
                        )
                    }
                )
                center()
                    .frame(width: widths.center)
            }
        }
    }
}

private struct ColumnDragHandle: View {
    let label: String
    let fraction: Double
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onKeyboard: (Double) -> Void

    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? BWTheme.accent.opacity(0.9) : Color.gray.opacity(0.18))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -5))
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { onChanged($0.translation.width) }
                    .onEnded { onEnded($0.translation.width) }
            )
            .focusable()
            .onKeyPress(.leftArrow) {
                onKeyboard(-0.02)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                onKeyboard(0.02)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(Text("\(Int((fraction * 100).rounded()))%"))
            .accessibilityHint("使用左右方向键或辅助调整操作改变栏宽")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onKeyboard(0.02)
                case .decrement: onKeyboard(-0.02)
                @unknown default: break
                }
            }
    }
}
