import EditorCore
import SwiftUI

/// The eight HSL swatches. The selected one drives the hue/sat/lum sliders below.
struct HueSwatches: View {
    @Binding var selection: HueBand
    let model: EditorModel
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HueBand.allCases) { band in
                let selected = band == selection
                let edited = HSLComponent.allCases.contains { model.recipe[.hsl(band, $0)] != nil }
                Button {
                    selection = band
                } label: {
                    Circle()
                        .fill(Color(hue: band.swatchHue / 360, saturation: 0.8, brightness: 0.9))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Theme.textPrimary, lineWidth: selected ? 2.5 : 0).padding(-4))
                        .overlay(alignment: .bottom) {
                            if edited { Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(y: 10) }
                        }
                        .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Press and hold to see which colors in the photo this band affects.
                .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 20) {
                    selection = band
                } onPressingChanged: { pressing in
                    if pressing {
                        holdTask = Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            model.hslSelection = band
                        }
                    } else {
                        holdTask?.cancel()
                        model.hslSelection = nil
                    }
                }
                .accessibilityLabel(band.displayName)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint("Press and hold to show these colors in the photo")
                .accessibilityIdentifier("swatch.\(band.rawValue)")
            }
        }
    }
}

/// A color wheel for one tonal range. Drag anywhere on the wheel to move the puck
/// relative to where it was, so a finger never hides a jump. Pull the finger out
/// past the wheel's edge for fine control (darktable-style); the puck changes color.
/// Double-tap resets; press and hold previews the photo without this wheel.
struct ColorWheel: View {
    let model: EditorModel
    let range: ToneRange
    var diameter: CGFloat = 96

    @State private var tracker: FineAdjust.WheelTracker?
    @State private var precision: FineAdjust.Precision = .coarse

    private var point: (x: Double, y: Double) {
        model.recipe[.gradeWheel(range)]?.pointValue ?? (0, 0)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(colors: stride(from: 0.0, through: 360, by: 30).map { Color(hue: (360 - $0).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.75, brightness: 0.85) }),
                        center: .center
                    ))
                Circle().fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)], center: .center, startRadius: 0, endRadius: diameter / 2))
                Circle().strokeBorder(Theme.divider, lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: diameter / 2, y: diameter / 2))
                    path.addLine(to: CGPoint(x: diameter / 2 + point.x * diameter / 2, y: diameter / 2 - point.y * diameter / 2))
                }
                .stroke(Color.white.opacity(0.6), lineWidth: 1)
                Circle()
                    .fill(puckColor)
                    .overlay(Circle().strokeBorder(Theme.ground, lineWidth: 1.5))
                    .frame(width: precision == .coarse ? 16 : 22, height: precision == .coarse ? 16 : 22)
                    .offset(x: point.x * diameter / 2, y: -point.y * diameter / 2)
                if precision != .coarse {
                    Text(precision.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(puckColor, in: Capsule())
                        .foregroundStyle(.black)
                        .offset(y: -diameter / 2 - 10)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .controlTouches(.freeform, ControlTouchHandlers(
                began: { touch in
                    tracker = FineAdjust.WheelTracker(start: point, touch: (touch.x, touch.y))
                },
                moved: { touch, fine in
                    guard var current = tracker else { return }
                    let radius = diameter / 2
                    let next = current.update(touch: (touch.x, touch.y), center: (radius, radius), radius: radius, forcedPrecision: fine ? .fine : .coarse)
                    tracker = current
                    if precision != current.precision { precision = current.precision }
                    model.setLive(.gradeWheel(range), .point(x: next.x, y: next.y))
                },
                ended: {
                    tracker = nil
                    precision = .coarse
                    model.commit(.gradeWheel(range))
                },
                hold: { model.setHidden([.gradeWheel(range), .gradeLuminance(range)], hidden: $0, label: "\(range.displayName) wheel") },
                doubleTap: { model.reset(.gradeWheel(range)) }
            ))
            .sensoryFeedback(.selection, trigger: precision)
            .accessibilityElement()
            .accessibilityLabel("\(range.displayName) wheel")
            .accessibilityValue(wheelDescription)
            .accessibilityIdentifier("wheel.\(range.rawValue)")
            .accessibilityAdjustableAction { direction in
                let polar = ColorMath.wheelPolar(x: point.x, y: point.y)
                let strength = min(max(polar.strength + (direction == .increment ? 0.05 : -0.05), 0), 1)
                let hue = polar.strength == 0 ? 30 : polar.hue
                let radians = hue * .pi / 180
                model.set(.gradeWheel(range), .point(x: cos(radians) * strength, y: sin(radians) * strength))
            }

            Text(range.displayName).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(wheelDescription).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
        }
    }

    private var puckColor: Color {
        switch precision {
        case .coarse: Theme.textPrimary
        case .fine: Color(hex: 0x5AC8FA)
        case .finer: Color(hex: 0xBF5AF2)
        }
    }

    private var wheelDescription: String {
        let polar = ColorMath.wheelPolar(x: point.x, y: point.y)
        return polar.strength < 0.005 ? "Neutral" : "\(Int(polar.hue.rounded()))° · \(Int((polar.strength * 100).rounded()))"
    }
}

/// A point-curve editor over a histogram-free grid. Drag anywhere to add and
/// move a point; drag a point off the top or bottom, or double-tap it, to remove
/// it; double-tap empty space to reset the curve.
struct ToneCurveEditor: View {
    let model: EditorModel

    private static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    /// How far past the top or bottom a point is dragged to remove it.
    private static let removeMargin = 0.12

    private var points: [CurvePoint] {
        if case .curve(let points)? = model.recipe[.toneCurve], points.count >= 2 { return points }
        return Self.identity
    }

    @State private var dragging: Int?
    /// The curve before the drag, so a point dragged off and back returns.
    @State private var dragStart: [CurvePoint]?
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            graph
            HStack {
                Text(removing ? "Release to remove the point" : "Drag to add or move a point. Drag one off the graph or double-tap it to remove it.")
                    .font(.caption)
                    .foregroundStyle(removing ? Theme.accent : Theme.textSecondary)
                Spacer()
                Button("Reset curve") { model.reset(.toneCurve) }
                    .font(.caption)
                    .disabled(model.recipe[.toneCurve] == nil)
                    .accessibilityIdentifier("toneCurve.reset")
            }
        }
    }

    private var graph: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let samples = ToneCurveSampler.sample(points, count: 64)
            ZStack {
                Rectangle().fill(Theme.panelRaised)
                Path { path in
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        path.move(to: CGPoint(x: f * size.width, y: 0)); path.addLine(to: CGPoint(x: f * size.width, y: size.height))
                        path.move(to: CGPoint(x: 0, y: f * size.height)); path.addLine(to: CGPoint(x: size.width, y: f * size.height))
                    }
                }
                .stroke(Theme.divider, lineWidth: 1)
                Path { path in
                    for (index, value) in samples.enumerated() {
                        let point = CGPoint(x: CGFloat(index) / CGFloat(samples.count - 1) * size.width, y: (1 - CGFloat(value)) * size.height)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(Theme.textPrimary, lineWidth: 1.5)
                ForEach(points.indices, id: \.self) { index in
                    Circle()
                        .fill(dragging == index ? (removing ? Color.red : Theme.accent) : Theme.textPrimary)
                        .frame(width: 12, height: 12)
                        .position(x: points[index].x * size.width, y: (1 - points[index].y) * size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(size: size))
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { tap in
                    let location = normalized(tap.location, size)
                    if let index = nearestInterior(to: location, in: points) {
                        var current = points
                        current.remove(at: index)
                        model.set(.toneCurve, current == Self.identity ? nil : .curve(current))
                    } else {
                        model.reset(.toneCurve)
                    }
                }
            )
        }
        .aspectRatio(1.6, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Tone curve")
        .accessibilityIdentifier("toneCurve")
    }

    private func normalized(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x / size.width, y: 1 - point.y / size.height)
    }

    private func nearest(to point: CGPoint, in points: [CurvePoint]) -> Int? {
        points.indices
            .filter { hypot(points[$0].x - point.x, points[$0].y - point.y) < 0.08 }
            .min { hypot(points[$0].x - point.x, points[$0].y - point.y) < hypot(points[$1].x - point.x, points[$1].y - point.y) }
    }

    /// Endpoints can't be removed, only moved up and down.
    private func nearestInterior(to point: CGPoint, in points: [CurvePoint]) -> Int? {
        nearest(to: point, in: points).flatMap { $0 > 0 && $0 < points.count - 1 ? $0 : nil }
    }

    private func drag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                let raw = normalized(drag.location, size)
                if dragStart == nil {
                    var current = points
                    let start = normalized(drag.startLocation, size)
                    if let near = nearest(to: start, in: current) {
                        dragging = near
                    } else {
                        let added = CurvePoint(x: min(max(start.x, 0.02), 0.98), y: min(max(start.y, 0), 1))
                        current.append(added)
                        current.sort { $0.x < $1.x }
                        dragging = current.firstIndex(of: added)
                    }
                    dragStart = current
                }
                guard var current = dragStart, let index = dragging, current.indices.contains(index) else { return }
                let isEnd = index == 0 || index == current.count - 1
                // Dragged well past the top or bottom: the point goes on release.
                removing = !isEnd && (raw.y < -Self.removeMargin || raw.y > 1 + Self.removeMargin)
                if removing {
                    current.remove(at: index)
                } else {
                    // Endpoints only move vertically; others stay between their neighbors.
                    let lower = index > 0 ? current[index - 1].x + 0.02 : 0
                    let upper = index < current.count - 1 ? current[index + 1].x - 0.02 : 1
                    current[index] = CurvePoint(x: isEnd ? current[index].x : min(max(raw.x, lower), upper), y: min(max(raw.y, 0), 1))
                }
                model.setLive(.toneCurve, current == Self.identity ? nil : .curve(current))
            }
            .onEnded { _ in
                dragging = nil
                dragStart = nil
                removing = false
                model.commit(.toneCurve)
            }
    }
}

/// Small RGB + luma histogram for the photo overlay and the Mac inspector.
struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { context, size in
            func draw(_ bins: [Float], _ color: Color) {
                guard bins.count > 1 else { return }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in bins.enumerated() {
                    path.addLine(to: CGPoint(x: CGFloat(index) / CGFloat(bins.count - 1) * size.width, y: size.height * (1 - CGFloat(min(value, 1)))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                context.fill(path, with: .color(color))
            }
            context.blendMode = .plusLighter
            draw(histogram.red, .red.opacity(0.55))
            draw(histogram.green, .green.opacity(0.55))
            draw(histogram.blue, .blue.opacity(0.6))
            context.blendMode = .normal
            draw(histogram.luma, .white.opacity(0.18))
        }
        .accessibilityHidden(true)
    }
}
