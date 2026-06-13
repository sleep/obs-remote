import SwiftUI

/// The three action buttons shown while capturing: record/stop, screenshot, and the
/// composite save-replay button (with its settings disclosure chevron). Observes
/// RecordingVM (for isRecording / duration) and ReplayBufferVM (for feedback states
/// and the replay duration label). Actions and size-estimation are injected.
struct RecordControlsView: View {
    @ObservedObject var recording: RecordingVM
    @ObservedObject var replay: ReplayBufferVM
    @Binding var showReplaySettings: Bool
    let onToggleRecording: () -> Void
    let onScreenshot: () -> Void
    let onSaveReplay: () -> Void
    let estimatedSizeLabel: (Double) -> String

    var body: some View {
        HStack(spacing: 8) {
            RecordButton(recording: recording, onToggle: onToggleRecording)
            ScreenshotButton(replay: replay, onScreenshot: onScreenshot)
            ReplayButton(
                replay: replay,
                showReplaySettings: $showReplaySettings,
                onSaveReplay: onSaveReplay,
                estimatedSizeLabel: estimatedSizeLabel
            )
        }
    }
}

// MARK: - Shared ButtonStyles

/// Card-shaped capture control button: rounded background that flips between
/// a neutral resting fill and a tinted active fill, with system-standard press
/// feedback (subtle opacity + scale dip). Used by Record and Screenshot.
private struct CaptureCardButtonStyle: ButtonStyle {
    var tint: Color
    var isActive: Bool
    var width: CGFloat = 72
    var height: CGFloat = 60
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
            .frame(width: width, height: height)
            .padding(6)
            .background(
                isActive
                    ? AnyShapeStyle(tint.opacity(0.12))
                    : AnyShapeStyle(.quaternary.opacity(0.5)),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Press feedback only (no background) — for buttons that live inside a shared
/// container (e.g. the Save / chevron pair inside ReplayButton).
private struct CapturePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Buttons

/// Record/stop button. Observes only RecordingVM.
private struct RecordButton: View {
    @ObservedObject var recording: RecordingVM
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 3) {
                if recording.isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .stroke(.red.opacity(0.4), lineWidth: 3)
                        )
                    Text(ViewFormatters.formatRecordingDuration(recording.recordingDuration))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text("Stop")
                        .font(.system(size: 9, weight: .medium))
                } else {
                    Image(systemName: "record.circle")
                        .font(.system(size: 20))
                    Text("Record")
                        .font(.system(size: 11, weight: .medium))
                    Text("R")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(CaptureCardButtonStyle(tint: .red, isActive: recording.isRecording))
    }
}

/// Screenshot button. Observes only ReplayBufferVM (for screenshotFeedback).
private struct ScreenshotButton: View {
    @ObservedObject var replay: ReplayBufferVM
    let onScreenshot: () -> Void

    private var isSuccess: Bool { replay.screenshotFeedback == .success }

    var body: some View {
        Button(action: onScreenshot) {
            VStack(spacing: 3) {
                if isSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                    Text("Saved!")
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20))
                    Text("Screenshot")
                        .font(.system(size: 11, weight: .medium))
                }
                Text("S")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(CaptureCardButtonStyle(tint: .green, isActive: isSuccess))
        .disabled(replay.screenshotFeedback == .inProgress)
    }
}

/// Save-replay button + settings disclosure chevron. Observes only ReplayBufferVM.
private struct ReplayButton: View {
    @ObservedObject var replay: ReplayBufferVM
    @Binding var showReplaySettings: Bool
    let onSaveReplay: () -> Void
    let estimatedSizeLabel: (Double) -> String

    private var isSuccess: Bool { replay.replaySaveFeedback == .success }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSaveReplay) {
                VStack(spacing: 2) {
                    if replay.replaySaveFeedback == .success {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.green)
                        Text("Saved!")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    } else if replay.replaySaveFeedback == .failed {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.red)
                        Text("Failed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                    } else if replay.replaySaveFeedback == .inProgress {
                        ProgressView()
                            .controlSize(.small)
                            .frame(height: 20)
                        Text("Saving...")
                            .font(.system(size: 11, weight: .medium))
                    } else {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.system(size: 20))
                        Text("Save Replay")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text("\(ViewFormatters.formatDuration(replay.replayDuration))  \(estimatedSizeLabel(replay.replayDuration))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Space")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.green)
                .frame(width: 90, height: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(CapturePressButtonStyle())
            .disabled(replay.replaySaveFeedback == .inProgress)

            Divider()
                .frame(height: 36)
                .padding(.horizontal, 1)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showReplaySettings.toggle()
                }
            } label: {
                Image(systemName: showReplaySettings ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 60)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CapturePressButtonStyle())
            .help("Replay buffer settings")
        }
        .padding(6)
        .background(
            isSuccess
                ? AnyShapeStyle(Color.green.opacity(0.12))
                : AnyShapeStyle(.quaternary.opacity(0.5)),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
