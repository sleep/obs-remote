import Foundation
import Network
import OBSRemoteShared

/// TCP server advertised via Bonjour so the iOS client can discover it automatically.
final class BonjourServer {

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let handler: (CommandMessage, @escaping (StatusResponse) -> Void) -> Void

    init(handler: @escaping (CommandMessage, @escaping (StatusResponse) -> Void) -> Void) {
        self.handler = handler
    }

    func start(port: UInt16 = OBSRemoteService.defaultPort) throws {
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: params, on: nwPort)

        // Advertise via Bonjour
        listener?.service = NWListener.Service(
            name: Host.current().localizedName ?? "OBS Remote Server",
            type: OBSRemoteService.type,
            domain: OBSRemoteService.domain
        )

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log("Server listening on port \(port)")
                log("Advertising via Bonjour as \(OBSRemoteService.type)")
            case .failed(let error):
                log("Server failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            log("New client connected: \(connection.endpoint)")
            self?.accept(connection)
        }

        listener?.start(queue: .main)
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log("Client ready: \(connection.endpoint)")
                self?.startReceiving(on: connection)
            case .failed(let error):
                log("Client disconnected with error: \(error)")
                self?.remove(connection)
            case .cancelled:
                log("Client disconnected")
                self?.remove(connection)
            default:
                break
            }
        }

        connection.start(queue: .main)
    }

    private func remove(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }

    private func startReceiving(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            var currentBuffer = buffer
            if let content = content {
                currentBuffer.append(content)
            }

            // Try to parse complete messages
            do {
                let (messages, remaining) = try MessageFraming.decode(CommandMessage.self, from: currentBuffer)
                for msg in messages {
                    log("Received command: \(msg.command.rawValue)")
                    self.handler(msg) { response in
                        self.send(response, on: connection)
                    }
                }
                currentBuffer = remaining
            } catch {
                log("Failed to decode message: \(error)")
            }

            if isComplete {
                connection.cancel()
                self.remove(connection)
            } else if error == nil {
                self.startReceiving(on: connection, buffer: currentBuffer)
            }
        }
    }

    private func send(_ response: StatusResponse, on connection: NWConnection) {
        do {
            let data = try MessageFraming.encode(response)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    log("Failed to send response: \(error)")
                }
            })
        } catch {
            log("Failed to encode response: \(error)")
        }
    }
}
