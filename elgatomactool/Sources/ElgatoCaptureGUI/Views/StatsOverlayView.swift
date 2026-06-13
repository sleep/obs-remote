import SwiftUI

/// In-preview stats overlay shown while capturing: audio graph (top-right), live
/// capture stats (bottom-left), and system stats (bottom-right). Observes StatsVM
/// and ReplayBufferVM (for buffer duration / size). The visibility per-stat is driven
/// by AppSettings which is passed in as the observed `settings`.
struct StatsOverlayView: View {
    @ObservedObject var stats: StatsVM
    @ObservedObject var replay: ReplayBufferVM
    @ObservedObject var settings: AppSettings

    private func showStat(_ stat: AppSettings.OverlayStat) -> Bool {
        settings.overlayStats.contains(stat)
    }

    var body: some View {
        VStack {
            Spacer()

            // Audio graph (above the bottom stats bar)
            if stats.hasAudio && showStat(.audio) {
                HStack {
                    Spacer()
                    AudioGraphView(
                        level: stats.audioLevel,
                        peak: stats.audioPeakLevel,
                        history: stats.audioHistory
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 8)
                }
            }

            HStack(alignment: .bottom) {
                let hasLeftStats = showStat(.resolution) || showStat(.fps) || showStat(.buffer) || showStat(.bitrate)
                if hasLeftStats {
                    HStack(spacing: 10) {
                        if showStat(.resolution), !stats.captureResolution.isEmpty {
                            Text(stats.captureResolution)
                        }
                        if showStat(.fps) {
                            HStack(spacing: 4) {
                                Text(String(format: "%.1ffps", stats.liveFPS))
                                    .foregroundStyle(stats.liveFPS >= 55 ? .white.opacity(0.8) :
                                                     stats.liveFPS >= 30 ? .yellow : .red)
                                MiniSparkline(
                                    data: stats.fpsHistory,
                                    color: stats.liveFPS >= 55 ? .green : stats.liveFPS >= 30 ? .yellow : .red,
                                    fixedMin: 0,
                                    fixedMax: max(stats.fpsHistory.max() ?? 60, 60)
                                )
                                if stats.droppedFrames > 0 {
                                    Text("\(stats.droppedFrames)drop")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        if showStat(.buffer) {
                            Text("BUF \(String(format: "%.0fs", replay.bufferDuration))")
                            Text("\(replay.bufferSizeMB)MB")
                        }
                        if showStat(.bitrate) {
                            Text(String(format: "%.1fMbps", stats.liveBitrateMbps))
                        }
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }

                Spacer()

                let hasRightStats = showStat(.cpu) || showStat(.gpu) || showStat(.ram) || showStat(.disk)
                if hasRightStats {
                    HStack(spacing: 10) {
                        if showStat(.cpu) {
                            StatWithSparkline(
                                label: "CPU",
                                value: String(format: "%.0f%%", stats.cpuPercent),
                                data: stats.cpuHistory,
                                color: .cyan,
                                fixedMin: 0
                            )
                        }
                        if showStat(.gpu) {
                            StatWithSparkline(
                                label: "GPU",
                                value: String(format: "%.0f%%", stats.gpuPercent),
                                data: stats.gpuHistory,
                                color: .purple,
                                fixedMin: 0
                            )
                        }
                        if showStat(.ram) {
                            StatWithSparkline(
                                label: "RAM",
                                value: ViewFormatters.formatRAM(stats.ramMB),
                                data: stats.ramHistory,
                                color: .green
                            )
                        }
                        if showStat(.disk) {
                            StatWithSparkline(
                                label: "DSK",
                                value: String(format: "%.0fG", stats.diskFreeGB),
                                data: stats.diskHistory,
                                color: .orange
                            )
                        }
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }
            }
        }
    }
}

/// Compact audio-graph-only overlay shown during preview (no full stats yet) when
/// an audio device is active. Observes only StatsVM.
struct PreviewAudioOverlayView: View {
    @ObservedObject var stats: StatsVM

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                AudioGraphView(
                    level: stats.audioLevel,
                    peak: stats.audioPeakLevel,
                    history: stats.audioHistory
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
            }
        }
    }
}
