import Foundation

/// 占位服务统一错误：阶段 0 只定义协议接线，真实实现按阶段补齐
enum ServiceNotReadyError: Error, Equatable {
    case notImplemented(String)
}

extension ServiceNotReadyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notImplemented(let feature):
            return "「\(feature)」尚未实现，将在后续阶段提供"
        }
    }
}
