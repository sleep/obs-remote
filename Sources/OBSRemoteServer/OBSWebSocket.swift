import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CommonCrypto

/// Client for the OBS WebSocket v5 protocol (obs-websocket 5.x, built into OBS 28+).
/// Connects to ws://localhost:4455 by default.
final class OBSWebSocket: NSObject, @unchecked Sendable {

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let host: String
    private let port: Int
    private let password: String?
    private var identified = false

    private let lock = NSLock()
    private var pendingRequests: [String: (Result<[String: Any], Error>) -> Void] = [:]

    var isConnected: Bool { identified }

    init(host: String = "127.0.0.1", port: Int = 4455, password: String? = nil) {
        self.host = host
        self.port = port
        self.password = password
        super.init()
    }

    // MARK: - Connection

    func connect() async throws {
        let url = URL(string: "ws://\(host):\(port)")!
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocket = session!.webSocketTask(with: url)
        webSocket!.resume()

        // Wait for Hello message and complete handshake
        let hello = try await receiveJSON()
        guard let op = hello["op"] as? Int, op == 0,
              let d = hello["d"] as? [String: Any] else {
            throw OBSError.unexpectedMessage
        }

        // Build Identify message
        var identifyData: [String: Any] = ["rpcVersion": 1]

        if let auth = d["authentication"] as? [String: Any],
           let challenge = auth["challenge"] as? String,
           let salt = auth["salt"] as? String {
            guard let password = password else {
                throw OBSError.authenticationRequired
            }
            let authString = generateAuthString(password: password, salt: salt, challenge: challenge)
            identifyData["authentication"] = authString
        }

        let identify: [String: Any] = ["op": 1, "d": identifyData]
        try await sendJSON(identify)

        // Wait for Identified (op 2)
        let identified = try await receiveJSON()
        guard let idOp = identified["op"] as? Int, idOp == 2 else {
            throw OBSError.authenticationFailed
        }

        self.identified = true
        log("Connected to OBS WebSocket")

        // Start background receive loop for request responses
        Task { await receiveLoop() }
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        identified = false
    }

    // MARK: - OBS Requests

    func startReplayBuffer() async throws {
        let _ = try await sendRequest("StartReplayBuffer")
        log("Replay buffer started")
    }

    func stopReplayBuffer() async throws {
        let _ = try await sendRequest("StopReplayBuffer")
        log("Replay buffer stopped")
    }

    func saveReplayBuffer() async throws {
        let _ = try await sendRequest("SaveReplayBuffer")
        log("Replay saved")
    }

    func getReplayBufferStatus() async throws -> Bool {
        let response = try await sendRequest("GetReplayBufferStatus")
        return response["outputActive"] as? Bool ?? false
    }

    // MARK: - Low-level protocol

    private func sendRequest(_ requestType: String, requestData: [String: Any]? = nil) async throws -> [String: Any] {
        let requestId = UUID().uuidString

        var d: [String: Any] = [
            "requestType": requestType,
            "requestId": requestId,
        ]
        if let requestData = requestData {
            d["requestData"] = requestData
        }

        let message: [String: Any] = ["op": 6, "d": d]

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingRequests[requestId] = { result in
                continuation.resume(with: result)
            }
            lock.unlock()

            Task {
                do {
                    try await sendJSON(message)
                } catch {
                    lock.lock()
                    let handler = pendingRequests.removeValue(forKey: requestId)
                    lock.unlock()
                    handler?(.failure(error))
                }
            }
        }
    }

    private func sendJSON(_ dict: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        let string = String(data: data, encoding: .utf8)!
        try await webSocket?.send(.string(string))
    }

    private func receiveJSON() async throws -> [String: Any] {
        guard let message = try await webSocket?.receive() else {
            throw OBSError.disconnected
        }
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OBSError.unexpectedMessage
            }
            return json
        case .data(let data):
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OBSError.unexpectedMessage
            }
            return json
        @unknown default:
            throw OBSError.unexpectedMessage
        }
    }

    private func receiveLoop() async {
        while identified {
            do {
                let json = try await receiveJSON()
                guard let op = json["op"] as? Int else { continue }

                if op == 7, let d = json["d"] as? [String: Any],
                   let requestId = d["requestId"] as? String {
                    let responseData = d["responseData"] as? [String: Any] ?? [:]
                    let status = d["requestStatus"] as? [String: Any]
                    let result = status?["result"] as? Bool ?? false

                    lock.lock()
                    let handler = pendingRequests.removeValue(forKey: requestId)
                    lock.unlock()

                    if result {
                        handler?(.success(responseData))
                    } else {
                        let comment = status?["comment"] as? String ?? "Request failed"
                        handler?(.failure(OBSError.requestFailed(comment)))
                    }
                }
            } catch {
                if identified {
                    log("WebSocket receive error: \(error)")
                    identified = false
                }
                break
            }
        }
    }

    // MARK: - Authentication

    private func generateAuthString(password: String, salt: String, challenge: String) -> String {
        let saltedPassword = sha256(password + salt)
        let base64SaltedPassword = Data(saltedPassword).base64EncodedString()
        let authHash = sha256(base64SaltedPassword + challenge)
        return Data(authHash).base64EncodedString()
    }

    private func sha256(_ string: String) -> [UInt8] {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash
    }
}

extension OBSWebSocket: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        log("WebSocket connection opened")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        log("WebSocket connection closed")
        identified = false
    }
}

// MARK: - Errors

enum OBSError: LocalizedError {
    case unexpectedMessage
    case authenticationRequired
    case authenticationFailed
    case requestFailed(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .unexpectedMessage: return "Unexpected message from OBS"
        case .authenticationRequired: return "OBS requires a password but none was provided"
        case .authenticationFailed: return "OBS authentication failed"
        case .requestFailed(let msg): return "OBS request failed: \(msg)"
        case .disconnected: return "Disconnected from OBS"
        }
    }
}

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    print("[\(formatter.string(from: Date()))] \(message)")
}
