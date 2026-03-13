import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem
    private let viewModel: CaptureViewModel
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: CaptureViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Elgato Capture")
            button.image?.isTemplate = false
            updateIcon()
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Observe state changes to update icon
        viewModel.$isCapturing
            .combineLatest(viewModel.$isRecording)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let tintColor: NSColor

        if viewModel.isRecording {
            symbolName = "circle.fill"
            tintColor = .systemRed
        } else if viewModel.isCapturing {
            symbolName = "circle.fill"
            tintColor = .systemGreen
        } else {
            symbolName = "circle.fill"
            tintColor = .systemGray
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let configured = image.withSymbolConfiguration(config) ?? image
            button.image = configured
            button.contentTintColor = tintColor
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status info
        let statusText: String
        if viewModel.isCapturing {
            let parts = [
                viewModel.captureResolution,
                String(format: "%.0ffps", viewModel.liveFPS),
                "Buffer \(String(format: "%.0fs", viewModel.bufferDuration))/\(formatDuration(viewModel.replayDuration))",
                "\(viewModel.bufferSizeMB)MB"
            ].filter { !$0.isEmpty }
            statusText = parts.joined(separator: " | ")
        } else {
            statusText = "Not capturing"
        }
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // Recording
        if viewModel.isCapturing {
            let recTitle = viewModel.isRecording ? "Stop Recording" : "Start Recording"
            let recItem = NSMenuItem(title: recTitle, action: #selector(toggleRecording), keyEquivalent: "r")
            recItem.target = self
            menu.addItem(recItem)

            // Screenshot
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

        // Preferences
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        // Quit
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
            viewModel.statusMessage = "Saving replay..."
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
            // Open a new window if none exist
            if let window = NSApp.windows.first(where: { $0.title != "" }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func showPreferences() {
        // Bring the app to front and show the main window — settings is a sheet on it
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let window = NSApp.windows.first(where: { $0.title != "" }) {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .showSettingsSheet, object: nil)
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
    static let showSettingsSheet = Notification.Name("showSettingsSheet")
}
