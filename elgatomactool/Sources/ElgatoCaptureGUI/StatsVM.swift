import SwiftUI
import CaptureCore

/// Stats sub-VM: system stats, FPS, dropped frames, bitrate, capture resolution,
/// and audio levels. Updated from the parent VM's 1Hz status timer.
@MainActor
final class StatsVM: ObservableObject {

    // Capture-side stats
    @Published var captureResolution: String = ""
    @Published var liveFPS: Double = 0
    @Published var droppedFrames: Int = 0
    @Published var fpsHistory: [Double] = []
    @Published var liveBitrateMbps: Double = 0

    // System stats
    @Published var cpuPercent: Double = 0
    @Published var ramMB: Double = 0
    @Published var diskFreeGB: Double = 0
    @Published var gpuPercent: Double = 0
    @Published var cpuHistory: [Double] = []
    @Published var ramHistory: [Double] = []
    @Published var diskHistory: [Double] = []
    @Published var gpuHistory: [Double] = []

    // Audio levels (linear 0–1)
    @Published var audioLevel: Double = 0
    @Published var audioPeakLevel: Double = 0
    @Published var audioHistory: [Double] = []
    @Published var hasAudio: Bool = false

    let systemStats = SystemStatsMonitor()
}
