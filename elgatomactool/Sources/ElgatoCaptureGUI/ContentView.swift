import SwiftUI
import AVFoundation
import CaptureCore

struct ContentView: View {
    @StateObject private var vm = CaptureViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Preview area
            ZStack {
                if vm.isCapturing {
                    CapturePreviewView(session: vm.engine.captureSession)
                        .aspectRatio(16/9, contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(.black)
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay {
                            VStack(spacing: 12) {
                                Image(systemName: "video.slash")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                                Text(vm.availableDevices.isEmpty
                                     ? "No capture devices found"
                                     : "Select a device and press Start")
                                    .foregroundStyle(.secondary)
                            }
                        }
                }

                // Recording indicator
                if vm.isRecording {
                    VStack {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 10, height: 10)
                                Text("REC")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                            .padding(12)
                        }
                        Spacer()
                    }
                }

                // Buffer stats overlay
                if vm.isCapturing {
                    VStack {
                        Spacer()
                        HStack {
                            HStack(spacing: 12) {
                                Text("BUF \(String(format: "%.0fs", vm.bufferDuration))")
                                Text("\(vm.bufferSizeMB)MB")
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                            Spacer()
                        }
                    }
                }
            }
            .clipped()

            Divider()

            // Controls
            VStack(spacing: 16) {
                // Device selector
                deviceSelector

                // Action buttons
                if vm.isCapturing {
                    captureControls
                }

                // Error / status
                if let error = vm.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                } else if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            vm.refreshDevices()
        }
    }

    // MARK: - Device selector

    private var deviceSelector: some View {
        HStack(spacing: 12) {
            Picker("Device", selection: $vm.selectedDevice) {
                if vm.availableDevices.isEmpty {
                    Text("No devices").tag(nil as AVCaptureDevice?)
                }
                ForEach(vm.availableDevices, id: \.uniqueID) { device in
                    HStack {
                        if isElgatoDevice(device) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        Text(device.localizedName)
                    }
                    .tag(device as AVCaptureDevice?)
                }
            }
            .labelsHidden()

            Button {
                vm.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh device list")

            Spacer()

            if vm.isCapturing {
                Button("Stop") {
                    vm.stopCapture()
                }
                .tint(.red)
            } else {
                Button("Start Capture") {
                    vm.startCapture()
                }
                .disabled(vm.selectedDevice == nil)
                .tint(.green)
            }
        }
    }

    // MARK: - Capture controls

    private var captureControls: some View {
        HStack(spacing: 12) {
            // Record
            ControlButton(
                title: vm.isRecording ? "Stop Rec" : "Record",
                icon: vm.isRecording ? "stop.circle.fill" : "record.circle",
                color: vm.isRecording ? .red : .primary,
                shortcut: "R"
            ) {
                vm.toggleRecording()
            }

            // Screenshot
            ControlButton(
                title: "Screenshot",
                icon: "camera.fill",
                color: .primary,
                shortcut: "S"
            ) {
                vm.takeScreenshot()
            }

            // Save Replay
            ControlButton(
                title: "Save Replay",
                icon: "arrow.counterclockwise.circle.fill",
                color: .green,
                shortcut: "Space"
            ) {
                vm.saveReplay()
            }

            Spacer()

            // Output folder
            Button {
                vm.openOutputFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open output folder")
        }
    }

    private func isElgatoDevice(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        let keywords = ["elgato", "cam link", "hd60", "4k60", "game capture"]
        return keywords.contains(where: { name.contains($0) })
    }
}

// MARK: - Control Button

struct ControlButton: View {
    let title: String
    let icon: String
    let color: Color
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(shortcut)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(color)
            .frame(width: 80, height: 60)
        }
        .buttonStyle(.plain)
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
