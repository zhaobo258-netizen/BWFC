import Foundation

// MARK: - 凭证模型

/// Kimi 账号 OAuth 凭证（设备码登录获得）。
/// 注意：refresh_token 每次刷新都会轮换（实测确认），刷新成功后必须立即持久化
/// 轮换后的新值，否则下次刷新将 invalid_grant 并被迫重新登录。
struct KimiOAuthTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// 过期时刻（由响应 expires_in 本地换算；实际有效期约 900 秒。
    /// 归一化为整秒：亚秒精度无业务意义，且保证 Keychain JSON 往返逐位一致）
    let expiresAt: Date

    init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Date(timeIntervalSince1970: expiresAt.timeIntervalSince1970.rounded())
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

// MARK: - Keychain 存储

/// OAuth 凭证的 Keychain 存储（整组凭证 JSON 序列化后存单条目；
/// 与静态分析 Key 同 service、独立 account，互不影响）。
struct KimiOAuthTokenStore: Sendable {
    /// Keychain account 名（静态 Key 为 "kimi"，本条目为登录凭证）
    static let account = "kimi-oauth"

    private let keychain: KeychainService

    init(service: String = CloudAPIKeyStore.defaultService) {
        self.keychain = KeychainService(service: service)
    }

    /// 是否已登录（存在可解码的凭证）
    var hasTokens: Bool {
        ((try? read()) ?? nil) != nil
    }

    var hasStoredTokens: Bool {
        keychain.contains(account: Self.account)
    }

    /// 读取凭证；不存在或数据损坏返回 nil（损坏视为未登录，不猜测修复）
    func read() throws -> KimiOAuthTokens? {
        guard let raw = try keychain.read(account: Self.account) else {
            return nil
        }
        guard let data = raw.data(using: .utf8) else {
            AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent(
                "kimi_oauth_credentials_corrupted"
            ))
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(KimiOAuthTokens.self, from: data)
        } catch {
            AppLog.logError(AppLog.persistence, LogSanitizer.formatEvent(
                "kimi_oauth_credentials_corrupted"
            ))
            return nil
        }
    }

    /// 保存凭证（覆盖更新）
    func save(_ tokens: KimiOAuthTokens) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(tokens)
        try keychain.save(String(decoding: data, as: UTF8.self), account: Self.account)
    }

    /// 删除凭证（退出登录；幂等）
    func delete() throws {
        try keychain.delete(account: Self.account)
    }
}

// MARK: - OAuth 客户端

/// OAuth 流程错误（全部脱敏：不含 token 与响应正文）
enum KimiOAuthError: Error, Equatable {
    /// 网络不可达/超时
    case network
    /// 响应无法解析或缺少必需字段
    case invalidResponse
    /// 授权被拒（invalid_grant / 401 / 403）：凭证已失效，需要重新登录
    case unauthorized
    /// 设备码轮询：用户尚未在浏览器完成授权
    case authorizationPending
    /// 设备码轮询：服务端要求放慢轮询
    case slowDown
    /// 设备码已过期（用户长时间未授权）
    case deviceCodeExpired
    /// 用户在浏览器拒绝了授权
    case accessDenied
}

/// 设备码授权响应
struct KimiDeviceAuthorization: Equatable, Sendable {
    /// 轮询用设备码
    let deviceCode: String
    /// 展示给用户的确认码
    let userCode: String
    /// 用户浏览器打开的完整授权地址（已带确认码）
    let verificationUriComplete: String
    /// 设备码有效期（秒；缺失时调用方使用保守默认值）
    let expiresIn: Int?
    /// 轮询间隔（秒）
    let intervalSeconds: Int
}

/// OAuth 客户端协议（登录控制器与凭证提供者依赖此协议，测试用 Mock）
protocol KimiOAuthClientProtocol: Sendable {
    /// 发起设备码授权
    func startDeviceAuthorization() async throws -> KimiDeviceAuthorization
    /// 轮询一次设备码换 token（未完成授权时抛 authorizationPending/slowDown）
    func pollDeviceToken(deviceCode: String) async throws -> KimiOAuthTokens
    /// 用 refresh_token 换新凭证（响应中的 refresh_token 已轮换）
    func refresh(refreshToken: String) async throws -> KimiOAuthTokens
}

/// 真实实现：auth.kimi.com 的表单接口（与 kimi CLI 同一协议）
struct KimiOAuthClient: KimiOAuthClientProtocol {
    private let networkSession: ProxyAdaptiveURLSession
    private let host: URL
    private let clientID: String
    private let now: @Sendable () -> Date

    init(
        session: URLSession? = nil,
        sessionFactory: (@Sendable () -> URLSession)? = nil,
        host: URL = CloudModelConfig.kimiOAuthHost,
        clientID: String = CloudModelConfig.kimiOAuthClientID,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.networkSession = ProxyAdaptiveURLSession(
            fixedSession: session,
            sessionFactory: sessionFactory
        )
        self.host = host
        self.clientID = clientID
        self.now = now
    }

    func startDeviceAuthorization() async throws -> KimiDeviceAuthorization {
        let (status, payload) = try await postForm(
            path: CloudModelConfig.kimiOAuthDeviceAuthorizationPath,
            params: ["client_id": clientID]
        )
        guard status == 200,
              let deviceCode = payload["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = payload["user_code"] as? String, !userCode.isEmpty,
              let verification = payload["verification_uri_complete"] as? String,
              !verification.isEmpty else {
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "kimi_oauth_device_auth_failed", statusCode: status
            ))
            throw KimiOAuthError.invalidResponse
        }
        return KimiDeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUriComplete: verification,
            expiresIn: (payload["expires_in"] as? NSNumber)?.intValue,
            intervalSeconds: max(1, (payload["interval"] as? NSNumber)?.intValue ?? 5)
        )
    }

    func pollDeviceToken(deviceCode: String) async throws -> KimiOAuthTokens {
        let (status, payload) = try await postForm(
            path: CloudModelConfig.kimiOAuthTokenPath,
            params: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ]
        )
        if status == 200 {
            return try parseTokens(payload)
        }
        switch payload["error"] as? String {
        case "authorization_pending": throw KimiOAuthError.authorizationPending
        case "slow_down": throw KimiOAuthError.slowDown
        case "expired_token": throw KimiOAuthError.deviceCodeExpired
        case "access_denied": throw KimiOAuthError.accessDenied
        default:
            AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                "kimi_oauth_poll_failed", statusCode: status
            ))
            if status == 401 || status == 403 { throw KimiOAuthError.unauthorized }
            if payload.isEmpty { throw KimiOAuthError.network }
            throw KimiOAuthError.invalidResponse
        }
    }

    func refresh(refreshToken: String) async throws -> KimiOAuthTokens {
        let (status, payload) = try await postForm(
            path: CloudModelConfig.kimiOAuthTokenPath,
            params: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]
        )
        if status == 200 {
            return try parseTokens(payload)
        }
        AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
            "kimi_oauth_refresh_failed", statusCode: status
        ))
        if status == 401 || status == 403 || payload["error"] as? String == "invalid_grant" {
            throw KimiOAuthError.unauthorized
        }
        if payload.isEmpty {
            throw KimiOAuthError.network
        }
        if (500...599).contains(status) {
            // 服务端故障按网络类处理（上层可重试，不清除凭证）
            throw KimiOAuthError.network
        }
        throw KimiOAuthError.invalidResponse
    }

    // MARK: - 内部

    private func parseTokens(_ payload: [String: Any]) throws -> KimiOAuthTokens {
        guard let accessToken = payload["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = payload["refresh_token"] as? String, !refreshToken.isEmpty,
              let expiresIn = (payload["expires_in"] as? NSNumber)?.doubleValue,
              expiresIn > 0 else {
            throw KimiOAuthError.invalidResponse
        }
        return KimiOAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(expiresIn)
        )
    }

    private func postForm(
        path: String, params: [String: String]
    ) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: host.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(params)
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await networkSession.data(for: request)
        } catch {
            throw KimiOAuthError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw KimiOAuthError.invalidResponse
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, payload)
    }

    /// application/x-www-form-urlencoded 编码（键按字典序，便于测试断言）
    static func formEncoded(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = params.keys.sorted().map { key in
            let value = params[key] ?? ""
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - 凭证提供者

/// 分析请求的凭证提供者：返回当前可用的凭证值。
/// 优先级：已登录的 OAuth access_token（临期自动刷新）> 静态分析 Key。
protocol KimiCredentialProviding: Sendable {
    /// 抛出统一的 AnalysisAPIError：
    /// missingAPIKey（未登录且无静态 Key）/ unauthorized（刷新被拒，需重新登录）/ network
    func validCredential() async throws -> String
}

/// actor 串行化刷新：并发请求不会用同一个 refresh_token 重复刷新
/// （refresh_token 轮换语义下重复刷新会作废对方）。
actor KimiCredentialProvider: KimiCredentialProviding {
    private let tokenStore: KimiOAuthTokenStore
    private let staticKeyStore: CloudAPIKeyStore
    private let client: any KimiOAuthClientProtocol
    private let now: @Sendable () -> Date
    private let refreshLeeway: TimeInterval
    private var refreshTask: Task<KimiOAuthTokens, Error>?
    private var refreshGeneration = 0

    init(
        tokenStore: KimiOAuthTokenStore = KimiOAuthTokenStore(),
        staticKeyStore: CloudAPIKeyStore = CloudAPIKeyStore.store(for: .analysis),
        client: any KimiOAuthClientProtocol = KimiOAuthClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        refreshLeeway: TimeInterval = CloudModelConfig.kimiOAuthRefreshLeewaySeconds
    ) {
        self.tokenStore = tokenStore
        self.staticKeyStore = staticKeyStore
        self.client = client
        self.now = now
        self.refreshLeeway = refreshLeeway
    }

    func validCredential() async throws -> String {
        let storedTokens: KimiOAuthTokens?
        do {
            storedTokens = try tokenStore.read()
        } catch KeychainError.interactionNotAllowed {
            throw AnalysisAPIError.credentialAccessRequired
        } catch {
            storedTokens = nil
        }
        if let tokens = storedTokens {
            if tokens.expiresAt.timeIntervalSince(now()) > refreshLeeway {
                return tokens.accessToken
            }
            let task: Task<KimiOAuthTokens, Error>
            let generation: Int
            if let inFlight = refreshTask {
                task = inFlight
                generation = refreshGeneration
            } else {
                refreshGeneration += 1
                generation = refreshGeneration
                let client = self.client
                let tokenStore = self.tokenStore
                task = Task {
                    let fresh = try await client.refresh(refreshToken: tokens.refreshToken)
                    do {
                        try tokenStore.save(fresh)
                    } catch {
                        AppLog.logError(AppLog.analysis, LogSanitizer.formatEvent(
                            "kimi_oauth_token_persist_failed",
                            error: String(describing: type(of: error))
                        ))
                    }
                    return fresh
                }
                refreshTask = task
            }
            defer {
                if generation == refreshGeneration {
                    refreshTask = nil
                }
            }
            do {
                let fresh = try await task.value
                return fresh.accessToken
            } catch KimiOAuthError.unauthorized {
                // 凭证失效：保留条目供设置页展示状态，由用户重新登录覆盖
                throw AnalysisAPIError.unauthorized
            } catch KimiOAuthError.network {
                throw AnalysisAPIError.network
            } catch {
                throw AnalysisAPIError.network
            }
        }
        let staticKey: String?
        do {
            staticKey = try staticKeyStore.readKey()
        } catch KeychainError.interactionNotAllowed {
            throw AnalysisAPIError.credentialAccessRequired
        } catch {
            staticKey = nil
        }
        if let key = staticKey, !key.isEmpty {
            return key
        }
        throw AnalysisAPIError.missingAPIKey
    }
}
