import SwiftUI
import AVFoundation
import CoreVideo
import IOSurface
import CaptureCore

/// NSView that renders CVPixelBuffers directly via IOSurface — zero-copy, no preview layer.
/// This avoids macOS throttling AVCaptureSession when an AVCaptureVideoPreviewLayer is occluded.
final class PixelBufferNSView: NSView {

    /// Number of frames received — used to skip the first few potentially-corrupt frames.
    private var frameCount = 0
    private static let framesToSkip = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        // Skip the first few frames to avoid green artifacts from incomplete GOPs
        frameCount += 1
        guard frameCount > Self.framesToSkip else { return }

        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        layer?.contents = surface.takeUnretainedValue()
    }

    func resetFrameCount() {
        frameCount = 0
        layer?.contents = nil
    }
}

/// SwiftUI bridge that displays live frames from the capture engine during capture.
struct PixelBufferDisplayView: NSViewRepresentable {

    let engine: CaptureEngine

    func makeNSView(context: Context) -> PixelBufferNSView {
        let view = PixelBufferNSView()
        context.coordinator.view = view
        context.coordinator.startObserving(engine: engine)
        return view
    }

    func updateNSView(_ nsView: PixelBufferNSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.startObserving(engine: engine)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: PixelBufferNSView?
        private weak var currentEngine: CaptureEngine?

        func startObserving(engine: CaptureEngine) {
            guard engine !== currentEngine else { return }
            currentEngine = engine
            view?.resetFrameCount()
            engine.onFrameForDisplay = { [weak self] pixelBuffer in
                DispatchQueue.main.async {
                    self?.view?.display(pixelBuffer)
                }
            }
        }
    }
}
