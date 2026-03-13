import SwiftUI
import CaptureCore

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Preferences")
                .font(.headline)

            // General
            GroupBox("General") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Start minimized (menu bar only)", isOn: $settings.startMinimized)
                    Toggle("Remember last device", isOn: $settings.rememberLastDevice)
                    Toggle("Auto-start capture on launch", isOn: $settings.autoStartCapture)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Output
            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Directory:")
                            .foregroundStyle(.secondary)
                        Text(settings.outputDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                    }

                    HStack(spacing: 12) {
                        Button("Choose...") {
                            chooseOutputDirectory()
                        }
                        Button("Reset to Default") {
                            settings.outputDirectoryPath = nil
                        }
                        .disabled(settings.outputDirectoryPath == nil)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Capture
            GroupBox("Capture") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Bitrate:")
                            .foregroundStyle(.secondary)
                        Picker("", selection: $settings.bitrateMbps) {
                            ForEach([5, 10, 15, 20, 30, 40, 50], id: \.self) { mbps in
                                Text("\(mbps) Mbps").tag(mbps)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 380)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose output directory for recordings, replays, and screenshots"

        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectoryPath = url.path
        }
    }
}
