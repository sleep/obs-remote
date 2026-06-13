import SwiftUI

/// Disclosed "Replay Buffer" panel: duration presets grid, custom-duration input, RAM
/// cap picker, and (during capture) a live buffer-status line. Observes
/// ReplayBufferVM (the settings + buffer numbers) and RecordingVM (only to know
/// whether to show the live status row). Size/RAM-cap math is injected so this view
/// doesn't need a reference to CaptureViewModel.
struct ReplaySettingsPanel: View {
    @ObservedObject var replay: ReplayBufferVM
    @ObservedObject var recording: RecordingVM
    let replayPresets: [Double]
    let ramPresets: [(label: String, bytes: Int)]
    let estimatedSizeLabel: (Double) -> String
    let maxDurationForRAMCap: () -> Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replay Buffer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            // Duration presets grid
            HStack(spacing: 6) {
                ForEach(replayPresets, id: \.self) { seconds in
                    let isSelected = replay.replayDuration == seconds
                    let ramCap = maxDurationForRAMCap()
                    let exceedsRAM = ramCap != nil && seconds > ramCap!

                    Button {
                        replay.replayDuration = seconds
                    } label: {
                        VStack(spacing: 2) {
                            Text(ViewFormatters.formatDuration(seconds))
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                            Text(estimatedSizeLabel(seconds))
                                .font(.system(size: 9))
                                .foregroundStyle(exceedsRAM ? .red : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(
                            isSelected ? Color.accentColor.opacity(0.2) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Custom duration + RAM limit row
            HStack(spacing: 16) {
                // Custom duration
                HStack(spacing: 6) {
                    Text("Custom:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("sec", text: $replay.customReplayDuration)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if let val = Double(replay.customReplayDuration), val > 0 {
                                replay.replayDuration = val
                            }
                        }
                    if let val = Double(replay.customReplayDuration), val > 0 {
                        Text(estimatedSizeLabel(val))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // RAM limit
                HStack(spacing: 6) {
                    Text("RAM cap:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $replay.maxReplayRAM) {
                        ForEach(ramPresets, id: \.bytes) { preset in
                            Text(preset.label).tag(preset.bytes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }

            // Current buffer status
            if recording.isCapturing {
                HStack(spacing: 12) {
                    Text("Buffer: \(String(format: "%.0fs", replay.bufferDuration)) / \(ViewFormatters.formatDuration(replay.replayDuration))")
                    Text("\(replay.bufferSizeMB) MB used")
                    if let ramCap = maxDurationForRAMCap() {
                        Text("RAM cap limits to \(ViewFormatters.formatDuration(ramCap))")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
