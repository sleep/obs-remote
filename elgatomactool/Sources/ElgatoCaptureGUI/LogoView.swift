import AppKit

/// Generates a vaporwave-styled NSImage for the dock icon using Core Graphics.
enum AppIconRenderer {

    static func makeIcon() -> NSImage {
        let pt: CGFloat = 512
        let px = 1024
        let scale: CGFloat = 2

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4 * px, bitsPerPixel: 32
        ) else {
            return NSImage(size: NSSize(width: pt, height: pt))
        }
        rep.size = NSSize(width: pt, height: pt)

        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: NSSize(width: pt, height: pt))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx

        let ctx = gctx.cgContext
        ctx.scaleBy(x: scale, y: scale)

        // CG origin is bottom-left. Flip to top-left for our drawing math.
        ctx.translateBy(x: 0, y: pt)
        ctx.scaleBy(x: 1, y: -1)

        drawIcon(ctx: ctx, size: pt)

        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: pt, height: pt))
        img.addRepresentation(rep)
        return img
    }

    // MARK: - Drawing

    private static func drawIcon(ctx: CGContext, size: CGFloat) {
        let w = size, h = size
        let cr: CGFloat = w * 0.22
        let horizonY = h * 0.45
        let sunR = w * 0.22
        let cx = w / 2

        let cardRect = CGRect(x: 0, y: 0, width: w, height: h)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cr, cornerHeight: cr, transform: nil)

        // --- Clipped interior ---
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()

        // Background
        ctx.setFillColor(rgb(0.05, 0.02, 0.1))
        ctx.fill(cardRect)

        // Radial glow
        if let grad = radialGrad([rgba(1, 0.43, 0.78, 0.4), rgba(0.61, 0.35, 0.71, 0.15), rgba(0, 0, 0, 0)]) {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: w * 0.1, y: horizonY - h * 0.4, width: w * 0.8, height: h * 0.6))
            ctx.clip()
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: cx, y: horizonY), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: horizonY), endRadius: w * 0.45,
                                   options: .drawsAfterEndLocation)
            ctx.restoreGState()
        }

        // Sun bands
        let sunGrad = linearGrad([rgb(1, 0.43, 0.78), rgb(1, 0.55, 0.3), rgb(1, 0.65, 0)])
        for band in 0..<5 {
            let t0 = CGFloat(band) / 5
            let t1 = CGFloat(band + 1) / 5
            let gap: CGFloat = 0.02 + CGFloat(band) * 0.03
            let top = horizonY - sunR * (1 - t0)
            let bot = horizonY - sunR * (1 - t1) + sunR * gap
            guard top < bot else { continue }

            let path = CGMutablePath()
            var started = false
            let n = 80
            // Forward sweep: top edge clipped to circle
            for s in 0...n {
                let x = cx - sunR + CGFloat(s) / CGFloat(n) * sunR * 2
                let dx = x - cx
                guard abs(dx) <= sunR else { continue }
                let cy = horizonY - sqrt(sunR * sunR - dx * dx)
                let y = max(cy, top)
                guard y <= bot else { continue }
                if !started { path.move(to: CGPoint(x: x, y: y)); started = true }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            // Reverse sweep: bottom edge
            for s in stride(from: n, through: 0, by: -1) {
                let x = cx - sunR + CGFloat(s) / CGFloat(n) * sunR * 2
                let dx = x - cx
                guard abs(dx) <= sunR else { continue }
                let cy = horizonY - sqrt(sunR * sunR - dx * dx)
                guard cy <= bot else { continue }
                path.addLine(to: CGPoint(x: x, y: bot))
            }
            path.closeSubpath()

            if let g = sunGrad {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                ctx.drawLinearGradient(g,
                    start: CGPoint(x: cx, y: horizonY - sunR),
                    end: CGPoint(x: cx, y: horizonY), options: [])
                ctx.restoreGState()
            }
        }

        // Horizon line
        ctx.setStrokeColor(rgba(0, 0.96, 1, 0.9))
        ctx.setLineWidth(w * 0.012)
        ctx.move(to: CGPoint(x: 0, y: horizonY))
        ctx.addLine(to: CGPoint(x: w, y: horizonY))
        ctx.strokePath()

        // Vertical grid lines converging to vanishing point
        let vp = CGPoint(x: cx, y: horizonY)
        for i in 0..<13 {
            let t = CGFloat(i) / 12
            let bx = t * w
            let d = abs(t - 0.5) * 2
            ctx.setStrokeColor(rgba(0, 0.96, 1, max(0.08, 0.45 - d * 0.4)))
            ctx.setLineWidth(w * 0.006)
            ctx.move(to: vp)
            ctx.addLine(to: CGPoint(x: bx, y: h))
            ctx.strokePath()
        }

        // Horizontal grid lines with perspective spacing
        for i in 1...8 {
            let t = pow(CGFloat(i) / 8, 2)
            let y = horizonY + t * (h - horizonY)
            let prog = (y - horizonY) / (h - horizonY)
            let lx = cx - prog * cx
            let rx = cx + prog * cx
            ctx.setStrokeColor(rgba(0, 0.96, 1, max(0.08, t * 0.55)))
            ctx.setLineWidth(w * 0.006)
            ctx.move(to: CGPoint(x: lx, y: y))
            ctx.addLine(to: CGPoint(x: rx, y: y))
            ctx.strokePath()
        }

        ctx.restoreGState() // end card clip

        // --- Gradient outline (unclipped) ---
        if let g = linearGrad([rgb(1, 0.43, 0.78), rgb(0.61, 0.35, 0.71), rgb(0, 0.96, 1)]) {
            ctx.saveGState()
            ctx.setLineWidth(w * 0.025)
            ctx.addPath(cardPath)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
            ctx.restoreGState()
        }
    }

    // MARK: - Color helpers

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    private static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func linearGrad(_ colors: [CGColor]) -> CGGradient? {
        let n = colors.count
        let locs = (0..<n).map { CGFloat($0) / CGFloat(n - 1) }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: locs)
    }

    private static func radialGrad(_ colors: [CGColor]) -> CGGradient? {
        let n = colors.count
        let locs = (0..<n).map { CGFloat($0) / CGFloat(n - 1) }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: locs)
    }
}
