import SwiftUI
import AVFoundation
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

@MainActor
final class CaptureViewModel: ObservableObject {

    // Device selection
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDevice: AVCaptureDevice? {
        didSet {
            guard selectedDevice?.uniqueID != oldValue?.uniqueID else { return }
            if let settings, settings.rememberLastDevice {
                settings.lastDeviceUniqueID = selectedDevice?.uniqueID
            }
            // Don't start preview if we're reconnecting capture
            if reconnectDeviceID == nil && !isReconnecting {
                startPreviewForSelectedDevice()
            }
        }
    }

    // State
    @Published var isPreviewing = false
    @Published var isCapturing = false
    @Published var isRecording = false
    @Published var deviceDisconnected = false
    @Published var recordingStartDate: Date?
    @Published var recordingDuration: TimeInterval = 0
    @Published var screenshotFeedback: ActionFeedback = .idle
    @Published var replaySaveFeedback: ActionFeedback = .idle
    @Published var replayThumbnails: [ReplayThumbnail] = []
    @Published var bufferDuration: Double = 0
    @Published var bufferFrameCount: Int = 0
    @Published var bufferSizeMB: Int = 0
    @Published var liveBitrateMbps: Double = 0
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?
    @Published var cameraAuthorized = false
    @Published var captureResolution: String = ""
    @Published var liveFPS: Double = 0
    @Published var droppedFrames: Int = 0
    @Published var fpsHistory: [Double] = []

    // Audio device selection
    @Published var availableAudioDevices: [AVCaptureDevice] = []
    @Published var selectedAudioDevice: AVCaptureDevice? {
        didSet {
            guard selectedAudioDevice?.uniqueID != oldValue?.uniqueID else { return }
            if let settings, settings.rememberLastDevice {
                settings.lastAudioDeviceUniqueID = selectedAudioDevice?.uniqueID
            }
            engine.setAudioInputDevice(selectedAudioDevice)
            hasAudio = engine.hasAudioInput
            audioHistory = []
        }
    }
    @Published var audioPassthroughEnabled: Bool = false {
        didSet {
            if audioPassthroughEnabled {
                engine.startPassthrough()
            } else {
                engine.stopPassthrough()
            }
        }
    }

    // Audio levels (linear 0–1)
    @Published var audioLevel: Double = 0
    @Published var audioPeakLevel: Double = 0
    @Published var audioHistory: [Double] = []
    @Published var hasAudio: Bool = false

    // System stats
    @Published var cpuPercent: Double = 0
    @Published var ramMB: Double = 0
    @Published var diskFreeGB: Double = 0
    @Published var gpuPercent: Double = 0
    @Published var cpuHistory: [Double] = []
    @Published var ramHistory: [Double] = []
    @Published var diskHistory: [Double] = []
    @Published var gpuHistory: [Double] = []

    // Settings — synced from AppSettings
    @Published var replayDuration: Double = 30 {
        didSet {
            applyReplayLimits()
            settings?.replayDuration = replayDuration
            trimOldThumbnails()
        }
    }
    @Published var customReplayDuration: String = "" // for custom entry
    @Published var maxReplayRAM: Int = 0 { // bytes, 0 = unlimited
        didSet {
            applyReplayLimits()
            settings?.maxReplayRAM = maxReplayRAM
        }
    }
    @Published var bitrateMbps: Int = 20 {
        didSet {
            settings?.bitrateMbps = bitrateMbps
            engine.updateBitrate(mbps: bitrateMbps)
        }
    }
    @Published var captureCodec: CaptureCodec = .h264 {
        didSet {
            guard captureCodec != oldValue else { return }
            settings?.captureCodec = captureCodec
            let newCodec = captureCodec
            // Engine swap is async because it may need to finalize an in-flight
            // recording before the codec change. Buffer was just (or is about
            // to be) cleared — also clear the thumbnail strip so the UI doesn't
            // keep stills around for content that no longer exists.
            replayThumbnails = []
            Task { [engine] in
                await engine.setCodec(newCodec)
                await MainActor.run { [weak self] in self?.syncState() }
            }
        }
    }

    private weak var settings: AppSettings?

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

    /// Estimated file size in MB for a given duration. Uses the live measured
    /// bitrate when capture is running (most accurate), falls back to the
    /// codec's configured/expected bitrate otherwise.
    func estimatedSizeMB(forSeconds seconds: Double) -> Double {
        let mbps: Double
        if liveBitrateMbps > 1.0 {
            mbps = liveBitrateMbps
        } else if captureCodec.isLossless {
            let (w, h, fps) = currentResolutionForEstimate()
            mbps = captureCodec.estimatedMbps(width: w, height: h, fps: fps)
        } else {
            mbps = Double(bitrateMbps)
        }
        return mbps * seconds / 8.0
    }

    /// Best-guess (width, height, fps) for pre-capture file-size estimates.
    /// Falls back to 1080p60 when no device info is available yet.
    private func currentResolutionForEstimate() -> (Int, Int, Double) {
        let parts = captureResolution.split(separator: "x")
        if parts.count == 2,
           let w = Int(parts[0]), let h = Int(parts[1]) {
            return (w, h, liveFPS > 0 ? liveFPS : 60)
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
        guard maxReplayRAM > 0 else { return nil }
        let mbps: Double
        if liveBitrateMbps > 1.0 {
            mbps = liveBitrateMbps
        } else if captureCodec.isLossless {
            let (w, h, fps) = currentResolutionForEstimate()
            mbps = captureCodec.estimatedMbps(width: w, height: h, fps: fps)
        } else {
            mbps = Double(bitrateMbps)
        }
        let bytesPerSecond = mbps * 1_000_000 / 8.0
        guard bytesPerSecond > 0 else { return nil }
        return Double(maxReplayRAM) / bytesPerSecond
    }

    private func applyReplayLimits() {
        engine.updateReplayLimits(duration: replayDuration, maxBytes: maxReplayRAM)
    }

    let engine: CaptureEngine
    let systemStats = SystemStatsMonitor()
    private var statusTimer: Timer?
    private var audioMeterTimer: Timer?
    private var thumbnailTimer: Timer?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var appNapActivity: NSObjectProtocol?

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

    init(settings: AppSettings) {
        self.settings = settings
        self.replayDuration = settings.replayDuration
        self.maxReplayRAM = settings.maxReplayRAM
        self.bitrateMbps = settings.bitrateMbps
        self.captureCodec = settings.captureCodec
        self.engine = CaptureEngine(replayDuration: settings.replayDuration,
                                    bitrateMbps: settings.bitrateMbps,
                                    codec: settings.captureCodec)
        engine.setOutputDirectory(settings.outputDirectory)

        // Mirror codec changes made elsewhere (Preferences sheet) into the VM.
        settings.$captureCodec
            .receive(on: RunLoop.main)
            .sink { [weak self] newCodec in
                guard let self else { return }
                if self.captureCodec != newCodec { self.captureCodec = newCodec }
            }
            .store(in: &settingsCancellables)

        engine.onStateChange = { [weak self] in
            Task { @MainActor in
                self?.syncState()
            }
        }

        settings.$outputDirectoryPath
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.engine.setOutputDirectory(settings.outputDirectory)
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

    /// Try to reconnect to the last-used device and optionally start capture.
    func autoConnectLastDevice() {
        guard let settings, settings.rememberLastDevice,
              let savedID = settings.lastDeviceUniqueID else { return }

        refreshDevices()

        if let match = availableDevices.first(where: { $0.uniqueID == savedID }) {
            selectedDevice = match
            if settings.autoStartCapture {
                startCapture()
            }
        }
    }

    // MARK: - Camera permission

    func checkCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.cameraAuthorized = granted
                    if granted {
                        self.refreshDevices()
                    } else {
                        self.errorMessage = "Camera access denied. Grant access in System Settings > Privacy & Security > Camera."
                    }
                }
            }
        case .denied, .restricted:
            cameraAuthorized = false
            errorMessage = "Camera access denied. Grant access in System Settings > Privacy & Security > Camera."
        @unknown default:
            break
        }
    }

    // MARK: - Device management

    func refreshDevices() {
        availableDevices = DeviceDiscovery.findCaptureDevices()
        availableAudioDevices = DeviceDiscovery.findAudioDevices()

        // Don't change selection while waiting for a device to come back
        if reconnectDeviceID == nil,
           selectedDevice == nil || !availableDevices.contains(where: { $0.uniqueID == selectedDevice?.uniqueID }) {
            selectedDevice = autoSelectDevice()
        }

        // Auto-select audio device matching video device name if none selected
        if selectedAudioDevice == nil || !availableAudioDevices.contains(where: { $0.uniqueID == selectedAudioDevice?.uniqueID }) {
            selectedAudioDevice = autoSelectAudioDevice()
        }

        if availableDevices.isEmpty {
            statusMessage = "No capture devices found. Plug in your Elgato and refresh."
        }

        // Start preview if we have a device and aren't already capturing
        if selectedDevice != nil && !isCapturing && !isPreviewing {
            startPreviewForSelectedDevice()
        }
    }

    private func autoSelectAudioDevice() -> AVCaptureDevice? {
        // Prefer the remembered audio device
        if let settings, settings.rememberLastDevice,
           let savedID = settings.lastAudioDeviceUniqueID,
           let match = availableAudioDevices.first(where: { $0.uniqueID == savedID }) {
            return match
        }

        guard let videoDevice = selectedDevice else { return nil }
        let videoName = videoDevice.localizedName.lowercased()

        // Exact name match
        if let match = availableAudioDevices.first(where: {
            $0.localizedName == videoDevice.localizedName
        }) {
            return match
        }

        // Partial name match (e.g. "Cam Link 4K" in audio device name)
        return availableAudioDevices.first(where: {
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
        availableAudioDevices = DeviceDiscovery.findAudioDevices()
        guard let id = selectedAudioDevice?.uniqueID else { return nil }
        let fresh = availableAudioDevices.first(where: { $0.uniqueID == id })
        if let fresh, fresh !== selectedAudioDevice {
            selectedAudioDevice = fresh
        }
        return fresh
    }

    private func autoSelectDevice() -> AVCaptureDevice? {
        let keywords = ["elgato", "cam link", "hd60", "4k60", "game capture"]
        if let match = availableDevices.first(where: { device in
            let name = device.localizedName.lowercased()
            return keywords.contains(where: { name.contains($0) })
        }) {
            return match
        }
        return availableDevices.first
    }

    // MARK: - Preview

    func startPreviewForSelectedDevice() {
        guard cameraAuthorized, let device = selectedDevice else { return }
        // Don't interrupt a running capture
        guard !isCapturing else { return }

        do {
            try engine.startPreview(with: device)
            isPreviewing = true
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            captureResolution = "\(dims.width)x\(dims.height)"

            // Set up audio — always re-resolve by uniqueID against a fresh
            // discovery session to avoid stale AVCaptureDevice refs.
            if let audioDevice = refreshSelectedAudioDevice() {
                engine.setAudioInputDevice(audioDevice)
                hasAudio = engine.hasAudioInput
                if hasAudio { startAudioMeterTimer() }
            } else {
                hasAudio = false
            }
        } catch {
            print("[GUI] Preview failed: \(error)")
            isPreviewing = false
        }
    }

    func stopPreview() {
        engine.stopPreview()
        isPreviewing = false
        captureResolution = ""
        hasAudio = false
        stopAudioMeterTimer()
    }

    // MARK: - Capture control

    func startCapture() {
        guard cameraAuthorized else {
            errorMessage = "Camera access not granted. Check System Settings > Privacy & Security > Camera."
            return
        }

        guard let device = selectedDevice else {
            errorMessage = "No device selected"
            return
        }

        errorMessage = nil
        statusMessage = "Starting capture..."

        do {
            try engine.start(with: device)
            isCapturing = true
            errorMessage = nil
            statusMessage = "Capturing from \(device.localizedName)"

            // Read resolution from the device's active format
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            captureResolution = "\(dims.width)x\(dims.height)"

            // Set up audio — refresh the device ref against a fresh discovery
            // session first so we don't pass a stale handle into the session.
            stopAudioMeterTimer()
            if let audioDevice = refreshSelectedAudioDevice() {
                engine.setAudioInputDevice(audioDevice)
                hasAudio = engine.hasAudioInput
            } else {
                hasAudio = false
            }

            startStatusTimer()
            startThumbnailTimer()
        } catch {
            errorMessage = error.localizedDescription
            isCapturing = false
            statusMessage = ""
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
        isCapturing = false
        deviceDisconnected = false
        // engine.stop() falls back to preview mode automatically
        isPreviewing = engine.isPreviewing
        stopStatusTimer()
        stopThumbnailTimer()
        replayThumbnails = []
        statusMessage = "Stopped"
        liveFPS = 0
        droppedFrames = 0
        fpsHistory = []
        recordingStartDate = nil
        recordingDuration = 0
        audioLevel = 0
        audioPeakLevel = 0
        audioHistory = []
        hasAudio = false
        audioPassthroughEnabled = false
        syncState()

        // Update resolution from the still-connected device
        if isPreviewing, let device = selectedDevice {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            captureResolution = "\(dims.width)x\(dims.height)"
        } else {
            captureResolution = ""
        }
    }

    // MARK: - Actions

    func toggleRecording() {
        let wasRecording = engine.recorder.isRecording
        if wasRecording {
            statusMessage = "Stopping recording..."
        } else {
            statusMessage = "Starting recording..."
        }
        Task.detached { [weak self] in
            self?.engine.toggleRecording()
            await MainActor.run {
                guard let self else { return }
                if wasRecording {
                    self.recordingStartDate = nil
                    self.recordingDuration = 0
                    self.statusMessage = "Recording stopped"
                } else {
                    self.recordingStartDate = Date()
                    self.statusMessage = "Recording started"
                }
                self.syncState()
            }
        }
    }

    func takeScreenshot() {
        screenshotFeedback = .inProgress
        statusMessage = "Saving screenshot..."
        Task.detached { [weak self] in
            self?.engine.takeScreenshot()
            await MainActor.run {
                guard let self else { return }
                self.screenshotFeedback = .success
                self.statusMessage = "Screenshot saved"
                self.clearFeedbackAfterDelay(\.screenshotFeedback)
                self.clearStatusAfterDelay()
            }
        }
    }

    func saveReplay() {
        replaySaveFeedback = .inProgress
        statusMessage = "Saving replay..."
        engine.saveReplay(lastSeconds: replayDuration) { [weak self] success in
            guard let self else { return }
            self.replaySaveFeedback = success ? .success : .failed
            self.statusMessage = success ? "Replay saved" : "Replay save failed"
            self.clearFeedbackAfterDelay(\.replaySaveFeedback)
        }
    }

    func openOutputFolder() {
        let url = engine.recorder.outputDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private func syncState() {
        isRecording = engine.recorder.isRecording
        if let start = recordingStartDate, isRecording {
            recordingDuration = Date().timeIntervalSince(start)
        }
        let stats = engine.replayBuffer.stats
        bufferDuration = stats.duration
        bufferFrameCount = stats.frameCount
        bufferSizeMB = stats.bytes / 1_048_576
        liveBitrateMbps = engine.liveBitrateMbps

        engine.sampleFPS()
        liveFPS = engine.liveFPS
        droppedFrames = engine.droppedFrames
        fpsHistory.append(liveFPS)
        if fpsHistory.count > 60 { fpsHistory.removeFirst(fpsHistory.count - 60) }

        // Audio levels
        hasAudio = engine.hasAudioInput
        if hasAudio {
            let levels = engine.sampleAudioLevels()
            audioLevel = Double(levels.rms)
            audioPeakLevel = Double(levels.peak)
            // Store peak in dB for the history graph (clamped to -60…0)
            let peakDB = levels.peak > 0 ? max(20 * log10(levels.peak), -60) : -60
            audioHistory.append(Double(peakDB))
            if audioHistory.count > 120 { audioHistory.removeFirst(audioHistory.count - 120) }
        }

        checkForStall()

        systemStats.sample()
        cpuPercent = systemStats.latestCPU
        ramMB = systemStats.latestRAM
        diskFreeGB = systemStats.latestDisk
        gpuPercent = systemStats.latestGPU
        cpuHistory = systemStats.cpuHistory
        ramHistory = systemStats.ramHistory
        diskHistory = systemStats.diskHistory
        gpuHistory = systemStats.gpuHistory
    }

    private func startStatusTimer() {
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
        guard hasAudio else { return }
        let levels = engine.sampleAudioLevels()
        audioLevel = Double(levels.rms)
        audioPeakLevel = Double(levels.peak)
        let peakDB = levels.peak > 0 ? max(20 * log10(levels.peak), -60) : -60
        audioHistory.append(Double(peakDB))
        if audioHistory.count > 120 { audioHistory.removeFirst(audioHistory.count - 120) }
    }

    // MARK: - Device reconnection

    private func handleDeviceDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else { return }
        print("[GUI] Device disconnected: \(device.localizedName) (\(device.uniqueID))")

        let wasOurVideoDevice = device.uniqueID == selectedDevice?.uniqueID
        let wasOurAudioDevice = device.uniqueID == selectedAudioDevice?.uniqueID

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
            hasAudio = false
            availableAudioDevices = DeviceDiscovery.findAudioDevices()
            // Start the reconnect machinery anchored on the video device if any
            // — otherwise the next AVCaptureDeviceWasConnected for the audio
            // half can be handled by attemptReconnect via the polling loop.
            if let videoID = selectedDevice?.uniqueID,
               reconnectDeviceID == nil {
                beginReconnect(forVideoID: videoID)
            }
        } else {
            availableDevices = DeviceDiscovery.findCaptureDevices()
            availableAudioDevices = DeviceDiscovery.findAudioDevices()
        }
    }

    /// Tear down the live pipeline and start the reconnect retry loop. Idempotent.
    private func beginReconnect(forVideoID videoID: String) {
        // If audio belongs to the same physical device (Cam Link etc.), record its
        // uniqueID so we can re-resolve it on reconnect even if its disconnect
        // notification hasn't fired yet.
        if reconnectAudioDeviceID == nil,
           let audioID = selectedAudioDevice?.uniqueID {
            reconnectAudioDeviceID = audioID
        }

        wasCapturingAtDisconnect = isCapturing
        reconnectDeviceID = videoID

        // Tear the pipeline down completely. The replay buffer is NOT cleared,
        // so already-captured frames survive for a manual save.
        if isCapturing || isPreviewing {
            engine.stop()
            engine.stopPreview()
            stopStatusTimer()
        }

        stopThumbnailTimer()
        deviceDisconnected = true
        statusMessage = "Device disconnected — buffer preserved, waiting to reconnect..."
        errorMessage = nil

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
        statusMessage = "Reconnecting..."

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Bail if the user cancelled / switched devices / stopped capture
            guard self.reconnectDeviceID == deviceID else {
                self.isReconnecting = false
                return
            }

            // Refresh both device lists. AVFoundation can take a beat to publish
            // a re-plugged device, so each iteration looks fresh.
            self.availableDevices = DeviceDiscovery.findCaptureDevices()
            self.availableAudioDevices = DeviceDiscovery.findAudioDevices()

            guard let fresh = self.availableDevices.first(where: { $0.uniqueID == deviceID }) else {
                // Device not enumerable yet — keep polling.
                self.attemptReconnect(deviceID: deviceID, delay: 0.5)
                return
            }

            // selectedDevice's didSet skips when uniqueID matches, which is what
            // we want — no preview-restart side effect during reconnect.
            self.selectedDevice = fresh

            do {
                if self.wasCapturingAtDisconnect {
                    try self.engine.start(with: fresh)
                    self.isCapturing = true
                    self.startStatusTimer()
                    self.startThumbnailTimer()
                } else {
                    try self.engine.startPreview(with: fresh)
                    self.isPreviewing = true
                }
                self.reconnectDeviceID = nil
                self.isReconnecting = false
                self.deviceDisconnected = false
                self.errorMessage = nil
                self.statusMessage = self.wasCapturingAtDisconnect
                    ? "Capturing from \(fresh.localizedName)"
                    : "Preview from \(fresh.localizedName)"
                let dims = CMVideoFormatDescriptionGetDimensions(fresh.activeFormat.formatDescription)
                self.captureResolution = "\(dims.width)x\(dims.height)"

                // Re-attach audio using a FRESHLY resolved AVCaptureDevice. The
                // pre-disconnect reference is invalid post-replug — passing it
                // into AVCaptureDeviceInput throws silently and the meters stay
                // flat (that's the "audio dies after reconnect" bug).
                self.reattachAudioAfterReconnect()
                self.wasCapturingAtDisconnect = false
                print("[GUI] Reconnected successfully (audio: \(self.hasAudio ? "yes" : "no"))")
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
        let targetID = reconnectAudioDeviceID ?? selectedAudioDevice?.uniqueID
        guard let targetID else {
            hasAudio = false
            return
        }

        if let fresh = freshAudioDevice(forID: targetID) {
            // Update the stored ref so it points at the fresh instance. didSet
            // skips re-firing because uniqueID is unchanged — we drive the
            // engine call explicitly below.
            if fresh !== selectedAudioDevice {
                selectedAudioDevice = fresh
            }
            let ok = engine.setAudioInputDevice(fresh)
            hasAudio = ok && engine.hasAudioInput
            if !ok {
                print("[GUI] Audio re-attach failed — device may still be settling")
            }
            reconnectAudioDeviceID = nil
        } else {
            // Audio device not enumerable yet. Don't lose the ID — leave it set
            // so the user can retry, and report no audio for now.
            hasAudio = false
            print("[GUI] Audio device \(targetID) not yet available post-reconnect")
        }
    }

    /// Detect capture stalls (0 FPS for several seconds) and attempt recovery.
    private func checkForStall() {
        guard isCapturing else {
            zeroFPSStreak = 0
            return
        }

        if liveFPS == 0 {
            zeroFPSStreak += 1
        } else {
            zeroFPSStreak = 0
            return
        }

        guard zeroFPSStreak >= Self.zeroFPSReconnectThreshold else { return }
        zeroFPSStreak = 0

        print("[GUI] Capture stall detected (\(Self.zeroFPSReconnectThreshold)s at 0fps) — attempting recovery")
        statusMessage = "Capture stalled — reconnecting..."

        guard let device = selectedDevice else { return }
        let deviceID = device.uniqueID

        // Stop and restart
        engine.stop()
        isCapturing = false
        isPreviewing = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.refreshDevices()
            if let match = self.availableDevices.first(where: { $0.uniqueID == deviceID }) {
                self.selectedDevice = match
                self.startCapture()
            } else {
                // Device not found — enter reconnect wait mode
                self.reconnectDeviceID = deviceID
                self.statusMessage = "Device lost — waiting to reconnect..."
            }
        }
    }

    private func clearStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.statusMessage == "Screenshot saved" {
                self?.statusMessage = ""
            }
        }
    }

    private func clearFeedbackAfterDelay(_ keyPath: ReferenceWritableKeyPath<CaptureViewModel, ActionFeedback>) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let current = self[keyPath: keyPath]
            if current == .success || current == .failed {
                self[keyPath: keyPath] = .idle
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
        let maxDuration = self.replayDuration
        Task.detached {
            guard let cgImage = engine.createThumbnail(maxWidth: 160) else { return }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.replayThumbnails.append(ReplayThumbnail(image: nsImage, capturedAt: Date()))
                let cutoff = Date().addingTimeInterval(-maxDuration)
                self.replayThumbnails.removeAll { $0.capturedAt < cutoff }
            }
        }
    }

    private func trimOldThumbnails() {
        let cutoff = Date().addingTimeInterval(-replayDuration)
        replayThumbnails.removeAll { $0.capturedAt < cutoff }
    }
}
