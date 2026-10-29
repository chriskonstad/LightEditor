import Foundation

/// Coarse/fine drag math for sliders and color wheels.
///
/// Dragging along a slider is coarse. Pulling the finger away from the control
/// (above or below a slider, outside a wheel) switches to finer steps, like Nitro's
/// sliders and darktable's fine adjustment. Every precision change re-anchors the
/// drag, so the value never jumps when the precision changes.
public enum FineAdjust {
    public enum Precision: Int, Sendable, Comparable {
        case coarse, fine, finer

        public var factor: Double {
            switch self {
            case .coarse: 1
            case .fine: 0.1
            case .finer: 0.025
            }
        }

        public var label: String {
            switch self {
            case .coarse: ""
            case .fine: "Fine"
            case .finer: "Finer"
            }
        }

        public static func < (lhs: Precision, rhs: Precision) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Precision for a finger `distance` points away from the control.
    public static func precision(forDistance distance: Double, fineAt: Double = 44, finerAt: Double = 130) -> Precision {
        if distance >= finerAt { return .finer }
        if distance >= fineAt { return .fine }
        return .coarse
    }

    /// Tracks one slider drag. Values are slider positions in 0...1.
    public struct SliderTracker: Sendable {
        public private(set) var precision: Precision = .coarse
        private var anchorValue: Double
        private var anchorX: Double

        public init(startValue: Double, startX: Double) {
            anchorValue = startValue
            anchorX = startX
        }

        /// The new position for a finger at `x`, `distance` points off the track,
        /// on a track `width` points wide. `forcedPrecision` (e.g. a held modifier
        /// key) can only make the drag finer.
        public mutating func update(x: Double, distance: Double, width: Double, forcedPrecision: Precision = .coarse) -> Double {
            let wanted = max(FineAdjust.precision(forDistance: distance), forcedPrecision)
            let current = value(at: x, width: width)
            if wanted != precision {
                anchorValue = current
                anchorX = x
                precision = wanted
                return current
            }
            return current
        }

        private func value(at x: Double, width: Double) -> Double {
            guard width > 0 else { return anchorValue }
            return min(max(anchorValue + (x - anchorX) / width * precision.factor, 0), 1)
        }
    }

    /// Tracks one color wheel drag. Points are in the unit disc; movement is
    /// relative, so the puck never jumps under the finger.
    public struct WheelTracker: Sendable {
        public private(set) var precision: Precision = .coarse
        private var anchor: (x: Double, y: Double)
        private var anchorTouch: (x: Double, y: Double)

        public init(start: (x: Double, y: Double), touch: (x: Double, y: Double)) {
            anchor = start
            anchorTouch = touch
        }

        /// The new wheel point for a touch at `touch` (view points, y down), on a
        /// wheel of `radius` points centered at `center`.
        public mutating func update(touch: (x: Double, y: Double), center: (x: Double, y: Double), radius: Double, forcedPrecision: Precision = .coarse) -> (x: Double, y: Double) {
            let distance = max(hypot(touch.x - center.x, touch.y - center.y) - radius, 0)
            let wanted = max(FineAdjust.precision(forDistance: distance, fineAt: 30, finerAt: 110), forcedPrecision)
            let current = point(at: touch, radius: radius)
            if wanted != precision {
                anchor = current
                anchorTouch = touch
                precision = wanted
            }
            return current
        }

        private func point(at touch: (x: Double, y: Double), radius: Double) -> (x: Double, y: Double) {
            guard radius > 0 else { return anchor }
            var x = anchor.x + (touch.x - anchorTouch.x) / radius * precision.factor
            var y = anchor.y - (touch.y - anchorTouch.y) / radius * precision.factor
            let length = hypot(x, y)
            if length > 1 {
                x /= length
                y /= length
            }
            return (x, y)
        }
    }
}
