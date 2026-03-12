import Foundation
import OBSRemoteShared

// MARK: - Configuration

let obsPassword: String? = {
    if let pwd = ProcessInfo.processInfo.environment["OBS_WEBSOCKET_PASSWORD"] {
        return pwd
    }
    // Check command-line args: --password <pwd>
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--password"), idx + 1 < args.count {
        return args[idx + 1]
    }
    return nil
}()

let obsPort: Int = {
    if let portStr = ProcessInfo.processInfo.environment["OBS_WEBSOCKET_PORT"],
       let port = Int(portStr) {
        return port
    }
    if let idx = CommandLine.arguments.firstIndex(of: "--obs-port"),
       idx + 1 < CommandLine.arguments.count,
       let port = Int(CommandLine.arguments[idx + 1]) {
        return port
    }
    return 4455
}()

// MARK: - State

let obsWS = OBSWebSocket(host: "127.0.0.1", port: obsPort, password: obsPassword)
var obsRunning = false
var replayBufferActive = false

// MARK: - OBS App Launcher

func launchOBS() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "OBS"]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        log("Failed to launch OBS: \(error)")
        return false
    }
}

func isOBSRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "obs"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func connectToOBS() async -> Bool {
    guard !obsWS.isConnected else { return true }

    // Retry a few times since OBS may still be starting up
    for attempt in 1...5 {
        do {
            try await obsWS.connect()
            return true
        } catch {
            log("OBS WebSocket connection attempt \(attempt) failed: \(error)")
            if attempt < 5 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }
    return false
}

// MARK: - Command Handler

func handleCommand(_ cmd: CommandMessage, reply: @escaping (StatusResponse) -> Void) {
    Task {
        let response: StatusResponse

        switch cmd.command {
        case .launchOBS:
            if isOBSRunning() {
                let connected = await connectToOBS()
                response = StatusResponse(
                    id: cmd.id,
                    success: true,
                    obsRunning: true,
                    replayBufferActive: replayBufferActive,
                    message: connected ? "OBS already running, connected" : "OBS running but WebSocket connection failed"
                )
            } else {
                let launched = launchOBS()
                if launched {
                    // Give OBS time to start up and initialize WebSocket server
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let connected = await connectToOBS()
                    response = StatusResponse(
                        id: cmd.id,
                        success: launched,
                        obsRunning: true,
                        replayBufferActive: false,
                        message: connected ? "OBS launched and connected" : "OBS launched but WebSocket connection failed"
                    )
                } else {
                    response = StatusResponse(
                        id: cmd.id,
                        success: false,
                        obsRunning: false,
                        message: "Failed to launch OBS"
                    )
                }
            }

        case .startReplayBuffer:
            guard obsWS.isConnected else {
                let connected = await connectToOBS()
                if !connected {
                    reply(StatusResponse(id: cmd.id, success: false, obsRunning: isOBSRunning(), message: "Not connected to OBS"))
                    return
                }
            }
            do {
                try await obsWS.startReplayBuffer()
                replayBufferActive = true
                response = StatusResponse(id: cmd.id, success: true, obsRunning: true, replayBufferActive: true, message: "Replay buffer started")
            } catch {
                response = StatusResponse(id: cmd.id, success: false, obsRunning: true, message: "Failed to start replay buffer: \(error.localizedDescription)")
            }

        case .stopReplayBuffer:
            guard obsWS.isConnected else {
                reply(StatusResponse(id: cmd.id, success: false, obsRunning: isOBSRunning(), message: "Not connected to OBS"))
                return
            }
            do {
                try await obsWS.stopReplayBuffer()
                replayBufferActive = false
                response = StatusResponse(id: cmd.id, success: true, obsRunning: true, replayBufferActive: false, message: "Replay buffer stopped")
            } catch {
                response = StatusResponse(id: cmd.id, success: false, obsRunning: true, message: "Failed to stop replay buffer: \(error.localizedDescription)")
            }

        case .saveReplay:
            guard obsWS.isConnected else {
                reply(StatusResponse(id: cmd.id, success: false, obsRunning: isOBSRunning(), message: "Not connected to OBS"))
                return
            }
            do {
                try await obsWS.saveReplayBuffer()
                response = StatusResponse(id: cmd.id, success: true, obsRunning: true, replayBufferActive: true, message: "Replay saved!")
            } catch {
                response = StatusResponse(id: cmd.id, success: false, obsRunning: true, replayBufferActive: replayBufferActive, message: "Failed to save replay: \(error.localizedDescription)")
            }

        case .getStatus:
            let running = isOBSRunning()
            var rbActive = false
            if running && !obsWS.isConnected {
                let _ = await connectToOBS()
            }
            if obsWS.isConnected {
                rbActive = (try? await obsWS.getReplayBufferStatus()) ?? false
                replayBufferActive = rbActive
            }
            response = StatusResponse(id: cmd.id, success: true, obsRunning: running, replayBufferActive: rbActive)
        }

        reply(response)
    }
}

// MARK: - Main

log("OBS Remote Server starting...")
log("OBS WebSocket target: 127.0.0.1:\(obsPort)")
if obsPassword != nil {
    log("OBS WebSocket password: configured")
}

let server = BonjourServer(handler: handleCommand)
try server.start()

// Auto-connect to OBS if it's already running
Task {
    if isOBSRunning() {
        log("OBS is already running, connecting...")
        let connected = await connectToOBS()
        if connected {
            replayBufferActive = (try? await obsWS.getReplayBufferStatus()) ?? false
            log("Replay buffer active: \(replayBufferActive)")
        }
    }
}

log("Server running. Press Ctrl+C to stop.")
dispatchMain()
