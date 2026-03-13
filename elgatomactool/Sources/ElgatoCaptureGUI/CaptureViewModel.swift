import SwiftUI
import AVFoundation
import CoreMedia
import CaptureCore
import Combine

@MainActor
final class CaptureViewModel: ObservableObject {

    // Device selection
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDevice: AVCaptureDevice?

    // State
    @Published var isCapturing = false
    @Published var isRecording = false
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
    @Published var cpuHistory: [Double] = []
    @Published var ramHistory: [Double] = []
    @Published var diskHistory: [Double] = []

    // Settings
    @Published var replayDuration: Double = 30 {
        didSet { applyReplayLimits() }
    }
    @Published var customReplayDuration: String = "" // for custom entry
    @Published var maxReplayRAM: Int = 0 { // bytes, 0 = unlimited
        didSet { applyReplayLimits() }
    }
    @Published var bitrateMbps: Int = 20

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

    init() {
        self.engine = CaptureEngine(replayDuration: 30, bitrateMbps: 20)

        engine.onStateChange = { [weak self] in
            Task { @MainActor in
                self?.syncState()
            }
        }

        checkCameraAccess()
        refreshDevices()
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

        if selectedDevice == nil || !availableDevices.contains(where: { $0.uniqueID == selectedDevice?.uniqueID }) {
            selectedDevice = autoSelectDevice()
        }

        if availableDevices.isEmpty {
            statusMessage = "No capture devices found. Plug in your Elgato and refresh."
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
        stopStatusTimer()
        statusMessage = "Stopped"
        captureResolution = ""
        liveFPS = 0
        droppedFrames = 0
        fpsHistory = []
        syncState()
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
        let url = Recorder.defaultOutputDir()
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

        systemStats.sample()
        cpuPercent = systemStats.latestCPU
        ramMB = systemStats.latestRAM
        diskFreeGB = systemStats.latestDisk
        cpuHistory = systemStats.cpuHistory
        ramHistory = systemStats.ramHistory
        diskHistory = systemStats.diskHistory
    }

    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncState()
            }
        }
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func clearStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.statusMessage == "Screenshot saved" {
                self?.statusMessage = ""
            }
        }
    }
}
