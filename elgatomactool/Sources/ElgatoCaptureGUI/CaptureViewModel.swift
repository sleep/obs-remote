import SwiftUI
import AVFoundation
import CoreImage
import CoreMedia
import CaptureCore
import Combine

enum ActionFeedback: Equatable {
    case idle, inProgress, success, failed
}

struct ReplayThumbnail: Identifiable {
    let id = UUID()
    let image: NSImage
    let capturedAt: Date
}

/// Composition root for the capture UI. Owns the engine + sub-VMs and routes
/// timer ticks, engine callbacks, NotificationCenter events, and AppSettings
/// observation into the appropriate sub-VM. Itself has no @Published storage
/// — views observing only the slice they need (e.g. `vm.stats.liveFPS`) avoid
/// the 1Hz objectWillChange storm that came from the previous monolith.
@MainActor
final class CaptureViewModel: ObservableObject {

    // MARK: Sub-VMs
    let stats = StatsVM()
    let devices = DeviceVM()
    let replay = ReplayBufferVM()
    let recording = RecordingVM()
    let toast = ToastVM()

    // MARK: Engine + settings
    let engine: CaptureEngine
    private weak var settings: AppSettings?

    // MARK: Timers + Combine
    private var statusTimer: Timer?
    private var audioMeterTimer: Timer?
    private var thumbnailTimer: Timer?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var appNapActivity: NSObjectProtocol?

    // MARK: Reconnect state machine
    /// UniqueID of the video device we were capturing from before a disconnect.
    private var reconnectDeviceID: String?
    /// UniqueID of the audio device that was selected at disconnect time. Saved
    /// separately because the audio half of a USB capture device disconnects with
    /// its own uniqueID and may come back as a fresh AVCaptureDevice instance.
    /// Using a stale ref silently fails — the old bug where audio went mute after
    /// reconnect was caused by feeding a stale reference into AVCaptureDeviceInput.
    private var reconnectAudioDeviceID: String?
    /// True while attemptReconnect is in progress (waiting or retrying).
    private var isReconnecting = false
    /// Was the user actively capturing (vs preview-only) at disconnect time?
    /// Determines whether we restore to full capture or just to preview.
    private var wasCapturingAtDisconnect = false
    /// Consecutive seconds with 0 FPS while supposedly capturing — triggers reconnect.
    private var zeroFPSStreak: Int = 0
    private static let zeroFPSReconnectThreshold = 3

    /// Preset durations in seconds
    static let replayPresets: [Double] = [15, 30, 60, 90, 120, 180, 300, 600]

    /// RAM cap options in bytes (0 = unlimited)
    static let ramPresets: [(label: String, bytes: Int)] = [
        ("Unlimited", 0),
        ("256 MB", 256 * 1_048_576),
        ("512 MB", 512 * 1_048_576),
        ("1 GB", 1024 * 1_048_576),
        ("2 GB", 2048 * 1_048_576),
        ("4 GB", 4096 * 1_048_576),
    ]

    init(settings: AppSettings) {
        self.settings = settings

        // Seed sub-VM values from persisted settings BEFORE wiring didSet
        // callbacks so we don't fire feedback into a half-built engine.
        replay.replayDuration = settings.replayDuration
        replay.maxReplayRAM = settings.maxReplayRAM
        recording.bitrateMbps = settings.bitrateMbps
        recording.captureCodec = settings.captureCodec

        self.engine = CaptureEngine(replayDuration: settings.replayDuration,
                                    bitrateMbps: settings.bitrateMbps,
                                    codec: settings.captureCodec)
        engine.setOutputDirectory(settings.outputDirectory)

        installSubVMCallbacks()

        // Mirror codec changes made elsewhere (Preferences sheet) into the VM.
        settings.$captureCodec
            .receive(on: RunLoop.main)
            .sink { [weak self] newCodec in
                guard let self else { return }
                if self.recording.captureCodec != newCodec {
                    self.recording.captureCodec = newCodec
                }
            }
            .store(in: &settingsCancellables)

        engine.onStateChange = { [weak self] in
            Task { @MainActor in
                self?.syncState()
            }
        }

        engine.onRecordingFinished = { [weak self] url in
            guard let self, let url else { return }
            self.showSaveToast(for: url, kind: .recording)
        }

        settings.$outputDirectoryPath
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.engine.setOutputDirectory(settings.outputDirectory)
            }
            .store(in: &settingsCancellables)

        // Visual effects — collapse the master toggle, 4 sliders, and filter
        // picker into one downstream call so the engine swaps its filter chain
        // atomically. Fires on subscribe too, so the initial state is pushed
        // before the first frame arrives.
        Publishers.MergeMany(
            settings.$visualEffectsEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$previewBrightness.map { _ in () }.eraseToAnyPublisher(),
            settings.$previewContrast.map { _ in () }.eraseToAnyPublisher(),
            settings.$previewSaturation.map { _ in () }.eraseToAnyPublisher(),
            settings.$previewHueDegrees.map { _ in () }.eraseToAnyPublisher(),
            settings.$previewFilter.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            self?.pushVisualEffectsToEngine()
        }
        .store(in: &settingsCancellables)

        // Watch for USB device connect/disconnect
        NotificationCenter.default.publisher(for: .AVCaptureDeviceWasDisconnected)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleDeviceDisconnected(notification)
            }
            .store(in: &settingsCancellables)

        NotificationCenter.default.publisher(for: .AVCaptureDeviceWasConnected)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleDeviceConnected()
            }
            .store(in: &settingsCancellables)

        checkCameraAccess()
        refreshDevices()
    }

    // MARK: - Sub-VM callback wiring

    private func installSubVMCallbacks() {
        // Selected video device
        devices.selectedDeviceChanged = { [weak self] oldDevice, newDevice in
            guard let self else { return }
            guard newDevice?.uniqueID != oldDevice?.uniqueID else { return }
            if let settings = self.settings, settings.rememberLastDevice {
                settings.lastDeviceUniqueID = newDevice?.uniqueID
            }
            // Don't drive the engine if we're reconnecting capture
            guard self.reconnectDeviceID == nil, !self.isReconnecting else { return }
            // Hot-swap the live pipeline. startCapture/startPreview both pick up
            // the new selectedDevice and tear the previous session down via the
            // engine. Without this branch, switching the picker mid-capture is
            // silently a no-op (startPreview bails when isCapturing is true).
            if self.recording.isCapturing {
                self.startCapture()
            } else {
                self.startPreviewForSelectedDevice()
            }
        }

        // Selected audio device
        devices.selectedAudioDeviceChanged = { [weak self] oldDevice, newDevice in
            guard let self else { return }
            guard newDevice?.uniqueID != oldDevice?.uniqueID else { return }
            if let settings = self.settings, settings.rememberLastDevice {
                settings.lastAudioDeviceUniqueID = newDevice?.uniqueID
            }
            self.engine.setAudioInputDevice(newDevice)
            self.stats.hasAudio = self.engine.hasAudioInput
            self.stats.audioHistory = []
        }

        // Audio passthrough toggle
        devices.audioPassthroughChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.engine.startPassthrough()
            } else {
                self.engine.stopPassthrough()
            }
        }

        // Replay duration
        replay.replayDurationChanged = { [weak self] newValue in
            guard let self else { return }
            self.applyReplayLimits()
            self.settings?.replayDuration = newValue
            self.trimOldThumbnails()
        }

        // Replay RAM cap
        replay.maxReplayRAMChanged = { [weak self] newValue in
            guard let self else { return }
            self.applyReplayLimits()
            self.settings?.maxReplayRAM = newValue
        }

        // Bitrate
        recording.bitrateChanged = { [weak self] newValue in
            guard let self else { return }
            self.settings?.bitrateMbps = newValue
            self.engine.updateBitrate(mbps: newValue)
        }

        // Codec
        recording.captureCodecChanged = { [weak self] newCodec in
            guard let self else { return }
            self.settings?.captureCodec = newCodec
            // Engine swap is async because it may need to finalize an in-flight
            // recording before the codec change. Buffer was just (or is about
            // to be) cleared — also clear the thumbnail strip so the UI doesn't
            // keep stills around for content that no longer exists.
            self.replay.replayThumbnails = []
            Task { [engine = self.engine] in
                await engine.setCodec(newCodec)
                await MainActor.run { [weak self] in self?.syncState() }
            }
        }
    }

    // MARK: - Estimates

    /// Estimated file size in MB for a given duration. Uses the live measured
    /// bitrate when capture is running (most accurate), falls back to the
    /// codec's configured/expected bitrate otherwise.
    func estimatedSizeMB(forSeconds seconds: Double) -> Double {
        let mbps: Double
        if stats.liveBitrateMbps > 1.0 {
            mbps = stats.liveBitrateMbps
        } else if recording.captureCodec.isLossless {
            let (w, h, fps) = currentResolutionForEstimate()
            mbps = recording.captureCodec.estimatedMbps(width: w, height: h, fps: fps)
        } else {
            mbps = Double(recording.bitrateMbps)
        }
        return mbps * seconds / 8.0
    }

    /// Best-guess (width, height, fps) for pre-capture file-size estimates.
    /// Falls back to 1080p60 when no device info is available yet.
    private func currentResolutionForEstimate() -> (Int, Int, Double) {
        let parts = stats.captureResolution.split(separator: "x")
        if parts.count == 2,
           let w = Int(parts[0]), let h = Int(parts[1]) {
            return (w, h, stats.liveFPS > 0 ? stats.liveFPS : 60)
        }
        return (1920, 1080, 60)
    }

    /// Human-readable estimated size string.
    func estimatedSizeLabel(forSeconds seconds: Double) -> String {
        let mb = estimatedSizeMB(forSeconds: seconds)
        if mb >= 1024 {
            return String(format: "~%.1f GB", mb / 1024)
        }
        return String(format: "~%.0f MB", mb)
    }

    /// Maximum duration the chosen RAM cap allows at the current bitrate.
    func maxDurationForRAMCap() -> Double? {
        guard replay.maxReplayRAM > 0 else { return nil }
        let mbps: Double
        if stats.liveBitrateMbps > 1.0 {
            mbps = stats.liveBitrateMbps
        } else if recording.captureCodec.isLossless {
            let (w, h, fps) = currentResolutionForEstimate()
            mbps = recording.captureCodec.estimatedMbps(width: w, height: h, fps: fps)
        } else {
            mbps = Double(recording.bitrateMbps)
        }
        let bytesPerSecond = mbps * 1_000_000 / 8.0
        guard bytesPerSecond > 0 else { return nil }
        return Double(replay.maxReplayRAM) / bytesPerSecond
    }

    private func applyReplayLimits() {
        engine.updateReplayLimits(duration: replay.replayDuration, maxBytes: replay.maxReplayRAM)
    }

    /// Build the CIFilter chain from current settings (or pass empty when the
    /// master toggle is off / nothing's been changed) and hand it to the engine.
    private func pushVisualEffectsToEngine() {
        guard let settings else { return }
        let filters: [CIFilter] = settings.effectsActive
            ? VideoFilterChain.buildFilters(adjustments: settings.previewAdjustments,
                                            filter: settings.previewFilter)
            : []
        engine.setVisualEffectFilters(filters)
    }

    /// Try to reconnect to the last-used device and optionally start capture.
    func autoConnectLastDevice() {
        guard let settings, settings.rememberLastDevice,
              let savedID = settings.lastDeviceUniqueID else { return }

        refreshDevices()

        if let match = devices.availableDevices.first(where: { $0.uniqueID == savedID }) {
            devices.selectedDevice = match
            if settings.autoStartCapture {
                startCapture()
            }
        }
    }

    // MARK: - Camera permission

    func checkCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            devices.cameraAuthorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.devices.cameraAuthorized = granted
                    if granted {
                        self.refreshDevices()
                    } else {
                        self.recording.errorMessage = "Camera access denied. Grant access in System Settings > Privacy & Security > Camera."
                    }
                }
            }
        case .denied, .restricted:
            devices.cameraAuthorized = false
            recording.errorMessage = "Camera access denied. Grant access in System Settings > Privacy & Security > Camera."
        @unknown default:
            break
        }
    }

    // MARK: - Device management

    func refreshDevices() {
        devices.availableDevices = DeviceDiscovery.findCaptureDevices()
        devices.availableAudioDevices = DeviceDiscovery.findAudioDevices()

        // Don't change selection while waiting for a device to come back
        if reconnectDeviceID == nil,
           devices.selectedDevice == nil || !devices.availableDevices.contains(where: { $0.uniqueID == devices.selectedDevice?.uniqueID }) {
            devices.selectedDevice = autoSelectDevice()
        }

        // Auto-select audio device matching video device name if none selected
        if devices.selectedAudioDevice == nil || !devices.availableAudioDevices.contains(where: { $0.uniqueID == devices.selectedAudioDevice?.uniqueID }) {
            devices.selectedAudioDevice = autoSelectAudioDevice()
        }

        if devices.availableDevices.isEmpty {
            recording.statusMessage = "No capture devices found. Plug in your Elgato and refresh."
        }

        // Start preview if we have a device and aren't already capturing
        if devices.selectedDevice != nil && !recording.isCapturing && !recording.isPreviewing {
            startPreviewForSelectedDevice()
        }
    }

    private func autoSelectAudioDevice() -> AVCaptureDevice? {
        // Prefer the remembered audio device
        if let settings, settings.rememberLastDevice,
           let savedID = settings.lastAudioDeviceUniqueID,
           let match = devices.availableAudioDevices.first(where: { $0.uniqueID == savedID }) {
            return match
        }

        guard let videoDevice = devices.selectedDevice else { return nil }
        let videoName = videoDevice.localizedName.lowercased()

        // Exact name match
        if let match = devices.availableAudioDevices.first(where: {
            $0.localizedName == videoDevice.localizedName
        }) {
            return match
        }

        // Partial name match (e.g. "Cam Link 4K" in audio device name)
        return devices.availableAudioDevices.first(where: {
            let audioName = $0.localizedName.lowercased()
            return audioName.contains(videoName) || videoName.contains(audioName)
        })
    }

    /// Re-fetch a video device by uniqueID from a freshly enumerated discovery
    /// session. AVCaptureDevice references can go stale across an unplug/replug —
    /// even when the uniqueID survives, the underlying object may be invalidated,
    /// so always re-resolve before handing it to AVCaptureSession.
    private func freshVideoDevice(forID id: String) -> AVCaptureDevice? {
        DeviceDiscovery.findCaptureDevices().first(where: { $0.uniqueID == id })
    }

    /// Re-fetch an audio device by uniqueID. Same staleness problem as video,
    /// and the cause of the silent-after-reconnect bug.
    private func freshAudioDevice(forID id: String) -> AVCaptureDevice? {
        DeviceDiscovery.findAudioDevices().first(where: { $0.uniqueID == id })
    }

    /// Refresh `selectedAudioDevice` so it points at a freshly enumerated
    /// AVCaptureDevice instance. Returns the resolved device (or nil if it's
    /// not enumerable yet). Use before any call into `engine.setAudioInputDevice`
    /// to avoid feeding it a stale reference.
    @discardableResult
    private func refreshSelectedAudioDevice() -> AVCaptureDevice? {
        devices.availableAudioDevices = DeviceDiscovery.findAudioDevices()
        guard let id = devices.selectedAudioDevice?.uniqueID else { return nil }
        let fresh = devices.availableAudioDevices.first(where: { $0.uniqueID == id })
        if let fresh, fresh !== devices.selectedAudioDevice {
            devices.selectedAudioDevice = fresh
        }
        return fresh
    }

    private func autoSelectDevice() -> AVCaptureDevice? {
        let keywords = ["elgato", "cam link", "hd60", "4k60", "game capture"]
        if let match = devices.availableDevices.first(where: { device in
            let name = device.localizedName.lowercased()
            return keywords.contains(where: { name.contains($0) })
        }) {
            return match
        }
        return devices.availableDevices.first
    }

    // MARK: - Preview

    func startPreviewForSelectedDevice() {
        guard devices.cameraAuthorized, let device = devices.selectedDevice else { return }
        // Don't interrupt a running capture
        guard !recording.isCapturing else { return }

        do {
            try engine.startPreview(with: device)
            recording.isPreviewing = true
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            stats.captureResolution = "\(dims.width)x\(dims.height)"

            // Set up audio — always re-resolve by uniqueID against a fresh
            // discovery session to avoid stale AVCaptureDevice refs.
            if let audioDevice = refreshSelectedAudioDevice() {
                engine.setAudioInputDevice(audioDevice)
                stats.hasAudio = engine.hasAudioInput
                if stats.hasAudio { startAudioMeterTimer() }
            } else {
                stats.hasAudio = false
            }
        } catch {
            print("[GUI] Preview failed: \(error)")
            recording.isPreviewing = false
        }
    }

    func stopPreview() {
        engine.stopPreview()
        recording.isPreviewing = false
        stats.captureResolution = ""
        stats.hasAudio = false
        stopAudioMeterTimer()
    }

    // MARK: - Capture control

    func startCapture() {
        guard devices.cameraAuthorized else {
            recording.errorMessage = "Camera access not granted. Check System Settings > Privacy & Security > Camera."
            return
        }

        guard let device = devices.selectedDevice else {
            recording.errorMessage = "No device selected"
            return
        }

        recording.errorMessage = nil
        recording.statusMessage = "Starting capture..."

        do {
            try engine.start(with: device)
            recording.isCapturing = true
            recording.errorMessage = nil
            recording.statusMessage = "Capturing from \(device.localizedName)"

            // Read resolution from the device's active format
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            stats.captureResolution = "\(dims.width)x\(dims.height)"

            // Set up audio — refresh the device ref against a fresh discovery
            // session first so we don't pass a stale handle into the session.
            stopAudioMeterTimer()
            if let audioDevice = refreshSelectedAudioDevice() {
                engine.setAudioInputDevice(audioDevice)
                stats.hasAudio = engine.hasAudioInput
            } else {
                stats.hasAudio = false
            }

            startStatusTimer()
            startThumbnailTimer()
        } catch {
            recording.errorMessage = error.localizedDescription
            recording.isCapturing = false
            recording.statusMessage = ""
            print("[GUI] Start failed: \(error)")
        }
    }

    func stopCapture() {
        // Cancel any in-flight reconnect — without this, a pending retry would
        // fire after stop() and silently restart capture.
        reconnectDeviceID = nil
        reconnectAudioDeviceID = nil
        isReconnecting = false
        wasCapturingAtDisconnect = false

        engine.stop()
        recording.isCapturing = false
        devices.deviceDisconnected = false
        // engine.stop() falls back to preview mode automatically
        recording.isPreviewing = engine.isPreviewing
        stopStatusTimer()
        stopThumbnailTimer()
        replay.replayThumbnails = []
        recording.statusMessage = "Stopped"
        stats.liveFPS = 0
        stats.droppedFrames = 0
        stats.fpsHistory = []
        recording.recordingStartDate = nil
        recording.recordingDuration = 0
        stats.audioLevel = 0
        stats.audioPeakLevel = 0
        stats.audioHistory = []
        stats.hasAudio = false
        devices.audioPassthroughEnabled = false
        syncState()

        // Update resolution from the still-connected device
        if recording.isPreviewing, let device = devices.selectedDevice {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            stats.captureResolution = "\(dims.width)x\(dims.height)"
        } else {
            stats.captureResolution = ""
        }
    }

    // MARK: - Actions

    func toggleRecording() {
        let wasRecording = engine.recorder.isRecording
        if wasRecording {
            recording.statusMessage = "Stopping recording..."
        } else {
            recording.statusMessage = "Starting recording..."
        }
        Task.detached { [weak self] in
            self?.engine.toggleRecording()
            await MainActor.run {
                guard let self else { return }
                if wasRecording {
                    self.recording.recordingStartDate = nil
                    self.recording.recordingDuration = 0
                    self.recording.statusMessage = "Recording stopped"
                } else {
                    self.recording.recordingStartDate = Date()
                    self.recording.statusMessage = "Recording started"
                }
                self.syncState()
            }
        }
    }

    func takeScreenshot() {
        replay.screenshotFeedback = .inProgress
        recording.statusMessage = "Saving screenshot..."
        Task.detached { [weak self] in
            let url = self?.engine.takeScreenshot()
            await MainActor.run {
                guard let self else { return }
                self.replay.screenshotFeedback = .success
                self.recording.statusMessage = "Screenshot saved"
                self.clearScreenshotFeedbackAfterDelay()
                self.clearStatusAfterDelay()
                if let url {
                    self.showSaveToast(for: url, kind: .screenshot)
                }
            }
        }
    }

    func saveReplay() {
        replay.replaySaveFeedback = .inProgress
        recording.statusMessage = "Saving replay..."
        engine.saveReplay(lastSeconds: replay.replayDuration) { [weak self] url in
            guard let self else { return }
            let success = url != nil
            self.replay.replaySaveFeedback = success ? .success : .failed
            self.recording.statusMessage = success ? "Replay saved" : "Replay save failed"
            self.clearReplaySaveFeedbackAfterDelay()
            if let url {
                self.showSaveToast(for: url, kind: .replay)
            }
        }
    }

    /// Read the size of a just-saved file and present a save toast.
    private func showSaveToast(for url: URL, kind: SaveToast.Kind) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        toast.show(SaveToast(url: url, kind: kind, sizeBytes: size))
    }

    func openOutputFolder() {
        let url = engine.recorder.outputDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private func syncState() {
        recording.isRecording = engine.recorder.isRecording
        if let start = recording.recordingStartDate, recording.isRecording {
            recording.recordingDuration = Date().timeIntervalSince(start)
        }
        let bufStats = engine.replayBuffer.stats
        replay.bufferDuration = bufStats.duration
        replay.bufferFrameCount = bufStats.frameCount
        replay.bufferSizeMB = bufStats.bytes / 1_048_576
        stats.liveBitrateMbps = engine.liveBitrateMbps

        engine.sampleFPS()
        stats.liveFPS = engine.liveFPS
        stats.droppedFrames = engine.droppedFrames
        stats.fpsHistory.append(stats.liveFPS)
        if stats.fpsHistory.count > 60 { stats.fpsHistory.removeFirst(stats.fpsHistory.count - 60) }

        // Audio levels
        stats.hasAudio = engine.hasAudioInput
        if stats.hasAudio {
            let levels = engine.sampleAudioLevels()
            stats.audioLevel = Double(levels.rms)
            stats.audioPeakLevel = Double(levels.peak)
            // Store peak in dB for the history graph (clamped to -60…0)
            let peakDB = levels.peak > 0 ? max(20 * log10(levels.peak), -60) : -60
            stats.audioHistory.append(Double(peakDB))
            if stats.audioHistory.count > 120 { stats.audioHistory.removeFirst(stats.audioHistory.count - 120) }
        }

        checkForStall()

        stats.systemStats.sample()
        stats.cpuPercent = stats.systemStats.latestCPU
        stats.ramMB = stats.systemStats.latestRAM
        stats.diskFreeGB = stats.systemStats.latestDisk
        stats.gpuPercent = stats.systemStats.latestGPU
        stats.cpuHistory = stats.systemStats.cpuHistory
        stats.ramHistory = stats.systemStats.ramHistory
        stats.diskHistory = stats.systemStats.diskHistory
        stats.gpuHistory = stats.systemStats.gpuHistory
    }

    private func startStatusTimer() {
        // Idempotent: a second startCapture() (e.g. device hot-swap) must not
        // stack timers. Two 1Hz timers firing offset by <1s would each drain
        // engine.frameCount mid-window, leaving liveFPS oscillating between
        // tiny and large values even though capture is healthy.
        stopStatusTimer()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.engine.sampleBitrate()
                self?.syncState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer

        // Prevent App Nap from throttling the capture pipeline
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Capture pipeline active"
        )
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil

        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }

    /// Lightweight timer for audio metering during preview (no capture stats needed).
    private func startAudioMeterTimer() {
        guard audioMeterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleAudioOnly()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        audioMeterTimer = timer
    }

    private func stopAudioMeterTimer() {
        audioMeterTimer?.invalidate()
        audioMeterTimer = nil
    }

    private func sampleAudioOnly() {
        guard stats.hasAudio else { return }
        let levels = engine.sampleAudioLevels()
        stats.audioLevel = Double(levels.rms)
        stats.audioPeakLevel = Double(levels.peak)
        let peakDB = levels.peak > 0 ? max(20 * log10(levels.peak), -60) : -60
        stats.audioHistory.append(Double(peakDB))
        if stats.audioHistory.count > 120 { stats.audioHistory.removeFirst(stats.audioHistory.count - 120) }
    }

    // MARK: - Device reconnection

    private func handleDeviceDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else { return }
        print("[GUI] Device disconnected: \(device.localizedName) (\(device.uniqueID))")

        let wasOurVideoDevice = device.uniqueID == devices.selectedDevice?.uniqueID
        let wasOurAudioDevice = device.uniqueID == devices.selectedAudioDevice?.uniqueID

        // The audio half of a USB capture device disconnects with its own
        // uniqueID. Save the ID up front so reconnect can re-resolve it; without
        // this we'd keep using the stale AVCaptureDevice ref and silently lose
        // audio after replug.
        if wasOurAudioDevice {
            reconnectAudioDeviceID = device.uniqueID
        }

        if wasOurVideoDevice {
            beginReconnect(forVideoID: device.uniqueID)
        } else if wasOurAudioDevice {
            // Audio-only device disappeared (separate from video). If we're
            // still capturing video, drop the audio output cleanly so we don't
            // sit on a stale input. The reconnect handler will re-attach when
            // the audio device returns.
            engine.setAudioInputDevice(nil)
            stats.hasAudio = false
            devices.availableAudioDevices = DeviceDiscovery.findAudioDevices()
            // Start the reconnect machinery anchored on the video device if any
            // — otherwise the next AVCaptureDeviceWasConnected for the audio
            // half can be handled by attemptReconnect via the polling loop.
            if let videoID = devices.selectedDevice?.uniqueID,
               reconnectDeviceID == nil {
                beginReconnect(forVideoID: videoID)
            }
        } else {
            devices.availableDevices = DeviceDiscovery.findCaptureDevices()
            devices.availableAudioDevices = DeviceDiscovery.findAudioDevices()
        }
    }

    /// Tear down the live pipeline and start the reconnect retry loop. Idempotent.
    private func beginReconnect(forVideoID videoID: String) {
        // If audio belongs to the same physical device (Cam Link etc.), record its
        // uniqueID so we can re-resolve it on reconnect even if its disconnect
        // notification hasn't fired yet.
        if reconnectAudioDeviceID == nil,
           let audioID = devices.selectedAudioDevice?.uniqueID {
            reconnectAudioDeviceID = audioID
        }

        wasCapturingAtDisconnect = recording.isCapturing
        reconnectDeviceID = videoID

        // Tear the pipeline down completely. The replay buffer is NOT cleared,
        // so already-captured frames survive for a manual save.
        if recording.isCapturing || recording.isPreviewing {
            engine.stop()
            engine.stopPreview()
            stopStatusTimer()
        }

        stopThumbnailTimer()
        devices.deviceDisconnected = true
        recording.statusMessage = "Device disconnected — buffer preserved, waiting to reconnect..."
        recording.errorMessage = nil

        // Don't wait for AVCaptureDeviceWasConnected — those notifications can
        // arrive before the device is enumerable in DiscoverySession (or be
        // missed entirely when audio+video halves race). The internal retry
        // loop polls every 0.5s until the device shows up.
        if !isReconnecting {
            attemptReconnect(deviceID: videoID, delay: 0.3)
        }
    }

    private func handleDeviceConnected() {
        print("[GUI] Device connected notification")

        // While reconnecting, the retry loop is already polling — nothing to do.
        if isReconnecting { return }

        if reconnectDeviceID != nil {
            // Reconnect state set but loop not running (shouldn't happen with the
            // immediate-start in beginReconnect, but be defensive).
            attemptReconnect(deviceID: reconnectDeviceID!, delay: 0.0)
        } else {
            refreshDevices()
        }
    }

    private func attemptReconnect(deviceID: String, delay: Double) {
        isReconnecting = true
        recording.statusMessage = "Reconnecting..."

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Bail if the user cancelled / switched devices / stopped capture
            guard self.reconnectDeviceID == deviceID else {
                self.isReconnecting = false
                return
            }

            // Refresh both device lists. AVFoundation can take a beat to publish
            // a re-plugged device, so each iteration looks fresh.
            self.devices.availableDevices = DeviceDiscovery.findCaptureDevices()
            self.devices.availableAudioDevices = DeviceDiscovery.findAudioDevices()

            guard let fresh = self.devices.availableDevices.first(where: { $0.uniqueID == deviceID }) else {
                // Device not enumerable yet — keep polling.
                self.attemptReconnect(deviceID: deviceID, delay: 0.5)
                return
            }

            // selectedDevice's didSet skips when uniqueID matches, which is what
            // we want — no preview-restart side effect during reconnect.
            self.devices.selectedDevice = fresh

            do {
                if self.wasCapturingAtDisconnect {
                    try self.engine.start(with: fresh)
                    self.recording.isCapturing = true
                    self.startStatusTimer()
                    self.startThumbnailTimer()
                } else {
                    try self.engine.startPreview(with: fresh)
                    self.recording.isPreviewing = true
                }
                self.reconnectDeviceID = nil
                self.isReconnecting = false
                self.devices.deviceDisconnected = false
                self.recording.errorMessage = nil
                self.recording.statusMessage = self.wasCapturingAtDisconnect
                    ? "Capturing from \(fresh.localizedName)"
                    : "Preview from \(fresh.localizedName)"
                let dims = CMVideoFormatDescriptionGetDimensions(fresh.activeFormat.formatDescription)
                self.stats.captureResolution = "\(dims.width)x\(dims.height)"

                // Re-attach audio using a FRESHLY resolved AVCaptureDevice. The
                // pre-disconnect reference is invalid post-replug — passing it
                // into AVCaptureDeviceInput throws silently and the meters stay
                // flat (that's the "audio dies after reconnect" bug).
                self.reattachAudioAfterReconnect()
                self.wasCapturingAtDisconnect = false
                print("[GUI] Reconnected successfully (audio: \(self.stats.hasAudio ? "yes" : "no"))")
            } catch {
                print("[GUI] Reconnect attempt failed: \(error) — retrying")
                self.attemptReconnect(deviceID: deviceID, delay: 0.5)
            }
        }
    }

    /// Look up the audio device by the uniqueID recorded at disconnect time and
    /// re-attach it. Falls back to `selectedAudioDevice`'s uniqueID for setups
    /// where audio was selected but never disconnected.
    private func reattachAudioAfterReconnect() {
        let targetID = reconnectAudioDeviceID ?? devices.selectedAudioDevice?.uniqueID
        guard let targetID else {
            stats.hasAudio = false
            return
        }

        if let fresh = freshAudioDevice(forID: targetID) {
            // Update the stored ref so it points at the fresh instance. didSet
            // skips re-firing because uniqueID is unchanged — we drive the
            // engine call explicitly below.
            if fresh !== devices.selectedAudioDevice {
                devices.selectedAudioDevice = fresh
            }
            let ok = engine.setAudioInputDevice(fresh)
            stats.hasAudio = ok && engine.hasAudioInput
            if !ok {
                print("[GUI] Audio re-attach failed — device may still be settling")
            }
            reconnectAudioDeviceID = nil
        } else {
            // Audio device not enumerable yet. Don't lose the ID — leave it set
            // so the user can retry, and report no audio for now.
            stats.hasAudio = false
            print("[GUI] Audio device \(targetID) not yet available post-reconnect")
        }
    }

    /// Detect capture stalls (0 FPS for several seconds) and attempt recovery.
    private func checkForStall() {
        guard recording.isCapturing else {
            zeroFPSStreak = 0
            return
        }

        if stats.liveFPS == 0 {
            zeroFPSStreak += 1
        } else {
            zeroFPSStreak = 0
            return
        }

        guard zeroFPSStreak >= Self.zeroFPSReconnectThreshold else { return }
        zeroFPSStreak = 0

        print("[GUI] Capture stall detected (\(Self.zeroFPSReconnectThreshold)s at 0fps) — attempting recovery")
        recording.statusMessage = "Capture stalled — reconnecting..."

        guard let device = devices.selectedDevice else { return }
        let deviceID = device.uniqueID

        // Stop and restart
        engine.stop()
        recording.isCapturing = false
        recording.isPreviewing = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.refreshDevices()
            if let match = self.devices.availableDevices.first(where: { $0.uniqueID == deviceID }) {
                self.devices.selectedDevice = match
                self.startCapture()
            } else {
                // Device not found — enter reconnect wait mode
                self.reconnectDeviceID = deviceID
                self.recording.statusMessage = "Device lost — waiting to reconnect..."
            }
        }
    }

    private func clearStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.recording.statusMessage == "Screenshot saved" {
                self?.recording.statusMessage = ""
            }
        }
    }

    private func clearScreenshotFeedbackAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let current = self.replay.screenshotFeedback
            if current == .success || current == .failed {
                self.replay.screenshotFeedback = .idle
            }
        }
    }

    private func clearReplaySaveFeedbackAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let current = self.replay.replaySaveFeedback
            if current == .success || current == .failed {
                self.replay.replaySaveFeedback = .idle
            }
        }
    }

    // MARK: - Replay thumbnails

    private func startThumbnailTimer() {
        stopThumbnailTimer()
        // First thumbnail after a brief delay to let frames start flowing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.captureThumbnail()
        }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureThumbnail()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        thumbnailTimer = timer
    }

    private func stopThumbnailTimer() {
        thumbnailTimer?.invalidate()
        thumbnailTimer = nil
    }

    private func captureThumbnail() {
        let engine = self.engine
        let maxDuration = self.replay.replayDuration
        Task.detached {
            guard let cgImage = engine.createThumbnail(maxWidth: 160) else { return }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.replay.replayThumbnails.append(ReplayThumbnail(image: nsImage, capturedAt: Date()))
                let cutoff = Date().addingTimeInterval(-maxDuration)
                self.replay.replayThumbnails.removeAll { $0.capturedAt < cutoff }
            }
        }
    }

    private func trimOldThumbnails() {
        let cutoff = Date().addingTimeInterval(-replay.replayDuration)
        replay.replayThumbnails.removeAll { $0.capturedAt < cutoff }
    }
}
