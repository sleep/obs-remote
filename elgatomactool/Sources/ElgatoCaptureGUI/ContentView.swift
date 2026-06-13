import SwiftUI
import AVFoundation
import CaptureCore

struct ContentView: View {
    @EnvironmentObject var vm: CaptureViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var remote: RemoteController

    var body: some View {
        // Wave 2: ContentBody composes a tree of small region views. Each region
        // observes only the sub-VM(s) it actually reads, so SwiftUI's diff engine
        // can skip regions whose inputs didn't change.
        ContentBody(
            vm: vm,
            settings: settings,
            stats: vm.stats,
            devices: vm.devices,
            replay: vm.replay,
            recording: vm.recording,
            remote: remote,
            toast: vm.toast
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
    @ObservedObject var remote: RemoteController
    @ObservedObject var toast: ToastVM
    @State private var showReplaySettings = false
    @State private var showRemote = false
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
        .sheet(isPresented: $showRemote) {
            RemotePanelView(remote: remote)
                .environmentObject(settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRemoteSheet)) { _ in
            showRemote = true
        }
        .onAppear {
            vm.refreshDevices()
        }
    }

    // MARK: - Fullscreen

    private var fullscreenView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CaptureVideoView(engine: vm.engine, recording: recording, devices: devices, settings: settings)
                .onTapGesture(count: 2) { toggleFullscreen() }

            // Recording indicator in fullscreen
            if recording.isRecording {
                VStack {
                    HStack {
                        Spacer()
                        RecordingIndicatorView(recording: recording)
                            .padding(12)
                    }
                    Spacer()
                }
            }

            // Save toast — bottom trailing
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    SaveToastView(toast: toast)
                        .padding(16)
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

                CaptureVideoView(engine: vm.engine, recording: recording, devices: devices, settings: settings)
                    .onTapGesture(count: 2) { toggleFullscreen() }

                // Preview badge
                if recording.isPreviewing && !recording.isCapturing {
                    VStack {
                        HStack {
                            PreviewBadgeView(stats: stats)
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
                            RecordingIndicatorView(recording: recording)
                                .padding(12)
                        }
                        Spacer()
                    }
                }

                // Stats overlay
                if recording.isCapturing {
                    StatsOverlayView(stats: stats, replay: replay, settings: settings)
                } else if stats.hasAudio && recording.isPreviewing && settings.overlayStats.contains(.audio) {
                    // Show audio graph during preview when audio device is active
                    PreviewAudioOverlayView(stats: stats)
                }

                // Disconnect overlay — shown on top of the frozen video/buffer
                if devices.deviceDisconnected {
                    DisconnectOverlayView()
                }

                // Save toast — bottom trailing of the preview area
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        SaveToastView(toast: toast)
                            .padding(12)
                    }
                }
            }
            .clipped()

            Divider()

            // Controls
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    // Left: device selectors
                    DeviceSelectorView(
                        devices: devices,
                        stats: stats,
                        isCapturing: recording.isCapturing,
                        remoteIsRunning: remote.isRunning,
                        onRefresh: { vm.refreshDevices() },
                        onOpenSettings: { openSettings() },
                        onOpenRemote: { showRemote = true },
                        onOpenOutputFolder: { vm.openOutputFolder() },
                        onStopCapture: { vm.stopCapture() }
                    )

                    if recording.isCapturing && !replay.replayThumbnails.isEmpty {
                        ReplayThumbnailStrip(replay: replay)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Spacer()
                    }

                    // Right: action buttons or Start Capture
                    if recording.isCapturing {
                        RecordControlsView(
                            recording: recording,
                            replay: replay,
                            showReplaySettings: $showReplaySettings,
                            onToggleRecording: { vm.toggleRecording() },
                            onScreenshot: { vm.takeScreenshot() },
                            onSaveReplay: { vm.saveReplay() },
                            estimatedSizeLabel: { vm.estimatedSizeLabel(forSeconds: $0) }
                        )
                    } else {
                        Button("Start Capture") {
                            vm.startCapture()
                        }
                        .disabled(devices.selectedDevice == nil)
                        .tint(.green)
                    }
                }

                if recording.isCapturing && showReplaySettings {
                    ReplaySettingsPanel(
                        replay: replay,
                        recording: recording,
                        replayPresets: CaptureViewModel.replayPresets,
                        ramPresets: CaptureViewModel.ramPresets,
                        estimatedSizeLabel: { vm.estimatedSizeLabel(forSeconds: $0) },
                        maxDurationForRAMCap: { vm.maxDurationForRAMCap() }
                    )
                }

                StatusMessageBanner(recording: recording)
            }
            .padding(16)
        }
    }

    private func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func toggleFullscreen() {
        guard let window = NSApp.keyWindow else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isFullscreen.toggle()
        }
        window.toggleFullScreen(nil)
    }
}
