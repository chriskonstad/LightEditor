import EditorCore
import SwiftUI

/// Formats recipe values the way Lightroom users expect to read them.
enum ValueFormat {
    static func format(_ key: ParamKey, _ value: Double, defaults: PhotoDefaults) -> String {
        switch key {
        case .temperature: return "\(Int(value.rounded())) K"
        case .exposure: return signed(value, decimals: 2)
        case .noiseReduction, .colorNoise, .sharpness, .detail, .gradeBlending, .vignetteMidpoint, .grainAmount, .grainSize:
            return "\(Int(value.rounded()))"
        default: return signed(value, decimals: 0)
        }
    }

    static func signed(_ value: Double, decimals: Int) -> String {
        let rounded = (value * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        let text = String(format: "%.\(decimals)f", abs(rounded))
        if rounded > 0 { return "+" + text }
        if rounded < 0 { return "−" + text }
        return text
    }
}

/// Maps a parameter's range onto a 0...1 slider track. Temperature is logarithmic
/// so the useful daylight range isn't crammed into a sliver.
enum SliderScale {
    static func position(_ key: ParamKey, value: Double) -> Double {
        guard let range = ParamCatalog.spec(for: key)?.range else { return 0 }
        if key == .temperature {
            return log(value / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    static func value(_ key: ParamKey, position: Double) -> Double {
        guard let range = ParamCatalog.spec(for: key)?.range else { return 0 }
        let p = min(max(position, 0), 1)
        if key == .temperature {
            return (range.lowerBound * pow(range.upperBound / range.lowerBound, p)).rounded()
        }
        var value = range.lowerBound + p * (range.upperBound - range.lowerBound)
        // Snap near the default so it's easy to return to zero.
        if let fixed = ParamCatalog.spec(for: key)?.fixedDefault, abs(value - fixed) < (range.upperBound - range.lowerBound) * 0.006 {
            value = fixed
        }
        return key == .exposure ? (value * 100).rounded() / 100 : value.rounded()
    }
}

/// A labeled fine slider bound to one recipe parameter. Double-tap to reset; press
/// and hold to see the photo without it.
struct ParamSlider: View {
    let model: EditorModel
    let key: ParamKey
    var label: String?
    var trackTint: Color = Theme.accent

    var body: some View {
        let spec = ParamCatalog.spec(for: key)
        let title = label ?? spec?.label ?? key.rawValue
        let value = model.value(key)
        let edited = model.recipe[key] != nil
        let formatted = ValueFormat.format(key, value, defaults: model.defaults)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .foregroundStyle(edited ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                Text(formatted)
                    .valueStyle()
                    .foregroundStyle(edited ? Theme.accent : Theme.textSecondary)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.reset(key) }

            FineSlider(
                position: SliderScale.position(key, value: value),
                origin: SliderScale.position(key, value: model.defaults.value(for: key)),
                tint: trackTint,
                onChange: { model.setLive(key, SliderScale.value(key, position: $0)) },
                onEditingChanged: { editing in if !editing { model.commit(key) } },
                onReset: { model.reset(key) },
                onHold: { holding in
                    // HSL sliders show their band's colors instead of hiding the value.
                    if let band = HueBand.allCases.first(where: { band in HSLComponent.allCases.contains { .hsl(band, $0) == key } }) {
                        model.hslSelection = holding ? band : nil
                    } else {
                        model.setHidden([key], hidden: holding, label: title)
                    }
                }
            )
            .accessibilityLabel(title)
            .accessibilityValue(formatted)
            .accessibilityIdentifier("slider.\(key.rawValue)")
        }
    }
}

/// A section header with an optional reset button for the group.
struct PanelHeader: View {
    let title: String
    var model: EditorModel?
    var group: PasteGroup?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if let model, let group, model.hasEdits(group) {
                // With earlier edits, offer going back to them as well as to the defaults.
                if model.canReturnToOpened(group) {
                    Menu("Reset") {
                        Button("Back to when opened", systemImage: "clock.arrow.circlepath") { model.returnToOpened(group) }
                        Button("Reset to defaults", systemImage: "arrow.counterclockwise") { model.reset(group: group) }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityIdentifier("reset.\(group.rawValue)")
                } else {
                    Button("Reset") { model.reset(group: group) }
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reset.\(group.rawValue)")
                }
            }
        }
        .padding(.top, 8)
    }
}
