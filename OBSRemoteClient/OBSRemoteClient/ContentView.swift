import SwiftUI

struct ContentView: View {
    @StateObject private var server = ServerConnection()
    @State private var showingSaveConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                connectionStatus

                if server.isConnected {
                    obsStatus
                    Spacer()
                    controlButtons
                    Spacer()

                    if let message = server.lastMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    Spacer()
                    ProgressView()
                    Text("Searching for OBS Remote Server...")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("OBS Remote")
            .onAppear {
                server.startBrowsing()
            }
            .onDisappear {
                server.stopBrowsing()
            }
        }
    }

    // MARK: - Connection status

    private var connectionStatus: some View {
        HStack {
            Circle()
                .fill(server.isConnected ? .green : .red)
                .frame(width: 12, height: 12)
            Text(server.isConnected
                 ? "Connected to \(server.serverName ?? "server")"
                 : "Disconnected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - OBS status badges

    private var obsStatus: some View {
        HStack(spacing: 20) {
            statusBadge(title: "OBS",
                        active: server.obsRunning,
                        activeColor: .green,
                        activeText: "Running",
                        inactiveText: "Not Running")
            statusBadge(title: "Replay Buffer",
                        active: server.replayBufferActive,
                        activeColor: .orange,
                        activeText: "Active",
                        inactiveText: "Inactive")
        }
    }

    private func statusBadge(title: String, active: Bool, activeColor: Color,
                              activeText: String, inactiveText: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(active ? activeText : inactiveText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(active ? activeColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Control buttons

    private var controlButtons: some View {
        VStack(spacing: 16) {
            if !server.obsRunning {
                ActionButton(title: "Launch OBS",
                             icon: "play.display",
                             color: .blue) {
                    server.send(.launchOBS)
                }
            }

            if server.obsRunning && !server.replayBufferActive {
                ActionButton(title: "Start Replay Buffer",
                             icon: "arrow.counterclockwise.circle",
                             color: .orange) {
                    server.send(.startReplayBuffer)
                }
            }

            if server.obsRunning && server.replayBufferActive {
                ActionButton(title: "Save Replay",
                             icon: "square.and.arrow.down.fill",
                             color: .green,
                             isLarge: true) {
                    server.send(.saveReplay)
                    withAnimation(.spring(response: 0.3)) {
                        showingSaveConfirmation = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { showingSaveConfirmation = false }
                    }
                }

                ActionButton(title: "Stop Replay Buffer",
                             icon: "stop.circle",
                             color: .red) {
                    server.send(.stopReplayBuffer)
                }
            }
        }
        .disabled(server.isBusy)
        .overlay {
            if showingSaveConfirmation {
                savedOverlay
            }
        }
    }

    private var savedOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Replay Saved!")
                .font(.title3.weight(.semibold))
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Reusable button

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    var isLarge: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(isLarge ? .title2.weight(.semibold) : .headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLarge ? 20 : 14)
                .foregroundStyle(.white)
                .background(color, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
