import Foundation

// MARK: - Commands sent from iOS client to Mac server
// (Duplicated from OBSRemoteShared so the iOS app has no SPM dependency)

enum OBSCommand: String, Codable, Sendable {
    case launchOBS
    case startReplayBuffer
    case stopReplayBuffer
    case saveReplay
    case getStatus
}

struct CommandMessage: Codable, Sendable {
    let command: OBSCommand
    let id: String

    init(command: OBSCommand, id: String = UUID().uuidString) {
        self.command = command
        self.id = id
    }
}

struct StatusResponse: Codable, Sendable {
    let id: String
    let success: Bool
    let obsRunning: Bool
    let replayBufferActive: Bool
    let message: String?
}

// MARK: - Length-prefixed framing

enum MessageFraming {

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    static func decode<T: Decodable>(_ type: T.Type, from buffer: Data) throws -> ([T], Data) {
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
