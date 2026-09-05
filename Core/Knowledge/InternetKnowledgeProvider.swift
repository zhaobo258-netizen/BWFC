import Foundation

struct InternetKnowledgeProvider: KnowledgeProvider {
    let kind: KnowledgeProviderKind = .internet
    let displayName = "互联网"
    var providerID: String {
        credentials == nil
            ? "internet:wikipedia-zh"
            : "internet:kimi-web-search"
    }

    private let networkSession: ProxyAdaptiveURLSession
    private let credentials: (any KimiCredentialProviding)?
    private let webSearchEndpoint: URL
    private let wikipediaEndpoint: URL

    init(
        session: URLSession? = nil,
        sessionFactory: (@Sendable () -> URLSession)? = nil,
        credentials: (any KimiCredentialProviding)? = nil,
        webSearchEndpoint: URL = CloudModelConfig.kimiWebSearchURL,
        wikipediaEndpoint: URL = URL(
            string: "https://zh.wikipedia.org/w/api.php"
        )!
    ) {
        self.networkSession = ProxyAdaptiveURLSession(
            fixedSession: session,
            sessionFactory: sessionFactory
        )
        self.credentials = credentials
        self.webSearchEndpoint = webSearchEndpoint
        self.wikipediaEndpoint = wikipediaEndpoint
    }

    func healthCheck() async -> KnowledgeProviderHealth {
        KnowledgeProviderHealth(
            isAvailable: true,
            message: credentials == nil
                ? "中文维基百科检索"
                : "Kimi 通用网页搜索（失败时回退维基百科）"
        )
    }

    func search(_ query: String, limit: Int = 5) async throws -> [KnowledgeConnection] {
        guard let trimmed = KnowledgeSearchQueryPolicy.keywords(query) else {
            throw KnowledgeProviderError.invalidSearchQuery
        }
        if credentials != nil {
            do {
                let results = try await searchWeb(
                    trimmed,
                    limit: limit
                )
                if !results.isEmpty {
                    return results
                }
            } catch {
                AppLog.logWarning(
                    AppLog.analysis,
                    LogSanitizer.formatEvent(
                        "project_chat_web_search_fallback",
                        error: String(describing: type(of: error))
                    )
                )
            }
        }
        return try await searchWikipedia(trimmed, limit: limit)
    }

    private func searchWeb(
        _ query: String,
        limit: Int
    ) async throws -> [KnowledgeConnection] {
        guard let credentials else {
            throw KnowledgeProviderError.invalidConfiguration
        }
        let credential = try await credentials.validCredential()
        var request = URLRequest(url: webSearchEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            WebSearchRequest(textQuery: query)
        )
        let (data, response) = try await networkSession.data(for: request)
        guard data.count <= 2_000_000 else {
            throw KnowledgeProviderError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw KnowledgeProviderError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw KnowledgeProviderError.serverRejected(http.statusCode)
        }
        let payload = try JSONDecoder().decode(WebSearchResponse.self, from: data)
        return payload.searchResults
            .prefix(max(1, min(limit, 8)))
            .enumerated()
            .compactMap { index, result in
                let location = result.url?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                guard let url = URL(string: location),
                      url.scheme == "https" || url.scheme == "http" else {
                    return nil
                }
                let title = result.title?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                guard !title.isEmpty else { return nil }
                let excerptText = (result.snippet ?? result.content ?? "")
                    .replacingOccurrences(
                        of: #"\s+"#,
                        with: " ",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let date = result.date?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let excerpt = [date, excerptText]
                    .compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }
                    .joined(separator: " · ")
                let siteName = result.siteName?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return KnowledgeConnection(
                    provider: .internet,
                    providerId: "internet:kimi-web-search",
                    providerName: siteName.flatMap { $0.isEmpty ? nil : $0 }
                        .map { "互联网 · \($0)" }
                        ?? "互联网 · Kimi 搜索",
                    sourceId: location,
                    title: title,
                    excerpt: excerpt,
                    sourceLocation: location,
                    relevance: max(0.1, 1 - Double(index) * 0.1),
                    retrievedAt: Date()
                )
            }
    }

    private func searchWikipedia(
        _ query: String,
        limit: Int
    ) async throws -> [KnowledgeConnection] {
        var components = URLComponents(
            url: wikipediaEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: query),
            URLQueryItem(name: "gsrlimit", value: String(max(1, min(limit, 8)))),
            URLQueryItem(name: "prop", value: "extracts|info"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exchars", value: "500"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url else {
            throw KnowledgeProviderError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("BangWoFenXi/1.0 knowledge-linking", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await networkSession.data(for: request)
            guard data.count <= 2_000_000 else {
                throw KnowledgeProviderError.responseTooLarge
            }
            guard let http = response as? HTTPURLResponse else {
                throw KnowledgeProviderError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw KnowledgeProviderError.serverRejected(http.statusCode)
            }
            let payload = try JSONDecoder().decode(Response.self, from: data)
            return (payload.query?.pages ?? []).enumerated().compactMap { index, page in
                guard let sourceURL = page.fullURL, !page.title.isEmpty else { return nil }
                let excerpt = page.extract?
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return KnowledgeConnection(
                    provider: .internet,
                    providerId: "internet:wikipedia-zh",
                    providerName: "互联网 · 维基百科",
                    sourceId: String(page.pageID),
                    title: page.title,
                    excerpt: excerpt,
                    sourceLocation: sourceURL,
                    relevance: max(0.1, 1 - Double(index) * 0.12),
                    retrievedAt: Date()
                )
            }
        } catch let error as KnowledgeProviderError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AnalysisAPIError.timeout
        } catch {
            throw KnowledgeProviderError.unavailable
        }
    }

    private struct WebSearchRequest: Encodable {
        var textQuery: String

        enum CodingKeys: String, CodingKey {
            case textQuery = "text_query"
        }
    }

    private struct WebSearchResponse: Decodable {
        var searchResults: [WebSearchResult]

        enum CodingKeys: String, CodingKey {
            case searchResults = "search_results"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            searchResults = try container.decodeIfPresent(
                [WebSearchResult].self,
                forKey: .searchResults
            ) ?? []
        }
    }

    private struct WebSearchResult: Decodable {
        var siteName: String?
        var title: String?
        var url: String?
        var snippet: String?
        var content: String?
        var date: String?

        enum CodingKeys: String, CodingKey {
            case siteName = "site_name"
            case title, url, snippet, content, date
        }
    }

    private struct Response: Decodable {
        var query: Query?
    }

    private struct Query: Decodable {
        var pages: [Page]
    }

    private struct Page: Decodable {
        var pageID: Int
        var title: String
        var extract: String?
        var fullURL: String?

        enum CodingKeys: String, CodingKey {
            case pageID = "pageid"
            case title, extract
            case fullURL = "fullurl"
        }
    }
}
