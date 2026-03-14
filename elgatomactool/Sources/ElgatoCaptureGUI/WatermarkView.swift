import SwiftUI

/// Repeating diagonal "stc" pattern that fills the letterbox/pillarbox bars around the video,
/// with a periodic tracer animation — a sweeping chromatic wave displaces individual text
/// elements, leaving rainbow-colored afterimage trails.
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
    private let ghostDelay: Double = 0.25
    private let tracerDuration: Double = 5.0
    private let sigma: CGFloat = 120
    private let maxShift: CGFloat = 25

    // Ghost colors: oldest trail (0) → leading edge (5)
    private let ghostHues: [(hue: Double, sat: Double)] = [
        (0.80, 0.55),  // Violet — oldest afterimage
        (0.65, 0.50),  // Blue
        (0.50, 0.45),  // Cyan
        (0.35, 0.40),  // Green
        (0.18, 0.35),  // Amber
        (0.00, 0.08),  // Near-white — leading edge
    ]

    var body: some View {
        GeometryReader { _ in
            if let start = tracerStart {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(start)

                    Canvas { context, canvasSize in
                        let diagonal = hypot(canvasSize.width, canvasSize.height)

                        // Base pattern (static, no displacement)
                        drawPattern(context: &context, size: canvasSize, color: .white.opacity(baseOpacity))

                        // Sweep parameters: wave crosses full canvas in tracerDuration
                        let sweepStart = -2.0 * sigma
                        let sweepRange = diagonal + 4.0 * sigma
                        let sweepSpeed = sweepRange / tracerDuration
                        let twoSigmaSq = 2.0 * sigma * sigma

                        // Ghost layers, oldest (back) → newest (front)
                        for i in 0..<numGhosts {
                            let delay = Double(numGhosts - 1 - i) * ghostDelay
                            let ghostElapsed = max(0, elapsed - delay)
                            let waveFront = sweepStart + sweepSpeed * ghostElapsed

                            let ageFactor = Double(i + 1) / Double(numGhosts)
                            let opacity = (0.06 + 0.29 * pow(ageFactor, 1.5)) * tracerOpacity

                            let ghost = ghostHues[i]
                            let color = Color(
                                hue: ghost.hue,
                                saturation: ghost.sat,
                                brightness: 1.0,
                                opacity: opacity
                            )

                            context.drawLayer { ghostCtx in
                                drawTracerPattern(
                                    context: &ghostCtx,
                                    size: canvasSize,
                                    color: color,
                                    waveFront: waveFront,
                                    twoSigmaSq: twoSigmaSq
                                )
                            }
                        }
                    }
                }
            } else {
                Canvas { context, canvasSize in
                    drawPattern(context: &context, size: canvasSize, color: .white.opacity(baseOpacity))
                }
            }
        }
        .allowsHitTesting(false)
        .clipped()
        // .onAppear { scheduleTracer(delay: 6) }
    }

    // MARK: - Pattern drawing

    /// Draws the static "stc" grid with no displacement.
    private func drawPattern(context: inout GraphicsContext, size: CGSize, color: Color) {
        let resolved = context.resolve(
            Text("stc")
                .font(.custom("Courier", fixedSize: fontSize))
                .fontWeight(.semibold)
                .foregroundColor(color)
        )

        let diagonal = hypot(size.width, size.height)
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

    /// Draws the "stc" grid with per-element gaussian displacement along the sweep axis.
    /// Elements near `waveFront` shift forward by up to `maxShift`; elements far away stay put.
    private func drawTracerPattern(
        context: inout GraphicsContext,
        size: CGSize,
        color: Color,
        waveFront: CGFloat,
        twoSigmaSq: CGFloat
    ) {
        let resolved = context.resolve(
            Text("stc")
                .font(.custom("Courier", fixedSize: fontSize))
                .fontWeight(.semibold)
                .foregroundColor(color)
        )

        let diagonal = hypot(size.width, size.height)
        let cols = Int(diagonal / gridX) + 4
        let rows = Int(diagonal / gridY) + 4

        // Transform into the rotated pattern space
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: .degrees(angle))
        context.translateBy(x: -diagonal / 2, y: -diagonal / 2)

        for row in 0..<rows {
            let rowOffset: CGFloat = row.isMultiple(of: 2) ? 0 : gridX * 0.5
            for col in 0..<cols {
                let x = CGFloat(col) * gridX + rowOffset
                let y = CGFloat(row) * gridY

                // Displacement along sweep direction (pattern x-axis)
                let d = x - waveFront
                let envelope = exp(-(d * d) / twoSigmaSq)
                let shiftX = envelope * maxShift

                context.draw(resolved, at: CGPoint(x: x + shiftX, y: y))
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
        tracerStart = Date()

        withAnimation(.easeIn(duration: 1.0)) {
            tracerOpacity = 1.0
        }

        // Wait for the last ghost to finish its sweep, then fade out
        let totalActive = tracerDuration + Double(numGhosts - 1) * ghostDelay

        DispatchQueue.main.asyncAfter(deadline: .now() + totalActive) {
            withAnimation(.easeOut(duration: 1.5)) {
                tracerOpacity = 0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + totalActive + 1.5) {
            tracerStart = nil
        }

        scheduleTracer(delay: cycleInterval)
    }
}
