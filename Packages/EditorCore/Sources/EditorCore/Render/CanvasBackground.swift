import CoreGraphics
import CoreImage

/// The color around the photo in the editor. A viewing preference, kept per
/// device in the app's settings: it is never part of a recipe or an export.
public enum CanvasBackground: String, CaseIterable, Identifiable, Sendable {
    case black
    /// The editor's own ground, the default.
    case dark
    case darkGray
    /// Neutral 18% gray (linear), for judging exposure against a known middle tone.
    case midGray
    case lightGray
    case white

    /// The `UserDefaults` key the app stores the choice under.
    public static let defaultsKey = "canvasBackground"
    public static let `default` = CanvasBackground.dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .black: "Black"
        case .dark: "Dark"
        case .darkGray: "Dark gray"
        case .midGray: "Mid gray (18%)"
        case .lightGray: "Light gray"
        case .white: "White"
        }
    }

    /// The color as 8-bit sRGB, shared by SwiftUI and the Metal canvas so they match.
    public var srgbHex: UInt32 {
        switch self {
        case .black: 0x000000
        case .dark: 0x0E0F11
        case .darkGray: 0x333333
        // 118/255 encodes 0.181 in linear light.
        case .midGray: 0x767676
        case .lightGray: 0xBDBDBD
        case .white: 0xFFFFFF
        }
    }

    /// Red, green and blue in 0...1, sRGB-encoded.
    public var srgbComponents: (red: Double, green: Double, blue: Double) {
        let hex = srgbHex
        return (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    public var ciColor: CIColor {
        let c = srgbComponents
        return CIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }
}
