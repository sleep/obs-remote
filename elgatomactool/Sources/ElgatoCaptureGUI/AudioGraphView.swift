import SwiftUI

/// A compact audio level meter with a horizontal bar and history graph.
/// The bar shows the current peak level with green/yellow/red coloring.
/// The graph plots dB history (values in -60…0 range).
struct AudioGraphView: View {
    let level: Double       // current RMS (linear 0–1)
    let peak: Double        // current peak (linear 0–1)
    let history: [Double]   // dB values (-60…0)

    private let barWidth: CGFloat = 100
    private let barHeight: CGFloat = 6
    private let graphWidth: CGFloat = 120
    private let graphHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Label + dB readout
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(peak > 0.01 ? .green : .secondary)
                Text(dbString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 40, alignment: .trailing)
            }

            // Level bar
            AudioLevelBar(level: peak, width: barWidth, height: barHeight)

            // History graph
            AudioHistoryGraph(data: history, width: graphWidth, height: graphHeight)
        }
    }

    private var dbString: String {
        if peak < 0.0001 { return "-inf" }
        let db = 20 * log10(peak)
        return String(format: "%.0fdB", max(db, -60))
    }
}

/// Horizontal level bar with green → yellow → red gradient.
struct AudioLevelBar: View {
    let level: Double  // linear 0–1
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            // Background track
            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2)
            context.fill(bg, with: .color(.white.opacity(0.1)))

            guard level > 0.001 else { return }

            // Filled portion
            let fillWidth = min(CGFloat(level), 1.0) * size.width
            let fillRect = CGRect(x: 0, y: 0, width: fillWidth, height: size.height)
            let fillPath = Path(roundedRect: fillRect, cornerRadius: height / 2)

            // Color based on level
            let color: Color = level > 0.9 ? .red : level > 0.5 ? .yellow : .green
            context.fill(fillPath, with: .color(color))

            // Gradient overlay for depth
            let gradient = Gradient(colors: [color.opacity(0.9), color.opacity(0.6)])
            context.fill(fillPath, with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
        .frame(width: width, height: height)
    }
}

/// Canvas-based audio history graph showing dB levels over time.
struct AudioHistoryGraph: View {
    let data: [Double]  // dB values, -60…0
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            guard data.count >= 2 else { return }

            let minDB: Double = -60
            let maxDB: Double = 0

            // Draw dB reference lines
            for db in stride(from: -48.0, through: -12.0, by: 12.0) {
                let y = (1 - (db - minDB) / (maxDB - minDB)) * Double(size.height)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: Double(size.width), y: y))
                context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
            }

            // Build the level path
            var linePath = Path()
            for (i, val) in data.enumerated() {
                let clamped = max(min(val, maxDB), minDB)
                let x = CGFloat(i) / CGFloat(data.count - 1) * size.width
                let y = (1 - (clamped - minDB) / (maxDB - minDB)) * size.height
                if i == 0 { linePath.move(to: CGPoint(x: x, y: y)) }
                else { linePath.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Fill under the curve
            var fillPath = linePath
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()

            // Gradient fill: green at bottom, yellow in middle, red at top
            let gradient = Gradient(colors: [
                .green.opacity(0.4),
                .yellow.opacity(0.3),
                .red.opacity(0.2),
            ])
            context.fill(fillPath, with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: size.height),
                endPoint: CGPoint(x: 0, y: 0)
            ))

            // Stroke the line
            context.stroke(linePath, with: .color(.green.opacity(0.8)), lineWidth: 1)
        }
        .frame(width: width, height: height)
    }
}
