import CoreImage
import Foundation
import ImageIO
import Vision

/// Reads the camera's own level gauge from a RAW, when it recorded one.
///
/// Fujifilm writes the electronic level's roll into its maker note (tag 0x144D,
/// signed rational, degrees). Sony's ARW only records coarse orientation, so it
/// has none. ImageIO doesn't expose the Fuji tag, so the maker note is read here.
public enum CameraLevel {
    /// The roll in degrees, positive when the camera was turned counter-clockwise
    /// (as seen from behind), or nil if the file has no reading.
    public static func roll(fileAt url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The maker note sits in the embedded JPEG's Exif, near the start of the file.
        guard let data = try? handle.read(upToCount: 4 << 20) else { return nil }
        return fujiRoll(in: data)
    }

    static func fujiRoll(in data: Data) -> Double? {
        // "FUJIFILM" followed by a little-endian offset to the IFD, from the note's start.
        let signature = Data("FUJIFILM".utf8) + Data([0x0C, 0x00, 0x00, 0x00])
        guard let range = data.range(of: signature) else { return nil }
        let base = range.lowerBound
        let bytes = [UInt8](data[base...])
        func u16(_ i: Int) -> Int? { i + 1 < bytes.count ? Int(bytes[i]) | Int(bytes[i + 1]) << 8 : nil }
        func u32(_ i: Int) -> Int? {
            guard i + 3 < bytes.count else { return nil }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        func s32(_ i: Int) -> Int32? { u32(i).map { Int32(bitPattern: UInt32($0)) } }
        guard let ifd = u32(8), let count = u16(ifd), count < 1000 else { return nil }
        for entry in 0..<count {
            let at = ifd + 2 + entry * 12
            guard let tag = u16(at), let type = u16(at + 2) else { return nil }
            // RollAngle: SRATIONAL (type 10), stored at an offset from the note's start.
            guard tag == 0x144D, type == 10, let offset = u32(at + 8),
                  let numerator = s32(offset), let denominator = s32(offset + 4), denominator != 0 else { continue }
            let degrees = Double(numerator) / Double(denominator)
            return abs(degrees) <= 45 ? degrees : nil
        }
        return nil
    }
}

/// Finds a photo's level and keeps auto straighten working across photos.
public enum AutoStraightener {
    /// The angle that levels the photo, in the recipe's convention (degrees,
    /// positive counter-clockwise): the camera's level reading for an upright
    /// landscape frame if the file has one, else Apple's horizon detection.
    public static func detect(source: PhotoSource, image: CIImage) async -> (AutoStraighten.Method, Double)? {
        // The decoder reads the level for local files; remote photos bring it along.
        if let roll = try? await RawDecoder.shared.info(for: source).cameraRoll {
            // A camera turned counter-clockwise records a scene turned clockwise.
            return (.camera, roll)
        }
        if let angle = await horizon(in: image) { return (.horizon, angle) }
        return nil
    }

    /// Apple's horizon detection on a small render of `image`, as the angle that levels it.
    ///
    /// Vision reports nothing for horizons within about a degree of level, which
    /// is most travel photos, and steps in coarse increments. So it looks at the
    /// photo turned by five known angles, where the tilt is always big enough to
    /// report, takes each turn back off, and uses the median. Measured on the X-T5
    /// sunset: consistent to about 0.3°.
    public static func horizon(in image: CIImage) async -> Double? {
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var found: [Double] = []
        for probe in [-5.0, -2.5, 0, 2.5, 5.0] {
            var turned = Recipe()
            turned.set(.crop, .crop(CropGeometry(angle: probe)), at: HLCStamp(millis: 0, node: "level"))
            let image = GradeGraph.apply(turned, to: small, inputs: GradeInputs(defaults: .generic))
            if let correction = await visionCorrection(image) { found.append(correction + probe) }
        }
        // Most looks must find it and agree; otherwise the "horizon" is probably something else.
        guard found.count >= 2 else { return nil }
        let sorted = found.sorted()
        guard sorted.last! - sorted.first! < 2 else { return nil }
        let angle = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return abs(angle) <= 20 ? (angle * 10).rounded() / 10 : nil
    }

    /// Vision's angle is the turn that levels the horizon (positive counter-clockwise).
    private static func visionCorrection(_ image: CIImage) async -> Double? {
        let image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        guard let cgImage = RenderContext.shared.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: RenderContext.sRGB) else { return nil }
        let request = DetectHorizonRequest()
        guard let observation = try? await request.perform(on: cgImage), observation.confidence > 0.3 else { return nil }
        return observation.angle.converted(to: .degrees).value
    }

    /// Fills in an auto straighten that isn't resolved for this photo yet (after a
    /// paste or a bulk edit): camera level, then Apple, and failing both the angle
    /// that came with it. Returns nil when there's nothing to do.
    public static func resolve(_ recipe: Recipe, source: PhotoSource, image: CIImage, stamp: HLCStamp) async -> Recipe? {
        guard case .crop(var geometry)? = recipe[.crop], let auto = geometry.auto, !auto.isResolved else { return nil }
        if let (method, angle) = await detect(source: source, image: image) {
            geometry.auto = AutoStraighten(method: method, detected: angle, tweak: auto.tweak)
            geometry.angle = min(max(angle + auto.tweak, -45), 45)
        } else {
            // Neither found a level: keep the pasted angle as a manual one.
            geometry.auto = nil
        }
        var resolved = recipe
        resolved.set(.crop, .crop(geometry), at: stamp)
        return resolved
    }
}
