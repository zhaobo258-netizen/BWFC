import SwiftUI

/// 三栏宽度联合求解（Codex 审计补强）。
/// 左、中、右宽度来自同一个求解结果，任何拖动顺序下恒有：
/// left + center + right + handles == availableWidth。
enum ThreeColumnMetrics {
    static let minLeft: CGFloat = 320
    static let minCenter: CGFloat = 420
    static let minRight: CGFloat = 280
    /// 极端窗口下的兜底宽度（避免负值；正常最小窗口 1280 不会触发）
    static let floorWidth: CGFloat = 160

    /// 三栏宽度结果
    struct Widths: Equatable {
        var left: CGFloat
        var center: CGFloat
        var right: CGFloat
    }

    /// 联合求解：给定可用总宽与左右占比，产出三栏宽度。
    /// 不变量：left + center + right == total - handles；center 恒为余量（≥ minCenter，除非总宽不足兜底）。
    static func solve(total: CGFloat, handles: CGFloat = 2,
                      leftFraction: Double, rightFraction: Double) -> Widths {
        let available = max(0, total - handles)

        // 总宽不足三栏最小值时等比收缩兜底，仍严格满足恒等式
        let minSum = minLeft + minCenter + minRight
        if available < minSum {
            let scale = available / minSum
            let left = max(0, minLeft * scale).rounded(.down)
            let right = max(0, minRight * scale).rounded(.down)
            let center = available - left - right
            return Widths(left: left, center: center, right: right)
        }

        // 左栏：占比驱动，钳制在 [minLeft, 给中右留足最小值]
        let maxLeft = available - minCenter - minRight
        let left = min(max(CGFloat(leftFraction) * available, minLeft), maxLeft)

        // 右栏：占比驱动，钳制在 [minRight, 给左中留足最小值]
        let maxRight = available - left - minCenter
        let right = min(max(CGFloat(rightFraction) * available, minRight), maxRight)

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
/// 左文稿 / 中分析 / 右笔记，宽度可拖动调整并经 @AppStorage 记忆；
/// 宽度由 ThreeColumnMetrics.solve 统一求解（联合约束）；
/// 分隔条带可访问标签与键盘调整能力（方向键 ±2%）。
struct ThreeColumnLayout<Left: View, Center: View, Right: View>: View {
    /// 左栏宽度占比（持久化记忆）
    @AppStorage("bwfx.workspace.leftFraction") private var leftFraction: Double = 0.34
    /// 右栏宽度占比（持久化记忆）；中栏取剩余
    @AppStorage("bwfx.workspace.rightFraction") private var rightFraction: Double = 0.25

    @ViewBuilder var left: () -> Left
    @ViewBuilder var center: () -> Center
    @ViewBuilder var right: () -> Right

    /// 拖动中的临时位移（结束时写入占比记忆）
    @State private var leftDragDelta: CGFloat = 0
    @State private var rightDragDelta: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            // 拖动中预览：把位移折算进占比后仍走同一联合求解
            let effectiveLeft = ThreeColumnMetrics.adjustedFraction(
                current: leftFraction, delta: leftDragDelta / max(1, total),
                total: total, minWidth: ThreeColumnMetrics.minLeft,
                reservedOthers: ThreeColumnMetrics.minCenter + ThreeColumnMetrics.minRight)
            let effectiveRight = ThreeColumnMetrics.adjustedFraction(
                current: rightFraction, delta: -rightDragDelta / max(1, total),
                total: total, minWidth: ThreeColumnMetrics.minRight,
                reservedOthers: ThreeColumnMetrics.minLeft + ThreeColumnMetrics.minCenter)
            let widths = ThreeColumnMetrics.solve(
                total: total, leftFraction: effectiveLeft, rightFraction: effectiveRight)

            HStack(spacing: 0) {
                left()
                    .frame(width: widths.left)
                dragHandle(
                    label: "调整文稿栏宽度",
                    fraction: effectiveLeft,
                    delta: $leftDragDelta,
                    onChanged: { value in leftDragDelta = value },
                    onEnded: { value in
                        leftFraction = ThreeColumnMetrics.adjustedFraction(
                            current: leftFraction, delta: value / max(1, total),
                            total: total, minWidth: ThreeColumnMetrics.minLeft,
                            reservedOthers: ThreeColumnMetrics.minCenter + ThreeColumnMetrics.minRight)
                        leftDragDelta = 0
                    },
                    onKeyboard: { step in
                        leftFraction = ThreeColumnMetrics.adjustedFraction(
                            current: leftFraction, delta: step,
                            total: total, minWidth: ThreeColumnMetrics.minLeft,
                            reservedOthers: ThreeColumnMetrics.minCenter + ThreeColumnMetrics.minRight)
                    }
                )
                center()
                    .frame(width: widths.center)
                dragHandle(
                    label: "调整笔记栏宽度",
                    fraction: effectiveRight,
                    delta: $rightDragDelta,
                    onChanged: { value in rightDragDelta = value },
                    onEnded: { value in
                        rightFraction = ThreeColumnMetrics.adjustedFraction(
                            current: rightFraction, delta: -value / max(1, total),
                            total: total, minWidth: ThreeColumnMetrics.minRight,
                            reservedOthers: ThreeColumnMetrics.minLeft + ThreeColumnMetrics.minCenter)
                        rightDragDelta = 0
                    },
                    onKeyboard: { step in
                        // 右栏：增大占比 = 向左扩展，方向与左栏一致表述为占比增减
                        rightFraction = ThreeColumnMetrics.adjustedFraction(
                            current: rightFraction, delta: step,
                            total: total, minWidth: ThreeColumnMetrics.minRight,
                            reservedOthers: ThreeColumnMetrics.minLeft + ThreeColumnMetrics.minCenter)
                    }
                )
                right()
                    .frame(width: widths.right)
            }
        }
    }

    /// 分隔拖动手柄：可拖动 + 可访问标签 + 键盘调整（方向键/±）
    private func dragHandle(
        label: String,
        fraction: Double,
        delta: Binding<CGFloat>,
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat) -> Void,
        onKeyboard: @escaping (Double) -> Void
    ) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in onChanged(value.translation.width) }
                    .onEnded { value in onEnded(value.translation.width) }
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(Text("\(Int((fraction * 100).rounded()))%"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onKeyboard(0.02)
                case .decrement: onKeyboard(-0.02)
                @unknown default: break
                }
            }
    }
}
