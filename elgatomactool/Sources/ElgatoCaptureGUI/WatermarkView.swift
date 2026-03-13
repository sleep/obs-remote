import SwiftUI

/// Repeating diagonal "stc" pattern that fills the letterbox/pillarbox bars around the video,
/// with a periodic tracer animation — ghost copies trail behind the drifting pattern
/// with staggered timing, fading opacity, and subtle hue shifts.
struct WatermarkView: View {

    @State private var tracerStart: Date?
    @State private var tracerOpacity: Double = 0

    private let cycleInterval: TimeInterval = 15
    private let angle: Double = -30
    private let baseOpacity: Double = 0.07
    private let fontSize: CGFloat = 12
    private let gridX: CGFloat = 72
    private let gridY: CGFloat = 30

    private let numGhosts = 6
    private let ghostDelay: Double = 0.12
    private let tracerDuration: Double = 5.0
    private let maxDrift: CGFloat = 60
    // 20° above horizontal — rightward with a slight upward float
    private let driftAngle: Double = -20 * .pi / 180

    // Ghost colors: oldest (0) → newest (5), subtle pastels
    private let ghostHues: [(hue: Double, saturation: Double)] = [
        (0.75, 0.35),  // Soft indigo
        (0.60, 0.30),  // Periwinkle blue
        (0.48, 0.28),  // Teal
        (0.33, 0.25),  // Sage green
        (0.15, 0.20),  // Warm amber
        (0.02, 0.12),  // Near-white with blush
    ]

    var body: some View {
        GeometryReader { _ in
            if let start = tracerStart {
                // Active state: TimelineView drives per-frame ghost drawing
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(start)

                    Canvas { context, canvasSize in
                        // Base pattern
                        drawPattern(context: &context, size: canvasSize, color: .white.opacity(baseOpacity))

                        // Ghost copies, oldest first (painter's order)
                        let driftX = cos(driftAngle) * maxDrift
                        let driftY = sin(driftAngle) * maxDrift

                        for i in 0..<numGhosts {
                            let ghostElapsed = elapsed - Double(i) * ghostDelay
                            guard ghostElapsed > 0 else { continue }

                            let rawProgress = min(ghostElapsed / tracerDuration, 1.0)
                            // Ease-out for natural deceleration
                            let progress = 1.0 - pow(1.0 - rawProgress, 2.0)

                            let offsetX = progress * driftX
                            let offsetY = progress * driftY

                            // Opacity: newest ghosts are brightest
                            let ageFactor = Double(numGhosts - i) / Double(numGhosts)
                            let opacity = (0.03 + 0.12 * pow(ageFactor, 1.5)) * tracerOpacity

                            let ghost = ghostHues[i]
                            let color = Color(hue: ghost.hue, saturation: ghost.saturation, brightness: 1.0, opacity: opacity)

                            context.drawLayer { ghostCtx in
                                ghostCtx.translateBy(x: offsetX, y: offsetY)
                                drawPattern(context: &ghostCtx, size: canvasSize, color: color)
                            }
                        }
                    }
                }
            } else {
                // Idle state: static canvas, no animation overhead
                Canvas { context, canvasSize in
                    drawPattern(context: &context, size: canvasSize, color: .white.opacity(baseOpacity))
                }
            }
        }
        .allowsHitTesting(false)
        .clipped()
        .onAppear { scheduleTracer(delay: 6) }
    }

    // MARK: - Pattern drawing

    private func drawPattern(context: inout GraphicsContext, size: CGSize, color: Color) {
        let resolved = context.resolve(
            Text("stc")
                .font(.custom("Courier", fixedSize: fontSize))
                .fontWeight(.semibold)
                .foregroundColor(color)
        )

        // Cover the full area after rotation — draw a larger grid
        let diagonal = sqrt(size.width * size.width + size.height * size.height)
        let cols = Int(diagonal / gridX) + 4
        let rows = Int(diagonal / gridY) + 4

        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: .degrees(angle))
        context.translateBy(x: -diagonal / 2, y: -diagonal / 2)

        for row in 0..<rows {
            let rowOffset: CGFloat = row.isMultiple(of: 2) ? 0 : gridX * 0.5
            for col in 0..<cols {
                let x = CGFloat(col) * gridX + rowOffset
                let y = CGFloat(row) * gridY
                context.draw(resolved, at: CGPoint(x: x, y: y))
            }
        }
    }

    // MARK: - Tracer animation

    private func scheduleTracer(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            runTracer()
        }
    }

    private func runTracer() {
        // Activate TimelineView
        tracerStart = Date()

        // Fade in
        withAnimation(.easeIn(duration: 1.0)) {
            tracerOpacity = 1.0
        }

        // Total animation time: tracerDuration + all ghost delays + fade-out
        let totalActive = tracerDuration + ghostDelay * Double(numGhosts)

        // Fade out after the last ghost finishes
        DispatchQueue.main.asyncAfter(deadline: .now() + totalActive) {
            withAnimation(.easeOut(duration: 1.5)) {
                tracerOpacity = 0
            }
        }

        // Switch back to static canvas after fade-out completes
        DispatchQueue.main.asyncAfter(deadline: .now() + totalActive + 1.5) {
            tracerStart = nil
        }

        scheduleTracer(delay: cycleInterval)
    }
}
