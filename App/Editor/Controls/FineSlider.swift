import EditorCore
import SwiftUI

/// A slider with Nitro-style fine adjustment.
///
/// - Drag along the track for coarse changes. The thumb moves with the finger,
///   relative to where it started, so touching the track never jumps the value.
/// - While dragging, pull the finger above or below the track: the thumb changes
///   color and the same movement makes a tenth (then a fortieth) of the change.
/// - Double-tap to reset. Press and hold to preview the photo without this setting.
/// - On the Mac, hold Option for fine steps.
struct FineSlider: View {
    /// Position on the track, 0...1.
    let position: Double
    /// Where the fill starts, usually the default value's position.
    var origin: Double = 0
    var tint: Color = Theme.accent
    let onChange: (Double) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onReset: () -> Void = {}
    var onHold: (Bool) -> Void = { _ in }

    @State private var tracker: FineAdjust.SliderTracker?
    @State private var precision: FineAdjust.Precision = .coarse

    private let thumb: CGFloat = 26
    private let fineColor = Color(hex: 0x5AC8FA)
    private let finerColor = Color(hex: 0xBF5AF2)

    var body: some View {
        GeometryReader { proxy in
            let usable = max(proxy.size.width - thumb, 1)
            let midY = proxy.size.height / 2
            let x = CGFloat(position) * usable + thumb / 2
            let originX = CGFloat(origin) * usable + thumb / 2
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: usable, height: 4)
                    .position(x: proxy.size.width / 2, y: midY)
                Capsule()
                    .fill(tint)
                    .frame(width: max(abs(x - originX), 0), height: 4)
                    .position(x: (x + originX) / 2, y: midY)
                if origin > 0.001 && origin < 0.999 {
                    Capsule().fill(Color.white.opacity(0.5)).frame(width: 2, height: 10).position(x: originX, y: midY)
                }
                Circle()
                    .fill(thumbColor)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: precision == .coarse ? thumb : thumb + 6, height: precision == .coarse ? thumb : thumb + 6)
                    .position(x: x, y: midY)
                if precision != .coarse {
                    Text(precision.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(thumbColor, in: Capsule())
                        .foregroundStyle(.black)
                        .fixedSize()
                        .position(x: x, y: midY - 26)
                }
            }
            .animation(.easeOut(duration: 0.12), value: precision)
            .contentShape(Rectangle())
            .controlTouches(.horizontalSlider, ControlTouchHandlers(
                began: { point in
                    tracker = FineAdjust.SliderTracker(startValue: position, startX: point.x)
                    onEditingChanged(true)
                },
                moved: { point, fine in
                    guard var current = tracker else { return }
                    let distance = max(abs(point.y - midY) - 12, 0)
                    let value = current.update(x: point.x, distance: distance, width: usable, forcedPrecision: fine ? .fine : .coarse)
                    tracker = current
                    if precision != current.precision { precision = current.precision }
                    onChange(value)
                },
                ended: {
                    tracker = nil
                    precision = .coarse
                    onEditingChanged(false)
                },
                hold: onHold,
                doubleTap: onReset
            ))
        }
        .frame(height: Theme.minTouch)
        .sensoryFeedback(.selection, trigger: precision)
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAdjustableAction { direction in
            onChange(min(max(position + (direction == .increment ? 0.01 : -0.01), 0), 1))
            onEditingChanged(false)
        }
        .accessibilityAction(named: "Reset", onReset)
    }

    private var thumbColor: Color {
        switch precision {
        case .coarse: .white
        case .fine: fineColor
        case .finer: finerColor
        }
    }
}
