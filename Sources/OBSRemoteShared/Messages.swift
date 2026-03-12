import Foundation

// MARK: - Commands sent from iOS client to Mac server

public enum OBSCommand: String, Codable, Sendable {
    case launchOBS
    case startReplayBuffer
    case stopReplayBuffer
    case saveReplay
    case getStatus
}

public struct CommandMessage: Codable, Sendable {
    public let command: OBSCommand
    public let id: String

    public init(command: OBSCommand, id: String = UUID().uuidString) {
        self.command = command
        self.id = id
    }
}

// MARK: - Responses sent from Mac server to iOS client

public struct StatusResponse: Codable, Sendable {
    public let id: String
    public let success: Bool
    public let obsRunning: Bool
    public let replayBufferActive: Bool
    public let message: String?

    public init(
        id: String,
        success: Bool,
        obsRunning: Bool = false,
        replayBufferActive: Bool = false,
        message: String? = nil
    ) {
        self.id = id
        self.success = success
        self.obsRunning = obsRunning
        self.replayBufferActive = replayBufferActive
        self.message = message
    }
}
