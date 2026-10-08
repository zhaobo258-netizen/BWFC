import SwiftUI
import AppKit

/// 《帮我分析》设计系统（界面设计定稿 v1.0，2026-10-08；沿用 A 版纸感/暖橙规范）。
/// 所有颜色均为明暗双态动态色；视图统一经 bwCard() / BWBadge 等取用，不散落魔法值。
/// Token 与《SwiftUI实现规格 v1.0》第一节一一对应；深色模式采用双 accent 方案：
/// 强调文字/选中态提亮（accent #D97B45），按钮底色保持深橙（accentButton #B85A2E），
/// 两者混用会导致按钮白字或强调文字对比度不达标，禁止互换。
enum BWTheme {
    // MARK: - 颜色（定稿 Token）

    /// 工作台底色（画布）
    static let canvas = Color(lightHex: 0xF5F4F0, darkHex: 0x1C1D1A)
    /// 卡片/正文/弹层面板
    static let panel = Color(lightHex: 0xFFFFFF, darkHex: 0x262724)
    /// 下沉面（头像底、分隔块）
    static let sunken = Color(lightHex: 0xEBE9E1, darkHex: 0x363732)

    /// 主文字
    static let ink = Color(lightHex: 0x252824, darkHex: 0xECEDE8)
    /// 次文字
    static let ink2 = Color(lightHex: 0x62665E, darkHex: 0xA8ABA0)
    /// 三级文字
    static let ink3 = Color(lightHex: 0x92958A, darkHex: 0x7C7F74)

    /// 强调文字/选中态（深色下提亮）
    static let accent = Color(lightHex: 0xA94B22, darkHex: 0xD97B45)
    /// 强调软底（选中底/新内容标记）
    static let accentSoft = Color(lightHex: 0xFAE7DC, darkHex: 0x3A291C)
    /// 强调描边（卡片 hover、回复卡竖条）
    static let accentLine = Color(lightHex: 0xE8A35C, darkHex: 0x8A5A34)
    /// 主按钮底色（深色下保持深橙，白字对比度 4.6:1）
    static let accentButton = Color(lightHex: 0xA94B22, darkHex: 0xB85A2E)

    /// 依据链接（必带下划线）
    static let evidence = Color(lightHex: 0x375F85, darkHex: 0x7BA3CC)

    /// 推测卡底色（必带文字标签，颜色不单独承担语义）
    static let inferBg = Color(lightHex: 0xFFF8EF, darkHex: 0x33291D)
    /// 推测标签底色
    static let inferTag = Color(lightHex: 0xF5E4CB, darkHex: 0x4A3A24)
    /// 推测标签/文字
    static let inferInk = Color(lightHex: 0x8F5A14, darkHex: 0xD9A85C)

    /// 内容分隔线
    static let border = Color(lightHex: 0xDEDED5, darkHex: 0x3B3C36)

    /// 状态语义三色
    static let ok = Color(lightHex: 0x2E7D52, darkHex: 0x63B487)
    static let warn = Color(lightHex: 0xB26A1B, darkHex: 0xD9A05B)
    static let danger = Color(lightHex: 0xB3402E, darkHex: 0xE07A5F)

    /// 状态浅底（chip/徽章底色，深浅分别实测）
    static let okBg = Color(lightHex: 0xE3EFE7, darkHex: 0x223A2C)
    static let warnBg = Color(lightHex: 0xFDF6EC, darkHex: 0x33291D)
    static let dangerBg = Color(lightHex: 0xFBEFEA, darkHex: 0x3D2420)
    static let runBg = Color(lightHex: 0xEAF0F6, darkHex: 0x22303C)

    /// AI 回复卡底色（左 3pt accentLine 竖条）
    static let replyBg = Color(lightHex: 0xFFF9F1, darkHex: 0x2E2820)
    /// 录音中 LIVE 红点/徽标（两态同色）
    static let liveRed = Color(lightHex: 0xD64B33, darkHex: 0xD64B33)
    /// 星标原话高亮（文本底部 62% 高亮带）
    static let starMark = Color(lightHex: 0xFCE9B8, darkHex: 0x5C4A20)

    // MARK: - 旧 Token 兼容映射（已按定稿值重定向，逐步收敛到新命名）

    /// 主强调色的深端（渐变用）
    static let accentDeep = Color(lightHex: 0x8A3A1B, darkHex: 0xC96B38)
    /// 纸感底色（窗口背景）→ canvas
    static let paper = canvas
    /// 卡片底色 → panel
    static let card = panel
    /// 卡片描边 → border
    static let cardStroke = border
    /// 栏背景 → canvas
    static let columnBackground = canvas

    /// 主按钮渐变（品牌标等少数装饰位保留）
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentButton, accentDeep],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - 语义尺寸（定稿：正文 14 起、辅助 12–13、命中区 ≥32）

    /// 页面标题 24–28
    static let fontSizePageTitle: CGFloat = 26
    /// 区块标题 16–18 Semibold
    static let fontSizeSectionTitle: CGFloat = 17
    /// 正文阅读字号
    static let fontSizeBody: CGFloat = 15
    /// 次级/来源字号（≥12pt 的可访问下限）
    static let fontSizeDetail: CGFloat = 12
    /// 卡片内小标题（来源/状态行）
    static let fontSizeLabel: CGFloat = 13
    /// 控件最小命中高度
    static let minimumHitHeight: CGFloat = 32
    /// 次按钮高度 32–36
    static let secondaryActionHeight: CGFloat = 34
    /// 主行动（发送等）高度
    static let primaryActionHeight: CGFloat = 36
    /// 全屏第一动作（标记此刻）高度
    static let heroActionHeight: CGFloat = 44
    /// 证据/来源按钮最小宽度
    static let minimumHitWidth: CGFloat = 32
}

extension Color {
    /// 明暗双态动态色
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// 明暗双态动态色（sRGB 十六进制，如 0xF5F4F0）
    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(light: NSColor(hex: lightHex), dark: NSColor(hex: darkHex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 卡片

private struct BWCardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(BWTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(BWTheme.border, lineWidth: 1)
            )
    }
}

extension View {
    /// 统一卡片样式：panel 底、圆角 12、1pt border，无堆叠阴影（定稿决策）
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
            .font(.system(size: BWTheme.fontSizeDetail))
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
