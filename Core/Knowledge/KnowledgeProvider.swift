import Foundation

struct KnowledgeProviderHealth: Sendable, Equatable {
    var isAvailable: Bool
    var message: String
}

protocol KnowledgeProvider: Sendable {
    var kind: KnowledgeProviderKind { get }
    var providerID: String { get }
    var displayName: String { get }
    func healthCheck() async -> KnowledgeProviderHealth
    func search(_ query: String, limit: Int) async throws -> [KnowledgeConnection]
}

enum KnowledgeProviderError: Error, Equatable {
    case unavailable
    case invalidConfiguration
    case invalidResponse
    case noSearchTool
    case multipleSearchTools([String])
    case permissionDenied
    case responseTooLarge
    case serverRejected(Int)
    case invalidSearchQuery
}

extension KnowledgeProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable: return "来源当前不可用"
        case .invalidConfiguration: return "连接配置无效"
        case .invalidResponse: return "来源返回了无法识别的数据"
        case .noSearchTool: return "MCP 中没有可用的知识搜索工具"
        case .multipleSearchTools:
            return "发现多个只读知识工具，请先选择要使用的工具"
        case .permissionDenied: return "没有读取知识库的权限"
        case .responseTooLarge: return "来源返回内容过大"
        case .serverRejected(let status): return "来源请求失败（HTTP \(status)）"
        case .invalidSearchQuery: return "搜索只接受不超过 24 字的关键词，请勿发送原话或整段资料"
        }
    }
}

enum KnowledgeSearchQueryPolicy {
    static func keywords(_ raw: String, excluding sourceTexts: [String] = []) -> String? {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...24).contains(query.count),
              query.rangeOfCharacter(from: .newlines) == nil,
              query.range(of: #"[。！？；\n\r]|https?://|\S+@\S+|\d{7,}"#,
                          options: .regularExpression) == nil else { return nil }
        let normalized = query.replacingOccurrences(of: " ", with: "").lowercased()
        guard !sourceTexts.contains(where: { source in
            let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "").lowercased()
            return text == normalized || (normalized.count >= 12 && text.contains(normalized))
        }) else { return nil }
        return query
    }
}
