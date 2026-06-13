import SwiftUI

/// "PREVIEW <resolution>" pill shown when previewing but not yet capturing.
/// Observes StatsVM (for resolution) — the visibility decision is made by the parent.
struct PreviewBadgeView: View {
    @ObservedObject var stats: StatsVM

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)
            Text("PREVIEW")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            if !stats.captureResolution.isEmpty {
                Text(stats.captureResolution)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.blue.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}
