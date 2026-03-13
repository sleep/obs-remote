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

            // Status Bar
            GroupBox("Menu Bar Display") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show next to the status icon:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let columns = [GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(AppSettings.StatusBarField.allCases) { field in
                            Toggle(field.label, isOn: statusBarBinding(for: field))
                                .toggleStyle(.checkbox)
                        }
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
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func statusBarBinding(for field: AppSettings.StatusBarField) -> Binding<Bool> {
        Binding(
            get: { settings.statusBarFields.contains(field) },
            set: { enabled in
                if enabled {
                    settings.statusBarFields.insert(field)
                } else {
                    settings.statusBarFields.remove(field)
                }
            }
        )
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
