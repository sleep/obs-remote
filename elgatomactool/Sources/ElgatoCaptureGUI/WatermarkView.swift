import SwiftUI

/// Repeating diagonal "stc" pattern that fills the letterbox/pillarbox bars around the video,
/// with a periodic glisten sweep.
struct WatermarkView: View {

    @State private var shimmerOffset: CGFloat = -0.3
    @State private var shimmerOpacity: Double = 0

    private let cycleInterval: TimeInterval = 15
    private let angle: Double = -30
    private let baseOpacity: Double = 0.07
    private let fontSize: CGFloat = 12
    private let gridX: CGFloat = 72
    private let gridY: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            Canvas { context, canvasSize in
                drawPattern(context: &context, size: canvasSize, highlight: false)
            }

            // Shimmer: brighter copy of the pattern masked by a moving diagonal band
            Canvas { context, canvasSize in
                drawPattern(context: &context, size: canvasSize, highlight: true)
            }
            .mask(
                GeometryReader { _ in
                    let bandWidth = size.width * 0.45
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white.opacity(0.2),
                                    .white.opacity(0.7),
                                    .white.opacity(0.2),
                                    .clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: bandWidth, height: size.height * 2)
                        .rotationEffect(.degrees(angle))
                        .offset(
                            x: shimmerOffset * (size.width + bandWidth) - bandWidth / 2,
                            y: 0
                        )
                        .opacity(shimmerOpacity)
                }
            )
        }
        .allowsHitTesting(false)
        .clipped()
        .onAppear { scheduleGlisten(delay: 5) }
    }

    // MARK: - Pattern drawing

    private func drawPattern(context: inout GraphicsContext, size: CGSize, highlight: Bool) {
        let opacity = highlight ? 0.13 : baseOpacity
        let resolved = context.resolve(
            Text("stc")
                .font(.custom("Courier", fixedSize: fontSize))
                .fontWeight(.semibold)
                .foregroundColor(.white.opacity(opacity))
        )

        // We need to cover the full area after rotation, so draw a larger grid
        let diagonal = sqrt(size.width * size.width + size.height * size.height)
        let cols = Int(diagonal / gridX) + 4
        let rows = Int(diagonal / gridY) + 4

        // Rotate around center
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: .degrees(angle))
        context.translateBy(x: -diagonal / 2, y: -diagonal / 2)

        for row in 0..<rows {
            // Brick-pattern offset: even rows shifted right by half a cell
            let rowOffset: CGFloat = row.isMultiple(of: 2) ? 0 : gridX * 0.5
            for col in 0..<cols {
                let x = CGFloat(col) * gridX + rowOffset
                let y = CGFloat(row) * gridY
                context.draw(resolved, at: CGPoint(x: x, y: y))
            }
        }
    }

    // MARK: - Glisten animation

    private func scheduleGlisten(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            runGlisten()
        }
    }

    private func runGlisten() {
        shimmerOffset = -0.3

        // Gentle fade in
        withAnimation(.easeIn(duration: 1.0)) {
            shimmerOpacity = 1
        }

        // Slow sweep across
        withAnimation(.linear(duration: 4.0)) {
            shimmerOffset = 1.3
        }

        // Long, soft fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation(.easeOut(duration: 1.5)) {
                shimmerOpacity = 0
            }
        }

        scheduleGlisten(delay: cycleInterval)
    }
}
