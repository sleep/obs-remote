import SwiftUI

/// A tiny sparkline graph drawn with Canvas for minimal overhead.
/// Updates only when `data` changes (driven by the 1s timer).
struct MiniSparkline: View {
    let data: [Double]
    let color: Color
    var fixedMin: Double? = nil
    var fixedMax: Double? = nil

    private let graphWidth: CGFloat = 48
    private let graphHeight: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            guard data.count >= 2 else { return }

            let lo = fixedMin ?? (data.min() ?? 0)
            let hi = fixedMax ?? (data.max() ?? 1)
            let range = max(hi - lo, 0.001)

            // Build line path
            var line = Path()
            for (i, val) in data.enumerated() {
                let x = CGFloat(i) / CGFloat(data.count - 1) * size.width
                let y = (1 - (val - lo) / range) * size.height
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else { line.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Fill under the line
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.2)))

            // Stroke the line
            context.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1)
        }
        .frame(width: graphWidth, height: graphHeight)
    }
}

/// A stat label with an inline sparkline.
struct StatWithSparkline: View {
    let label: String
    let value: String
    let data: [Double]
    let color: Color
    var fixedMin: Double? = nil
    var fixedMax: Double? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text("\(label) \(value)")
            MiniSparkline(data: data, color: color, fixedMin: fixedMin, fixedMax: fixedMax)
        }
    }
}
