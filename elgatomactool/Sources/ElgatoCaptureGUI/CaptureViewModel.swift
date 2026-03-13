import SwiftUI
import AVFoundation
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

    // Settings
    @Published var replayDuration: Double = 30
    @Published var bitrateMbps: Int = 20

    let engine: CaptureEngine
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
        syncState()
    }

    // MARK: - Actions

    func toggleRecording() {
        engine.toggleRecording()
        if !engine.recorder.isRecording {
            statusMessage = "Recording started"
        } else {
            statusMessage = "Recording stopped"
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
