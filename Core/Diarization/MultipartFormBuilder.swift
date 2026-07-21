import Foundation

/// multipart/form-data 请求体构建器（纯逻辑，可单测；无第三方依赖）。
struct MultipartFormBuilder: Sendable {
    let boundary: String
    private(set) var data = Data()

    init(boundary: String = "----BangWoFenXiFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))") {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// 添加文本字段
    mutating func addField(name: String, value: String) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        data.append(value.data(using: .utf8)!)
        data.append("\r\n".data(using: .utf8)!)
    }

    /// 添加数组文本字段（name[] 形式，每个元素一个 part）
    mutating func addArrayField(name: String, values: [String]) {
        for value in values {
            addField(name: name, value: value)
        }
    }

    /// 添加文件字段
    mutating func addFile(name: String, fileName: String, mimeType: String, fileData: Data) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        data.append(fileData)
        data.append("\r\n".data(using: .utf8)!)
    }

    /// 收尾，返回完整请求体
    func finish() -> Data {
        var result = data
        result.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return result
    }
}
