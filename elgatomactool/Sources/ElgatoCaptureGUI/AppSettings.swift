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

    private enum Keys {
        static let lastDeviceUniqueID = "lastDeviceUniqueID"
        static let rememberLastDevice = "rememberLastDevice"
        static let autoStartCapture = "autoStartCapture"
        static let startMinimized = "startMinimized"
        static let replayDuration = "replayDuration"
        static let maxReplayRAM = "maxReplayRAM"
        static let bitrateMbps = "bitrateMbps"
        static let outputDirectoryPath = "outputDirectoryPath"
        static let statusBarFields = "statusBarFields"
    }

    private let defaults = UserDefaults.standard

    @Published var lastDeviceUniqueID: String? {
        didSet { defaults.set(lastDeviceUniqueID, forKey: Keys.lastDeviceUniqueID) }
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

    @Published var outputDirectoryPath: String? {
        didSet { defaults.set(outputDirectoryPath, forKey: Keys.outputDirectoryPath) }
    }

    /// Which data fields to show as text in the menu bar next to the icon.
    @Published var statusBarFields: Set<StatusBarField> {
        didSet { defaults.set(statusBarFields.map(\.rawValue), forKey: Keys.statusBarFields) }
    }

    var outputDirectory: URL {
        if let path = outputDirectoryPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Recorder.defaultOutputDir()
    }

    init() {
        self.lastDeviceUniqueID = defaults.string(forKey: Keys.lastDeviceUniqueID)
        self.rememberLastDevice = defaults.object(forKey: Keys.rememberLastDevice) as? Bool ?? true
        self.autoStartCapture = defaults.object(forKey: Keys.autoStartCapture) as? Bool ?? true
        self.startMinimized = defaults.object(forKey: Keys.startMinimized) as? Bool ?? false
        self.replayDuration = defaults.object(forKey: Keys.replayDuration) as? Double ?? 30
        self.maxReplayRAM = defaults.object(forKey: Keys.maxReplayRAM) as? Int ?? 0
        self.bitrateMbps = defaults.object(forKey: Keys.bitrateMbps) as? Int ?? 20
        self.outputDirectoryPath = defaults.string(forKey: Keys.outputDirectoryPath)

        if let saved = defaults.stringArray(forKey: Keys.statusBarFields) {
            self.statusBarFields = Set(saved.compactMap { StatusBarField(rawValue: $0) })
        } else {
            self.statusBarFields = []
        }
    }
}
