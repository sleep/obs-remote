import SwiftUI
import CaptureCore

/// The video preview surface itself: pixel buffer when capturing, live AVCaptureSession
/// during preview-only, otherwise a placeholder. Observes only RecordingVM (for the
/// capturing/previewing flags) and DeviceVM (for the placeholder text). The engine is
/// passed by reference and is not reactive.
struct CaptureVideoView: View {
    let engine: CaptureEngine
    @ObservedObject var recording: RecordingVM
    @ObservedObject var devices: DeviceVM

    var body: some View {
        if recording.isCapturing {
            PixelBufferDisplayView(engine: engine)
                .aspectRatio(16/9, contentMode: .fit)
        } else if recording.isPreviewing {
            CapturePreviewView(session: engine.captureSession)
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
}
