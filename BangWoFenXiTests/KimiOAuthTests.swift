import Foundation
import Testing
@testable import BangWoFenXi

/// OAuth 网络客户端专用 Mock 协议存储（与其他套件隔离）
final class OAuthMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    static let storage = MockURLProtocolStorage()
    override class var sharedStorage: MockURLProtocolStorage { storage }
}

/// Kimi 账号 OAuth：客户端协议形态、凭证存储、凭证提供者（刷新/回退/失效）
@Suite("Kimi OAuth", .serialized)
final class KimiOAuthTests {
    let credentialServiceName = "com.zhaobo.BangWoFenXi.tests.\(UUID().uuidString)"
    private var storage: MockURLProtocolStorage { OAuthMockURLProtocol.storage }

    init() {
        OAuthMockURLProtocol.storage.reset()
    }

    deinit {
        try? LocalCredentialStore(service: credentialServiceName).delete(account: KimiOAuthTokenStore.account)
        try? LocalCredentialStore(service: credentialServiceName).delete(account: "kimi")
    }

    private func makeClient(now: Date = Date(timeIntervalSince1970: 1_000_000)) -> KimiOAuthClient {
        KimiOAuthClient(session: OAuthMockURLProtocol.makeSession(), now: { now })
    }

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func tokens(
        access: String = "at-1", refresh: String = "rt-1",
        expiresAt: Date = Date(timeIntervalSince1970: 1_000_900)
    ) -> KimiOAuthTokens {
        KimiOAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    // MARK: - 客户端：请求形态与解析

    @Test("设备授权：POST 表单只带 client_id，正确解析响应字段")
    func deviceAuthorizationShape() async throws {
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.json([
                "device_code": "dev-123", "user_code": "WXYZ-7890",
                "verification_uri": "https://auth.kimi.com/device",
                "verification_uri_complete": "https://auth.kimi.com/device?code=WXYZ-7890",
                "expires_in": 600, "interval": 5
            ]))
        }
        let auth = try await makeClient().startDeviceAuthorization()
        #expect(auth.deviceCode == "dev-123")
        #expect(auth.userCode == "WXYZ-7890")
        #expect(auth.verificationUriComplete == "https://auth.kimi.com/device?code=WXYZ-7890")
        #expect(auth.expiresIn == 600)
        #expect(auth.intervalSeconds == 5)

        let request = try #require(storage.capturedRequests.first)
        #expect(request.url?.absoluteString == "https://auth.kimi.com/api/oauth/device_authorization")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: mockRequestBodyData(of: request) ?? Data(), as: UTF8.self)
        #expect(body == "client_id=\(CloudModelConfig.kimiOAuthClientID)")
    }

    @Test("设备码轮询：pending/slow_down/expired/denied 分类；成功解析 token 组")
    func pollClassification() async throws {
        let client = makeClient()
        for (code, expected) in [
            ("authorization_pending", KimiOAuthError.authorizationPending),
            ("slow_down", KimiOAuthError.slowDown),
            ("expired_token", KimiOAuthError.deviceCodeExpired),
            ("access_denied", KimiOAuthError.accessDenied)
        ] {
            storage.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (response, Self.json(["error": code]))
            }
            await #expect(throws: expected) {
                _ = try await client.pollDeviceToken(deviceCode: "dev-123")
            }
        }

        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.json([
                "access_token": "at-new", "refresh_token": "rt-new",
                "expires_in": 900, "token_type": "Bearer", "scope": "kimi-code"
            ]))
        }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let tokens = try await KimiOAuthClient(
            session: OAuthMockURLProtocol.makeSession(), now: { now }
        ).pollDeviceToken(deviceCode: "dev-123")
        #expect(tokens.accessToken == "at-new")
        #expect(tokens.refreshToken == "rt-new")
        #expect(tokens.expiresAt == now.addingTimeInterval(900))

        // 轮询请求形态：device_code 授权类型
        let request = try #require(storage.capturedRequests.last)
        #expect(request.url?.absoluteString == "https://auth.kimi.com/api/oauth/token")
        let body = String(decoding: mockRequestBodyData(of: request) ?? Data(), as: UTF8.self)
        #expect(body.contains("device_code=dev-123"))
        #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }

    @Test("设备码轮询收到非 JSON 错误页时归类为可重试网络错误")
    func pollHTMLResponseIsNetworkError() async {
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html>gateway error</html>".utf8))
        }

        await #expect(throws: KimiOAuthError.network) {
            _ = try await makeClient().pollDeviceToken(deviceCode: "dev-123")
        }
    }

    @Test("刷新：请求形态正确；401/invalid_grant → unauthorized；5xx → network")
    func refreshClassification() async throws {
        let client = makeClient()
        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.json([
                "access_token": "at-2", "refresh_token": "rt-2", "expires_in": 900
            ]))
        }
        let tokens = try await client.refresh(refreshToken: "rt-1")
        #expect(tokens.accessToken == "at-2")
        #expect(tokens.refreshToken == "rt-2", "轮换后的 refresh_token 必须取自响应")
        let request = try #require(storage.capturedRequests.first)
        let body = String(decoding: mockRequestBodyData(of: request) ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=rt-1"))
        #expect(body.contains("client_id=\(CloudModelConfig.kimiOAuthClientID)"))

        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        await #expect(throws: KimiOAuthError.unauthorized) {
            _ = try await client.refresh(refreshToken: "rt-1")
        }

        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Self.json(["error": "invalid_grant"]))
        }
        await #expect(throws: KimiOAuthError.unauthorized) {
            _ = try await client.refresh(refreshToken: "rt-1")
        }

        storage.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        await #expect(throws: KimiOAuthError.network) {
            _ = try await client.refresh(refreshToken: "rt-1")
        }
    }

    @Test("刷新收到非 JSON 错误页时归类为可重试网络错误")
    func refreshHTMLResponseIsNetworkError() async {
        storage.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html>gateway error</html>".utf8))
        }

        await #expect(throws: KimiOAuthError.network) {
            _ = try await makeClient().refresh(refreshToken: "rt-1")
        }
    }

    // MARK: - 凭证存储

    @Test("凭证存储：往返一致、覆盖更新、删除幂等、损坏数据视为未登录")
    func tokenStoreRoundTrip() throws {
        let store = KimiOAuthTokenStore(service: credentialServiceName)
        #expect(!store.hasTokens)
        #expect(try store.read() == nil)

        let first = Self.tokens()
        try store.save(first)
        #expect(store.hasTokens)
        #expect(try store.read() == first)

        let second = Self.tokens(access: "at-2", refresh: "rt-2")
        try store.save(second)
        #expect(try store.read() == second, "保存必须覆盖旧凭证")

        try store.delete()
        #expect(!store.hasTokens)
        try store.delete() // 幂等

        // 损坏数据：如实视为未登录，不猜测修复
        try LocalCredentialStore(service: credentialServiceName)
            .save("not-json", account: KimiOAuthTokenStore.account)
        #expect(try store.read() == nil)
        #expect(!store.hasTokens)
    }

    // MARK: - 凭证提供者

    private func makeProvider(
        client: MockKimiOAuthClient,
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> (KimiCredentialProvider, KimiOAuthTokenStore, CloudAPIKeyStore) {
        let tokenStore = KimiOAuthTokenStore(service: credentialServiceName)
        let staticStore = CloudAPIKeyStore(service: credentialServiceName, account: "kimi")
        let provider = KimiCredentialProvider(
            tokenStore: tokenStore, staticKeyStore: staticStore,
            client: client, now: { now }, refreshLeeway: 300
        )
        return (provider, tokenStore, staticStore)
    }

    @Test("凭证提供者：token 未临期直接返回，不发刷新请求")
    func freshTokenNoRefresh() async throws {
        let client = MockKimiOAuthClient()
        let (provider, store, _) = makeProvider(client: client)
        // 过期时刻距 now 900 秒 > 300 秒余量
        try store.save(Self.tokens(expiresAt: Date(timeIntervalSince1970: 1_000_900)))

        #expect(try await provider.validCredential() == "at-1")
        #expect(client.refreshCalls.isEmpty)
    }

    @Test("凭证提供者：临期先刷新，轮换后的凭证立即持久化")
    func expiringTokenRefreshesAndPersists() async throws {
        let client = MockKimiOAuthClient()
        let rotated = Self.tokens(access: "at-2", refresh: "rt-2",
                                  expiresAt: Date(timeIntervalSince1970: 1_000_900))
        client.refreshResults = [.success(rotated)]
        let (provider, store, _) = makeProvider(client: client)
        // 剩余 100 秒 < 300 秒余量 → 必须先刷新
        try store.save(Self.tokens(expiresAt: Date(timeIntervalSince1970: 1_000_100)))

        #expect(try await provider.validCredential() == "at-2")
        #expect(client.refreshCalls == ["rt-1"])
        #expect(try store.read() == rotated,
                "refresh_token 轮换语义：新凭证必须立即写回本机凭证存储")
    }

    @Test("凭证提供者：并发临期请求共享一次刷新与同一轮换凭证")
    func concurrentRefreshIsSingleFlight() async throws {
        let client = MockKimiOAuthClient()
        let gate = RefreshContinuationBox()
        let rotated = Self.tokens(
            access: "at-rotated",
            refresh: "rt-rotated",
            expiresAt: Date(timeIntervalSince1970: 1_000_900)
        )
        client.refreshHandler = { _ in
            try await gate.wait()
        }
        let (provider, store, _) = makeProvider(client: client)
        try store.save(Self.tokens(expiresAt: Date(timeIntervalSince1970: 1_000_100)))

        let callers = (0..<12).map { _ in
            Task { try await provider.validCredential() }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, gate.waitingCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        let refreshCallsBeforeRelease = client.refreshCalls
        gate.resumeAll(returning: rotated)

        var credentials: [String] = []
        for caller in callers {
            credentials.append(try await caller.value)
        }

        #expect(refreshCallsBeforeRelease == ["rt-1"])
        #expect(Set(credentials) == ["at-rotated"])
        #expect(try store.read() == rotated)
    }

    @Test("凭证提供者：刷新被拒 → unauthorized（凭证保留，待用户重新登录）")
    func refreshUnauthorized() async throws {
        let client = MockKimiOAuthClient()
        client.refreshResults = [.failure(.unauthorized)]
        let (provider, store, _) = makeProvider(client: client)
        let stale = Self.tokens(expiresAt: Date(timeIntervalSince1970: 1_000_100))
        try store.save(stale)

        await #expect(throws: AnalysisAPIError.unauthorized) {
            _ = try await provider.validCredential()
        }
        #expect(try store.read() == stale, "刷新失败不得清除凭证（设置页仍显示登录态）")
    }

    @Test("凭证提供者：刷新网络失败 → network（可重试，不清凭证）")
    func refreshNetworkFailure() async throws {
        let client = MockKimiOAuthClient()
        client.refreshResults = [.failure(.network)]
        let (provider, store, _) = makeProvider(client: client)
        try store.save(Self.tokens(expiresAt: Date(timeIntervalSince1970: 1_000_100)))

        await #expect(throws: AnalysisAPIError.network) {
            _ = try await provider.validCredential()
        }
        #expect(store.hasTokens)
    }

    @Test("凭证提供者：未登录时回退静态 Key；两者皆无 → missingAPIKey")
    func staticKeyFallback() async throws {
        let client = MockKimiOAuthClient()
        let (provider, _, staticStore) = makeProvider(client: client)

        await #expect(throws: AnalysisAPIError.missingAPIKey) {
            _ = try await provider.validCredential()
        }

        try staticStore.saveKey("sk-static-fallback")
        #expect(try await provider.validCredential() == "sk-static-fallback")
        #expect(client.refreshCalls.isEmpty, "静态 Key 路径不得触发 OAuth 刷新")
    }

    @Test("凭证提供者：已登录时 OAuth 优先于静态 Key")
    func oauthTakesPriority() async throws {
        let client = MockKimiOAuthClient()
        let (provider, store, staticStore) = makeProvider(client: client)
        try staticStore.saveKey("sk-static")
        try store.save(Self.tokens(expiresAt: Date(timeIntervalSince1970: 1_000_900)))

        #expect(try await provider.validCredential() == "at-1")
    }

    @Test("AppEnvironment 默认 V1 与 V2 分析路径共享同一凭证提供者")
    @MainActor
    func appEnvironmentSharesCredentialsAcrossAnalysisPaths() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bwfx-kimi-env-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "bwfx-kimi-env-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let credentials = CountingFailingKimiCredentials()
        let environment = AppEnvironment(
            meetingStore: InMemoryMeetingStore(),
            fileStore: MeetingFileStore(baseDirectory: directory),
            kimiCredentials: credentials,
            credentialServiceName: credentialServiceName,
            aiProviderConfigurationStore: AIProviderConfigurationStore(
                defaults: defaults
            )
        )

        await #expect(throws: AnalysisAPIError.network) {
            _ = try await environment.negotiationAnalysis.analyze(
                instructions: "test",
                inputJSON: "{}"
            )
        }
        await #expect(throws: AnalysisAPIError.network) {
            _ = try await environment.conversationAnalysis.analyze(
                instructions: "test",
                inputJSON: "{}"
            )
        }
        let callCount = await credentials.callCount()
        #expect(callCount == 2)
    }

    // MARK: - 登录控制器

    @MainActor
    private func makeLogin(
        client: MockKimiOAuthClient
    ) -> (KimiLoginController, KimiOAuthTokenStore, OpenedURLBox) {
        let store = KimiOAuthTokenStore(service: credentialServiceName)
        let opened = OpenedURLBox()
        let controller = KimiLoginController(
            client: client, tokenStore: store,
            openURL: { url in opened.append(url) },
            sleeper: { _ in await Task.yield() }
        )
        return (controller, store, opened)
    }

    @Test("登录控制器：授权→打开浏览器→轮询 pending→成功→凭证落本机存储")
    @MainActor
    func loginHappyPath() async throws {
        let client = MockKimiOAuthClient()
        let saved = Self.tokens(access: "at-login", refresh: "rt-login",
                                expiresAt: Date().addingTimeInterval(900))
        client.pollResults = [
            .failure(.authorizationPending),
            .failure(.authorizationPending),
            .success(saved)
        ]
        let (controller, store, opened) = makeLogin(client: client)
        var stateChanged = false
        controller.onLoginStateChanged = { stateChanged = true }

        controller.begin()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, controller.phase != .succeeded {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(controller.phase == .succeeded)
        #expect(try store.read() == saved)
        #expect(opened.urls.map(\.absoluteString) == ["https://auth.example.com/device?code=ABCD-1234"])
        #expect(client.pollCalls.count == 3)
        #expect(client.pollCalls.allSatisfy { $0 == "device-code-1" })
        #expect(stateChanged)
        #expect(controller.isLoggedIn)
    }

    @Test("登录控制器：用户拒绝授权 → failed；取消登录回到 idle 且不再轮询")
    @MainActor
    func loginDeniedAndCancel() async throws {
        let denied = MockKimiOAuthClient()
        denied.pollResults = [.failure(.accessDenied)]
        let (deniedController, store, _) = makeLogin(client: denied)
        deniedController.begin()
        var deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, deniedController.phase == .starting
                || deniedController.phase == .waitingApproval(userCode: "ABCD-1234") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(deniedController.phase == .failed("授权被拒绝，请重新登录"))
        #expect(!store.hasTokens)

        // 取消：等待授权中取消 → idle，轮询停止
        let pending = MockKimiOAuthClient()
        pending.pollResults = [.failure(.authorizationPending)]
        let (controller, _, _) = makeLogin(client: pending)
        controller.begin()
        deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, pending.pollCalls.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        controller.cancel()
        #expect(controller.phase == .idle)
        let countAfterCancel = pending.pollCalls.count
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pending.pollCalls.count <= countAfterCancel + 1, "取消后轮询必须停止")
    }
}

/// 打开过的 URL 记录盒（MainActor 闭包捕获用）
final class OpenedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func append(_ url: URL) { lock.withLock { _urls.append(url) } }
}

final class RefreshContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<KimiOAuthTokens, Error>] = []

    var waitingCount: Int { lock.withLock { continuations.count } }

    func wait() async throws -> KimiOAuthTokens {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
    }

    func resumeAll(returning tokens: KimiOAuthTokens) {
        let waiting = lock.withLock {
            let waiting = continuations
            continuations.removeAll()
            return waiting
        }
        for continuation in waiting {
            continuation.resume(returning: tokens)
        }
    }
}

actor CountingFailingKimiCredentials: KimiCredentialProviding {
    private var calls = 0

    func validCredential() async throws -> String {
        calls += 1
        throw AnalysisAPIError.network
    }

    func callCount() -> Int {
        calls
    }
}
