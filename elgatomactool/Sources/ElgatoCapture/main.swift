import AppKit
import AVFoundation
import CaptureCore

// MARK: - CLI argument parsing

let args = CommandLine.arguments

if args.contains("--help") || args.contains("-h") {
    print("""
    Elgato Capture — Hardware-accelerated 1080p60 capture tool

    USAGE:
      elgato-capture [OPTIONS]

    OPTIONS:
      --list-devices       List available capture devices and exit
      --replay-duration N  Replay buffer duration in seconds (default: 30)
      --bitrate N          Encoding bitrate in Mbps (default: 20)
      --output-dir PATH    Output directory (default: ~/Movies/ElgatoCapture)
      --help               Show this help

    KEYBOARD CONTROLS (in preview window):
      R                    Toggle recording
      S                    Save screenshot (PNG)
      Space                Save replay buffer (MP4)
      Q                    Quit

    OUTPUT:
      Files are saved to ~/Movies/ElgatoCapture/
        recording_2024-01-15_14-30-00.mp4
        replay_2024-01-15_14-30-00.mp4
        screenshot_2024-01-15_14-30-00.png

    PERFORMANCE NOTES:
      Uses Apple Silicon hardware encoder (VideoToolbox).
      Preview uses AVCaptureVideoPreviewLayer (GPU-composited, zero CPU cost).
      Capture format: NV12 (hardware pipeline native, no color conversion).
      Typical CPU usage on M2: < 5%
    """)
    exit(0)
}

if args.contains("--list-devices") {
    DeviceDiscovery.printDevices()
    exit(0)
}

func argValue(_ flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

let replayDuration = Double(argValue("--replay-duration") ?? "") ?? 30.0
let bitrateMbps = Int(argValue("--bitrate") ?? "") ?? 20

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: PreviewWindow?
    var engine: CaptureEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("===========================================")
        print("  Elgato Capture — 1080p60 Hardware Encoder")
        print("===========================================")
        print("")
        print("  Replay buffer: \(Int(replayDuration))s")
        print("  Bitrate: \(bitrateMbps) Mbps")
        print("  Output: ~/Movies/ElgatoCapture/")
        print("")

        let engine = CaptureEngine(replayDuration: replayDuration, bitrateMbps: bitrateMbps)
        self.engine = engine

        do {
            try engine.start()
        } catch {
            print("ERROR: \(error.localizedDescription)")
            print("")
            print("Troubleshooting:")
            print("  1. Make sure your Elgato is connected and recognized by macOS")
            print("  2. Run with --list-devices to see available devices")
            print("  3. Grant camera access in System Settings > Privacy > Camera")
            exit(1)
        }

        let window = PreviewWindow(engine: engine)
        window.showHelp()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        print("")
        print("Controls: [R] Record  [S] Screenshot  [Space] Save Replay  [Q] Quit")
        print("")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
        print("Goodbye.")
    }
}

// MARK: - Launch

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

// Activate the app (bring to front)
if #available(macOS 14.0, *) {
    app.activate()
} else {
    app.activate(ignoringOtherApps: true)
}

app.run()
