import SwiftUI
import AVFoundation

/// NSViewRepresentable that wraps AVCaptureVideoPreviewLayer for zero-cost GPU-composited preview.
struct CapturePreviewView: NSViewRepresentable {

    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.session = session
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
}
