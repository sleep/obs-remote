import SwiftUI
import AVFoundation
import CoreImage

/// NSViewRepresentable that wraps AVCaptureVideoPreviewLayer for zero-cost GPU-composited preview.
struct CapturePreviewView: NSViewRepresentable {

    let session: AVCaptureSession
    let adjustments: VideoAdjustments
    let filter: VideoFilter

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.session = session
        view.setVideoFilters(VideoFilterChain.buildFilters(adjustments: adjustments, filter: filter))
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.session = session
        nsView.setVideoFilters(VideoFilterChain.buildFilters(adjustments: adjustments, filter: filter))
    }
}

final class PreviewNSView: NSView {

    private var previewLayer: AVCaptureVideoPreviewLayer?

    var session: AVCaptureSession? {
        didSet {
            guard session !== oldValue else { return }
            setupPreviewLayer()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    private func setupPreviewLayer() {
        previewLayer?.removeFromSuperlayer()
        revealTimer?.invalidate()

        guard let session else { return }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // Start hidden to avoid showing the green artifact from the first corrupt frame
        preview.opacity = 0
        preview.filters = pendingFilters.isEmpty ? nil : pendingFilters
        layer?.addSublayer(preview)
        self.previewLayer = preview

        // Reveal after a short delay so the device has time to produce clean frames
        revealTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.previewLayer?.opacity = 1
            }
        }
    }

    private var revealTimer: Timer?

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    /// Applies the filters to the live preview layer, or stashes them until a
    /// layer is created (filters can arrive in makeNSView before the session is
    /// bound, and setupPreviewLayer recreates the layer when the session swaps).
    func setVideoFilters(_ filters: [CIFilter]) {
        pendingFilters = filters
        guard let previewLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.filters = filters.isEmpty ? nil : filters
        CATransaction.commit()
    }

    private var pendingFilters: [CIFilter] = []
}
