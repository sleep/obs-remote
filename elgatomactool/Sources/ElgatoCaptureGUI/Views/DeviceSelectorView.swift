import SwiftUI
import AVFoundation

/// Video + audio device pickers plus the inline button row (refresh, settings, open
/// folder, stop, audio passthrough toggle, level meter). Observes DeviceVM (the
/// selections / available device lists / passthrough flag) and StatsVM (only for
/// `hasAudio` and the live peak meter shown next to the audio picker). All action
/// callbacks are passed in so the view does not need a reference to CaptureViewModel.
struct DeviceSelectorView: View {
    @ObservedObject var devices: DeviceVM
    @ObservedObject var stats: StatsVM
    let isCapturing: Bool
    let remoteIsRunning: Bool
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onOpenRemote: () -> Void
    let onOpenOutputFolder: () -> Void
    let onStopCapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Video device row
            devicePickerRow(
                icon: "video.fill",
                picker: Menu {
                    if devices.availableDevices.isEmpty {
                        Text("No devices")
                    }
                    ForEach(devices.availableDevices, id: \.uniqueID) { device in
                        Button {
                            devices.selectedDevice = device
                        } label: {
                            if ViewFormatters.isElgatoDevice(device) {
                                Image(systemName: "star.fill")
                            }
                            Text(device.localizedName)
                            if device.uniqueID == devices.selectedDevice?.uniqueID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let selected = devices.selectedDevice,
                           ViewFormatters.isElgatoDevice(selected) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        Text(devices.selectedDevice?.localizedName
                             ?? (devices.availableDevices.isEmpty ? "No devices" : "Select…"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true),
                buttons: HStack(spacing: 6) {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh device list")

                    if #available(macOS 14.0, *) {
                        SettingsLink {
                            Image(systemName: "gearshape")
                        }
                        .help("Preferences")
                    } else {
                        Button {
                            onOpenSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("Preferences")
                    }

                    Button {
                        onOpenRemote()
                    } label: {
                        Image(systemName: remoteIsRunning
                              ? "antenna.radiowaves.left.and.right" : "iphone")
                            .foregroundStyle(remoteIsRunning ? Color.green : Color.secondary)
                    }
                    .help("Mobile remote control")

                    Button {
                        onOpenOutputFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Open output folder")

                    if isCapturing {
                        Button {
                            onStopCapture()
                        } label: {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.red)
                        }
                        .help("Stop capture")
                    }
                }
            )

            // Audio device row
            devicePickerRow(
                icon: "waveform",
                picker: Menu {
                    Button {
                        devices.selectedAudioDevice = nil
                    } label: {
                        Text("None")
                        if devices.selectedAudioDevice == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                    ForEach(devices.availableAudioDevices, id: \.uniqueID) { device in
                        Button {
                            devices.selectedAudioDevice = device
                        } label: {
                            if ViewFormatters.isElgatoDevice(device) {
                                Image(systemName: "star.fill")
                            }
                            Text(device.localizedName)
                            if device.uniqueID == devices.selectedAudioDevice?.uniqueID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let selected = devices.selectedAudioDevice,
                           ViewFormatters.isElgatoDevice(selected) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        Text(devices.selectedAudioDevice?.localizedName ?? "None")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true),
                buttons: HStack(spacing: 6) {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh audio device list")

                    Button {
                        devices.audioPassthroughEnabled.toggle()
                    } label: {
                        Image(systemName: devices.audioPassthroughEnabled
                              ? "speaker.wave.2.fill" : "speaker.slash")
                            .foregroundStyle(devices.audioPassthroughEnabled ? .green : .secondary)
                    }
                    .help(devices.audioPassthroughEnabled ? "Disable audio passthrough" : "Play audio through speakers")
                    .disabled(!stats.hasAudio)

                    if stats.hasAudio {
                        AudioLevelBar(level: stats.audioPeakLevel, width: 60, height: 6)
                    }
                }
            )
        }
    }

    private func devicePickerRow(
        icon: String,
        picker: some View,
        buttons: some View
    ) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(.secondary)
                picker
                    .labelsHidden()
            }
            .frame(width: 280, alignment: .leading)

            buttons
        }
    }
}
