import SwiftUI
import AVFoundation
import CaptureCore

/// Device sub-VM: tracks discovered devices + selection. The didSet handlers and
/// reconnect/state-machine logic live on the parent CaptureViewModel since they
/// need to drive the engine, recording state, and stats. This VM only owns the
/// @Published surface so views observing only "what's selected / what's available
/// / are we disconnected" can opt out of the 1Hz status churn.
@MainActor
final class DeviceVM: ObservableObject {

    // Video devices
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDevice: AVCaptureDevice? {
        didSet { selectedDeviceChanged?(oldValue, selectedDevice) }
    }

    // Audio devices
    @Published var availableAudioDevices: [AVCaptureDevice] = []
    @Published var selectedAudioDevice: AVCaptureDevice? {
        didSet { selectedAudioDeviceChanged?(oldValue, selectedAudioDevice) }
    }

    @Published var audioPassthroughEnabled: Bool = false {
        didSet { audioPassthroughChanged?(audioPassthroughEnabled) }
    }

    @Published var cameraAuthorized: Bool = false
    @Published var deviceDisconnected: Bool = false

    // Callbacks installed by CaptureViewModel — the didSet side-effects (engine
    // calls, settings persistence, preview restart) live there, not here.
    var selectedDeviceChanged: ((AVCaptureDevice?, AVCaptureDevice?) -> Void)?
    var selectedAudioDeviceChanged: ((AVCaptureDevice?, AVCaptureDevice?) -> Void)?
    var audioPassthroughChanged: ((Bool) -> Void)?
}
