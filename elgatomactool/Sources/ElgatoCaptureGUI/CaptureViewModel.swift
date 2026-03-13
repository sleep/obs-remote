import SwiftUI
import AVFoundation
import CoreMedia
import CaptureCore
import Combine

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
    @Published var bufferDuration: Double = 0
    @Published var bufferFrameCount: Int = 0
    @Published var bufferSizeMB: Int = 0
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?
    @Published var cameraAuthorized = false
    @Published var captureResolution: String = ""
    @Published var liveFPS: Double = 0
    @Published var droppedFrames: Int = 0
    @Published var fpsHistory: [Double] = []

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
        didSet { settings?.bitrateMbps = bitrateMbps }
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

    /// Estimated file size in MB for a given duration at the current bitrate.
    func estimatedSizeMB(forSeconds seconds: Double) -> Double {
        // bitrateMbps is megabits/s → divide by 8 for megabytes/s
        return Double(bitrateMbps) * seconds / 8.0
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
        let bytesPerSecond = Double(bitrateMbps) * 1_000_000 / 8.0
        guard bytesPerSecond > 0 else { return nil }
        return Double(maxReplayRAM) / bytesPerSecond
    }

    private func applyReplayLimits() {
        engine.updateReplayLimits(duration: replayDuration, maxBytes: maxReplayRAM)
    }

    let engine: CaptureEngine
    let systemStats = SystemStatsMonitor()
    private var statusTimer: Timer?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var appNapActivity: NSObjectProtocol?

    /// UniqueID of the device we were capturing from before a disconnect.
    private var reconnectDeviceID: String?
    /// True while attemptReconnect is in progress (waiting or retrying).
    private var isReconnecting = false
    /// Consecutive seconds with 0 FPS while supposedly capturing — triggers reconnect.
    private var zeroFPSStreak: Int = 0
    private static let zeroFPSReconnectThreshold = 3

    init(settings: AppSettings) {
        self.settings = settings
        self.replayDuration = settings.replayDuration
        self.maxReplayRAM = settings.maxReplayRAM
        self.bitrateMbps = settings.bitrateMbps
        self.engine = CaptureEngine(replayDuration: settings.replayDuration,
                                    bitrateMbps: settings.bitrateMbps)
        engine.setOutputDirectory(settings.outputDirectory)

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

        // Don't change selection while waiting for a device to come back
        if reconnectDeviceID == nil,
           selectedDevice == nil || !availableDevices.contains(where: { $0.uniqueID == selectedDevice?.uniqueID }) {
            selectedDevice = autoSelectDevice()
        }

        if availableDevices.isEmpty {
            statusMessage = "No capture devices found. Plug in your Elgato and refresh."
        }

        // Start preview if we have a device and aren't already capturing
        if selectedDevice != nil && !isCapturing && !isPreviewing {
            startPreviewForSelectedDevice()
        }
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
        } catch {
            print("[GUI] Preview failed: \(error)")
            isPreviewing = false
        }
    }

    func stopPreview() {
        engine.stopPreview()
        isPreviewing = false
        captureResolution = ""
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

            startStatusTimer()
        } catch {
            errorMessage = error.localizedDescription
            isCapturing = false
            statusMessage = ""
            print("[GUI] Start failed: \(error)")
        }
    }

    func stopCapture() {
        engine.stop()
        isCapturing = false
        deviceDisconnected = false
        // engine.stop() falls back to preview mode automatically
        isPreviewing = engine.isPreviewing
        stopStatusTimer()
        statusMessage = "Stopped"
        liveFPS = 0
        droppedFrames = 0
        fpsHistory = []
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
        engine.toggleRecording()
        if wasRecording {
            statusMessage = "Recording stopped"
        } else {
            statusMessage = "Recording started"
        }
    }

    func takeScreenshot() {
        engine.takeScreenshot()
        statusMessage = "Screenshot saved"
        clearStatusAfterDelay()
    }

    func saveReplay() {
        engine.saveReplay(lastSeconds: replayDuration)
        statusMessage = "Saving replay..."
    }

    func openOutputFolder() {
        let url = engine.recorder.outputDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private func syncState() {
        isRecording = engine.recorder.isRecording
        let stats = engine.replayBuffer.stats
        bufferDuration = stats.duration
        bufferFrameCount = stats.frameCount
        bufferSizeMB = stats.bytes / 1_048_576

        engine.sampleFPS()
        liveFPS = engine.liveFPS
        droppedFrames = engine.droppedFrames
        fpsHistory.append(liveFPS)
        if fpsHistory.count > 60 { fpsHistory.removeFirst(fpsHistory.count - 60) }

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

    // MARK: - Device reconnection

    private func handleDeviceDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else { return }
        print("[GUI] Device disconnected: \(device.localizedName)")

        let wasOurDevice = device.uniqueID == selectedDevice?.uniqueID

        if wasOurDevice {
            reconnectDeviceID = device.uniqueID

            // Stop the engine cleanly (tears down encoder + session) but the replay
            // buffer is NOT cleared by stop(), so existing frames survive for saving.
            // Keep isCapturing = true so the UI still shows stats/controls/buffer info.
            if isCapturing {
                engine.stop()
                stopStatusTimer()
            }

            deviceDisconnected = true
            statusMessage = "Device disconnected — buffer preserved, waiting to reconnect..."
            errorMessage = nil
        } else {
            availableDevices = DeviceDiscovery.findCaptureDevices()
        }
    }

    private func handleDeviceConnected() {
        print("[GUI] Device connected")

        // Ignore duplicate connect events if we're already reconnecting
        if isReconnecting { return }

        if let targetID = reconnectDeviceID {
            availableDevices = DeviceDiscovery.findCaptureDevices()
            if availableDevices.contains(where: { $0.uniqueID == targetID }) {
                attemptReconnect(deviceID: targetID, retries: 5, delay: 1.0)
            }
        } else {
            refreshDevices()
        }
    }

    private func attemptReconnect(deviceID: String, retries: Int, delay: Double) {
        guard retries > 0 else {
            isReconnecting = false
            reconnectDeviceID = nil
            statusMessage = "Reconnect failed"
            errorMessage = "Could not reconnect to device after multiple attempts."
            return
        }

        isReconnecting = true
        statusMessage = "Reconnecting..."

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Bail if the user switched devices or reconnect was cancelled
            guard self.reconnectDeviceID == deviceID else {
                self.isReconnecting = false
                return
            }

            // Refresh the device object (may have changed across unplug/replug)
            self.availableDevices = DeviceDiscovery.findCaptureDevices()
            guard let fresh = self.availableDevices.first(where: { $0.uniqueID == deviceID }) else {
                print("[GUI] Device not available yet, retrying (\(retries - 1) left)")
                self.attemptReconnect(deviceID: deviceID, retries: retries - 1, delay: delay)
                return
            }
            self.selectedDevice = fresh

            do {
                try self.engine.start(with: fresh)
                self.reconnectDeviceID = nil
                self.isReconnecting = false
                self.deviceDisconnected = false
                self.isCapturing = true
                self.errorMessage = nil
                self.statusMessage = "Capturing from \(fresh.localizedName)"
                let dims = CMVideoFormatDescriptionGetDimensions(fresh.activeFormat.formatDescription)
                self.captureResolution = "\(dims.width)x\(dims.height)"
                self.startStatusTimer()
                print("[GUI] Reconnected successfully")
            } catch {
                print("[GUI] Reconnect attempt failed (\(retries - 1) left): \(error)")
                self.attemptReconnect(deviceID: deviceID, retries: retries - 1, delay: delay)
            }
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
}
