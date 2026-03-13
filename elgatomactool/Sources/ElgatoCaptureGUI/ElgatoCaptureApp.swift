import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    let settings = AppSettings()
    private(set) lazy var viewModel = CaptureViewModel(settings: settings)
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if settings.startMinimized {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        statusBarController = StatusBarController(viewModel: viewModel, settings: settings)
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.viewModel)
                .environmentObject(appDelegate.settings)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 620)
    }
}
