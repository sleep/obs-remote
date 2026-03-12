# OBS Remote

Control OBS from your iPhone (or any device) over your local network. Launch OBS, start the replay buffer, and save replays with one tap.

Two versions included:

- **Node.js + Web UI** — zero-install on client, works from any browser
- **Swift (native)** — Bonjour-based macOS server + SwiftUI iOS app

---

## Node.js Version (Recommended)

A Node server that serves a mobile-optimized web page. Open it from any phone/tablet/computer on your LAN.

```
┌──────────────┐       WebSocket       ┌──────────────┐   obs-websocket  ┌─────┐
│  Any Browser │ ◄──────────────────► │  Node Server │ ◄──────────────► │ OBS │
│  (phone/etc) │    LAN :8080         │              │   localhost:4455  │     │
└──────────────┘                       └──────────────┘                  └─────┘
```

### Quick Start

```bash
cd node-server
npm install
node server.js
```

The server prints your LAN URL — open it on your phone:

```
=================================
  OBS Remote Server
=================================

  Open on your phone:
    http://192.168.1.42:8080

  OBS WebSocket: ws://127.0.0.1:4455
=================================
```

### Configuration

| Env Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | HTTP/WebSocket port |
| `OBS_WS_URL` | `ws://127.0.0.1:4455` | OBS WebSocket URL |
| `OBS_WS_PASSWORD` | _(none)_ | OBS WebSocket password |

Example with password:
```bash
OBS_WS_PASSWORD=secret node server.js
```

### Add to Home Screen (iOS)

Open the URL in Safari, tap Share > Add to Home Screen. It runs full-screen like a native app.

---

## Swift Version (Native)

Bonjour-based macOS server + SwiftUI iOS app with automatic discovery.

```
┌─────────────┐     Bonjour + TCP     ┌─────────────────┐   obs-websocket  ┌─────┐
│  iOS Client │ ◄──────────────────► │  macOS Server   │ ◄──────────────► │ OBS │
│  (SwiftUI)  │    local network      │ (obs-remote-    │   localhost:4455  │     │
│             │                       │     server)     │                   │     │
└─────────────┘                       └─────────────────┘                  └─────┘
```

### macOS Server

```bash
swift build
swift run obs-remote-server
# With password:
swift run obs-remote-server --password YOUR_PASSWORD
```

### iOS Client

1. Open Xcode
2. Create a new iOS App project named `OBSRemoteClient`
3. Replace the generated files with the files from `OBSRemoteClient/OBSRemoteClient/`
4. Add the `Info.plist` entries for Bonjour
5. Build and run on your iPhone

---

## OBS Setup

Open OBS > Tools > WebSocket Server Settings:
- Enable the WebSocket server
- Note the port (default: 4455)
- Set a password if desired

Requires **OBS 28+** (obs-websocket v5 is built in).

## Commands

| Command | Description |
|---------|-------------|
| Launch OBS | Opens OBS.app on the Mac |
| Start Replay Buffer | Begins the OBS replay buffer |
| Stop Replay Buffer | Stops the replay buffer |
| Save Replay | Saves the current replay buffer to disk |
