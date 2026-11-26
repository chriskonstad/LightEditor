import EditorCore
import SwiftUI

/// The Grade tab's color wheels, in two states:
///
/// - **Overview:** all four wheels, small. Drag one for a quick change; tap it (or
///   its name) to open it.
/// - **Open:** one wheel, large, beside (or above) Hue, Saturation and Luminance
///   sliders bound to the same values, with the sliders' usual fine adjustment.
///   Chips switch wheels without closing; "All wheels" (or Escape) goes back.
///
/// The large wheel makes drags finer by itself, and every wheel slows down under
/// slow drags (`FineAdjust.WheelTracker`), so quick drags are coarse and deliberate
/// ones precise. The sliders are for exact values.
struct GradeWheelsSection: View {
    let model: EditorModel
    @State private var open: ToneRange?
    /// The hue each wheel last had. Display state only: a neutral wheel renders the
    /// same whatever its hue, but its Hue slider shouldn't snap back to red.
    @State private var hueMemory: [ToneRange: Double] = [:]
    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        Group {
            if let open {
                openWheel(open)
            } else {
                overview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Overview

    private var overviewColumns: Int { width >= 560 ? 4 : 2 }

    private var overview: some View {
        let columns = overviewColumns
        let diameter = columns == 4 ? min(max(width / 4 - 24, 96), 150) : 118
        return VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: columns), spacing: 12) {
                ForEach(ToneRange.allCases) { range in
                    ColorWheel(model: model, range: range, diameter: diameter, onOpen: { show(range) })
                }
            }
            Text("Drag a wheel for a quick change. Tap one to fine-tune it.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    // MARK: One wheel open

    /// Beside the sliders where the panel is short (iPhone) or wide (iPad portrait);
    /// above them in a tall, narrow inspector (iPad landscape, Mac), and at
    /// accessibility text sizes, where the slider labels need the full width.
    private var sideBySide: Bool {
        if dynamicTypeSize.isAccessibilitySize { return false }
        #if os(iOS)
        if sizeClass == .compact { return true }
        #endif
        return width >= 560
    }

    private func openWheel(_ range: ToneRange) -> some View {
        let side = sideBySide
        let diameter = side ? min(max(width * 0.46, 140), 300) : min(max(width - 24, 140), 300)
        let layout = side
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .center, spacing: 12))
        let selection = Binding(get: { range }, set: { open = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            // One row: back, then the wheel chips. Narrower widths and larger text
            // drop the back button's title, then turn the chips into a menu.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { backButton(titled: true); WheelRangeChips(model: model, selection: selection) }
                HStack(spacing: 0) { backButton(titled: false); WheelRangeChips(model: model, selection: selection) }
                HStack(spacing: 0) { backButton(titled: false); WheelRangeMenu(selection: selection); Spacer(minLength: 0) }
            }

            layout {
                ColorWheel(model: model, range: range, diameter: diameter)
                    .frame(maxWidth: side ? nil : .infinity)
                WheelSliders(model: model, range: range, hueMemory: Binding(
                    get: { hueMemory[range] ?? 0 },
                    set: { hueMemory[range] = $0 }
                ))
                .frame(maxWidth: .infinity)
            }
        }
        .transition(.opacity)
    }

    private func backButton(titled: Bool) -> some View {
        Button {
            show(nil)
        } label: {
            Group {
                if titled {
                    Label("All wheels", systemImage: "chevron.backward")
                } else {
                    Image(systemName: "chevron.backward")
                }
            }
            .font(.subheadline.weight(.semibold))
            .fixedSize()
            .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("All wheels")
        .accessibilityIdentifier("wheel.overview")
    }

    private func show(_ range: ToneRange?) {
        withAnimation(.snappy(duration: 0.25)) { open = range }
    }
}

/// Chips to switch the open wheel. An edited wheel's chip has a dot in its color.
private struct WheelRangeChips: View {
    let model: EditorModel
    @Binding var selection: ToneRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ToneRange.allCases) { range in chip(range) }
        }
    }

    private func chip(_ range: ToneRange) -> some View {
        let selected = range == selection
        let point = model.recipe[.gradeWheel(range)]?.pointValue
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = range }
        } label: {
            Text(range.displayName)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(selected ? Theme.panelRaised : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.divider : .clear, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    if let point {
                        Circle().fill(WheelPaint.color(x: point.x, y: point.y)).frame(width: 5, height: 5).offset(y: 6)
                    }
                }
                .frame(minHeight: Theme.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("wheel.chip.\(range.rawValue)")
    }
}

/// The chips as a menu, for when they don't fit (large text sizes).
private struct WheelRangeMenu: View {
    @Binding var selection: ToneRange

    var body: some View {
        // A Menu, not a menu-style Picker: only a label's own frame grows the hit area.
        Menu {
            Picker("Wheel", selection: $selection) {
                ForEach(ToneRange.allCases) { range in Text(range.displayName).tag(range) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.displayName)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .foregroundStyle(Theme.accent)
            .touchTarget()
        }
        .accessibilityIdentifier("wheel.picker")
    }
}

/// Colors shared by the wheel and its sliders, matching the hue the render uses.
enum WheelPaint {
    static func color(hue: Double, saturation: Double = 0.75) -> Color {
        Color(hue: WheelPolar.wrap(hue) / 360, saturation: saturation, brightness: 0.85)
    }

    static func color(x: Double, y: Double) -> Color {
        let polar = WheelPolar(x: x, y: y)
        return color(hue: polar.hue, saturation: 0.35 + 0.5 * polar.strength)
    }

    static let hueGradient = Gradient(colors: stride(from: 0.0, through: 360, by: 30).map { color(hue: $0) })
}

/// Hue, Saturation and Luminance for the open wheel. Hue and Saturation edit the
/// wheel's point in polar form; dragging either is one undo step, like any slider.
private struct WheelSliders: View {
    let model: EditorModel
    let range: ToneRange
    @Binding var hueMemory: Double

    private var key: ParamKey { .gradeWheel(range) }

    private var polar: WheelPolar {
        let point = model.recipe[key]?.pointValue ?? (0, 0)
        return WheelPolar(x: point.x, y: point.y, fallbackHue: hueMemory)
    }

    /// Hue runs 0...359 so the right end doesn't wrap around to the left.
    private static let maxHue = 359.0

    var body: some View {
        let polar = self.polar
        let edited = model.recipe[key] != nil
        VStack(alignment: .leading, spacing: 4) {
            row(
                title: "Hue", value: "\(Int(polar.hue.rounded()))°", edited: edited,
                slider: FineSlider(
                    position: min(polar.hue / Self.maxHue, 1),
                    trackGradient: WheelPaint.hueGradient,
                    onChange: { position in
                        let hue = (position * Self.maxHue).rounded()
                        hueMemory = hue
                        // A neutral wheel has no hue to change; Saturation will use this one.
                        if !self.polar.isNeutral { model.setLive(key, self.polar.with(hue: hue).paramValue) }
                    },
                    onEditingChanged: { if !$0 { model.commit(key) } },
                    onReset: { model.reset(key) },
                    onHold: hold
                ),
                identifier: "hue"
            )
            row(
                title: "Saturation", value: "\(Int((polar.strength * 100).rounded()))", edited: edited,
                slider: FineSlider(
                    position: polar.strength,
                    trackGradient: Gradient(colors: [Color(white: 0.5), WheelPaint.color(hue: polar.hue, saturation: 0.85)]),
                    onChange: { position in
                        model.setLive(key, self.polar.with(strength: (position * 100).rounded() / 100).paramValue)
                    },
                    onEditingChanged: { if !$0 { model.commit(key) } },
                    onReset: { model.reset(key) },
                    onHold: hold
                ),
                identifier: "saturation"
            )
            ParamSlider(model: model, key: .gradeLuminance(range), label: "Luminance")
        }
        .onChange(of: polar.hue, initial: true) { _, hue in
            if !self.polar.isNeutral { hueMemory = hue }
        }
    }

    private func hold(_ holding: Bool) {
        model.setHidden([key, .gradeLuminance(range)], hidden: holding, label: "\(range.displayName) wheel")
    }

    private func row(title: String, value: String, edited: Bool, slider: FineSlider, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).foregroundStyle(edited ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                Text(value).valueStyle().foregroundStyle(edited ? Theme.accent : Theme.textSecondary)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.reset(key) }
            slider
                .accessibilityLabel("\(range.displayName) \(title.lowercased())")
                .accessibilityValue(value)
                .accessibilityIdentifier("slider.\(key.rawValue).\(identifier)")
        }
    }
}

/// A color wheel for one tonal range. Drag anywhere on it to move the puck relative
/// to where it was, so a finger never hides a jump; slow drags move it finer (hold
/// Option on the Mac for finer still). Double-tap resets; press and hold previews
/// the photo without this wheel. With `onOpen`, it shows its name and value below,
/// and a tap opens it.
struct ColorWheel: View {
    let model: EditorModel
    let range: ToneRange
    var diameter: CGFloat = 96
    var onOpen: (() -> Void)?

    @State private var tracker: FineAdjust.WheelTracker?
    @State private var precision: FineAdjust.Precision = .coarse

    private var point: (x: Double, y: Double) {
        model.recipe[.gradeWheel(range)]?.pointValue ?? (0, 0)
    }

    private var large: Bool { diameter > 150 }
    private var puckSize: CGFloat { (large ? 22 : 16) + (precision == .coarse ? 0 : 6) }

    var body: some View {
        VStack(spacing: 4) {
            wheel
            if let onOpen {
                Button(action: onOpen) {
                    VStack(spacing: 1) {
                        HStack(spacing: 3) {
                            Text(range.displayName).font(.caption)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        Text(readout).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fine-tune \(range.displayName)")
                .accessibilityValue(readout)
                .accessibilityIdentifier("wheel.open.\(range.rawValue)")
            }
        }
    }

    private var wheel: some View {
        let strength = WheelPolar(x: point.x, y: point.y).strength
        return ZStack {
            Circle()
                .fill(AngularGradient(
                    gradient: Gradient(colors: stride(from: 0.0, through: 360, by: 30).map { WheelPaint.color(hue: 360 - $0) }),
                    center: .center
                ))
            Circle().fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)], center: .center, startRadius: 0, endRadius: diameter / 2))
            Circle().strokeBorder(Theme.divider, lineWidth: 1)
            if large {
                // Crosshair and the current strength's ring, to read small offsets.
                Path { path in
                    path.move(to: CGPoint(x: diameter / 2, y: 0)); path.addLine(to: CGPoint(x: diameter / 2, y: diameter))
                    path.move(to: CGPoint(x: 0, y: diameter / 2)); path.addLine(to: CGPoint(x: diameter, y: diameter / 2))
                }
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                if strength > 0.02 {
                    Circle()
                        .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: strength * diameter, height: strength * diameter)
                }
            }
            Path { path in
                path.move(to: CGPoint(x: diameter / 2, y: diameter / 2))
                path.addLine(to: CGPoint(x: diameter / 2 + point.x * diameter / 2, y: diameter / 2 - point.y * diameter / 2))
            }
            .stroke(Color.white.opacity(0.6), lineWidth: 1)
            Circle()
                .fill(puckColor)
                .overlay(Circle().strokeBorder(Theme.ground, lineWidth: 1.5))
                .frame(width: puckSize, height: puckSize)
                .offset(x: point.x * diameter / 2, y: -point.y * diameter / 2)
            if precision != .coarse {
                Text(precision.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(puckColor, in: Capsule())
                    .foregroundStyle(.black)
                    .fixedSize()
                    .offset(y: -diameter / 2 - 10)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .controlTouches(.freeform, ControlTouchHandlers(
            began: { touch in
                tracker = FineAdjust.WheelTracker(start: point, touch: (touch.x, touch.y), time: Self.now)
            },
            moved: { touch, fine in
                guard var current = tracker else { return }
                let next = current.update(touch: (touch.x, touch.y), time: Self.now, radius: diameter / 2, forcedPrecision: fine ? .fine : .coarse)
                tracker = current
                if precision != current.precision { precision = current.precision }
                model.setLive(.gradeWheel(range), WheelPolar(x: next.x, y: next.y).paramValue)
            },
            ended: {
                tracker = nil
                precision = .coarse
                model.commit(.gradeWheel(range))
            },
            hold: { model.setHidden([.gradeWheel(range), .gradeLuminance(range)], hidden: $0, label: "\(range.displayName) wheel") },
            doubleTap: { model.reset(.gradeWheel(range)) },
            tap: onOpen
        ))
        .sensoryFeedback(.selection, trigger: precision)
        .accessibilityElement()
        .accessibilityLabel("\(range.displayName) wheel")
        .accessibilityValue(readout)
        .accessibilityIdentifier("wheel.\(range.rawValue)")
        .accessibilityAdjustableAction { direction in
            let polar = WheelPolar(x: point.x, y: point.y, fallbackHue: 30)
            model.set(.gradeWheel(range), polar.with(strength: polar.strength + (direction == .increment ? 0.05 : -0.05)).paramValue)
        }
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private var puckColor: Color {
        switch precision {
        case .coarse: Theme.textPrimary
        case .fine: Color(hex: 0x5AC8FA)
        case .finer: Color(hex: 0xBF5AF2)
        }
    }

    private var readout: String {
        let polar = WheelPolar(x: point.x, y: point.y)
        var text = polar.strength < 0.005 ? "Neutral" : "\(Int(polar.hue.rounded()))° · \(Int((polar.strength * 100).rounded()))"
        if let luminance = model.recipe.scalar(.gradeLuminance(range)), luminance.rounded() != 0 {
            text += " · L " + ValueFormat.signed(luminance, decimals: 0)
        }
        return text
    }
}
