import SwiftUI

struct LogoView: View {
    let size: CGFloat

    // Color palette
    private static let hotPink = Color(red: 1.0, green: 0.43, blue: 0.78)
    private static let purple = Color(red: 0.61, green: 0.35, blue: 0.71)
    private static let cyan = Color(red: 0.0, green: 0.96, blue: 1.0)
    private static let sunOrange = Color(red: 1.0, green: 0.65, blue: 0.0)
    private static let darkBg = Color(red: 0.05, green: 0.02, blue: 0.1)

    var body: some View {
        VStack(spacing: size * 0.12) {
            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                let cornerRadius = w * 0.12
                let cardRect = CGRect(origin: .zero, size: canvasSize)
                let roundedPath = Path(roundedRect: cardRect, cornerRadius: cornerRadius)

                // -- Clipped interior --
                context.drawLayer { clipped in
                    clipped.clip(to: roundedPath)

                    // 1. Dark background
                    clipped.fill(Path(cardRect), with: .color(Self.darkBg))

                    // 2. Radial glow behind sun
                    let horizonY = h * 0.45
                    let glowCenter = CGPoint(x: w / 2, y: horizonY)
                    let glowRect = CGRect(
                        x: w * 0.15, y: horizonY - h * 0.35,
                        width: w * 0.7, height: h * 0.5
                    )
                    clipped.fill(
                        Path(ellipseIn: glowRect),
                        with: .radialGradient(
                            Gradient(colors: [
                                Self.hotPink.opacity(0.35),
                                Self.purple.opacity(0.15),
                                .clear
                            ]),
                            center: glowCenter,
                            startRadius: 0,
                            endRadius: w * 0.4
                        )
                    )

                    // 3. Retro sun — banded half-circle above horizon
                    let sunRadius = w * 0.22
                    let sunCenter = CGPoint(x: w / 2, y: horizonY)
                    let sunGradient = Gradient(colors: [
                        Color(red: 1.0, green: 0.43, blue: 0.78),
                        Color(red: 1.0, green: 0.55, blue: 0.3),
                        Color(red: 1.0, green: 0.65, blue: 0.0)
                    ])

                    // Draw sun as 5 horizontal bands with gaps
                    let bandCount = 5
                    for band in 0..<bandCount {
                        let t0 = Double(band) / Double(bandCount)
                        let t1 = Double(band + 1) / Double(bandCount)

                        // Gap increases toward bottom (wider gaps for lower bands)
                        let gapFraction = 0.02 + Double(band) * 0.025
                        let bandTop = horizonY - sunRadius * (1.0 - t0)
                        let bandBottom = horizonY - sunRadius * (1.0 - t1) - sunRadius * gapFraction

                        guard bandTop < bandBottom + sunRadius * 0.01 else { continue }

                        // Clip band to circle
                        var bandPath = Path()
                        let steps = 40
                        // Top arc
                        for s in 0...steps {
                            let x = w / 2 - sunRadius + CGFloat(s) / CGFloat(steps) * sunRadius * 2
                            let dx = x - sunCenter.x
                            let maxDx = sqrt(max(sunRadius * sunRadius - 0, 0))
                            guard abs(dx) <= maxDx else { continue }
                            let circleY = sunCenter.y - sqrt(max(sunRadius * sunRadius - dx * dx, 0))
                            let y = max(circleY, bandTop)
                            if y > bandBottom { continue }
                            if bandPath.isEmpty {
                                bandPath.move(to: CGPoint(x: x, y: max(y, bandTop)))
                            } else {
                                bandPath.addLine(to: CGPoint(x: x, y: max(y, bandTop)))
                            }
                        }
                        // Bottom arc (reverse)
                        for s in stride(from: steps, through: 0, by: -1) {
                            let x = w / 2 - sunRadius + CGFloat(s) / CGFloat(steps) * sunRadius * 2
                            let dx = x - sunCenter.x
                            guard abs(dx) <= sqrt(sunRadius * sunRadius) else { continue }
                            let circleY = sunCenter.y - sqrt(max(sunRadius * sunRadius - dx * dx, 0))
                            if circleY > bandBottom { continue }
                            bandPath.addLine(to: CGPoint(x: x, y: bandBottom))
                        }
                        bandPath.closeSubpath()

                        clipped.fill(
                            bandPath,
                            with: .linearGradient(
                                sunGradient,
                                startPoint: CGPoint(x: w / 2, y: horizonY - sunRadius),
                                endPoint: CGPoint(x: w / 2, y: horizonY)
                            )
                        )
                    }

                    // 4. Horizon line
                    var horizonLine = Path()
                    horizonLine.move(to: CGPoint(x: 0, y: horizonY))
                    horizonLine.addLine(to: CGPoint(x: w, y: horizonY))
                    clipped.stroke(horizonLine, with: .color(Self.cyan.opacity(0.8)), lineWidth: 1.5)

                    // 5. Perspective grid — vertical lines converging to vanishing point
                    let vanishingPoint = CGPoint(x: w / 2, y: horizonY)
                    let verticalLineCount = 13
                    for i in 0..<verticalLineCount {
                        let t = CGFloat(i) / CGFloat(verticalLineCount - 1)
                        let bottomX = t * w
                        let distFromCenter = abs(t - 0.5) * 2 // 0 at center, 1 at edge
                        let opacity = max(0.1, 0.5 - distFromCenter * 0.4)

                        var line = Path()
                        line.move(to: vanishingPoint)
                        line.addLine(to: CGPoint(x: bottomX, y: h))
                        clipped.stroke(
                            line,
                            with: .color(Self.cyan.opacity(opacity)),
                            lineWidth: 0.8
                        )
                    }

                    // 6. Perspective grid — horizontal lines with pow spacing
                    let horizLineCount = 8
                    for i in 1...horizLineCount {
                        let t = pow(CGFloat(i) / CGFloat(horizLineCount), 2.0)
                        let y = horizonY + t * (h - horizonY)
                        let opacity = max(0.1, t * 0.6)

                        // Compute left and right x at this y by interpolating from vanishing point
                        let progress = (y - horizonY) / (h - horizonY)
                        let leftX = w / 2 - progress * (w / 2)
                        let rightX = w / 2 + progress * (w / 2)

                        var line = Path()
                        line.move(to: CGPoint(x: leftX, y: y))
                        line.addLine(to: CGPoint(x: rightX, y: y))
                        clipped.stroke(
                            line,
                            with: .color(Self.cyan.opacity(opacity)),
                            lineWidth: 0.8
                        )
                    }
                }

                // -- Outline stroke (unclipped) --
                context.stroke(
                    roundedPath,
                    with: .linearGradient(
                        Gradient(colors: [Self.hotPink, Self.purple, Self.cyan]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: w, y: h)
                    ),
                    lineWidth: 2
                )
            }
            .frame(width: size, height: size)

            // Title text
            Text("ELGATO CAPTURE")
                .font(.system(size: size * 0.08, weight: .bold, design: .monospaced))
                .tracking(size * 0.04)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Self.hotPink, Self.cyan],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}
