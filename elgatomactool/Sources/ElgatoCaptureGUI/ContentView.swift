import SwiftUI
import AVFoundation
import CaptureCore

struct ContentView: View {
    @EnvironmentObject var vm: CaptureViewModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        // ContentView reads from every sub-VM today — Wave 2 will decompose this
        // into smaller observers. For now we still re-render the whole tree on
        // any sub-VM change, but the parent CaptureViewModel itself no longer
        // emits objectWillChange on every 1Hz tick.
        ContentBody(
            vm: vm,
            settings: settings,
            stats: vm.stats,
            devices: vm.devices,
            replay: vm.replay,
            recording: vm.recording
        )
    }
}

private struct ContentBody: View {
    let vm: CaptureViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var stats: StatsVM
    @ObservedObject var devices: DeviceVM
    @ObservedObject var replay: ReplayBufferVM
    @ObservedObject var recording: RecordingVM
    @State private var showReplaySettings = false
    @State private var showSettings = false
    @State private var isFullscreen = false

    var body: some View {
        ZStack {
            if isFullscreen {
                fullscreenView
            } else {
                normalView
            }
        }
        .frame(minWidth: isFullscreen ? nil : 640, minHeight: isFullscreen ? nil : 480)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsSheet)) { _ in
            showSettings = true
        }
        .onAppear {
            vm.refreshDevices()
        }
    }

    // MARK: - Fullscreen

    private var fullscreenView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            videoView
                .onTapGesture(count: 2) { toggleFullscreen() }

            // Recording indicator in fullscreen
            if recording.isRecording {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 10, height: 10)
                            Text("REC")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                            Text(formatRecordingDuration(recording.recordingDuration))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .onExitCommand { toggleFullscreen() }
    }

    // MARK: - Normal view

    private var normalView: some View {
        VStack(spacing: 0) {
            // Preview area
            ZStack {
                // Background pattern — visible in letterbox/pillarbox bars
                Color(white: 0.06)
                // WatermarkView()

                videoView
                    .onTapGesture(count: 2) { toggleFullscreen() }

                // Preview badge
                if recording.isPreviewing && !recording.isCapturing {
                    VStack {
                        HStack {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 8, height: 8)
                                Text("PREVIEW")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white)
                                if !stats.captureResolution.isEmpty {
                                    Text(stats.captureResolution)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.blue.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // Recording indicator
                if recording.isRecording {
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
                                Text(formatRecordingDuration(recording.recordingDuration))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                            .padding(12)
                        }
                        Spacer()
                    }
                }

                // Stats overlay
                if recording.isCapturing {
                    statsOverlay
                } else if stats.hasAudio && recording.isPreviewing && showStat(.audio) {
                    // Show audio graph during preview when audio device is active
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            AudioGraphView(
                                level: stats.audioLevel,
                                peak: stats.audioPeakLevel,
                                history: stats.audioHistory
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                        }
                    }
                }

                // Disconnect overlay — shown on top of the frozen video/buffer
                if devices.deviceDisconnected {
                    Rectangle()
                        .fill(.black.opacity(0.6))
                    VStack(spacing: 12) {
                        Image(systemName: "cable.connector.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.yellow)
                        Text("Device disconnected")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text("Buffer preserved — you can still save replays")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .clipped()

            Divider()

            // Controls
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    // Left: device selectors
                    deviceSelector

                    if recording.isCapturing && !replay.replayThumbnails.isEmpty {
                        replayThumbnailStrip
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Spacer()
                    }

                    // Right: action buttons or Start Capture
                    if recording.isCapturing {
                        actionButtons
                    } else {
                        Button("Start Capture") {
                            vm.startCapture()
                        }
                        .disabled(devices.selectedDevice == nil)
                        .tint(.green)
                    }
                }

                if recording.isCapturing && showReplaySettings {
                    replaySettings
                }

                if let error = recording.errorMessage {
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
                } else if !recording.statusMessage.isEmpty {
                    Text(recording.statusMessage)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Shared video view

    @ViewBuilder
    private var videoView: some View {
        if recording.isCapturing {
            PixelBufferDisplayView(engine: vm.engine)
                .aspectRatio(16/9, contentMode: .fit)
        } else if recording.isPreviewing {
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
                        Text(devices.availableDevices.isEmpty
                             ? "No capture devices found"
                             : "Select a device to preview")
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }

    // MARK: - Stats overlay

    private func showStat(_ stat: AppSettings.OverlayStat) -> Bool {
        settings.overlayStats.contains(stat)
    }

    private var statsOverlay: some View {
        VStack {
            Spacer()

            // Audio graph (above the bottom stats bar)
            if stats.hasAudio && showStat(.audio) {
                HStack {
                    Spacer()
                    AudioGraphView(
                        level: stats.audioLevel,
                        peak: stats.audioPeakLevel,
                        history: stats.audioHistory
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 8)
                }
            }

            HStack(alignment: .bottom) {
                let hasLeftStats = showStat(.resolution) || showStat(.fps) || showStat(.buffer) || showStat(.bitrate)
                if hasLeftStats {
                    HStack(spacing: 10) {
                        if showStat(.resolution), !stats.captureResolution.isEmpty {
                            Text(stats.captureResolution)
                        }
                        if showStat(.fps) {
                            HStack(spacing: 4) {
                                Text(String(format: "%.1ffps", stats.liveFPS))
                                    .foregroundStyle(stats.liveFPS >= 55 ? .white.opacity(0.8) :
                                                     stats.liveFPS >= 30 ? .yellow : .red)
                                MiniSparkline(
                                    data: stats.fpsHistory,
                                    color: stats.liveFPS >= 55 ? .green : stats.liveFPS >= 30 ? .yellow : .red,
                                    fixedMin: 0,
                                    fixedMax: max(stats.fpsHistory.max() ?? 60, 60)
                                )
                                if stats.droppedFrames > 0 {
                                    Text("\(stats.droppedFrames)drop")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        if showStat(.buffer) {
                            Text("BUF \(String(format: "%.0fs", replay.bufferDuration))")
                            Text("\(replay.bufferSizeMB)MB")
                        }
                        if showStat(.bitrate) {
                            Text(String(format: "%.1fMbps", stats.liveBitrateMbps))
                        }
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }

                Spacer()

                let hasRightStats = showStat(.cpu) || showStat(.gpu) || showStat(.ram) || showStat(.disk)
                if hasRightStats {
                    HStack(spacing: 10) {
                        if showStat(.cpu) {
                            StatWithSparkline(
                                label: "CPU",
                                value: String(format: "%.0f%%", stats.cpuPercent),
                                data: stats.cpuHistory,
                                color: .cyan,
                                fixedMin: 0
                            )
                        }
                        if showStat(.gpu) {
                            StatWithSparkline(
                                label: "GPU",
                                value: String(format: "%.0f%%", stats.gpuPercent),
                                data: stats.gpuHistory,
                                color: .purple,
                                fixedMin: 0
                            )
                        }
                        if showStat(.ram) {
                            StatWithSparkline(
                                label: "RAM",
                                value: formatRAM(stats.ramMB),
                                data: stats.ramHistory,
                                color: .green
                            )
                        }
                        if showStat(.disk) {
                            StatWithSparkline(
                                label: "DSK",
                                value: String(format: "%.0fG", stats.diskFreeGB),
                                data: stats.diskHistory,
                                color: .orange
                            )
                        }
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }
            }
        }
    }

    private func toggleFullscreen() {
        guard let window = NSApp.keyWindow else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isFullscreen.toggle()
        }
        window.toggleFullScreen(nil)
    }

    // MARK: - Device selector

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

    private var deviceSelector: some View {
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
                            if isElgatoDevice(device) {
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
                        vm.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh device list")

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Preferences")

                    Button {
                        vm.openOutputFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Open output folder")

                    if recording.isCapturing {
                        Button {
                            vm.stopCapture()
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
                            if isElgatoDevice(device) {
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
                        vm.refreshDevices()
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

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            recordButton
            screenshotButton
            replayButton
        }
    }

    private var recordButton: some View {
        Button {
            vm.toggleRecording()
        } label: {
            VStack(spacing: 3) {
                if recording.isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .stroke(.red.opacity(0.4), lineWidth: 3)
                        )
                    Text(formatRecordingDuration(recording.recordingDuration))
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
            .foregroundStyle(recording.isRecording ? .red : .primary)
            .frame(width: 72, height: 60)
            .padding(6)
            .background(
                recording.isRecording
                    ? AnyShapeStyle(.red.opacity(0.12))
                    : AnyShapeStyle(.quaternary.opacity(0.5)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var screenshotButton: some View {
        Button {
            vm.takeScreenshot()
        } label: {
            VStack(spacing: 3) {
                if replay.screenshotFeedback == .success {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                    Text("Saved!")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
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
            .foregroundStyle(replay.screenshotFeedback == .success ? .green : .primary)
            .frame(width: 72, height: 60)
            .padding(6)
            .background(
                replay.screenshotFeedback == .success
                    ? AnyShapeStyle(.green.opacity(0.12))
                    : AnyShapeStyle(.quaternary.opacity(0.5)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(replay.screenshotFeedback == .inProgress)
    }

    private var replayButton: some View {
        HStack(spacing: 0) {
            Button {
                vm.saveReplay()
            } label: {
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
                    Text("\(formatDuration(replay.replayDuration))  \(vm.estimatedSizeLabel(forSeconds: replay.replayDuration))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Space")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.green)
                .frame(width: 90, height: 60)
            }
            .buttonStyle(.plain)
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
            .buttonStyle(.plain)
            .help("Replay buffer settings")
        }
        .padding(6)
        .background(
            replay.replaySaveFeedback == .success
                ? AnyShapeStyle(.green.opacity(0.12))
                : AnyShapeStyle(.quaternary.opacity(0.5)),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    // MARK: - Replay settings

    private var replaySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replay Buffer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            // Duration presets grid
            HStack(spacing: 6) {
                ForEach(CaptureViewModel.replayPresets, id: \.self) { seconds in
                    let isSelected = replay.replayDuration == seconds
                    let ramCap = vm.maxDurationForRAMCap()
                    let exceedsRAM = ramCap != nil && seconds > ramCap!

                    Button {
                        replay.replayDuration = seconds
                    } label: {
                        VStack(spacing: 2) {
                            Text(formatDuration(seconds))
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                            Text(vm.estimatedSizeLabel(forSeconds: seconds))
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
                        Text(vm.estimatedSizeLabel(forSeconds: val))
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
                        ForEach(CaptureViewModel.ramPresets, id: \.bytes) { preset in
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
                    Text("Buffer: \(String(format: "%.0fs", replay.bufferDuration)) / \(formatDuration(replay.replayDuration))")
                    Text("\(replay.bufferSizeMB) MB used")
                    if let ramCap = vm.maxDurationForRAMCap() {
                        Text("RAM cap limits to \(formatDuration(ramCap))")
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

    private func formatDuration(_ seconds: Double) -> String {
        if seconds >= 60 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return secs > 0 ? "\(mins)m\(secs)s" : "\(mins)m"
        }
        return "\(Int(seconds))s"
    }

    private func formatRAM(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1fG", mb / 1024)
        }
        return String(format: "%.0fM", mb)
    }

    private func formatRecordingDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func isElgatoDevice(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        let keywords = ["elgato", "cam link", "hd60", "4k60", "game capture"]
        return keywords.contains(where: { name.contains($0) })
    }

    // MARK: - Replay thumbnail strip

    private var replayThumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(replay.replayThumbnails) { thumb in
                        VStack(spacing: 2) {
                            Image(nsImage: thumb.image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 80, height: 45)
                                .clipped()
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                                )
                            Text(thumbnailAgeLabel(thumb.capturedAt))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .id(thumb.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .frame(height: 68)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: replay.replayThumbnails.count) { _ in
                if let last = replay.replayThumbnails.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(last.id, anchor: .trailing)
                    }
                }
            }
        }
    }

    private func thumbnailAgeLabel(_ date: Date) -> String {
        let age = Int(Date().timeIntervalSince(date))
        if age < 60 { return "-\(age)s" }
        return "-\(age / 60)m\(age % 60)s"
    }
}
