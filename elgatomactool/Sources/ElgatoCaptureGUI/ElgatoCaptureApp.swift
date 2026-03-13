import SwiftUI

@main
struct ElgatoCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 620)
    }
}
