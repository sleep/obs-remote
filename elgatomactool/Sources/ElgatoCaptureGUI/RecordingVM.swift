import SwiftUI
import CaptureCore

/// Recording/capture-state sub-VM: preview/capture/record flags, recording timer
/// state, user-facing status + error messages, bitrate + codec selection.
/// Side-effects of bitrate/codec changes (engine calls, settings persistence,
/// async codec swap) are wired in by the parent CaptureViewModel via the
/// callback hooks below.
@MainActor
final class RecordingVM: ObservableObject {

    @Published var isPreviewing: Bool = false
    @Published var isCapturing: Bool = false
    @Published var isRecording: Bool = false

    @Published var recordingStartDate: Date?
    @Published var recordingDuration: TimeInterval = 0

    @Published var statusMessage: String = ""
    @Published var errorMessage: String?

    @Published var bitrateMbps: Int = 20 {
        didSet { bitrateChanged?(bitrateMbps) }
    }
    @Published var captureCodec: CaptureCodec = .h264 {
        didSet {
            guard captureCodec != oldValue else { return }
            captureCodecChanged?(captureCodec)
        }
    }

    // Callbacks installed by CaptureViewModel.
    var bitrateChanged: ((Int) -> Void)?
    var captureCodecChanged: ((CaptureCodec) -> Void)?
}
