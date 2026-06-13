import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    let settings = AppSettings()
    private(set) lazy var viewModel = CaptureViewModel(settings: settings)
    private(set) lazy var statusBarController = StatusBarController(viewModel: viewModel, settings: settings)
    private var didFinishSetup = false

    private lazy var appIcon: NSImage = AppIconRenderer.makeIcon()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Assign the dock icon as early as possible. Adding a SwiftUI Settings
        // scene initialises the dock tile before applicationDidFinishLaunching
        // fires, so a later assignment is silently ignored and the user sees the
        // generic executable placeholder.
        NSApp.applicationIconImage = appIcon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureSetup()
    }

    /// Called from both applicationDidFinishLaunching and the SwiftUI body
    /// to guarantee the status bar is created regardless of lifecycle timing.
    func ensureSetup() {
        guard !didFinishSetup else { return }
        didFinishSetup = true

        NSApp.setActivationPolicy(.regular)
        if settings.startMinimized {
            // Hide the auto-opened window without closing it — closing would
            // trip applicationShouldTerminateAfterLastWindowClosed and flip us
            // to .accessory, removing the dock icon.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.title != "" {
                    window.orderOut(nil)
                }
            }
        } else {
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // Reassert the icon after the activation policy change — switching to
        // .regular can reset the dock tile to the placeholder.
        NSApp.applicationIconImage = appIcon

        _ = statusBarController
        viewModel.autoConnectLastDevice()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar when window is closed
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}

@main
struct ElgatoCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private var settings: AppSettings { appDelegate.settings }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.viewModel)
                .environmentObject(appDelegate.settings)
                .onAppear { appDelegate.ensureSetup() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 620)
        .commands {
            CommandMenu("View") {
                ForEach(AppSettings.OverlayStat.allCases) { stat in
                    Toggle(stat.label, isOn: overlayStatBinding(for: stat))
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.viewModel)
        }
    }

    private func overlayStatBinding(for stat: AppSettings.OverlayStat) -> Binding<Bool> {
        Binding(
            get: { settings.overlayStats.contains(stat) },
            set: { enabled in
                if enabled {
                    settings.overlayStats.insert(stat)
                } else {
                    settings.overlayStats.remove(stat)
                }
            }
        )
    }
}
