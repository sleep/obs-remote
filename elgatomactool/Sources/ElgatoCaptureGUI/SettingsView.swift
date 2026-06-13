import SwiftUI
import CaptureCore

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            settingsContent
        }
        .frame(width: 460, height: 720)
    }

    private var settingsContent: some View {
        VStack(spacing: 20) {
            // General
            GroupBox("General") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Start minimized (window hidden)", isOn: $settings.startMinimized)
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

            // Overlay Stats
            GroupBox("Overlay Stats") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show on the video preview:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let columns = [GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(AppSettings.OverlayStat.allCases) { stat in
                            Toggle(stat.label, isOn: overlayStatBinding(for: stat))
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
                        Text("Quality:")
                            .foregroundStyle(.secondary)
                        Picker("", selection: $settings.captureCodec) {
                            ForEach(CaptureCodec.allCases) { codec in
                                Text(codec.displayName).tag(codec)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }

                    if settings.captureCodec == .h264 {
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
                    } else {
                        // Lossless mode — explain the tradeoffs so file sizes
                        // aren't a surprise (≈ 442 Mbps at 1080p60, ~55 MB/sec).
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Lossless 4:2:2 capture — writes .mov files for NLE compatibility.")
                                    .font(.caption)
                                Text("Expect ~55 MB/sec at 1080p60. Replay buffer will use the RAM cap aggressively.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Visual Effects (master toggle + adjustments)
            GroupBox("Adjustments") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Apply visual effects", isOn: $settings.visualEffectsEnabled)
                        .toggleStyle(.switch)
                    Text(settings.visualEffectsEnabled
                         ? "Baked into recordings, replays, and screenshots. Adds a Core Image render per frame."
                         : "Off — capture pipeline runs on the raw camera buffer (no per-frame cost).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider().padding(.vertical, 2)

                    adjustmentSlider(
                        label: "Brightness",
                        value: $settings.previewBrightness,
                        range: -0.5...0.5,
                        defaultValue: 0,
                        format: signedPercent
                    )
                    adjustmentSlider(
                        label: "Contrast",
                        value: $settings.previewContrast,
                        range: 0.5...1.8,
                        defaultValue: 1,
                        format: multiplier
                    )
                    adjustmentSlider(
                        label: "Saturation",
                        value: $settings.previewSaturation,
                        range: 0...2,
                        defaultValue: 1,
                        format: multiplier
                    )
                    adjustmentSlider(
                        label: "Hue",
                        value: $settings.previewHueDegrees,
                        range: -180...180,
                        defaultValue: 0,
                        format: degrees
                    )

                    HStack {
                        Spacer()
                        Button("Reset Adjustments") {
                            settings.resetPreviewAdjustments()
                        }
                        .disabled(settings.previewAdjustments.isNeutral)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Filters
            GroupBox("Filters") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Layered on top of adjustments. Disabled by the master toggle above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let columns = [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ]
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(VideoFilter.allCases) { filter in
                            FilterChip(
                                filter: filter,
                                isSelected: settings.previewFilter == filter
                            ) {
                                settings.previewFilter = filter
                            }
                        }
                    }
                    .opacity(settings.visualEffectsEnabled ? 1 : 0.45)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Adjustment slider row

    private func adjustmentSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
                .onTapGesture(count: 2) {
                    value.wrappedValue = defaultValue
                }
            Text(format(value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var signedPercent: (Double) -> String {
        { String(format: "%+.0f%%", $0 * 100) }
    }
    private var multiplier: (Double) -> String {
        { String(format: "%.2f×", $0) }
    }
    private var degrees: (Double) -> String {
        { String(format: "%.0f°", $0) }
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

    private func overlayStatBinding(for stat: AppSettings.OverlayStat) -> Binding<Bool> {
        Binding(
            get: { settings.overlayStats.contains(stat) },
            set: { enabled in
                if enabled {
                    settings.overlayStats.insert(stat)
                } else {
                    settings.overlayStats.remove(stat)
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

// MARK: - Filter chip

private struct FilterChip: View {
    let filter: VideoFilter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(swatchGradient)
                        .frame(height: 36)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                    }
                }
                Text(filter.label)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var swatchGradient: LinearGradient {
        let base = filter.swatchColor
        return LinearGradient(
            colors: [base.opacity(0.65), base],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
