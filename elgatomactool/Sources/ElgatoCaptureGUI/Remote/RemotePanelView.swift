import SwiftUI
import AppKit

/// Pairing panel: shows the QR code + URL for the mobile remote, with controls
/// to start/stop the server and rotate the access key.
struct RemotePanelView: View {
    @ObservedObject var remote: RemoteController
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            header

            if remote.isRunning {
                runningContent
            } else {
                stoppedContent
            }

            Divider()

            HStack {
                Toggle("Start automatically on launch", isOn: $settings.remoteEnabled)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Mobile Remote")
                .font(.system(size: 18, weight: .bold))
            Text("Scan with your phone to control capture, view stats and the live preview.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var runningContent: some View {
        if let qr = remote.qrImage {
            Image(nsImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(LinearGradient(colors: [.pink, .cyan],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 2)
                )
        }

        if let url = remote.remoteURL {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                Text(url)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .primary)
                }
                .buttonStyle(.borderless)
                .help("Copy URL")
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Label("No LAN connection detected — connect to Wi-Fi or Ethernet.",
                  systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        HStack(spacing: 12) {
            Label("Server running on port \(String(remote.port))", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.green)
            Spacer()
            Button("Rotate Key") { remote.regeneratePSK() }
                .help("Generate a new access key (re-scan required)")
            Button("Stop") { remote.stop() }
                .tint(.red)
        }
    }

    @ViewBuilder
    private var stoppedContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(colors: [.pink, .cyan],
                                   startPoint: .top, endPoint: .bottom)
                )
            Text("The remote server is off.")
                .foregroundStyle(.secondary)
            if let error = remote.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                remote.start()
            } label: {
                Label("Start Remote Server", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.pink)
        }
        .padding(.vertical, 8)
    }
}
