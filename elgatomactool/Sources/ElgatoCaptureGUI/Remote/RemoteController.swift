import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CaptureCore
import Combine
import SwiftUI

/// Owns the remote web server lifecycle and bridges it to the capture view model.
/// Lives on the main actor; the networking layer hops here for state and dispatches
/// heavy image work off-main.
@MainActor
final class RemoteController: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var lanIP: String?
    @Published private(set) var qrImage: NSImage?
    @Published var lastError: String?

    private let viewModel: CaptureViewModel
    private let settings: AppSettings
    private var server: RemoteServer?

    /// Preloaded web assets (name -> bytes + content type). Captured by the server's
    /// asset closure so it can serve them from any thread without touching the actor.
    private let assets: [String: (Data, String)]
    private var iconCache: [Int: Data] = [:]
    private lazy var baseIcon: NSImage = AppIconRenderer.makeIcon()

    init(viewModel: CaptureViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
        self.assets = RemoteController.loadAssets()
    }

    /// The URL a phone should open, including the pre-shared key.
    var remoteURL: String? {
        guard isRunning, let host = lanIP else { return nil }
        return "http://\(host):\(port)/?k=\(settings.remotePSK)"
    }

    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }
        lastError = nil

        let psk = settings.remotePSK
        let assets = self.assets

        let routes = RemoteRoutes(
            validate: { presented in
                guard let presented else { return false }
                // Constant-time-ish comparison.
                return presented.count == psk.count && presented == psk
            },
            state: { [weak self] in
                await self?.stateJSON() ?? Data("{}".utf8)
            },
            preview: { [weak self] in
                await self?.previewJPEG()
            },
            action: { [weak self] body in
                await self?.handleAction(body) ?? Data("{\"ok\":false}".utf8)
            },
            settings: { [weak self] body in
                await self?.handleSettings(body) ?? Data("{\"ok\":false}".utf8)
            },
            icon: { [weak self] size in
                await self?.iconPNG(size: size)
            },
            asset: { name in
                guard let (data, type) = assets[name] else { return nil }
                return (data, type)
            }
        )

        let server = RemoteServer(routes: routes)
        server.onStateChange = { [weak self] running, port in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = running
                self.port = port
                if running {
                    // Remember the actually-bound port so an installed PWA keeps
                    // resolving to the same address on the next launch.
                    if port != 0 { self.settings.remotePort = Int(port) }
                    self.lanIP = RemoteController.primaryLANAddress()
                    self.refreshQR()
                } else {
                    self.qrImage = nil
                }
            }
        }

        do {
            try server.start(preferredPort: UInt16(settings.remotePort))
            self.server = server
        } catch {
            lastError = "Failed to start remote server: \(error.localizedDescription)"
            self.server = nil
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        port = 0
        qrImage = nil
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    /// Make a fresh pre-shared key and restart so the new key takes effect.
    func regeneratePSK() {
        settings.remotePSK = AppSettings.generatePSK()
        if isRunning {
            stop()
            start()
        } else {
            refreshQR()
        }
    }

    // MARK: - State snapshot

    private func stateJSON() -> Data {
        let vm = viewModel

        let devices = vm.devices.availableDevices.map { device -> [String: Any] in
            ["id": device.uniqueID,
             "name": device.localizedName,
             "selected": device.uniqueID == vm.devices.selectedDevice?.uniqueID]
        }
        let audioDevices = vm.devices.availableAudioDevices.map { device -> [String: Any] in
            ["id": device.uniqueID,
             "name": device.localizedName,
             "selected": device.uniqueID == vm.devices.selectedAudioDevice?.uniqueID]
        }

        func feedback(_ f: ActionFeedback) -> String {
            switch f {
            case .idle: return "idle"
            case .inProgress: return "inProgress"
            case .success: return "success"
            case .failed: return "failed"
            }
        }

        let snapshot: [String: Any] = [
            "capturing": vm.recording.isCapturing,
            "previewing": vm.recording.isPreviewing,
            "recording": vm.recording.isRecording,
            "recordingDuration": vm.recording.recordingDuration,
            "deviceDisconnected": vm.devices.deviceDisconnected,
            "cameraAuthorized": vm.devices.cameraAuthorized,
            "resolution": vm.stats.captureResolution,
            "fps": vm.stats.liveFPS,
            "droppedFrames": vm.stats.droppedFrames,
            "bitrate": vm.stats.liveBitrateMbps,
            "statusMessage": vm.recording.statusMessage,
            "errorMessage": vm.recording.errorMessage.map { $0 as Any } ?? NSNull(),
            "screenshotFeedback": feedback(vm.replay.screenshotFeedback),
            "replayFeedback": feedback(vm.replay.replaySaveFeedback),
            "passthrough": vm.devices.audioPassthroughEnabled,
            "hasAudio": vm.stats.hasAudio,
            "audio": ["level": vm.stats.audioLevel, "peak": vm.stats.audioPeakLevel],
            "buffer": ["duration": vm.replay.bufferDuration,
                       "frames": vm.replay.bufferFrameCount,
                       "sizeMB": vm.replay.bufferSizeMB],
            "system": ["cpu": vm.stats.cpuPercent,
                       "gpu": vm.stats.gpuPercent,
                       "ramMB": vm.stats.ramMB,
                       "diskFreeGB": vm.stats.diskFreeGB],
            "history": ["fps": Array(vm.stats.fpsHistory.suffix(60)),
                        "cpu": Array(vm.stats.cpuHistory.suffix(60)),
                        "gpu": Array(vm.stats.gpuHistory.suffix(60)),
                        "audio": Array(vm.stats.audioHistory.suffix(60))],
            "devices": devices,
            "audioDevices": audioDevices,
            "settings": [
                "bitrateMbps": vm.recording.bitrateMbps,
                "replayDuration": vm.replay.replayDuration,
                "maxReplayRAM": vm.replay.maxReplayRAM,
                "rememberLastDevice": settings.rememberLastDevice,
                "autoStartCapture": settings.autoStartCapture,
                "startMinimized": settings.startMinimized,
                "outputDirectory": settings.outputDirectory.path,
                "overlayStats": AppSettings.OverlayStat.allCases.map { $0.rawValue }
                    .filter { settings.overlayStats.contains(AppSettings.OverlayStat(rawValue: $0)!) },
                "statusBarFields": AppSettings.StatusBarField.allCases.map { $0.rawValue }
                    .filter { settings.statusBarFields.contains(AppSettings.StatusBarField(rawValue: $0)!) },
            ],
            "options": [
                "replayPresets": CaptureViewModel.replayPresets,
                "ramPresets": CaptureViewModel.ramPresets.map { ["label": $0.label, "bytes": $0.bytes] },
                "bitratePresets": [5, 10, 15, 20, 30, 40, 50],
                "overlayStats": AppSettings.OverlayStat.allCases.map { ["id": $0.rawValue, "label": $0.label] },
                "statusBarFields": AppSettings.StatusBarField.allCases.map { ["id": $0.rawValue, "label": $0.label] },
            ],
        ]

        return (try? JSONSerialization.data(withJSONObject: snapshot)) ?? Data("{}".utf8)
    }

    // MARK: - Preview JPEG

    private func previewJPEG() async -> Data? {
        let engine = viewModel.engine
        // createThumbnail is thread-safe; encode off the main actor.
        return await Task.detached(priority: .utility) {
            guard let cg = engine.createThumbnail(maxWidth: 720) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cg)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        }.value
    }

    // MARK: - Commands

    private func handleAction(_ body: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            return Data("{\"ok\":false,\"error\":\"bad request\"}".utf8)
        }

        let vm = viewModel
        switch cmd {
        case "start":
            vm.startCapture()
        case "stop":
            vm.stopCapture()
        case "record":
            vm.toggleRecording()
        case "screenshot":
            vm.takeScreenshot()
        case "replay":
            vm.saveReplay()
        case "refresh":
            vm.refreshDevices()
        case "passthrough":
            if let on = obj["on"] as? Bool { vm.devices.audioPassthroughEnabled = on }
        case "selectDevice":
            if let id = obj["id"] as? String,
               let device = vm.devices.availableDevices.first(where: { $0.uniqueID == id }) {
                vm.devices.selectedDevice = device
            }
        case "selectAudioDevice":
            if let id = obj["id"] as? String, id != "none",
               let device = vm.devices.availableAudioDevices.first(where: { $0.uniqueID == id }) {
                vm.devices.selectedAudioDevice = device
            } else {
                vm.devices.selectedAudioDevice = nil
            }
        default:
            return Data("{\"ok\":false,\"error\":\"unknown command\"}".utf8)
        }
        return Data("{\"ok\":true}".utf8)
    }

    private func handleSettings(_ body: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Data("{\"ok\":false,\"error\":\"bad request\"}".utf8)
        }

        let vm = viewModel
        if let v = obj["bitrateMbps"] as? Int { vm.recording.bitrateMbps = v }
        if let v = obj["replayDuration"] as? NSNumber { vm.replay.replayDuration = v.doubleValue }
        if let v = obj["maxReplayRAM"] as? Int { vm.replay.maxReplayRAM = v }
        if let v = obj["rememberLastDevice"] as? Bool { settings.rememberLastDevice = v }
        if let v = obj["autoStartCapture"] as? Bool { settings.autoStartCapture = v }
        if let v = obj["startMinimized"] as? Bool { settings.startMinimized = v }

        if let arr = obj["overlayStats"] as? [String] {
            settings.overlayStats = Set(arr.compactMap { AppSettings.OverlayStat(rawValue: $0) })
        }
        if let arr = obj["statusBarFields"] as? [String] {
            settings.statusBarFields = Set(arr.compactMap { AppSettings.StatusBarField(rawValue: $0) })
        }

        return Data("{\"ok\":true}".utf8)
    }

    // MARK: - Icon rendering

    private func iconPNG(size: Int) -> Data? {
        if let cached = iconCache[size] { return cached }
        let target = NSSize(width: size, height: size)
        let resized = NSImage(size: target)
        resized.lockFocus()
        baseIcon.draw(in: NSRect(origin: .zero, size: target),
                      from: .zero, operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        iconCache[size] = png
        return png
    }

    // MARK: - QR code

    private func refreshQR() {
        guard let urlString = remoteURL else { qrImage = nil; return }
        qrImage = RemoteController.makeQR(from: urlString)
    }

    static func makeQR(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale: CGFloat = 12
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    // MARK: - Asset loading

    private static func loadAssets() -> [String: (Data, String)] {
        let files: [(String, String)] = [
            ("index.html", "text/html; charset=utf-8"),
            ("app.css", "text/css; charset=utf-8"),
            ("app.js", "text/javascript; charset=utf-8"),
            ("sw.js", "text/javascript; charset=utf-8"),
        ]
        var result: [String: (Data, String)] = [:]
        for (name, type) in files {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            if let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "WebRoot")
                ?? Bundle.module.url(forResource: base, withExtension: ext),
               let data = try? Data(contentsOf: url) {
                result[name] = (data, type)
            }
        }
        return result
    }

    // MARK: - LAN address discovery

    /// Best-effort primary IPv4 address on a real LAN interface (Wi-Fi / Ethernet).
    static func primaryLANAddress() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var preferred: String?
        var fallback: String?

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let addr = current.pointee.ifa_addr
            if let addr, (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    let name = String(cString: current.pointee.ifa_name)
                    if name == "en0" || name == "en1" {
                        preferred = preferred ?? ip
                    } else if name.hasPrefix("en") {
                        fallback = fallback ?? ip
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        address = preferred ?? fallback
        return address
    }
}
