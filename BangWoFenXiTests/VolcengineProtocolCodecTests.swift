import Foundation
import Testing
@testable import BangWoFenXi

@Suite("火山 Seed 协议编解码")
struct VolcengineProtocolCodecTests {
    @Test("客户端 JSON 请求携带正序号与长度")
    func encodesJSONRequest() throws {
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let frame = VolcengineProtocolCodec.encodeJSONRequest(payload, sequence: 7)
        #expect(frame[0] == 0x11)
        #expect(frame[1] == 0x11)
        #expect(frame[2] == 0x10)
        #expect(frame.count == 12 + payload.count)
    }

    @Test("最后一个音频包使用负序号与结束标记")
    func encodesFinalAudio() {
        let frame = VolcengineProtocolCodec.encodeAudio(
            Data([1, 2, 3]),
            sequence: 8,
            isFinal: true
        )
        #expect(frame[1] == 0x23)
        #expect(Array(frame[4..<8]) == [255, 255, 255, 248])
    }

    @Test("解码最终服务响应")
    func decodesFinalResponse() throws {
        let payload = Data("{\"result\":{}}".utf8)
        let frame = try VolcengineProtocolCodec.decode(serverResponse(payload: payload))
        #expect(frame.messageType == .fullServerResponse)
        #expect(frame.isFinal)
        #expect(frame.payload == payload)
    }

    @Test("拒绝压缩帧和越界长度")
    func rejectsMalformedFrames() {
        var compressed = serverResponse(payload: Data("{}".utf8))
        compressed[2] = 0x11
        #expect(throws: VolcengineProtocolError.unsupportedCompression) {
            try VolcengineProtocolCodec.decode(compressed)
        }

        var truncated = serverResponse(payload: Data("{}".utf8))
        truncated.removeLast()
        #expect(throws: VolcengineProtocolError.malformedFrame) {
            try VolcengineProtocolCodec.decode(truncated)
        }
    }
}

private func serverResponse(payload: Data, final: Bool = true) -> Data {
    var data = Data([0x11, final ? 0x92 : 0x90, 0x10, 0x00])
    appendBigEndian(UInt32(payload.count), to: &data)
    data.append(payload)
    return data
}

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}
