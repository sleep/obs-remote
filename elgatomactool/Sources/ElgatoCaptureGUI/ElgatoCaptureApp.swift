import SwiftUI
import AppKit

@main
struct ElgatoCaptureApp: App {

    // SPM executables don't get a .app bundle, so NSApplication defaults to
    // .prohibited activation policy (no dock icon, no windows). Fix that here.
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 620)
    }
}
