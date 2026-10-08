import SwiftUI

/// 工作台共享组件（界面设计定稿 v1.0）。
/// 本文件为独立组件库：ProjectWorkspaceView 的接线（状态条 chips 数据源、
/// 底部证据条/标记按钮、窄窗单区切换）由集成人按《交接_界面定稿SwiftUI实现》完成；
/// 组件本身已被人物理解页等独立视图直接使用。
///
/// 组件清单：
/// - `BWStatusChip`：状态条 chip——只渲染「需要处理」的项（正常态不进状态条）
/// - `BWMarkButton`：「标记此刻」44pt 实心主按钮 + 已标记反馈 + 计数
/// - `BWInferenceCard`：推测卡——inferBg 底 +「推测」文字标签（颜色不单独承担语义）
/// - `BWLevelIndicator`：录音电平 3 柱 1s 循环动画（录音中才显示）
/// - `BWTagChip`：语义小标签（推测/待核对/AI 推断等）

// MARK: - 状态条 chip

/// 状态条 chip：panel 底 + border + 7pt 状态点。
/// 规则：只挂「需要处理」的项——待确认/失败/过期；正常态（音频已保存等）不进状态条。
struct BWStatusChip: View {
    enum Tone {
        /// 需要处理（警告）
        case warn
        /// 失败/逾期（错误底）
        case error
        /// 处理中（中性信息，canvas 底）
        case running

        var dotColor: Color {
            switch self {
            case .warn: return BWTheme.warn
            case .error: return BWTheme.danger
            case .running: return BWTheme.evidence
            }
        }
    }

    let text: String
    let tone: Tone
    /// nil 时为纯状态展示；有值时才是可点按钮（按钮都是真按钮）
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .accessibilityLabel(text)
    }

    private var label: some View {
        HStack(spacing: 6) {
            Circle().fill(tone.dotColor).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: BWTheme.fontSizeDetail, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tone == .error ? BWTheme.danger : BWTheme.ink2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            tone == .error ? BWTheme.dangerBg : BWTheme.panel,
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(BWTheme.border, lineWidth: 1)
        )
    }
}

// MARK: - 标记此刻（会中第一动作）

/// 「标记此刻」：44pt 高 accentButton 实心大按钮；点击后短暂「已标记 ✓」反馈；
/// 旁显已标记计数由调用方放置。录音中全屏最大按钮（S04）。
struct BWMarkButton: View {
    let markedCount: Int
    let action: () -> Void

    @State private var justMarked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Button(action: {
                action()
                justMarked = true
                // 900ms 后恢复按钮文案（对齐原型反馈时长）
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    justMarked = false
                }
            }) {
                HStack(spacing: 7) {
                    Image(systemName: justMarked ? "checkmark" : "bookmark.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(justMarked ? "已标记" : "标记此刻")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: BWTheme.heroActionHeight)
                .background(BWTheme.accentButton, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: BWTheme.accentButton.opacity(0.25), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: justMarked)
            .accessibilityLabel("标记此刻")
            .help("标记当前时刻的原话，会后在「标记」页集中查看")

            if markedCount > 0 {
                Text("已标记 \(markedCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BWTheme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(BWTheme.accentSoft, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

// MARK: - 推测卡

/// 推测卡：inferBg 底 +「推测」文字标签 + 依据入口。
/// 推断内容必须带文字标签，颜色不单独承担语义（定稿决策 4）。
struct BWInferenceCard<Actions: View>: View {
    let text: String
    /// 右侧依据/操作（如「查看依据」链接）
    @ViewBuilder var actions: Actions

    init(text: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(BWTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            BWTagChip(text: "推测")
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(BWTheme.inferBg, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 语义小标签

/// 推测/待核对等语义标签：inferTag 底 + inferInk 字（深色下均提亮，实测 6.6:1）
struct BWTagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BWTheme.inferInk)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(BWTheme.inferTag, in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - 录音电平指示

/// 电平指示：3 柱 1s 循环缩放动画；与 REC 计时并列，录音中才显示。
struct BWLevelIndicator: View {
    var barColor: Color = BWTheme.ok
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let heights: [CGFloat] = [0.6, 1.0, 0.75]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor)
                    .frame(width: 3.4, height: 15 * height)
                    .scaleEffect(y: animate && !reduceMotion ? 0.45 : 1)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 1)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .frame(height: 15)
        .onAppear { animate = true }
        .accessibilityHidden(true)
    }
}
