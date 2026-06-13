import SwiftUI

/// One saved-file toast. The kind drives the icon and label; the URL is what
/// the Open / Show-in-Finder buttons act on.
struct SaveToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case screenshot, replay, recording
    }
    let id = UUID()
    let url: URL
    let kind: Kind
    let sizeBytes: Int64

    var filename: String { url.lastPathComponent }

    var iconSystemName: String {
        switch kind {
        case .screenshot: return "camera.fill"
        case .replay: return "arrow.counterclockwise.circle.fill"
        case .recording: return "record.circle"
        }
    }

    var kindLabel: String {
        switch kind {
        case .screenshot: return "Screenshot saved"
        case .replay: return "Replay saved"
        case .recording: return "Recording saved"
        }
    }

    var tint: Color {
        switch kind {
        case .screenshot: return .green
        case .replay: return .green
        case .recording: return .red
        }
    }
}

/// Holds the currently-visible save toast. Setting `current` to a new value
/// replaces any previous toast (last-wins, no stacking) and resets the 15s
/// dismissal timer.
@MainActor
final class ToastVM: ObservableObject {
    @Published private(set) var current: SaveToast?

    static let visibleDuration: TimeInterval = 15

    private var dismissTask: Task<Void, Never>?

    func show(_ toast: SaveToast) {
        dismissTask?.cancel()
        current = toast
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.current?.id == toast.id {
                    self.current = nil
                }
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}
