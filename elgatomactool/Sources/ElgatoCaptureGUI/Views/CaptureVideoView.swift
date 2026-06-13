import SwiftUI
import CaptureCore

/// The video preview surface itself: pixel buffer when capturing, live AVCaptureSession
/// during preview-only, otherwise a placeholder. Observes only RecordingVM (for the
/// capturing/previewing flags) and DeviceVM (for the placeholder text). The engine is
/// passed by reference and is not reactive.
///
/// Visual-effect routing:
/// - During capture: effects are baked into the buffer in CaptureEngine, so
///   PixelBufferDisplayView shows the already-filtered frame. No CALayer
///   filters here — would double-apply.
/// - During preview-only: AVCaptureVideoPreviewLayer renders direct from the
///   session and bypasses the engine's data callback, so we apply effects via
///   CALayer.filters when the master toggle is on.
struct CaptureVideoView: View {
    let engine: CaptureEngine
    @ObservedObject var recording: RecordingVM
    @ObservedObject var devices: DeviceVM
    @ObservedObject var settings: AppSettings

    var body: some View {
        if recording.isCapturing {
            PixelBufferDisplayView(engine: engine)
                .aspectRatio(16/9, contentMode: .fit)
        } else if recording.isPreviewing {
            CapturePreviewView(
                session: engine.captureSession,
                adjustments: previewAdjustments,
                filter: previewFilter
            )
            .aspectRatio(16/9, contentMode: .fit)
        } else {
            Rectangle()
                .fill(.black)
                .aspectRatio(16/9, contentMode: .fit)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(devices.availableDevices.isEmpty
                             ? "No capture devices found"
                             : "Select a device to preview")
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }

    /// Adjustments for the preview-only path — neutralised when the master
    /// toggle is off so the AVCaptureVideoPreviewLayer renders the raw feed.
    private var previewAdjustments: VideoAdjustments {
        settings.visualEffectsEnabled ? settings.previewAdjustments : .neutral
    }

    private var previewFilter: VideoFilter {
        settings.visualEffectsEnabled ? settings.previewFilter : .none
    }
}
