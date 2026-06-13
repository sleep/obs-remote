import Foundation
import Network

/// A parsed HTTP request.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

/// A response to send back to the client.
struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "text/plain; charset=utf-8"
    var body: Data = Data()
    var extraHeaders: [String: String] = [:]

    static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ string: String, status: Int = 200,
                     contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, contentType: contentType, body: Data(string.utf8))
    }
}

/// Async hooks the server calls to satisfy requests. Implemented by the controller,
/// which hops to the main actor / does heavy work off-main as needed.
struct RemoteRoutes {
    /// Validates a presented pre-shared key.
    var validate: @Sendable (_ psk: String?) -> Bool
    /// Returns the current state snapshot as JSON.
    var state: @Sendable () async -> Data
    /// Returns the latest preview frame as JPEG (or nil if none yet).
    var preview: @Sendable () async -> Data?
    /// Handles an action POST body, returns a JSON result.
    var action: @Sendable (_ body: Data) async -> Data
    /// Handles a settings PATCH body, returns a JSON result.
    var settings: @Sendable (_ body: Data) async -> Data
    /// Returns a generated PNG icon at the requested pixel size.
    var icon: @Sendable (_ size: Int) async -> Data?
    /// Returns a bundled static web asset (html/css/js/manifest/etc).
    var asset: @Sendable (_ name: String) -> (data: Data, contentType: String)?
}

/// Minimal, dependency-free HTTP/1.1 server built on Network.framework.
/// Handles one request per connection (Connection: close) — robust and simple for LAN use.
final class RemoteServer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "remote.server", qos: .userInitiated)
    private var listener: NWListener?
    private let routes: RemoteRoutes
    private var triedFallback = false

    private(set) var actualPort: UInt16 = 0

    /// Called on the server queue whenever the listener becomes ready or fails.
    var onStateChange: ((Bool, UInt16) -> Void)?

    init(routes: RemoteRoutes) {
        self.routes = routes
    }

    var isRunning: Bool { listener != nil }

    /// Start listening. Tries `preferredPort` first; if that port can't be bound
    /// (e.g. already in use) it transparently falls back to an OS-assigned port.
    func start(preferredPort: UInt16) throws {
        stop()
        triedFallback = false
        try bind(to: NWEndpoint.Port(rawValue: preferredPort) ?? .any)
    }

    private func bind(to port: NWEndpoint.Port) throws {
        // Listen on all interfaces so phones on the LAN can connect.
        let tcpParams = NWParameters.tcp
        tcpParams.allowLocalEndpointReuse = true

        let listener = try NWListener(using: tcpParams, on: port)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.actualPort = self.listener?.port?.rawValue ?? port.rawValue
                self.onStateChange?(true, self.actualPort)
            case .failed:
                // Preferred port likely busy — retry once on an OS-assigned port.
                if !self.triedFallback && port != .any {
                    self.triedFallback = true
                    self.listener?.cancel()
                    self.listener = nil
                    try? self.bind(to: .any)
                } else {
                    self.onStateChange?(false, 0)
                }
            case .cancelled:
                self.onStateChange?(false, 0)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        actualPort = 0
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }

            // Guard against runaway requests.
            if buffer.count > 4 * 1024 * 1024 {
                self.send(.text("Request too large", status: 413), on: connection)
                return
            }

            if let request = self.parse(buffer) {
                Task {
                    let response = await self.route(request)
                    self.send(response, on: connection)
                }
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    /// Parse a full HTTP request from the buffer, or nil if more bytes are needed.
    private func parse(_ buffer: Data) -> HTTPRequest? {
        // Find header/body separator.
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: sep) else { return nil }

        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let rawTarget = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Wait for the full body if there is one.
        let bodyStart = range.upperBound
        let available = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if available < contentLength { return nil }

        let body: Data
        if contentLength > 0 {
            let end = buffer.index(bodyStart, offsetBy: contentLength)
            body = buffer.subdata(in: bodyStart..<end)
        } else {
            body = Data()
        }

        // Split path and query.
        var path = rawTarget
        var query: [String: String] = [:]
        if let qIdx = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[rawTarget.startIndex..<qIdx])
            let queryString = String(rawTarget[rawTarget.index(after: qIdx)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
                query[key] = value
            }
        }

        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        let psk = request.query["k"] ?? request.headers["x-psk"]

        // The static shell (HTML/CSS/JS), service worker, manifest, and icons are
        // served without auth so the page can boot and the browser can fetch its
        // relative assets without re-stamping the PSK on each URL. The PSK gates
        // /api/* — the actual control surface and data — and the JS shell shows
        // the locked overlay until the API accepts the key.
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return staticAsset("index.html")
        case ("GET", "/app.css"):
            return staticAsset("app.css")
        case ("GET", "/app.js"):
            return staticAsset("app.js")
        case ("GET", "/sw.js"):
            return staticAsset("sw.js")
        case ("GET", "/manifest.webmanifest"):
            return manifest(psk: psk)
        case ("GET", "/icon-180.png"):
            return await iconResponse(size: 180)
        case ("GET", "/icon-192.png"):
            return await iconResponse(size: 192)
        case ("GET", "/icon-512.png"):
            return await iconResponse(size: 512)
        case ("GET", "/favicon.ico"):
            return HTTPResponse(status: 204)
        case ("GET", "/api/ping"):
            return .json(Data("{\"ok\":true}".utf8))
        default:
            break
        }

        // Everything else (the API) requires a valid PSK.
        guard routes.validate(psk) else {
            return .json(Data("{\"error\":\"unauthorized\"}".utf8), status: 401)
        }

        switch (request.method, request.path) {
        case ("GET", "/api/state"):
            return .json(await routes.state())
        case ("GET", "/api/preview.jpg"):
            if let jpeg = await routes.preview() {
                return HTTPResponse(status: 200, contentType: "image/jpeg", body: jpeg,
                                    extraHeaders: ["Cache-Control": "no-store"])
            }
            return HTTPResponse(status: 204)
        case ("POST", "/api/action"):
            return .json(await routes.action(request.body))
        case ("POST", "/api/settings"):
            return .json(await routes.settings(request.body))
        default:
            return .text("Not found", status: 404)
        }
    }

    private func staticAsset(_ name: String) -> HTTPResponse {
        guard let asset = routes.asset(name) else {
            return .text("Not found", status: 404)
        }
        var extra: [String: String] = [:]
        if name == "sw.js" {
            extra["Service-Worker-Allowed"] = "/"
            extra["Cache-Control"] = "no-cache"
        }
        return HTTPResponse(status: 200, contentType: asset.contentType, body: asset.data,
                            extraHeaders: extra)
    }

    private func iconResponse(size: Int) async -> HTTPResponse {
        if let png = await routes.icon(size) {
            return HTTPResponse(status: 200, contentType: "image/png", body: png,
                                extraHeaders: ["Cache-Control": "public, max-age=86400"])
        }
        return HTTPResponse(status: 404)
    }

    private func manifest(psk: String?) -> HTTPResponse {
        // start_url carries the PSK so the installed PWA stays authenticated.
        let key = psk ?? ""
        let json = """
        {
          "name": "Elgato Capture Remote",
          "short_name": "Capture",
          "description": "Remote control for Elgato Capture",
          "start_url": "/?k=\(key)",
          "scope": "/",
          "display": "standalone",
          "orientation": "portrait",
          "background_color": "#07060d",
          "theme_color": "#07060d",
          "icons": [
            { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
            { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable" }
          ]
        }
        """
        return HTTPResponse(status: 200, contentType: "application/manifest+json", body: Data(json.utf8))
    }

    // MARK: - Sending

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        for (key, value) in response.extraHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(response.body)

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
