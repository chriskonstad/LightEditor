import Foundation

/// Small CPU-side color helpers shared by the grade graph and the UI.
public enum ColorMath {
    /// HSV to sRGB (gamma-encoded), hue in degrees.
    public static func hsvToRGB(hue: Double, saturation: Double, value: Double) -> (r: Double, g: Double, b: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = value * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    public static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    public static func linearToOklab(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// The unit (a, b) direction in Oklab of a fully saturated color with the given
    /// HSV hue. Color wheels use HSV hue in the UI, so this maps a wheel angle onto
    /// the perceptual plane the grade kernel works in.
    public static func oklabDirection(hue: Double) -> (a: Double, b: Double) {
        let rgb = hsvToRGB(hue: hue, saturation: 1, value: 1)
        let lab = linearToOklab(srgbToLinear(rgb.r), srgbToLinear(rgb.g), srgbToLinear(rgb.b))
        let length = max((lab.a * lab.a + lab.b * lab.b).squareRoot(), 1e-9)
        return (lab.a / length, lab.b / length)
    }

    /// Converts a wheel point in the unit disc to (hue degrees, strength 0...1).
    public static func wheelPolar(x: Double, y: Double) -> (hue: Double, strength: Double) {
        let strength = min((x * x + y * y).squareRoot(), 1)
        var hue = atan2(y, x) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (hue, strength)
    }
}

/// Monotone cubic interpolation (Fritsch–Carlson) through tone curve points.
public enum ToneCurveSampler {
    public static func sample(_ points: [CurvePoint], count: Int = 256) -> [Float] {
        var pts = points.sorted { $0.x < $1.x }
        if pts.first.map({ $0.x > 0 }) ?? true { pts.insert(CurvePoint(x: 0, y: pts.first?.y ?? 0), at: 0) }
        if pts.last.map({ $0.x < 1 }) ?? true { pts.append(CurvePoint(x: 1, y: pts.last?.y ?? 1)) }
        // Merge points with the same x.
        pts = pts.reduce(into: []) { result, point in
            if let last = result.last, abs(last.x - point.x) < 1e-6 { result[result.count - 1] = point } else { result.append(point) }
        }
        let n = pts.count
        guard n >= 2 else { return (0..<count).map { Float($0) / Float(count - 1) } }

        var deltas = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { deltas[i] = (pts[i + 1].y - pts[i].y) / (pts[i + 1].x - pts[i].x) }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = deltas[0]
        tangents[n - 1] = deltas[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = deltas[i - 1] * deltas[i] <= 0 ? 0 : (deltas[i - 1] + deltas[i]) / 2
        }
        for i in 0..<(n - 1) where deltas[i] == 0 {
            tangents[i] = 0
            tangents[i + 1] = 0
        }
        for i in 0..<(n - 1) where deltas[i] != 0 {
            let a = tangents[i] / deltas[i], b = tangents[i + 1] / deltas[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                tangents[i] = t * a * deltas[i]
                tangents[i + 1] = t * b * deltas[i]
            }
        }

        var output = [Float](repeating: 0, count: count)
        var segment = 0
        for index in 0..<count {
            let x = Double(index) / Double(count - 1)
            while segment < n - 2 && x > pts[segment + 1].x { segment += 1 }
            let p0 = pts[segment], p1 = pts[segment + 1]
            let h = p1.x - p0.x
            let t = min(max((x - p0.x) / h, 0), 1)
            let t2 = t * t, t3 = t2 * t
            let h00: Double = 2 * t3 - 3 * t2 + 1
            let h10: Double = t3 - 2 * t2 + t
            let h01: Double = -2 * t3 + 3 * t2
            let h11: Double = t3 - t2
            let y0: Double = h00 * p0.y + h10 * h * tangents[segment]
            let y: Double = y0 + h01 * p1.y + h11 * h * tangents[segment + 1]
            output[index] = Float(min(max(y, 0), 1))
        }
        return output
    }
}
