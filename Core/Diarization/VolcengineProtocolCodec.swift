import Foundation

enum VolcengineProtocolError: Error, Equatable {
    case malformedFrame
    case unsupportedVersion
    case unsupportedSerialization
    case unsupportedCompression
    case unexpectedMessageType(UInt8)
}

enum VolcengineMessageType: UInt8, Equatable, Sendable {
    case fullClientRequest = 0x1
    case audioOnlyClientRequest = 0x2
    case fullServerResponse = 0x9
    case serverAcknowledgement = 0xB
    case serverError = 0xF
}

struct VolcengineFrame: Equatable, Sendable {
    var messageType: VolcengineMessageType
    var flags: UInt8
    var sequence: Int32?
    var errorCode: Int32?
    var payload: Data

    var isFinal: Bool { flags == 0x2 || flags == 0x3 }
}

enum VolcengineProtocolCodec {
    private static let versionAndHeaderSize: UInt8 = 0x11
    private static let jsonWithoutCompression: UInt8 = 0x10
    private static let rawWithoutCompression: UInt8 = 0x00

    static func encodeJSONRequest(_ payload: Data, sequence: Int32 = 1) -> Data {
        encode(
            messageType: .fullClientRequest,
            flags: 0x1,
            serializationAndCompression: jsonWithoutCompression,
            sequence: sequence,
            payload: payload
        )
    }

    static func encodeAudio(_ payload: Data, sequence: Int32, isFinal: Bool) -> Data {
        encode(
            messageType: .audioOnlyClientRequest,
            flags: isFinal ? 0x3 : 0x1,
            serializationAndCompression: rawWithoutCompression,
            sequence: isFinal ? -abs(sequence) : sequence,
            payload: payload
        )
    }

    static func decode(_ data: Data) throws -> VolcengineFrame {
        guard data.count >= 4 else { throw VolcengineProtocolError.malformedFrame }
        let bytes = [UInt8](data)
        guard bytes[0] >> 4 == 1 else { throw VolcengineProtocolError.unsupportedVersion }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        guard headerSize >= 4, bytes.count >= headerSize else {
            throw VolcengineProtocolError.malformedFrame
        }
        let rawType = bytes[1] >> 4
        guard let messageType = VolcengineMessageType(rawValue: rawType) else {
            throw VolcengineProtocolError.unexpectedMessageType(rawType)
        }
        let flags = bytes[1] & 0x0F
        let serialization = bytes[2] >> 4
        let compression = bytes[2] & 0x0F
        guard compression == 0 else { throw VolcengineProtocolError.unsupportedCompression }
        if messageType == .fullServerResponse, serialization != 1 {
            throw VolcengineProtocolError.unsupportedSerialization
        }

        var cursor = headerSize
        var sequence: Int32?
        var errorCode: Int32?
        if flags == 0x1 || flags == 0x3 {
            sequence = try readInt32(bytes, cursor: &cursor)
        }
        if messageType == .serverError {
            errorCode = try readInt32(bytes, cursor: &cursor)
        }

        var payload = Data()
        if messageType == .fullServerResponse || messageType == .serverError {
            let payloadSize = try readUInt32(bytes, cursor: &cursor)
            guard cursor <= bytes.count,
                  Int(payloadSize) <= bytes.count - cursor else {
                throw VolcengineProtocolError.malformedFrame
            }
            payload = Data(bytes[cursor..<(cursor + Int(payloadSize))])
            cursor += Int(payloadSize)
        } else if messageType == .serverAcknowledgement, cursor < bytes.count {
            let payloadSize = try readUInt32(bytes, cursor: &cursor)
            guard cursor <= bytes.count,
                  Int(payloadSize) <= bytes.count - cursor else {
                throw VolcengineProtocolError.malformedFrame
            }
            payload = Data(bytes[cursor..<(cursor + Int(payloadSize))])
            cursor += Int(payloadSize)
        }
        guard cursor == bytes.count else { throw VolcengineProtocolError.malformedFrame }
        return VolcengineFrame(
            messageType: messageType,
            flags: flags,
            sequence: sequence,
            errorCode: errorCode,
            payload: payload
        )
    }

    private static func encode(
        messageType: VolcengineMessageType,
        flags: UInt8,
        serializationAndCompression: UInt8,
        sequence: Int32,
        payload: Data
    ) -> Data {
        var result = Data([
            versionAndHeaderSize,
            (messageType.rawValue << 4) | flags,
            serializationAndCompression,
            0
        ])
        append(sequence, to: &result)
        append(UInt32(payload.count), to: &result)
        result.append(payload)
        return result
    }

    private static func append(_ value: Int32, to data: inout Data) {
        append(UInt32(bitPattern: value), to: &data)
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readInt32(_ bytes: [UInt8], cursor: inout Int) throws -> Int32 {
        Int32(bitPattern: try readUInt32(bytes, cursor: &cursor))
    }

    private static func readUInt32(_ bytes: [UInt8], cursor: inout Int) throws -> UInt32 {
        guard cursor <= bytes.count - 4 else { throw VolcengineProtocolError.malformedFrame }
        let value = UInt32(bytes[cursor]) << 24
            | UInt32(bytes[cursor + 1]) << 16
            | UInt32(bytes[cursor + 2]) << 8
            | UInt32(bytes[cursor + 3])
        cursor += 4
        return value
    }
}
