import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EditorCore

/// How close each camera look, rendered from the RAW, comes to the camera's own JPEG
/// (the preview embedded in the RAW). Set EDITORCORE_RAW_FIXTURES to a folder of RAWs
/// and CAMERA_LOOK_CHECK to a folder for the side-by-side images, then read the
/// "LOOKMATCH" lines.
@Suite(.serialized) struct CameraLookMatchTests {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["CAMERA_LOOK_CHECK"].map { URL(fileURLWithPath: $0) }
    }

    @Test(.enabled(if: outputDirectory != nil && !DecodeTests.fixtureFiles.isEmpty))
    func compareWithEmbeddedJPEG() async throws {
        let out = try #require(Self.outputDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        for url in DecodeTests.fixtureFiles where ["arw", "raf"].contains(url.pathExtension.lowercased()) {
            guard let camera = Self.embeddedPreview(url) else {
                print("LOOKMATCH \(url.lastPathComponent): no embedded preview")
                continue
            }
            let source = PhotoSource(url: url)
            let info = try await decoder.info(for: source)
            let base = try await decoder.decode(source, rawStage: RawStageParams(), longEdge: max(camera.width, camera.height)).image
            let inputs = GradeInputs(defaults: info.defaults)
            let plain = try #require(ThumbnailRenderer.render(Recipe(), base: base, inputs: inputs, longEdge: CGFloat(max(camera.width, camera.height))))
            let lookName = info.cameraLook?.name ?? "none"
            let looked = info.cameraLook.map { Recipe().applying($0, amount: 1, defaults: info.defaults, stamp: testClock.now()) } ?? Recipe()
            let ours = try #require(ThumbnailRenderer.render(looked, base: base, inputs: inputs, longEdge: CGFloat(max(camera.width, camera.height))))

            let reference = LabImage(camera)
            for (label, image) in [("no look", plain), ("look \(lookName)", ours)] {
                let lab = LabImage(image)
                let d = reference.compare(with: lab)
                print(String(format: "LOOKMATCH %@ %@: ΔE2000 pixel %.2f block %.2f · camera L%.1f a%.1f b%.1f · ours L%.1f a%.1f b%.1f · Δ L%+.1f a%+.1f b%+.1f · chroma camera %.1f ours %.1f",
                             url.lastPathComponent, label, d.pixelDE, d.blockDE,
                             reference.mean.L, reference.mean.a, reference.mean.b, lab.mean.L, lab.mean.a, lab.mean.b,
                             lab.mean.L - reference.mean.L, lab.mean.a - reference.mean.a, lab.mean.b - reference.mean.b,
                             reference.meanChroma, lab.meanChroma))
            }
            try Self.sideBySide([camera, plain, ours]).write(to: out.appending(path: url.deletingPathExtension().lastPathComponent + "-camera-plain-look.jpg"))
        }
    }

    /// Fits a Sony look's preset to the camera's JPEG of a fixture shot in that look, by
    /// coordinate descent on block ΔE2000, and prints the fitted parameters. Set
    /// CAMERA_LOOK_TUNE to the look's code (e.g. FL) and EDITORCORE_RAW_FIXTURES to a
    /// folder holding a RAW shot in it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CAMERA_LOOK_TUNE"] != nil && !DecodeTests.fixtureFiles.isEmpty))
    func tuneLookToEmbeddedJPEG() async throws {
        let code = ProcessInfo.processInfo.environment["CAMERA_LOOK_TUNE"]!
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        var found: (URL, SourceInfo)?
        for url in DecodeTests.fixtureFiles {
            let info = try await decoder.info(for: PhotoSource(url: url))
            if info.sonyLook?.look == code { found = (url, info); break }
        }
        let (url, info) = try #require(found, "no fixture shot in \(code)")
        let settings = try #require(info.sonyLook)
        let camera = try #require(Self.embeddedPreview(url))
        let reference = LabImage(camera)
        let base = try await decoder.decode(PhotoSource(url: url), rawStage: RawStageParams(), longEdge: 808).image
        let inputs = GradeInputs(defaults: info.defaults)
        let start = try #require(SonyLooks.cameraPreset(for: settings))

        func score(_ params: [ParamKey: ParamValue]) -> Double {
            var preset = start
            preset.params = params
            let recipe = Recipe().applying(preset, amount: 1, defaults: info.defaults, stamp: testClock.now())
            guard let image = ThumbnailRenderer.render(recipe, base: base, inputs: inputs, longEdge: 808) else { return .infinity }
            return reference.compare(with: LabImage(image)).blockDE
        }

        // Each knob: how to read and write it, its bounds and its coarsest step.
        struct Knob { var name: String; var get: ([ParamKey: ParamValue]) -> Double; var set: (inout [ParamKey: ParamValue], Double) -> Void; var range: ClosedRange<Double>; var step: Double; var cost = 0.05 }
        func scalar(_ key: ParamKey, _ range: ClosedRange<Double>, _ step: Double = 8) -> Knob {
            Knob(name: key.rawValue,
                 get: { if case .scalar(let v)? = $0[key] { v } else { 0 } },
                 set: { $0[key] = abs($1) < 0.01 ? nil : .scalar($1) }, range: range, step: step)
        }
        func wheel(_ range: ToneRange, axis: Int) -> Knob {
            Knob(name: "\(range.rawValue).\(axis == 0 ? "x" : "y")",
                 get: { if case .point(let x, let y)? = $0[.gradeWheel(range)] { axis == 0 ? x : y } else { 0 } },
                 set: { params, value in
                     var (x, y) = (0.0, 0.0)
                     if case .point(let px, let py)? = params[.gradeWheel(range)] { (x, y) = (px, py) }
                     if axis == 0 { x = value } else { y = value }
                     params[.gradeWheel(range)] = abs(x) < 0.001 && abs(y) < 0.001 ? nil : .point(x: x, y: y)
                 }, range: -0.4...0.4, step: 0.08)
        }
        let curveXs = [0.0, 0.25, 0.5, 0.75, 1.0]
        func curvePoints(_ params: [ParamKey: ParamValue]) -> [Double] {
            guard case .curve(let points)? = params[.toneCurve] else { return curveXs }
            return curveXs.map { x in
                // Sample the stored curve at our knots (linear between its points).
                let sorted = points.sorted { $0.x < $1.x }
                guard let upper = sorted.firstIndex(where: { $0.x >= x }) else { return sorted.last!.y }
                if upper == 0 { return sorted[0].y }
                let a = sorted[upper - 1], b = sorted[upper]
                return a.y + (b.y - a.y) * (x - a.x) / max(b.x - a.x, 1e-9)
            }
        }
        func curve(_ index: Int, _ range: ClosedRange<Double>) -> Knob {
            Knob(name: "curve@\(curveXs[index])",
                 get: { curvePoints($0)[index] },
                 set: { params, value in
                     var ys = curvePoints(params)
                     ys[index] = value
                     params[.toneCurve] = .curve(zip(curveXs, ys).map { CurvePoint(x: $0, y: $1) })
                 }, range: range, step: 0.04)
        }

        var knobs = [
            scalar(.contrast, -50...60), scalar(.highlights, -70...40), scalar(.shadows, -50...60),
            scalar(.whites, -50...50), scalar(.blacks, -50...40), scalar(.saturation, -60...40), scalar(.vibrance, -50...50),
            curve(0, 0...0.12), curve(1, 0.1...0.4), curve(2, 0.35...0.65), curve(3, 0.6...0.9), curve(4, 0.88...1),
        ]
        // Per-hue knobs only fit the colors this one photo has, so they cost more to move
        // and stay within a narrower range; CAMERA_LOOK_TUNE_HSL=0 leaves them out.
        if ProcessInfo.processInfo.environment["CAMERA_LOOK_TUNE_HSL"] != "0" {
            for band in HueBand.allCases {
                for (component, range) in [(HSLComponent.hue, -15.0...15.0), (.saturation, -25.0...25.0), (.luminance, -15.0...15.0)] {
                    var knob = scalar(.hsl(band, component), range, 5)
                    knob.cost = Double(ProcessInfo.processInfo.environment["CAMERA_LOOK_TUNE_HSL_COST"] ?? "") ?? 0.6
                    knobs.append(knob)
                }
            }
        }
        for range in [ToneRange.shadows, .midtones, .highlights] { knobs += [wheel(range, axis: 0), wheel(range, axis: 1)] }

        var params = start.params
        let startParams = params
        // Moving a knob across its whole range costs `cost` ΔE, so changes must earn their keep.
        func penalty(_ params: [ParamKey: ParamValue]) -> Double {
            knobs.reduce(0) { total, knob in
                total + knob.cost * abs(knob.get(params) - knob.get(startParams)) / (knob.range.upperBound - knob.range.lowerBound)
            }
        }
        func objective(_ params: [ParamKey: ParamValue]) -> Double { score(params) + penalty(params) }
        var best = objective(params)
        print(String(format: "LOOKTUNE %@ start block ΔE2000 %.3f", code, best))
        for scale in [1.0, 0.5, 0.25, 0.125] {
            var improved = true
            var passes = 0
            while improved && passes < 6 {
                improved = false
                passes += 1
                for knob in knobs {
                    let current = knob.get(params)
                    for direction in [1.0, -1.0] {
                        let value = min(max(current + direction * knob.step * scale, knob.range.lowerBound), knob.range.upperBound)
                        guard value != current else { continue }
                        var trial = params
                        knob.set(&trial, value)
                        let s = objective(trial)
                        if s < best - 1e-4 { best = s; params = trial; improved = true; break }
                    }
                }
            }
            print(String(format: "LOOKTUNE %@ step ×%.3f block ΔE2000 %.3f (objective %.3f)", code, scale, score(params), best))
        }
        for key in params.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            print("LOOKTUNE \(code) param \(key.rawValue) = \(params[key]!)")
        }
    }

    /// The largest preview the camera embedded in the RAW.
    static func embeddedPreview(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Images next to each other at the first one's height, as JPEG data.
    static func sideBySide(_ images: [CGImage]) throws -> Data {
        let height = images[0].height
        let widths = images.map { Int(Double($0.width) * Double(height) / Double($0.height)) }
        let gap = 16
        let context = try #require(CGContext(data: nil, width: widths.reduce(0, +) + gap * (images.count - 1), height: height,
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: height))
        var x = 0
        for (image, width) in zip(images, widths) {
            context.draw(image, in: CGRect(x: x, y: 0, width: width, height: height))
            x += width + gap
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// An image resampled to a fixed grid and converted to CIELAB (D65), so two renders of
/// the same frame can be compared pixel by pixel.
struct LabImage {
    static let width = 404, height = 270, block = 8
    var pixels: [(L: Double, a: Double, b: Double)] = []

    init(_ image: CGImage) {
        var rgba = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        let context = CGContext(data: &rgba, width: Self.width, height: Self.height, bitsPerComponent: 8, bytesPerRow: Self.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        for i in stride(from: 0, to: rgba.count, by: 4) {
            pixels.append(Self.lab(r: Double(rgba[i]) / 255, g: Double(rgba[i + 1]) / 255, b: Double(rgba[i + 2]) / 255))
        }
    }

    var mean: (L: Double, a: Double, b: Double) {
        let n = Double(pixels.count)
        return (pixels.map(\.L).reduce(0, +) / n, pixels.map(\.a).reduce(0, +) / n, pixels.map(\.b).reduce(0, +) / n)
    }

    var meanChroma: Double { pixels.map { ($0.a * $0.a + $0.b * $0.b).squareRoot() }.reduce(0, +) / Double(pixels.count) }

    /// Mean ΔE2000 per pixel, and per block of averaged pixels (less sensitive to
    /// sharpening, noise and the half-pixel framing difference).
    func compare(with other: LabImage) -> (pixelDE: Double, blockDE: Double) {
        let pixelDE = zip(pixels, other.pixels).map { Self.deltaE2000($0, $1) }.reduce(0, +) / Double(pixels.count)
        var blocks: [Double] = []
        for by in stride(from: 0, to: Self.height - Self.block + 1, by: Self.block) {
            for bx in stride(from: 0, to: Self.width - Self.block + 1, by: Self.block) {
                func average(_ image: LabImage) -> (L: Double, a: Double, b: Double) {
                    var sum = (L: 0.0, a: 0.0, b: 0.0)
                    for y in by..<by + Self.block {
                        for x in bx..<bx + Self.block {
                            let p = image.pixels[y * Self.width + x]
                            sum.L += p.L; sum.a += p.a; sum.b += p.b
                        }
                    }
                    let n = Double(Self.block * Self.block)
                    return (sum.L / n, sum.a / n, sum.b / n)
                }
                blocks.append(Self.deltaE2000(average(self), average(other)))
            }
        }
        return (pixelDE, blocks.reduce(0, +) / Double(blocks.count))
    }

    static func lab(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (rl, gl, bl) = (linear(r), linear(g), linear(b))
        let x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// CIEDE2000 (Sharma, Wu and Dalal's formulation).
    static func deltaE2000(_ p: (L: Double, a: Double, b: Double), _ q: (L: Double, a: Double, b: Double)) -> Double {
        let rad = Double.pi / 180
        let c1 = (p.a * p.a + p.b * p.b).squareRoot(), c2 = (q.a * q.a + q.b * q.b).squareRoot()
        let cBar = (c1 + c2) / 2
        let g = 0.5 * (1 - (pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))).squareRoot())
        let a1 = (1 + g) * p.a, a2 = (1 + g) * q.a
        let c1p = (a1 * a1 + p.b * p.b).squareRoot(), c2p = (a2 * a2 + q.b * q.b).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let h = atan2(b, a) / rad
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(p.b, a1), h2 = hue(q.b, a2)
        let dL = q.L - p.L, dC = c2p - c1p
        var dh = 0.0
        if c1p * c2p != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * (c1p * c2p).squareRoot() * sin(dh / 2 * rad)
        let lBar = (p.L + q.L) / 2, cBarP = (c1p + c2p) / 2
        var hBar = h1 + h2
        if c1p * c2p != 0 {
            if abs(h1 - h2) <= 180 { hBar /= 2 } else { hBar = h1 + h2 < 360 ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hBar - 30) * rad) + 0.24 * cos(2 * hBar * rad) + 0.32 * cos((3 * hBar + 6) * rad) - 0.20 * cos((4 * hBar - 63) * rad)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let rc = 2 * (pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(lBar - 50, 2) / (20 + pow(lBar - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cBarP, sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * rad) * rc
        let l = dL / sl, c = dC / sc, h = dH / sh
        return (l * l + c * c + h * h + rt * c * h).squareRoot()
    }
}
