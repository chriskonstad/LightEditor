import EditorCore
import SwiftUI

/// Colored slider tracks that show what moving the slider does: the hue a color
/// band turns toward, warmer or cooler, duller or more vivid, darker or lighter.
/// A slider whose effect has no clear color (Clarity, Grain, Border…) keeps the
/// plain accent fill. Used by `ParamSlider` and the mask sliders.
enum SliderTracks {
    static func gradient(for key: ParamKey) -> Gradient? {
        if let (band, component) = hsl(key) { return hslGradient(band, component) }
        switch key {
        case .temperature, .localTemperature: return temperature
        case .tint, .localTint: return tint
        case .saturation, .vibrance: return saturation
        case .exposure, .highlights, .shadows, .whites, .blacks: return tone
        default:
            if ToneRange.allCases.contains(where: { key == .gradeLuminance($0) }) { return tone }
            return nil
        }
    }

    /// Cooler (blue) to warmer (amber), as the photo changes. No neutral middle:
    /// the as-shot value, where the photo is unchanged, sits anywhere on the track.
    static let temperature = Gradient(colors: [Color(hue: 0.58, saturation: 0.65, brightness: 0.9), Color(hue: 0.13, saturation: 0.75, brightness: 0.95)])
    /// Green to magenta.
    static let tint = Gradient(colors: [Color(hue: 0.33, saturation: 0.6, brightness: 0.8), Color(white: 0.75), Color(hue: 0.86, saturation: 0.55, brightness: 0.9)])
    /// Gray on the left; past the middle the spectrum fades in, so the right end
    /// reads as "more color" rather than as one hue.
    static let saturation = Gradient(stops: [
        .init(color: Color(white: 0.5), location: 0),
        .init(color: Color(white: 0.62), location: 0.45),
        .init(color: Color(hue: 0.0, saturation: 0.75, brightness: 0.92), location: 0.62),
        .init(color: Color(hue: 0.13, saturation: 0.8, brightness: 0.95), location: 0.74),
        .init(color: Color(hue: 0.33, saturation: 0.75, brightness: 0.85), location: 0.86),
        .init(color: Color(hue: 0.58, saturation: 0.8, brightness: 0.95), location: 1),
    ])
    /// Darker to lighter. It stops short of black and white so the thumb stays visible.
    static let tone = Gradient(colors: [Color(white: 0.12), Color(white: 0.85)])

    /// Hue runs from the band's left neighbor through its own color to the right
    /// neighbor: the HSL kernel shifts a band about as far as the next band's center.
    /// Saturation runs from gray to the band's color, luminance from dark to light.
    static func hslGradient(_ band: HueBand, _ component: HSLComponent) -> Gradient {
        let hue = band.swatchHue
        let bands = HueBand.allCases
        let index = bands.firstIndex(of: band)!
        let previous = bands[(index + bands.count - 1) % bands.count].swatchHue
        let next = bands[(index + 1) % bands.count].swatchHue
        func color(_ degrees: Double, saturation: Double = 0.8, brightness: Double = 0.9) -> Color {
            Color(hue: (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360,
                  saturation: saturation, brightness: brightness)
        }
        switch component {
        case .hue:
            // Unwrap around red so the left neighbor sits below this hue and the right above.
            let left = previous > hue ? previous - 360 : previous
            let right = next < hue ? next + 360 : next
            return Gradient(colors: [color(left), color(hue), color(right)])
        case .saturation:
            return Gradient(colors: [Color(white: 0.55), color(hue)])
        case .luminance:
            return Gradient(colors: [color(hue, saturation: 0.85, brightness: 0.3), color(hue), color(hue, saturation: 0.35, brightness: 1)])
        }
    }

    private static func hsl(_ key: ParamKey) -> (HueBand, HSLComponent)? {
        for band in HueBand.allCases {
            for component in HSLComponent.allCases where key == .hsl(band, component) { return (band, component) }
        }
        return nil
    }
}
