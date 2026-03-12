# OBS Remote

Control OBS from your iPhone over your local network. Launch OBS, start the replay buffer, and save replays with one tap.

## Architecture

```
┌─────────────┐     Bonjour + TCP     ┌─────────────────┐    WebSocket    ┌─────┐
│  iOS Client │ ◄──────────────────► │  macOS Server   │ ◄────────────► │ OBS │
│  (SwiftUI)  │    local network      │ (obs-remote-    │   localhost     │     │
│             │                       │     server)     │   :4455        │     │
└─────────────┘                       └─────────────────┘                └─────┘
```

- **iOS Client** discovers the server automatically via Bonjour (zero-config)
- **macOS Server** launches OBS and controls it through the built-in obs-websocket v5 API
- Communication uses length-prefixed JSON over TCP

## Requirements

- macOS 13+ (server)
- iOS 16+ (client)
- OBS 28+ (has obs-websocket built in)
- Swift 5.9+
- Both devices on the same local network

## Setup

### 1. OBS WebSocket

Open OBS > Tools > WebSocket Server Settings:
- Enable the WebSocket server
- Note the port (default: 4455)
- Set a password if desired

### 2. macOS Server

```bash
cd obs-remote
swift build
swift run obs-remote-server
```

With a password:
```bash
swift run obs-remote-server --password YOUR_PASSWORD
```

Or via environment variable:
```bash
OBS_WEBSOCKET_PASSWORD=YOUR_PASSWORD swift run obs-remote-server
```

The server will advertise itself on your local network via Bonjour.

### 3. iOS Client

1. Open Xcode
2. Create a new iOS App project named `OBSRemoteClient`
3. Replace the generated files with the files from `OBSRemoteClient/OBSRemoteClient/`
4. Add the `Info.plist` entries for Bonjour (local network permission + `_obsremote._tcp` service)
5. Build and run on your iPhone

## Usage

1. Start the macOS server: `swift run obs-remote-server`
2. Open the iOS app — it auto-discovers the server
3. Tap **Launch OBS** to start OBS on your Mac
4. Tap **Start Replay Buffer** to begin buffering
5. Tap **Save Replay** whenever you want to clip the last N seconds

## Commands

| Command | Description |
|---------|-------------|
| Launch OBS | Opens OBS.app on the Mac |
| Start Replay Buffer | Begins the OBS replay buffer |
| Stop Replay Buffer | Stops the replay buffer |
| Save Replay | Saves the current replay buffer to disk |
