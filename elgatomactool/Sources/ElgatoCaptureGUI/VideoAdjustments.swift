import Foundation
import CoreImage
import SwiftUI

/// User-tweakable colour adjustments applied to the live preview. Recording is
/// untouched — these are display-only and run as Core Image filters on the
/// preview layer.
struct VideoAdjustments: Equatable, Codable {
    var brightness: Double = 0      // -0.5 ... 0.5
    var contrast: Double = 1        // 0.5 ... 1.8
    var saturation: Double = 1      // 0 ... 2
    var hueDegrees: Double = 0      // -180 ... 180

    static let neutral = VideoAdjustments()

    var isNeutral: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && hueDegrees == 0
    }
}

/// Preset look-up filters layered on top of the user's adjustments.
enum VideoFilter: String, CaseIterable, Identifiable, Codable {
    case none
    case vibrant
    case punch
    case gameStream
    case purpleHaze
    case neonNight
    case vaporwave
    case cyberpunk
    case noir
    case sepia
    case coolBlue
    case warmSun
    case dreamy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .vibrant: return "Vibrant"
        case .punch: return "Punch"
        case .gameStream: return "Game Stream"
        case .purpleHaze: return "Purple Haze"
        case .neonNight: return "Neon Night"
        case .vaporwave: return "Vaporwave"
        case .cyberpunk: return "Cyberpunk"
        case .noir: return "Noir"
        case .sepia: return "Sepia"
        case .coolBlue: return "Cool Blue"
        case .warmSun: return "Warm Sun"
        case .dreamy: return "Dreamy"
        }
    }

    /// The colour shown in the filter chip — gives a visual hint of the look.
    var swatchColor: Color {
        switch self {
        case .none: return Color(white: 0.35)
        case .vibrant: return Color(red: 0.95, green: 0.55, blue: 0.20)
        case .punch: return Color(red: 0.95, green: 0.30, blue: 0.30)
        case .gameStream: return Color(red: 0.20, green: 0.85, blue: 0.55)
        case .purpleHaze: return Color(red: 0.65, green: 0.30, blue: 0.95)
        case .neonNight: return Color(red: 0.85, green: 0.20, blue: 1.00)
        case .vaporwave: return Color(red: 1.00, green: 0.45, blue: 0.85)
        case .cyberpunk: return Color(red: 0.40, green: 0.95, blue: 1.00)
        case .noir: return Color(white: 0.85)
        case .sepia: return Color(red: 0.75, green: 0.55, blue: 0.30)
        case .coolBlue: return Color(red: 0.30, green: 0.55, blue: 0.95)
        case .warmSun: return Color(red: 1.00, green: 0.75, blue: 0.30)
        case .dreamy: return Color(red: 0.95, green: 0.75, blue: 0.95)
        }
    }
}

// MARK: - Building the CIFilter chain

enum VideoFilterChain {

    /// Compose the user's manual adjustments and the preset filter into a Core
    /// Image filter array suitable for `CALayer.filters` on macOS.
    static func buildFilters(adjustments: VideoAdjustments, filter: VideoFilter) -> [CIFilter] {
        var stack: [CIFilter] = []

        // 1. User adjustments first — brightness/contrast/saturation via CIColorControls.
        if adjustments.brightness != 0 || adjustments.contrast != 1 || adjustments.saturation != 1 {
            let controls = CIFilter(name: "CIColorControls")!
            controls.setValue(adjustments.brightness, forKey: kCIInputBrightnessKey)
            controls.setValue(adjustments.contrast, forKey: kCIInputContrastKey)
            controls.setValue(adjustments.saturation, forKey: kCIInputSaturationKey)
            controls.name = "userControls"
            stack.append(controls)
        }
        if adjustments.hueDegrees != 0 {
            let hue = CIFilter(name: "CIHueAdjust")!
            hue.setValue(adjustments.hueDegrees * .pi / 180, forKey: kCIInputAngleKey)
            hue.name = "userHue"
            stack.append(hue)
        }

        // 2. Preset filter on top.
        stack.append(contentsOf: filtersForPreset(filter))

        return stack
    }

    private static func filtersForPreset(_ filter: VideoFilter) -> [CIFilter] {
        switch filter {
        case .none:
            return []

        case .vibrant:
            return [colorControls(brightness: 0, contrast: 1, saturation: 1.30)]

        case .punch:
            return [colorControls(brightness: 0.02, contrast: 1.15, saturation: 1.20)]

        case .gameStream:
            return [colorControls(brightness: 0.04, contrast: 1.18, saturation: 1.35)]

        case .purpleHaze:
            return [
                colorControls(brightness: 0, contrast: 1.05, saturation: 1.10),
                hueAdjust(degrees: 18),
                colorMatrix(
                    r: (1.05, 0.00, 0.15, 0),
                    g: (0.00, 0.90, 0.00, 0),
                    b: (0.10, 0.00, 1.10, 0)
                )
            ]

        case .neonNight:
            return [
                colorControls(brightness: -0.03, contrast: 1.35, saturation: 1.55),
                hueAdjust(degrees: -25),
                colorMatrix(
                    r: (1.10, 0.00, 0.10, 0),
                    g: (0.00, 0.85, 0.05, 0),
                    b: (0.05, 0.00, 1.20, 0)
                )
            ]

        case .vaporwave:
            return [
                colorControls(brightness: 0.03, contrast: 1.10, saturation: 1.25),
                hueAdjust(degrees: 35),
                colorMatrix(
                    r: (1.10, 0.05, 0.10, 0),
                    g: (0.00, 0.90, 0.10, 0),
                    b: (0.10, 0.05, 1.15, 0)
                )
            ]

        case .cyberpunk:
            return [
                colorControls(brightness: -0.02, contrast: 1.30, saturation: 1.45),
                hueAdjust(degrees: -15),
                colorMatrix(
                    r: (1.10, 0.00, 0.10, 0),
                    g: (0.00, 0.95, 0.05, 0),
                    b: (0.10, 0.05, 1.10, 0)
                )
            ]

        case .noir:
            return [colorControls(brightness: 0, contrast: 1.30, saturation: 0)]

        case .sepia:
            let sepia = CIFilter(name: "CISepiaTone")!
            sepia.setValue(0.85, forKey: kCIInputIntensityKey)
            sepia.name = "sepia"
            return [sepia]

        case .coolBlue:
            return [
                colorMatrix(
                    r: (0.90, 0.00, 0.05, 0),
                    g: (0.00, 0.98, 0.05, 0),
                    b: (0.05, 0.00, 1.10, 0)
                )
            ]

        case .warmSun:
            return [
                colorControls(brightness: 0.02, contrast: 1.05, saturation: 1.05),
                colorMatrix(
                    r: (1.10, 0.05, 0.00, 0),
                    g: (0.00, 1.00, 0.00, 0),
                    b: (0.00, 0.00, 0.90, 0)
                )
            ]

        case .dreamy:
            return [
                colorControls(brightness: 0.05, contrast: 0.95, saturation: 1.08),
                colorMatrix(
                    r: (1.05, 0.00, 0.05, 0),
                    g: (0.00, 1.00, 0.05, 0),
                    b: (0.05, 0.00, 1.05, 0)
                )
            ]
        }
    }

    // MARK: helpers

    private static func colorControls(brightness: Double, contrast: Double, saturation: Double) -> CIFilter {
        let f = CIFilter(name: "CIColorControls")!
        f.setValue(brightness, forKey: kCIInputBrightnessKey)
        f.setValue(contrast, forKey: kCIInputContrastKey)
        f.setValue(saturation, forKey: kCIInputSaturationKey)
        f.name = "controls-\(UUID().uuidString.prefix(8))"
        return f
    }

    private static func hueAdjust(degrees: Double) -> CIFilter {
        let f = CIFilter(name: "CIHueAdjust")!
        f.setValue(degrees * .pi / 180, forKey: kCIInputAngleKey)
        f.name = "hue-\(UUID().uuidString.prefix(8))"
        return f
    }

    /// Build a CIColorMatrix filter from per-channel mix vectors. Each tuple is
    /// (component-from-R, component-from-G, component-from-B, bias).
    private static func colorMatrix(
        r: (Double, Double, Double, Double),
        g: (Double, Double, Double, Double),
        b: (Double, Double, Double, Double)
    ) -> CIFilter {
        let f = CIFilter(name: "CIColorMatrix")!
        f.setValue(CIVector(x: CGFloat(r.0), y: CGFloat(r.1), z: CGFloat(r.2), w: 0), forKey: "inputRVector")
        f.setValue(CIVector(x: CGFloat(g.0), y: CGFloat(g.1), z: CGFloat(g.2), w: 0), forKey: "inputGVector")
        f.setValue(CIVector(x: CGFloat(b.0), y: CGFloat(b.1), z: CGFloat(b.2), w: 0), forKey: "inputBVector")
        f.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        f.setValue(CIVector(x: CGFloat(r.3), y: CGFloat(g.3), z: CGFloat(b.3), w: 0), forKey: "inputBiasVector")
        f.name = "matrix-\(UUID().uuidString.prefix(8))"
        return f
    }
}
