import SwiftUI
import AppKit

/// 《帮我分析》设计系统（参考得到系学习工具质感：纸感底色、暖橙主色、卡片化信息层级）。
/// 所有颜色均为明暗双态动态色；视图统一经 bwCard() / BWBadge 等取用，不散落魔法值。
enum BWTheme {
    // MARK: - 颜色

    /// 主强调色：暖橙
    static let accent = Color(light: NSColor(srgbRed: 0.98, green: 0.45, blue: 0.12, alpha: 1),
                              dark: NSColor(srgbRed: 1.00, green: 0.52, blue: 0.22, alpha: 1))
    /// 主强调色的深端（渐变用）
    static let accentDeep = Color(light: NSColor(srgbRed: 0.92, green: 0.33, blue: 0.06, alpha: 1),
                                  dark: NSColor(srgbRed: 0.95, green: 0.40, blue: 0.10, alpha: 1))
    /// 纸感底色（窗口背景）
    static let paper = Color(light: NSColor(srgbRed: 0.972, green: 0.960, blue: 0.937, alpha: 1),
                             dark: NSColor(srgbRed: 0.118, green: 0.110, blue: 0.102, alpha: 1))
    /// 卡片底色
    static let card = Color(light: NSColor.white,
                            dark: NSColor(srgbRed: 0.165, green: 0.157, blue: 0.149, alpha: 1))
    /// 卡片描边
    static let cardStroke = Color(light: NSColor(white: 0, alpha: 0.07),
                                  dark: NSColor(white: 1, alpha: 0.09))
    /// 栏背景（工作台左右栏的轻微区分）
    static let columnBackground = Color(light: NSColor(srgbRed: 0.984, green: 0.976, blue: 0.960, alpha: 1),
                                        dark: NSColor(srgbRed: 0.133, green: 0.125, blue: 0.118, alpha: 1))

    /// 主按钮渐变（得到系橙）
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    /// 明暗双态动态色
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - 卡片

private struct BWCardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(BWTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(BWTheme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

extension View {
    /// 统一卡片样式：白卡、圆角 12、细描边、极浅投影
    func bwCard(padding: CGFloat = 12) -> some View {
        modifier(BWCardModifier(padding: padding))
    }
}

// MARK: - 徽标

/// 小徽标（状态/属性标签）：彩色文字 + 同色浅底胶囊
struct BWBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.13), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - 说话人圆点

/// 说话人头像点：彩色圆 + 姓名首字
struct BWSpeakerDot: View {
    let name: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18))
            Text(String(name.prefix(1)))
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 品牌标

/// App 品牌标（首页顶部）：橙色圆角方 + 白色声波
struct BWBrandMark: View {
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(BWTheme.accentGradient)
            HStack(spacing: size * 0.09) {
                ForEach(Array([0.32, 0.62, 0.92, 0.62, 0.32].enumerated()), id: \.offset) { _, h in
                    Capsule()
                        .fill(.white)
                        .frame(width: size * 0.09, height: size * CGFloat(h) * 0.62)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
