import Foundation
import Network
import Combine

/// Discovers the Mac server via Bonjour and manages the TCP connection.
@MainActor
final class ServerConnection: ObservableObject {

    // MARK: - Published state

    @Published var isConnected = false
    @Published var serverName: String?
    @Published var obsRunning = false
    @Published var replayBufferActive = false
    @Published var lastMessage: String?
    @Published var isBusy = false
    @Published var discoveredServers: [NWBrowser.Result] = []

    // MARK: - Internals

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pendingCallbacks: [String: (StatusResponse) -> Void] = [:]
    private var statusTimer: Timer?

    private static let serviceType = "_obsremote._tcp"

    // MARK: - Browsing

    func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.discoveredServers = Array(results)
                // Auto-connect to first server found
                if self?.connection == nil, let first = results.first {
                    self?.connect(to: first.endpoint)
                }
            }
        }

        browser?.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("Browser failed: \(error)")
            }
        }

        browser?.start(queue: .main)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Connection

    func connect(to endpoint: NWEndpoint) {
        connection?.cancel()

        let params = NWParameters.tcp
        connection = NWConnection(to: endpoint, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isConnected = true
                    if case .service(let name, _, _, _) = endpoint {
                        self?.serverName = name
                    }
                    self?.receiveBuffer = Data()
                    self?.startReceiving()
                    self?.startStatusPolling()
                    // Request initial status
                    self?.send(.getStatus)
                case .failed, .cancelled:
                    self?.isConnected = false
                    self?.serverName = nil
                    self?.obsRunning = false
                    self?.replayBufferActive = false
                    self?.stopStatusPolling()
                default:
                    break
                }
            }
        }

        connection?.start(queue: .main)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        stopStatusPolling()
    }

    // MARK: - Commands

    func send(_ command: OBSCommand, completion: ((StatusResponse) -> Void)? = nil) {
        let msg = CommandMessage(command: command)
        isBusy = true

        if let completion = completion {
            pendingCallbacks[msg.id] = completion
        } else {
            pendingCallbacks[msg.id] = { [weak self] response in
                self?.handleResponse(response)
            }
        }

        do {
            let data = try MessageFraming.encode(msg)
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    Task { @MainActor in
                        self?.isBusy = false
                        self?.lastMessage = "Send failed: \(error.localizedDescription)"
                    }
                }
            })
        } catch {
            isBusy = false
            lastMessage = "Encode failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Receiving

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let content = content {
                    self.receiveBuffer.append(content)
                    self.processBuffer()
                }

                if isComplete {
                    self.disconnect()
                } else if error == nil {
                    self.startReceiving()
                }
            }
        }
    }

    private func processBuffer() {
        do {
            let (responses, remaining) = try MessageFraming.decode(StatusResponse.self, from: receiveBuffer)
            receiveBuffer = remaining

            for response in responses {
                if let callback = pendingCallbacks.removeValue(forKey: response.id) {
                    callback(response)
                } else {
                    handleResponse(response)
                }
            }
        } catch {
            lastMessage = "Decode error: \(error.localizedDescription)"
        }
    }

    private func handleResponse(_ response: StatusResponse) {
        isBusy = false
        obsRunning = response.obsRunning
        replayBufferActive = response.replayBufferActive
        if let msg = response.message {
            lastMessage = msg
        }
    }

    // MARK: - Status polling

    private func startStatusPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.send(.getStatus)
            }
        }
    }

    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
}
