import Foundation
import Network

// MARK: - Service constants

public enum OBSRemoteService {
    public static let type = "_obsremote._tcp"
    public static let domain = "local."
    public static let defaultPort: UInt16 = 56780
}

// MARK: - Length-prefixed framing for JSON messages over TCP

public enum MessageFraming {

    /// Encode a Codable value into a length-prefixed frame: [4-byte big-endian length][JSON payload]
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    /// Extract complete frames from a buffer, returning (parsed messages, remaining buffer).
    public static func decode<T: Decodable>(_ type: T.Type, from buffer: Data) throws -> ([T], Data) {
        var results: [T] = []
        var offset = 0

        while offset + 4 <= buffer.count {
            let lengthBytes = buffer[offset..<offset + 4]
            let length = Int(UInt32(bigEndian: lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))

            guard offset + 4 + length <= buffer.count else { break }

            let jsonData = buffer[offset + 4..<offset + 4 + length]
            let decoded = try JSONDecoder().decode(T.self, from: jsonData)
            results.append(decoded)
            offset += 4 + length
        }

        let remaining = buffer.subdata(in: offset..<buffer.count)
        return (results, remaining)
    }
}
