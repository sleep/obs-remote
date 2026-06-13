import SwiftUI
import CaptureCore

/// Replay buffer + replay-action sub-VM: buffer stats, replay duration/RAM
/// settings, thumbnails, save/screenshot feedback. didSet side-effects (engine
/// limit updates, settings persistence, thumbnail trim) are wired in by the
/// parent CaptureViewModel via the callback hooks below.
@MainActor
final class ReplayBufferVM: ObservableObject {

    // Live buffer stats (updated by the parent VM's 1Hz timer)
    @Published var bufferDuration: Double = 0
    @Published var bufferFrameCount: Int = 0
    @Published var bufferSizeMB: Int = 0

    // User-configurable replay settings
    @Published var replayDuration: Double = 30 {
        didSet { replayDurationChanged?(replayDuration) }
    }
    @Published var customReplayDuration: String = "" // for custom entry
    @Published var maxReplayRAM: Int = 0 { // bytes, 0 = unlimited
        didSet { maxReplayRAMChanged?(maxReplayRAM) }
    }

    // Visual artefacts
    @Published var replayThumbnails: [ReplayThumbnail] = []

    // Action feedback
    @Published var replaySaveFeedback: ActionFeedback = .idle
    @Published var screenshotFeedback: ActionFeedback = .idle

    // Callbacks installed by CaptureViewModel.
    var replayDurationChanged: ((Double) -> Void)?
    var maxReplayRAMChanged: ((Int) -> Void)?
}
