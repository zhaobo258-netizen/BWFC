import SwiftUI
import AppKit

/// 宽边栏导航（界面设计定稿 v1.0，2026-10-08 老板授权颠覆 64pt 窄栏）。
///
/// 规格（《SwiftUI实现规格 v1.0》第二节）：
/// - 宽 232pt；折叠 64pt；窗口 ≤1023pt 自动折叠（不改写用户手动偏好）；
///   折叠态经 UserDefaults 持久化，重启保持。
/// - 结构：品牌区 →「开始录音」CTA 常驻 → 分组（开始：项目/当前交流；管理：人物库/业务项目）
///   → 底部（深色切换 / 收起 / 设置 / 用户卡）。
/// - 徽标长在菜单上：当前交流 LIVE（仅录音中）、人物库待确认数、业务项目逾期数；
///   数据一律来自持久存储与运行时会话集合，不凭页面内存猜测（S02）。
/// - 当前项：accentSoft 底 + accent 左 3pt 竖条。
struct WorkspaceSidebar: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    /// 窗口过窄（≤1023pt）时由 RootView 传入 true 强制折叠；与用户手动偏好互不覆盖
    var forcedCollapsed: Bool = false

    /// 用户手动折叠偏好（重启保持；S01）
    @AppStorage("bwfx.sidebar.collapsed") private var userCollapsed = false
    /// 外观选择（system/light/dark）；深色模式 Token 见 BWTheme 双 accent 方案
    @AppStorage("bwfx.appearance") private var appearance: String = SidebarAppearance.system.rawValue

    @State private var badges: SidebarBadgeSnapshot = .empty
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isMini: Bool { forcedCollapsed || userCollapsed }

    private var appearanceSetting: SidebarAppearance {
        SidebarAppearance(rawValue: appearance) ?? .system
    }

    var body: some View {
        VStack(spacing: 0) {
            brand
            recordCTA
            nav
                .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(.horizontal, isMini ? 8 : 12)
        .padding(.top, 16)
        .padding(.bottom, isMini ? 10 : 12)
        .frame(width: isMini ? 64 : 232)
        .background(BWTheme.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(BWTheme.border).frame(width: 1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isMini)
        .task(id: badgeRefreshKey) { reloadBadges() }
    }

    /// 路由变化或运行时录音集合变化时重算徽标（数据来自持久存储 + 运行时会话集合）
    private var badgeRefreshKey: String {
        "\(router.route)|\(environment.liveRecordingProjectIDs.count)"
    }

    // MARK: - 品牌区

    private var brand: some View {
        HStack(spacing: 10) {
            BWBrandMark(size: 34)
            if !isMini {
                VStack(alignment: .leading, spacing: 1) {
                    Text("帮我分析")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(BWTheme.ink)
                        .lineLimit(1)
                    Text("录音知识工作台")
                        .font(.system(size: 11))
                        .foregroundStyle(BWTheme.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, isMini ? 0 : 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 开始录音 CTA（常驻）

    private var recordCTA: some View {
        Button {
            if let liveID = badges.liveProjectID {
                router.showProjectWorkspace(liveID, autoStart: false)
            } else {
                // 回到首页消费一次性开录请求，复用既有知情确认与建项目链路
                router.requestStartRecording()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                if !isMini {
                    Text("开始录音")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(BWTheme.accentButton, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: BWTheme.accentButton.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 14)
        .help("开始录音（零预填，点开就录）")
        .accessibilityLabel("开始录音")
    }

    // MARK: - 导航分组

    private var nav: some View {
        VStack(spacing: 2) {
            if !isMini { groupLabel("开始") }
            navItem(
                section: .home,
                title: "项目",
                icon: "house",
                isOn: isHomeSelected
            ) {
                router.showProjectHome()
            }
            navItem(
                section: .currentSession,
                title: "当前交流",
                icon: "waveform",
                isOn: isWorkspaceSelected,
                badge: badges.liveProjectID != nil ? .live : nil,
                isEnabled: badges.currentSessionTarget != nil
            ) {
                if let target = badges.currentSessionTarget {
                    router.showProjectWorkspace(target, autoStart: false)
                }
            }

            if !isMini { groupLabel("管理") }
            navItem(
                section: .people,
                title: "人物库",
                icon: "person.2",
                isOn: router.route == .peopleLibrary,
                badge: badges.pendingPersons > 0 ? .warn(badges.pendingPersons) : nil
            ) {
                router.showPeopleLibrary()
            }
            navItem(
                section: .business,
                title: "业务项目",
                icon: "briefcase",
                isOn: router.route == .businessProjects,
                badge: badges.overdueFollowUps > 0 ? .danger(badges.overdueFollowUps) : nil
            ) {
                router.showBusinessProjects()
            }
        }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(BWTheme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private enum SidebarSection {
        case home, currentSession, people, business
    }

    private enum SidebarBadge {
        case live
        case warn(Int)
        case danger(Int)
    }

    private var isHomeSelected: Bool {
        if case .projectHome = router.route { return true }
        return false
    }

    private var isWorkspaceSelected: Bool {
        if case .projectWorkspace = router.route { return true }
        return false
    }

    private func navItem(
        section: SidebarSection,
        title: String,
        icon: String,
        isOn: Bool,
        badge: SidebarBadge? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 18)
                if !isMini {
                    Text(title)
                        .font(.system(size: 14, weight: isOn ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let badge {
                        badgeView(badge)
                    }
                }
            }
            .foregroundStyle(isOn ? BWTheme.accent : BWTheme.ink)
            .padding(.horizontal, isMini ? 0 : 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 40)
            .background(isOn ? BWTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) {
                if isOn {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(BWTheme.accentButton)
                        .frame(width: 3)
                        .padding(.vertical, 8)
                        .offset(x: isMini ? -8 : -12)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(SidebarItemButtonStyle(isOn: isOn))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(isEnabled ? title : "\(title)（当前没有进行中的交流）")
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func badgeView(_ badge: SidebarBadge) -> some View {
        switch badge {
        case .live:
            Text("LIVE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(BWTheme.liveRed, in: Capsule())
        case .warn(let count):
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(BWTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(BWTheme.accentSoft, in: Capsule())
        case .danger(let count):
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(BWTheme.danger)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(BWTheme.dangerBg, in: Capsule())
        }
    }

    // MARK: - 底部（主题 / 收起 / 设置 / 用户卡）

    private var footer: some View {
        VStack(spacing: 2) {
            Rectangle().fill(BWTheme.border).frame(height: 1)
                .padding(.bottom, 8)

            footerButton(
                title: isDarkEffective ? "浅色模式" : "深色模式",
                icon: isDarkEffective ? "sun.max" : "moon"
            ) {
                appearance = (isDarkEffective ? SidebarAppearance.light : .dark).rawValue
            }

            if !forcedCollapsed {
                footerButton(
                    title: "收起导航",
                    icon: isMini ? "chevron.forward.2" : "chevron.backward.2"
                ) {
                    userCollapsed.toggle()
                }
            }

            footerButton(title: "设置", icon: "gearshape") {
                router.showSettings()
            }

            userCard
        }
    }

    /// 当前生效的深浅态：显式选择优先，否则跟随系统
    private var isDarkEffective: Bool {
        switch appearanceSetting {
        case .light: return false
        case .dark: return true
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private func footerButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 18)
                if !isMini {
                    Text(title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(BWTheme.ink3)
            .padding(.horizontal, isMini ? 0 : 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .frame(minHeight: BWTheme.minimumHitHeight)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(SidebarItemButtonStyle(isOn: false))
        .help(title)
        .accessibilityLabel(title)
    }

    /// 用户卡：来自人物库中「这是我」的人物；未设置时如实提示并引导去人物库
    private var userCard: some View {
        Button {
            router.showPeopleLibrary()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(BWTheme.sunken)
                    if let me = badges.currentUserPerson {
                        Text(String(me.displayName.prefix(1)))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(BWTheme.ink2)
                    } else {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(BWTheme.ink3)
                    }
                }
                .frame(width: 32, height: 32)
                if !isMini {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(badges.currentUserPerson?.displayName ?? "未设置「我」")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(BWTheme.ink)
                            .lineLimit(1)
                        Text(badges.currentUserPerson?.role ?? "在人物库标记「这是我」")
                            .font(.system(size: 11))
                            .foregroundStyle(BWTheme.ink3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, isMini ? 0 : 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(SidebarItemButtonStyle(isOn: false))
        .help("人物库")
        .accessibilityLabel("当前用户：\(badges.currentUserPerson?.displayName ?? "未设置")")
    }

    // MARK: - 徽标数据

    private func reloadBadges() {
        let projects = (try? environment.allProjects()) ?? []
        let businessProjects = (try? environment.businessProjectStore.load()) ?? []
        let persons = (try? environment.personLibraryStore.load()) ?? []
        badges = SidebarBadgeProvider.snapshot(
            projects: projects,
            businessProjects: businessProjects,
            persons: persons,
            liveProjectIDs: environment.liveRecordingProjectIDs
        )
    }
}

/// 边栏项 hover 反馈（可点的都是真按钮，hover 有 canvas 底反馈）
private struct SidebarItemButtonStyle: ButtonStyle {
    let isOn: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(!isOn && (isHovering || configuration.isPressed)
                          ? BWTheme.canvas : Color.clear)
            )
            .onHover { isHovering = $0 }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// 外观选择（存 UserDefaults；RootView 据此前 preferredColorScheme）
enum SidebarAppearance: String {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 边栏徽标快照（持久数据投影；不凭页面状态）
struct SidebarBadgeSnapshot: Equatable {
    /// 运行时正在录音的项目（LIVE 徽标）
    var liveProjectID: UUID?
    /// 磁盘上仍处于录音/暂停/处理中的最近项目（「当前交流」落点）
    var resumableProjectID: UUID?
    /// 未人工确认的说话人数（人物库徽标）
    var pendingPersons: Int
    /// 业务项目逾期跟进数（业务项目徽标）
    var overdueFollowUps: Int
    /// 人物库中标记为「我」的人物（用户卡）
    var currentUserPerson: Person?

    static let empty = SidebarBadgeSnapshot(
        liveProjectID: nil, resumableProjectID: nil,
        pendingPersons: 0, overdueFollowUps: 0, currentUserPerson: nil
    )

    /// 「当前交流」导航落点：优先进行中录音，其次可恢复的未结束项目
    var currentSessionTarget: UUID? { liveProjectID ?? resumableProjectID }
}

/// 边栏徽标计算（纯逻辑，可单测）
enum SidebarBadgeProvider {
    static func snapshot(
        projects: [Project],
        businessProjects: [BusinessProject],
        persons: [Person],
        liveProjectIDs: Set<UUID>
    ) -> SidebarBadgeSnapshot {
        let live = projects
            .filter { liveProjectIDs.contains($0.id) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .first?.id

        let resumable = projects
            .filter { [.recording, .paused, .processing].contains($0.status) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .first?.id

        // 待确认人物 = 各场录音中尚未人工确认的说话人槽位（匿名/自动归属均待确认）
        let pending = projects.reduce(0) { partial, project in
            partial + project.speakers.filter { !$0.isUserConfirmed }.count
        }

        let overdue = businessProjects
            .filter { $0.status == .active }
            .reduce(0) { $0 + $1.overdueFollowUps.count }

        return SidebarBadgeSnapshot(
            liveProjectID: live,
            resumableProjectID: resumable,
            pendingPersons: pending,
            overdueFollowUps: overdue,
            currentUserPerson: persons.first { $0.isCurrentUser }
        )
    }
}
