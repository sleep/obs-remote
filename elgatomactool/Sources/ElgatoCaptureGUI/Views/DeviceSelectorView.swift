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
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onOpenOutputFolder: () -> Void
    let onStopCapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Video device row
            devicePickerRow(
                icon: "video.fill",
                picker: Picker("Device", selection: $devices.selectedDevice) {
                    if devices.availableDevices.isEmpty {
                        Text("No devices").tag(nil as AVCaptureDevice?)
                    }
                    ForEach(devices.availableDevices, id: \.uniqueID) { device in
                        HStack {
                            if ViewFormatters.isElgatoDevice(device) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                            Text(device.localizedName)
                        }
                        .tag(device as AVCaptureDevice?)
                    }
                },
                buttons: HStack(spacing: 6) {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh device list")

                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Preferences")

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
                picker: Picker("Audio", selection: $devices.selectedAudioDevice) {
                    Text("None").tag(nil as AVCaptureDevice?)
                    ForEach(devices.availableAudioDevices, id: \.uniqueID) { device in
                        HStack {
                            if ViewFormatters.isElgatoDevice(device) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                            Text(device.localizedName)
                        }
                        .tag(device as AVCaptureDevice?)
                    }
                },
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
