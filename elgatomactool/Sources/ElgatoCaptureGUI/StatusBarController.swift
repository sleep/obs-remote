import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem
    private let viewModel: CaptureViewModel
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []
    private var updateTimer: Timer?

    // Cached status-dot icons. The dot only changes when state changes,
    // so we build these once and reuse them on every tick.
    private let idleDot: NSImage
    private let capturingDot: NSImage
    private let recordingDot: NSImage

    init(viewModel: CaptureViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.idleDot = StatusBarController.makeStatusDot(color: .systemGray)
        self.capturingDot = StatusBarController.makeStatusDot(color: .systemGreen)
        self.recordingDot = StatusBarController.makeStatusDot(color: .systemRed)
        super.init()

        updateStatusBar()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Update icon on state changes
        viewModel.recording.$isCapturing
            .combineLatest(viewModel.recording.$isRecording)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusBar() }
            .store(in: &cancellables)

        // Update when settings change which fields to show
        settings.$statusBarFields
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)

        // Periodic update for live data (FPS, buffer, CPU, etc.)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusBar() }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer

        print("[StatusBar] Created status bar item")
    }

    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Status bar rendering

    private func updateStatusBar() {
        guard let button = statusItem.button else { return }

        let circleImage: NSImage
        if viewModel.recording.isRecording {
            circleImage = recordingDot
        } else if viewModel.recording.isCapturing {
            circleImage = capturingDot
        } else {
            circleImage = idleDot
        }

        // Build the text portion from enabled fields
        let text = buildStatusText()

        if text.isEmpty {
            button.image = circleImage
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.image = circleImage
            button.title = " " + text
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
    }

    private static func makeStatusDot(color: NSColor) -> NSImage {
        let circleSize: CGFloat = 10
        let imageSize = NSSize(width: circleSize + 4, height: 18)
        let image = NSImage(size: imageSize, flipped: false) { _ in
            let circleRect = NSRect(x: 2, y: 4, width: circleSize, height: circleSize)
            color.setFill()
            NSBezierPath(ovalIn: circleRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func buildStatusText() -> String {
        let fields = settings.statusBarFields
        guard !fields.isEmpty else { return "" }

        // Ordered consistently by the enum's allCases order
        var parts: [String] = []
        for field in AppSettings.StatusBarField.allCases {
            guard fields.contains(field) else { continue }
            if let value = valueForField(field) {
                parts.append(value)
            }
        }
        return parts.joined(separator: "  ")
    }

    private func valueForField(_ field: AppSettings.StatusBarField) -> String? {
        switch field {
        case .device:
            return viewModel.devices.selectedDevice?.localizedName
        case .resolution:
            let r = viewModel.stats.captureResolution
            return r.isEmpty ? nil : r
        case .fps:
            guard viewModel.recording.isCapturing else { return nil }
            return String(format: "%.0ffps", viewModel.stats.liveFPS)
        case .buffer:
            guard viewModel.recording.isCapturing else { return nil }
            return String(format: "%.0fs/\(formatDuration(viewModel.replay.replayDuration))", viewModel.replay.bufferDuration)
        case .bufferMB:
            guard viewModel.recording.isCapturing else { return nil }
            return "\(viewModel.replay.bufferSizeMB)MB"
        case .cpu:
            guard viewModel.recording.isCapturing else { return nil }
            return String(format: "CPU %.0f%%", viewModel.stats.cpuPercent)
        case .gpu:
            guard viewModel.recording.isCapturing else { return nil }
            return String(format: "GPU %.0f%%", viewModel.stats.gpuPercent)
        case .ram:
            guard viewModel.recording.isCapturing else { return nil }
            let mb = viewModel.stats.ramMB
            if mb >= 1024 {
                return String(format: "RAM %.1fG", mb / 1024)
            }
            return String(format: "RAM %.0fM", mb)
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status info
        let statusText: String
        if viewModel.recording.isCapturing {
            let parts = [
                viewModel.stats.captureResolution,
                String(format: "%.0ffps", viewModel.stats.liveFPS),
                "Buffer \(String(format: "%.0fs", viewModel.replay.bufferDuration))/\(formatDuration(viewModel.replay.replayDuration))",
                "\(viewModel.replay.bufferSizeMB)MB"
            ].filter { !$0.isEmpty }
            statusText = parts.joined(separator: " | ")
        } else {
            statusText = "Not capturing"
        }
        let infoItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        menu.addItem(.separator())

        // Recording
        if viewModel.recording.isCapturing {
            let recTitle = viewModel.recording.isRecording ? "Stop Recording" : "Start Recording"
            let recItem = NSMenuItem(title: recTitle, action: #selector(toggleRecording), keyEquivalent: "r")
            recItem.target = self
            menu.addItem(recItem)

            let ssItem = NSMenuItem(title: "Take Screenshot", action: #selector(takeScreenshot), keyEquivalent: "s")
            ssItem.target = self
            menu.addItem(ssItem)

            // Save Replay submenu
            let replayMenu = NSMenu()
            for seconds in [15.0, 30.0, 60.0] {
                let item = NSMenuItem(title: "Last \(formatDuration(seconds))", action: #selector(saveReplayAction(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(seconds)
                replayMenu.addItem(item)
            }
            let fullItem = NSMenuItem(title: "Full Buffer", action: #selector(saveFullReplay), keyEquivalent: "")
            fullItem.target = self
            replayMenu.addItem(fullItem)

            let replayItem = NSMenuItem(title: "Save Replay", action: nil, keyEquivalent: "")
            replayItem.submenu = replayMenu
            menu.addItem(replayItem)

            menu.addItem(.separator())
        }

        // Open output folder
        let folderItem = NSMenuItem(title: "Open Output Folder", action: #selector(openOutputFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(.separator())

        // Show/Hide window
        let hasWindow = NSApp.windows.contains(where: { $0.isVisible && $0.title != "" })
        let windowTitle = hasWindow ? "Hide Window" : "Show Window"
        let windowItem = NSMenuItem(title: windowTitle, action: #selector(toggleWindow), keyEquivalent: "")
        windowItem.target = self
        menu.addItem(windowItem)

        let remoteItem = NSMenuItem(title: "Mobile Remote...", action: #selector(showRemote), keyEquivalent: "")
        remoteItem.target = self
        menu.addItem(remoteItem)

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Elgato Capture", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        Task { @MainActor in viewModel.toggleRecording() }
    }

    @objc private func takeScreenshot() {
        Task { @MainActor in viewModel.takeScreenshot() }
    }

    @objc private func saveReplayAction(_ sender: NSMenuItem) {
        let seconds = Double(sender.tag)
        Task { @MainActor in
            viewModel.engine.saveReplay(lastSeconds: seconds)
            viewModel.recording.statusMessage = "Saving replay..."
        }
    }

    @objc private func saveFullReplay() {
        Task { @MainActor in viewModel.saveReplay() }
    }

    @objc private func openOutputFolder() {
        Task { @MainActor in viewModel.openOutputFolder() }
    }

    @objc private func toggleWindow() {
        let hasVisibleWindow = NSApp.windows.contains(where: { $0.isVisible && $0.title != "" })
        if hasVisibleWindow {
            for window in NSApp.windows where window.isVisible && window.title != "" {
                window.close()
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            if let window = NSApp.windows.first(where: { $0.title != "" }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func showPreferences() {
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func showRemote() {
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let window = NSApp.windows.first(where: { $0.title != "" }) {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .showRemoteSheet, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds >= 60 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return secs > 0 ? "\(mins)m\(secs)s" : "\(mins)m"
        }
        return "\(Int(seconds))s"
    }
}

extension Notification.Name {
    static let showRemoteSheet = Notification.Name("showRemoteSheet")
}
