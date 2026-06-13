import SwiftUI
import CaptureCore

final class AppSettings: ObservableObject {

    /// Available data fields for the menu bar status text.
    enum StatusBarField: String, CaseIterable, Identifiable {
        case device = "device"
        case resolution = "resolution"
        case fps = "fps"
        case buffer = "buffer"
        case bufferMB = "bufferMB"
        case cpu = "cpu"
        case gpu = "gpu"
        case ram = "ram"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .device: return "Device Name"
            case .resolution: return "Resolution"
            case .fps: return "FPS"
            case .buffer: return "Buffer Duration"
            case .bufferMB: return "Buffer Size (MB)"
            case .cpu: return "CPU %"
            case .gpu: return "GPU %"
            case .ram: return "RAM Usage"
            }
        }
    }

    /// Overlay stat items that can be shown/hidden on the video preview.
    enum OverlayStat: String, CaseIterable, Identifiable {
        case resolution, fps, buffer, bitrate, audio, cpu, gpu, ram, disk

        var id: String { rawValue }

        var label: String {
            switch self {
            case .resolution: return "Resolution"
            case .fps: return "FPS"
            case .buffer: return "Buffer"
            case .bitrate: return "Bitrate"
            case .audio: return "Audio"
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .ram: return "RAM"
            case .disk: return "Disk"
            }
        }
    }

    private enum Keys {
        static let lastDeviceUniqueID = "lastDeviceUniqueID"
        static let lastAudioDeviceUniqueID = "lastAudioDeviceUniqueID"
        static let rememberLastDevice = "rememberLastDevice"
        static let autoStartCapture = "autoStartCapture"
        static let startMinimized = "startMinimized"
        static let replayDuration = "replayDuration"
        static let maxReplayRAM = "maxReplayRAM"
        static let bitrateMbps = "bitrateMbps"
        static let captureCodec = "captureCodec"
        static let outputDirectoryPath = "outputDirectoryPath"
        static let statusBarFields = "statusBarFields"
        static let overlayStats = "overlayStats"
        static let remoteEnabled = "remoteEnabled"
        static let remotePort = "remotePort"
        static let remotePSK = "remotePSK"
        static let previewBrightness = "previewBrightness"
        static let previewContrast = "previewContrast"
        static let previewSaturation = "previewSaturation"
        static let previewHueDegrees = "previewHueDegrees"
        static let previewFilter = "previewFilter"
        static let visualEffectsEnabled = "visualEffectsEnabled"
    }

    private let defaults = UserDefaults.standard

    @Published var lastDeviceUniqueID: String? {
        didSet { defaults.set(lastDeviceUniqueID, forKey: Keys.lastDeviceUniqueID) }
    }

    @Published var lastAudioDeviceUniqueID: String? {
        didSet { defaults.set(lastAudioDeviceUniqueID, forKey: Keys.lastAudioDeviceUniqueID) }
    }

    @Published var rememberLastDevice: Bool {
        didSet { defaults.set(rememberLastDevice, forKey: Keys.rememberLastDevice) }
    }

    @Published var autoStartCapture: Bool {
        didSet { defaults.set(autoStartCapture, forKey: Keys.autoStartCapture) }
    }

    @Published var startMinimized: Bool {
        didSet { defaults.set(startMinimized, forKey: Keys.startMinimized) }
    }

    @Published var replayDuration: Double {
        didSet { defaults.set(replayDuration, forKey: Keys.replayDuration) }
    }

    @Published var maxReplayRAM: Int {
        didSet { defaults.set(maxReplayRAM, forKey: Keys.maxReplayRAM) }
    }

    @Published var bitrateMbps: Int {
        didSet { defaults.set(bitrateMbps, forKey: Keys.bitrateMbps) }
    }

    @Published var captureCodec: CaptureCodec {
        didSet { defaults.set(captureCodec.rawValue, forKey: Keys.captureCodec) }
    }

    @Published var outputDirectoryPath: String? {
        didSet { defaults.set(outputDirectoryPath, forKey: Keys.outputDirectoryPath) }
    }

    /// Which data fields to show as text in the menu bar next to the icon.
    @Published var statusBarFields: Set<StatusBarField> {
        didSet { defaults.set(statusBarFields.map(\.rawValue), forKey: Keys.statusBarFields) }
    }

    /// Which stats to show in the video overlay. All enabled by default.
    @Published var overlayStats: Set<OverlayStat> {
        didSet { defaults.set(overlayStats.map(\.rawValue), forKey: Keys.overlayStats) }
    }

    // MARK: - Remote control

    /// Whether the remote web server should run (and auto-start on launch).
    @Published var remoteEnabled: Bool {
        didSet { defaults.set(remoteEnabled, forKey: Keys.remoteEnabled) }
    }

    /// Preferred TCP port for the remote web server.
    @Published var remotePort: Int {
        didSet { defaults.set(remotePort, forKey: Keys.remotePort) }
    }

    /// Pre-shared key embedded in the remote URL. Generated once and kept stable
    /// so installed PWAs keep working across sessions.
    @Published var remotePSK: String {
        didSet { defaults.set(remotePSK, forKey: Keys.remotePSK) }
    }

    // MARK: - Preview adjustments

    @Published var previewBrightness: Double {
        didSet { defaults.set(previewBrightness, forKey: Keys.previewBrightness) }
    }

    @Published var previewContrast: Double {
        didSet { defaults.set(previewContrast, forKey: Keys.previewContrast) }
    }

    @Published var previewSaturation: Double {
        didSet { defaults.set(previewSaturation, forKey: Keys.previewSaturation) }
    }

    @Published var previewHueDegrees: Double {
        didSet { defaults.set(previewHueDegrees, forKey: Keys.previewHueDegrees) }
    }

    @Published var previewFilter: VideoFilter {
        didSet { defaults.set(previewFilter.rawValue, forKey: Keys.previewFilter) }
    }

    /// Master toggle. When false, every visual effect is bypassed — preview AND
    /// the encode pipeline run on the raw camera buffer, so no per-frame CI work
    /// happens. Adjustments + filter selection are remembered while disabled.
    @Published var visualEffectsEnabled: Bool {
        didSet { defaults.set(visualEffectsEnabled, forKey: Keys.visualEffectsEnabled) }
    }

    /// Convenience accessor that bundles the four adjustment knobs.
    var previewAdjustments: VideoAdjustments {
        VideoAdjustments(
            brightness: previewBrightness,
            contrast: previewContrast,
            saturation: previewSaturation,
            hueDegrees: previewHueDegrees
        )
    }

    /// True when an actual render pass is required — used to short-circuit the
    /// CIFilter chain when nothing would change.
    var effectsActive: Bool {
        visualEffectsEnabled && (!previewAdjustments.isNeutral || previewFilter != .none)
    }

    func resetPreviewAdjustments() {
        previewBrightness = 0
        previewContrast = 1
        previewSaturation = 1
        previewHueDegrees = 0
    }

    /// Generate a URL-safe, human-friendly pre-shared key (no ambiguous chars).
    static func generatePSK(length: Int = 12) -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789abcdefghijkmnpqrstuvwxyz")
        var key = ""
        for _ in 0..<length {
            key.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return key
    }

    var outputDirectory: URL {
        if let path = outputDirectoryPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Recorder.defaultOutputDir()
    }

    init() {
        self.lastDeviceUniqueID = defaults.string(forKey: Keys.lastDeviceUniqueID)
        self.lastAudioDeviceUniqueID = defaults.string(forKey: Keys.lastAudioDeviceUniqueID)
        self.rememberLastDevice = defaults.object(forKey: Keys.rememberLastDevice) as? Bool ?? true
        self.autoStartCapture = defaults.object(forKey: Keys.autoStartCapture) as? Bool ?? true
        self.startMinimized = defaults.object(forKey: Keys.startMinimized) as? Bool ?? false
        self.replayDuration = defaults.object(forKey: Keys.replayDuration) as? Double ?? 30
        self.maxReplayRAM = defaults.object(forKey: Keys.maxReplayRAM) as? Int ?? 0
        self.bitrateMbps = defaults.object(forKey: Keys.bitrateMbps) as? Int ?? 20
        if let raw = defaults.string(forKey: Keys.captureCodec),
           let codec = CaptureCodec(rawValue: raw) {
            self.captureCodec = codec
        } else {
            self.captureCodec = .h264
        }
        self.outputDirectoryPath = defaults.string(forKey: Keys.outputDirectoryPath)

        if let saved = defaults.stringArray(forKey: Keys.statusBarFields) {
            self.statusBarFields = Set(saved.compactMap { StatusBarField(rawValue: $0) })
        } else {
            self.statusBarFields = []
        }

        if let saved = defaults.stringArray(forKey: Keys.overlayStats) {
            self.overlayStats = Set(saved.compactMap { OverlayStat(rawValue: $0) })
        } else {
            // All enabled by default
            self.overlayStats = Set(OverlayStat.allCases)
        }

        self.remoteEnabled = defaults.object(forKey: Keys.remoteEnabled) as? Bool ?? false
        self.remotePort = defaults.object(forKey: Keys.remotePort) as? Int ?? 8723
        if let saved = defaults.string(forKey: Keys.remotePSK), !saved.isEmpty {
            self.remotePSK = saved
        } else {
            let generated = AppSettings.generatePSK()
            self.remotePSK = generated
            defaults.set(generated, forKey: Keys.remotePSK)
        }

        self.previewBrightness = defaults.object(forKey: Keys.previewBrightness) as? Double ?? 0
        self.previewContrast = defaults.object(forKey: Keys.previewContrast) as? Double ?? 1
        self.previewSaturation = defaults.object(forKey: Keys.previewSaturation) as? Double ?? 1
        self.previewHueDegrees = defaults.object(forKey: Keys.previewHueDegrees) as? Double ?? 0
        if let raw = defaults.string(forKey: Keys.previewFilter),
           let filter = VideoFilter(rawValue: raw) {
            self.previewFilter = filter
        } else {
            self.previewFilter = .none
        }
        self.visualEffectsEnabled = defaults.object(forKey: Keys.visualEffectsEnabled) as? Bool ?? true
    }
}
