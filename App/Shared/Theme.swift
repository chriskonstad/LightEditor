import SwiftUI

/// The editor's dark, neutral palette from UI-SPEC.
enum Theme {
    static let ground = Color(hex: 0x0E0F11)
    static let panel = Color(hex: 0x141518)
    static let panelRaised = Color(hex: 0x1A1B1F)
    static let divider = Color(hex: 0x23252A)
    static let textPrimary = Color(hex: 0xECECEC)
    static let textSecondary = Color(hex: 0x9DA1A8)
    static let accent = Color(hex: 0xE8A33D)
    static let onAccent = Color(hex: 0x1A1206)

    #if os(iOS)
    static let minTouch: CGFloat = 44
    #else
    static let minTouch: CGFloat = 28
    #endif
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension View {
    /// Tabular numerals for every value readout.
    func valueStyle() -> some View {
        font(.callout.monospacedDigit()).foregroundStyle(Theme.textSecondary)
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .frame(minHeight: Theme.minTouch)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}
