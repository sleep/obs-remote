import AppKit
import AVFoundation
import CaptureCore

/// NSWindow subclass that displays the live capture preview and handles keyboard shortcuts.
final class PreviewWindow: NSWindow {

    private let engine: CaptureEngine
    private weak var statusField: NSTextField?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var statusTimer: Timer?

    init(engine: CaptureEngine) {
        self.engine = engine

        let frame = NSRect(x: 0, y: 0, width: 960, height: 540) // Half of 1080p
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.title = "Elgato Capture"
        self.minSize = NSSize(width: 480, height: 270)
        self.isReleasedWhenClosed = false
        self.center()
        self.contentAspectRatio = NSSize(width: 16, height: 9)

        setupPreviewLayer()
        setupStatusOverlay()
        setupKeyHandling()
    }

    // MARK: - Setup

    private func setupPreviewLayer() {
        let contentView = NSView(frame: self.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        self.contentView = contentView

        let preview = AVCaptureVideoPreviewLayer(session: engine.captureSession)
        preview.videoGravity = .resizeAspect
        preview.frame = contentView.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView.layer?.addSublayer(preview)
        self.previewLayer = preview
    }

    private func setupStatusOverlay() {
        guard let contentView = self.contentView else { return }

        let field = NSTextField(labelWithString: "")
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .white
        field.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        field.isBezeled = false
        field.isEditable = false
        field.drawsBackground = true
        field.alignment = .left
        field.translatesAutoresizingMaskIntoConstraints = false

        // Rounded corners
        field.wantsLayer = true
        field.layer?.cornerRadius = 6

        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
        ])

        self.statusField = field
        updateStatus()

        // Update status every second
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }

        engine.onStateChange = { [weak self] in
            self?.updateStatus()
        }
    }

    private func setupKeyHandling() {
        // We handle keyDown in the window itself
    }

    // MARK: - Key handling

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            engine.toggleRecording()
            flashStatus(engine.recorder.isRecording ? "RECORDING" : "STOPPED")

        case "s":
            engine.takeScreenshot()
            flashStatus("SCREENSHOT SAVED")

        case " ":
            engine.saveReplay()
            flashStatus("SAVING REPLAY...")

        case "q":
            NSApp.terminate(nil)

        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Status display

    func updateStatus() {
        let stats = engine.replayBuffer.stats
        let recording = engine.recorder.isRecording

        var parts: [String] = []
        parts.append(recording ? "● REC" : "○ IDLE")
        parts.append("BUF: \(String(format: "%.0fs", stats.duration))")
        parts.append("\(stats.frameCount) frames")
        parts.append("\(stats.bytes / 1_048_576)MB")

        statusField?.stringValue = " " + parts.joined(separator: "  |  ") + " "
    }

    func flashStatus(_ text: String) {
        statusField?.stringValue = " \(text) "
        statusField?.textColor = .systemYellow

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.statusField?.textColor = .white
            self?.updateStatus()
        }
    }

    /// Show initial help in the title bar
    func showHelp() {
        self.subtitle = "[R] Record  [S] Screenshot  [Space] Save Replay  [Q] Quit"
    }
}
