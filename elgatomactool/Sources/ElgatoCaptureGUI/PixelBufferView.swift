import SwiftUI
import AVFoundation
import CoreVideo
import IOSurface
import QuartzCore
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
        // CALayer.contents can be assigned off the main thread, but Core Animation
        // will otherwise try to implicit-animate the swap and emit thread warnings.
        // Frame this mutation in a CATransaction with actions disabled.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface.takeUnretainedValue()
        CATransaction.commit()
    }

    func resetFrameCount() {
        frameCount = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = nil
        CATransaction.commit()
    }
}

/// SwiftUI bridge that displays live frames from the capture engine during
/// capture. Visual effects are baked into the buffer upstream in CaptureEngine
/// (so display, encoder, and replay all match), so this view does NOT apply any
/// CALayer.filters — it would double-apply.
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
                // Called on the engine's video-output queue. Skip the main-queue hop —
                // CALayer.contents can be set off-main when wrapped in a CATransaction
                // with implicit actions disabled (see PixelBufferNSView.display).
                self?.view?.display(pixelBuffer)
            }
        }
    }
}
