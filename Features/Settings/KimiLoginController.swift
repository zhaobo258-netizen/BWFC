import Foundation

/// Kimi 账号设备码登录控制器（设置页使用）：
/// 发起设备授权 → 打开浏览器让用户确认 → 轮询换 token → 存 Keychain。
/// 凭证只进 Keychain；user_code 本身不含身份信息，可展示与记录。
@MainActor
@Observable
final class KimiLoginController {
    enum Phase: Equatable {
        /// 未开始
        case idle
        /// 正在发起设备授权
        case starting
        /// 等待用户在浏览器完成授权（展示确认码）
        case waitingApproval(userCode: String)
        /// 登录成功，凭证已保存
        case succeeded
        /// 失败（脱敏文案，可重试）
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private let client: any KimiOAuthClientProtocol
    private let tokenStore: KimiOAuthTokenStore
    private let openURL: @MainActor (URL) -> Void
    /// 轮询间隔的等待实现（测试注入即时返回）
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let now: () -> Date
    private var task: Task<Void, Never>?

    /// 登录成功/退出后回调（外部刷新 isAnalysisConfigured 等状态）
    var onLoginStateChanged: (() -> Void)?

    init(
        client: any KimiOAuthClientProtocol = KimiOAuthClient(),
        tokenStore: KimiOAuthTokenStore = KimiOAuthTokenStore(),
        openURL: @escaping @MainActor (URL) -> Void,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.tokenStore = tokenStore
        self.openURL = openURL
        self.sleeper = sleeper
        self.now = now
    }

    /// 是否已登录（供视图展示状态）
    var isLoggedIn: Bool {
        tokenStore.hasTokens
    }

    /// 开始设备码登录（进行中重复调用无效）
    func begin() {
        guard task == nil else { return }
        phase = .starting
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    /// 取消进行中的登录
    func cancel() {
        task?.cancel()
        task = nil
        if phase != .succeeded {
            phase = .idle
        }
    }

    /// 退出登录：删除凭证（幂等）
    func logout() {
        cancel()
        do {
            try tokenStore.delete()
            phase = .idle
        } catch {
            phase = .failed("退出失败：\(error.localizedDescription)")
        }
        onLoginStateChanged?()
    }

    // MARK: - 内部

    private func run() async {
        let authorization: KimiDeviceAuthorization
        do {
            authorization = try await client.startDeviceAuthorization()
        } catch {
            phase = .failed(Self.message(for: error))
            return
        }
        if let url = URL(string: authorization.verificationUriComplete) {
            openURL(url)
        }
        phase = .waitingApproval(userCode: authorization.userCode)

        var interval = TimeInterval(authorization.intervalSeconds)
        let deadline = now().addingTimeInterval(TimeInterval(authorization.expiresIn ?? 600))
        while !Task.isCancelled {
            if now() >= deadline {
                phase = .failed("授权超时，请重新登录")
                return
            }
            do {
                let tokens = try await client.pollDeviceToken(deviceCode: authorization.deviceCode)
                do {
                    try tokenStore.save(tokens)
                } catch {
                    phase = .failed("凭证保存失败：\(error.localizedDescription)")
                    return
                }
                phase = .succeeded
                onLoginStateChanged?()
                return
            } catch KimiOAuthError.authorizationPending {
                // 用户尚未确认，按间隔继续
            } catch KimiOAuthError.slowDown {
                interval += 5
            } catch {
                phase = .failed(Self.message(for: error))
                return
            }
            await sleeper(interval)
        }
    }

    /// 脱敏错误文案（不含 token 与响应正文）
    private static func message(for error: Error) -> String {
        switch error {
        case KimiOAuthError.network:
            return "网络不可达，请检查网络后重试"
        case KimiOAuthError.accessDenied:
            return "授权被拒绝，请重新登录"
        case KimiOAuthError.deviceCodeExpired:
            return "授权码已过期，请重新登录"
        case KimiOAuthError.unauthorized:
            return "授权失败，请重新登录"
        default:
            return "登录失败，请稍后重试"
        }
    }
}
