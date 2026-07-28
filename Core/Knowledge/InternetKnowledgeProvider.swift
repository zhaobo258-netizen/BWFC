import Foundation

struct InternetKnowledgeProvider: KnowledgeProvider {
    let kind: KnowledgeProviderKind = .internet
    let displayName = "互联网"

    private let session: URLSession
    private let endpoint: URL

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://zh.wikipedia.org/w/api.php")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func healthCheck() async -> KnowledgeProviderHealth {
        KnowledgeProviderHealth(isAvailable: true, message: "中文维基百科检索")
    }

    func search(_ query: String, limit: Int = 5) async throws -> [KnowledgeConnection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: trimmed),
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
            let (data, response) = try await session.data(for: request)
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
