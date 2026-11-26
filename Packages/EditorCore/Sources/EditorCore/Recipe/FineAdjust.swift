import Foundation

/// Coarse/fine drag math for sliders and color wheels.
///
/// Dragging along a slider is coarse. Pulling the finger away from the track
/// (above or below it) switches to finer steps, like Nitro's sliders and
/// darktable's fine adjustment. Every precision change re-anchors the drag, so the
/// value never jumps when the precision changes. Color wheels get their precision
/// from drag speed instead (see `WheelTracker`).
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
    ///
    /// Precision comes from drag speed rather than from pulling the finger off the
    /// control, which a wheel that fills the panel has no room for: a quick drag
    /// moves the puck one-to-one with the finger, and a slow, deliberate one moves it
    /// down to `slowGain` of that, like pointer acceleration in reverse. A held
    /// modifier (`forcedPrecision`, Option on the Mac) scales that further. Movement
    /// is integrated step by step, so at the rim, moving back inward responds at once.
    public struct WheelTracker: Sendable {
        /// Gain at or below `slowSpeed`.
        public static let slowGain = 0.25
        /// Finger speeds, in points per second, where the gain starts to rise and where it reaches 1.
        public static let slowSpeed = 40.0
        public static let fastSpeed = 400.0

        public private(set) var precision: Precision = .coarse
        public private(set) var point: (x: Double, y: Double)
        private var lastTouch: (x: Double, y: Double)
        private var lastTime: Double?
        /// Smoothed finger speed, so one jittery sample doesn't jerk the gain.
        private var speed: Double?

        /// `time` is when the finger was at `touch`, in seconds; pass it to measure
        /// speed from the first move.
        public init(start: (x: Double, y: Double), touch: (x: Double, y: Double), time: Double? = nil) {
            point = start
            lastTouch = touch
            lastTime = time
        }

        /// The gain for a finger moving at `speed` points per second (smoothstep
        /// from `slowGain` to 1).
        public static func gain(forSpeed speed: Double) -> Double {
            let t = min(max((speed - slowSpeed) / (fastSpeed - slowSpeed), 0), 1)
            return slowGain + (1 - slowGain) * t * t * (3 - 2 * t)
        }

        /// The new wheel point for a touch at `touch` (view points, y down) at `time`
        /// seconds, on a wheel of `radius` points. Without times the gain stays 1.
        public mutating func update(touch: (x: Double, y: Double), time: Double? = nil, radius: Double, forcedPrecision: Precision = .coarse) -> (x: Double, y: Double) {
            precision = forcedPrecision
            let dx = touch.x - lastTouch.x, dy = touch.y - lastTouch.y
            var gain = 1.0
            if let time {
                if let lastTime, time > lastTime {
                    let sample = hypot(dx, dy) / (time - lastTime)
                    speed = speed.map { $0 * 0.5 + sample * 0.5 } ?? sample
                }
                if let speed { gain = Self.gain(forSpeed: speed) }
                lastTime = time
            }
            lastTouch = touch
            guard radius > 0 else { return point }
            let scale = gain * precision.factor / radius
            point = WheelPolar.clampedToDisc(x: point.x + dx * scale, y: point.y - dy * scale)
            return point
        }
    }
}

/// A color wheel point in the unit disc as hue (degrees, 0..<360, counterclockwise
/// from +x, the HSV hue the wheel is painted with) and strength (0...1). The focused
/// wheel's Hue and Saturation sliders edit these.
public struct WheelPolar: Sendable, Equatable {
    public var hue: Double
    public var strength: Double

    public init(hue: Double, strength: Double) {
        self.hue = WheelPolar.wrap(hue)
        self.strength = min(max(strength, 0), 1)
    }

    /// Reads a point. A neutral point has no hue of its own, so it takes
    /// `fallbackHue` (the hue last shown), and raising Saturation from zero, or
    /// dragging it to zero and back, keeps the hue the user chose.
    public init(x: Double, y: Double, fallbackHue: Double = 0) {
        let polar = ColorMath.wheelPolar(x: x, y: y)
        self.init(hue: polar.strength < Self.neutral ? fallbackHue : polar.hue, strength: polar.strength)
    }

    /// Below this strength a point counts as neutral.
    public static let neutral = 1e-4

    public var isNeutral: Bool { strength < Self.neutral }

    public var point: (x: Double, y: Double) {
        let radians = hue * .pi / 180
        return (cos(radians) * strength, sin(radians) * strength)
    }

    /// The recipe value: nil when neutral, so a wheel set back to the middle reads
    /// as unedited, as a reset does.
    public var paramValue: ParamValue? {
        guard !isNeutral else { return nil }
        let p = point
        return .point(x: p.x, y: p.y)
    }

    public func with(hue: Double) -> WheelPolar { WheelPolar(hue: hue, strength: strength) }
    public func with(strength: Double) -> WheelPolar { WheelPolar(hue: hue, strength: strength) }

    public static func wrap(_ hue: Double) -> Double {
        let h = hue.truncatingRemainder(dividingBy: 360)
        return h < 0 ? h + 360 : h
    }

    public static func clampedToDisc(x: Double, y: Double) -> (x: Double, y: Double) {
        let length = hypot(x, y)
        return length > 1 ? (x / length, y / length) : (x, y)
    }
}
