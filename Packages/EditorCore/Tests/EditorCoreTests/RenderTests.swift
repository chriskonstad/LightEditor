import CoreImage
import Foundation
import Testing
@testable import EditorCore

let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

/// A solid image with linear sRGB values.
func solid(_ r: Double, _ g: Double, _ b: Double, size: CGFloat = 8) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: linearSRGB)!)
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
}

/// Reads linear sRGB pixels from an image.
func pixels(_ image: CIImage, rect: CGRect? = nil) -> [SIMD4<Float>] {
    let bounds = rect ?? image.extent
    let count = Int(bounds.width) * Int(bounds.height)
    var buffer = [SIMD4<Float>](repeating: .zero, count: count)
    buffer.withUnsafeMutableBytes { raw in
        RenderContext.shared.render(image, toBitmap: raw.baseAddress!, rowBytes: Int(bounds.width) * 16, bounds: bounds, format: .RGBAf, colorSpace: linearSRGB)
    }
    return buffer
}

func pixel(_ image: CIImage, x: CGFloat = 0, y: CGFloat = 0) -> SIMD4<Float> {
    pixels(image, rect: CGRect(x: x, y: y, width: 1, height: 1))[0]
}

func graded(_ base: CIImage, _ edit: (inout Recipe) -> Void, defaults: PhotoDefaults = .generic, luts: (any LUTProvider)? = nil) -> CIImage {
    var recipe = Recipe()
    edit(&recipe)
    return GradeGraph.apply(recipe, to: base, inputs: GradeInputs(defaults: defaults, luts: luts))
}

func oklabHue(_ p: SIMD4<Float>) -> Double {
    let lab = ColorMath.linearToOklab(Double(p.x), Double(p.y), Double(p.z))
    var hue = atan2(lab.b, lab.a) * 180 / .pi
    if hue < 0 { hue += 360 }
    return hue
}

func chroma(_ p: SIMD4<Float>) -> Double {
    let lab = ColorMath.linearToOklab(Double(p.x), Double(p.y), Double(p.z))
    return (lab.a * lab.a + lab.b * lab.b).squareRoot()
}

@Suite struct RenderTests {
    @Test func kernelsCompile() {
        Kernels.warmUp()
    }

    @Test func identityRecipeIsANoOp() {
        let base = solid(0.2, 0.4, 0.6)
        let p = pixel(graded(base) { _ in })
        #expect(abs(p.x - 0.2) < 1e-3 && abs(p.y - 0.4) < 1e-3 && abs(p.z - 0.6) < 1e-3)
    }

    @Test func exposureDoublesPerStop() {
        let p = pixel(graded(solid(0.1, 0.1, 0.1)) { $0.setScalar(.exposure, 1, at: testClock.now()) })
        #expect(abs(p.x - 0.2) < 2e-3)
    }

    @Test func contrastSpreadsTones() {
        let dark = pixel(graded(solid(0.03, 0.03, 0.03)) { $0.setScalar(.contrast, 60, at: testClock.now()) })
        let bright = pixel(graded(solid(0.6, 0.6, 0.6)) { $0.setScalar(.contrast, 60, at: testClock.now()) })
        #expect(dark.x < 0.03)
        #expect(bright.x > 0.6)
    }

    @Test func shadowsLiftDarksMoreThanBrights() {
        let dark = pixel(graded(solid(0.03, 0.03, 0.03)) { $0.setScalar(.shadows, 100, at: testClock.now()) })
        let bright = pixel(graded(solid(0.8, 0.8, 0.8)) { $0.setScalar(.shadows, 100, at: testClock.now()) })
        #expect(dark.x / 0.03 > 1.5)
        #expect(abs(bright.x / 0.8 - 1) < 0.05)
    }

    @Test func hslHueShiftsOnlyItsBand() {
        let red = solid(0.8, 0.05, 0.03), blue = solid(0.03, 0.08, 0.8), grey = solid(0.3, 0.3, 0.3)
        let edit: (inout Recipe) -> Void = { $0.setScalar(.hsl(.red, .hue), 100, at: testClock.now()) }
        let redBefore = oklabHue(pixel(red)), redAfter = oklabHue(pixel(graded(red, edit)))
        #expect(redAfter - redBefore > 10, "red moved toward orange")
        #expect(abs(oklabHue(pixel(graded(blue, edit))) - oklabHue(pixel(blue))) < 0.5)
        let g = pixel(graded(grey, edit))
        #expect(abs(g.x - 0.3) < 1e-3 && abs(g.z - 0.3) < 1e-3, "neutrals are untouched")
    }

    @Test func hslSaturationDesaturatesBand() {
        let blue = solid(0.03, 0.08, 0.8), red = solid(0.8, 0.05, 0.03)
        let edit: (inout Recipe) -> Void = { $0.setScalar(.hsl(.blue, .saturation), -100, at: testClock.now()) }
        #expect(chroma(pixel(graded(blue, edit))) < 0.03)
        #expect(abs(chroma(pixel(graded(red, edit))) - chroma(pixel(red))) < 1e-3)
    }

    @Test func hslLuminanceBrightensBand() {
        let green = solid(0.05, 0.6, 0.05)
        let after = pixel(graded(green) { $0.setScalar(.hsl(.green, .luminance), 100, at: testClock.now()) })
        #expect(after.y > 0.65)
    }

    /// A smooth hue ramp must stay smooth: no step between neighbors larger than the
    /// largest step in the source, give or take.
    @Test func hslHasNoBanding() {
        let width = 720
        var ramp = [SIMD4<Float>]()
        for i in 0..<width {
            let rgb = ColorMath.hsvToRGB(hue: Double(i) / Double(width) * 360, saturation: 0.8, value: 0.9)
            ramp.append(SIMD4(Float(ColorMath.srgbToLinear(rgb.r)), Float(ColorMath.srgbToLinear(rgb.g)), Float(ColorMath.srgbToLinear(rgb.b)), 1))
        }
        let data = ramp.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: 1), format: .RGBAf, colorSpace: linearSRGB)
        let output = graded(image) { recipe in
            recipe.setScalar(.hsl(.orange, .hue), 100, at: testClock.now())
            recipe.setScalar(.hsl(.aqua, .saturation), -100, at: testClock.now())
            recipe.setScalar(.hsl(.blue, .luminance), -100, at: testClock.now())
            recipe.setScalar(.hsl(.magenta, .hue), -100, at: testClock.now())
        }
        let before = pixels(image), after = pixels(output)
        func maxStep(_ row: [SIMD4<Float>]) -> Float {
            zip(row, row.dropFirst()).map { (a: SIMD4<Float>, b: SIMD4<Float>) -> Float in
                let d = a - b
                return max(abs(d.x), abs(d.y), abs(d.z))
            }.max() ?? 0
        }
        #expect(maxStep(after) < maxStep(before) * 3, "steps: before \(maxStep(before)), after \(maxStep(after))")
    }

    @Test func shadowWheelTintsShadowsNotHighlights() {
        let edit: (inout Recipe) -> Void = { recipe in
            let radians = 240.0 * .pi / 180  // blue
            recipe.set(.gradeWheel(.shadows), .point(x: cos(radians), y: sin(radians)), at: testClock.now())
        }
        let dark = pixel(graded(solid(0.02, 0.02, 0.02), edit))
        let bright = pixel(graded(solid(0.85, 0.85, 0.85), edit))
        #expect(dark.z > dark.x * 1.3)
        #expect(abs(bright.z - bright.x) < 0.02)
    }

    @Test func warmerTemperatureWarms() {
        let defaults = PhotoDefaults(values: [.temperature: 5500, .tint: 0])
        let grey = solid(0.3, 0.3, 0.3)
        let warm = pixel(graded(grey, { $0.setScalar(.temperature, 8000, at: testClock.now()) }, defaults: defaults))
        let cool = pixel(graded(grey, { $0.setScalar(.temperature, 3500, at: testClock.now()) }, defaults: defaults))
        #expect(warm.x > warm.z, "higher Kelvin should look warmer, got \(warm)")
        #expect(cool.z > cool.x, "lower Kelvin should look cooler, got \(cool)")
    }

    @Test func saturationMinus100IsGrey() {
        let p = pixel(graded(solid(0.7, 0.2, 0.1)) { $0.setScalar(.saturation, -100, at: testClock.now()) })
        #expect(abs(p.x - p.y) < 0.01 && abs(p.y - p.z) < 0.01)
    }

    @Test func toneCurveLiftsBlacks() {
        let p = pixel(graded(solid(0, 0, 0)) {
            $0.set(.toneCurve, .curve([CurvePoint(x: 0, y: 0.2), CurvePoint(x: 1, y: 1)]), at: testClock.now())
        })
        #expect(p.x > 0.02)
    }

    @Test func cropAndStraighten() {
        let base = solid(0.5, 0.5, 0.5, size: 400).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        let cropped = graded(base) {
            $0.set(.crop, .crop(CropGeometry(rect: NormalizedRect(x: 0.25, y: 0, width: 0.5, height: 1), angle: 5)), at: testClock.now())
        }
        #expect(cropped.extent == CGRect(x: 0, y: 0, width: 200, height: 200))
        // Straightening never exposes empty corners.
        let corner = pixel(cropped, x: 0, y: 0)
        #expect(corner.w > 0.99)
    }

    @Test func vignetteDarkensCorners() {
        let base = solid(0.5, 0.5, 0.5, size: 100)
        let output = graded(base) { $0.setScalar(.vignetteAmount, -100, at: testClock.now()) }
        let center = pixel(output, x: 50, y: 50), corner = pixel(output, x: 0, y: 0)
        #expect(corner.x < center.x * 0.6)
        #expect(abs(center.x - 0.5) < 0.01)
    }

    struct FixedLUTs: LUTProvider {
        let cube: CubeLUT
        func lut(for ref: LUTRef) -> CubeLUT? { ref.hash == cube.hash ? cube : nil }
    }

    @Test func lutAppliesWithAmount() throws {
        let invert = try CubeParser.parse(makeCube(size: 17) { (1 - $0, 1 - $1, 1 - $2) })
        let provider = FixedLUTs(cube: invert)
        let black = solid(0, 0, 0)
        let full = pixel(graded(black, { $0.set(.lut, .lut(invert.ref, amount: 1), at: testClock.now()) }, luts: provider))
        #expect(full.x > 0.95)
        let half = pixel(graded(black, { $0.set(.lut, .lut(invert.ref, amount: 0.5), at: testClock.now()) }, luts: provider))
        #expect(half.x > 0.05 && half.x < 0.95)
        let missing = pixel(graded(black, { $0.set(.lut, .lut(LUTRef(hash: "nope", name: "x"), amount: 1), at: testClock.now()) }, luts: provider))
        #expect(missing.x < 0.01, "an unknown LUT renders without it")
    }

    @Test func histogramIsNormalized() {
        let histogram = Histogram.compute(solid(0.2, 0.2, 0.2, size: 64))
        #expect(histogram.luma.count == Histogram.binCount)
        #expect(histogram.luma.max() == 1)
    }

    @Test func toneCurveSamplerIsMonotone() {
        let samples = ToneCurveSampler.sample([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.5), CurvePoint(x: 0.6, y: 0.55), CurvePoint(x: 1, y: 1)])
        #expect(samples.first == 0)
        #expect(samples.last == 1)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-6 })
    }

    @Test func cameraNames() {
        #expect(CameraNames.displayName("ILCE-7RM5") == "A7R V")
        #expect(CameraNames.displayName("ILCE-7M4") == "A7 IV")
        #expect(CameraNames.displayName("X-T5") == "X-T5")
    }
}

@Suite(.serialized) struct DecodeTests {
    /// Set EDITORCORE_RAW_FIXTURES to a folder with real ARW/RAF/DNG files to run these.
    static var fixtureFiles: [URL] {
        guard let path = ProcessInfo.processInfo.environment["EDITORCORE_RAW_FIXTURES"] else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { ["arw", "raf", "dng", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    }

    @Test(.enabled(if: !fixtureFiles.isEmpty)) func decodesAndCaches() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let decoder = RawDecoder(cache: DecodeCache(directory: cacheDirectory))
        for url in Self.fixtureFiles {
            let source = PhotoSource(url: url)
            let info = try await decoder.info(for: source)
            let start = ContinuousClock.now
            let decoded = try await decoder.decode(source, rawStage: RawStageParams(), longEdge: 1024)
            let first = ContinuousClock.now - start
            #expect(max(decoded.size.width, decoded.size.height) <= 1024)
            let again = ContinuousClock.now
            _ = try await decoder.decode(source, rawStage: RawStageParams(), longEdge: 1024)
            let second = ContinuousClock.now - again
            print("\(url.lastPathComponent): \(info.badge) decode \(first), cached \(second), defaults \(info.defaults.values)")
            #expect(second < first)
            if info.isRAW { #expect(info.supportsRAW9, "\(url.lastPathComponent) should support RAW 9") }
        }
    }
}

@Suite @MainActor struct JobCenterTests {
    @Test func runsAndReports() async throws {
        let center = JobCenter()
        center.revealDelay = .zero
        center.lingerDuration = .milliseconds(10)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let task = center.run("Work") { reporter in
            reporter.progress(0.5)
            for await _ in gate { break }
            return 42
        }
        // Wait until the job is revealed while it's blocked on the gate.
        for _ in 0..<200 where center.activeCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(center.activeCount == 1)
        #expect(center.visibleJobs.first?.progress == 0.5)
        open.yield()
        #expect(try await task.value == 42)
        for _ in 0..<200 where !center.jobs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(center.jobs.isEmpty)
    }

    @Test func cancels() async throws {
        let center = JobCenter()
        center.revealDelay = .zero
        let task = center.run("Long") { _ in
            try await Task.sleep(for: .seconds(10))
            return 1
        }
        try await Task.sleep(for: .milliseconds(20))
        center.jobs.first?.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(center.jobs.first?.state == .cancelled)
    }

    @Test func reportsChangesToObserver() async throws {
        let center = JobCenter()
        var seen: [(Double?, String?, Job.State)] = []
        let task = center.run("Batch", started: { job in
            job.onChange = { seen.append(($0.progress, $0.detail, $0.state)) }
        }) { reporter in
            reporter.progress(0.5, detail: "1 of 2")
            try await Task.sleep(for: .milliseconds(20))
            return 2
        }
        #expect(try await task.value == 2)
        for _ in 0..<200 where seen.last?.2 != .finished { try await Task.sleep(for: .milliseconds(5)) }
        #expect(seen.contains { $0.0 == 0.5 && $0.1 == "1 of 2" })
        #expect(seen.last?.2 == .finished)
        #expect(seen.last?.0 == 1)
    }

    @Test func quickJobsStayHidden() async throws {
        let center = JobCenter()
        center.revealDelay = .milliseconds(200)
        _ = try await center.run("Quick") { _ in 1 }.value
        #expect(center.visibleJobs.isEmpty)
    }
}

@Suite struct FolderLibraryTests {
    @Test func savesAndReadsEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = solid(0.5, 0.2, 0.1, size: 32)
        let jpeg = try #require(RenderContext.shared.jpegRepresentation(of: image, colorSpace: RenderContext.sRGB))
        try jpeg.write(to: directory.appending(path: "a.jpg"))
        let library = FolderLibrary(directory: directory)
        let assets = await library.assets(in: .recents)
        #expect(assets.count == 1)
        #expect(await library.assets(in: .raw).count == 0)
        let session = try await library.beginEditing(assets[0]) { _ in }
        guard case .none = session.stored else { Issue.record("expected no edit"); return }
        var recipe = Recipe(decoder: .none)
        recipe.setScalar(.exposure, 1, at: testClock.now())
        let rendered = try await Exporter.render(source: session.original, recipe: recipe, luts: nil, options: ExportOptions(format: .jpeg))
        try await library.save(session, recipe: recipe, rendered: rendered, format: .jpeg)
        guard case .ours(let stored) = await library.storedEdit(for: assets[0]) else { Issue.record("expected our edit"); return }
        #expect(stored == recipe)
        #expect(await library.assets(in: .recentlyEdited).count == 1)
    }
}

@Suite struct HSLSelectionTests {
    @Test func showsOnlyTheBand() {
        let blue = solid(0.03, 0.08, 0.8), red = solid(0.8, 0.05, 0.03)
        func shown(_ image: CIImage, _ band: HueBand) -> SIMD4<Float> {
            pixel(GradeGraph.apply(Recipe(), to: image, inputs: { var i = GradeInputs(defaults: .generic); i.hslSelection = band; return i }()))
        }
        let blueShown = shown(blue, .blue)
        #expect(blueShown.z > 0.7, "blue stays blue")
        let redHidden = shown(red, .blue)
        #expect(abs(redHidden.x - redHidden.z) < 0.01, "red turns gray")
        #expect(redHidden.x < 0.2, "and dim")
    }
}

@Suite struct ExportSizingTests {
    @Test func megapixelsToLongEdge() {
        let full = CGSize(width: 9504, height: 6336)
        let edge = ExportSizing.longEdge(megapixels: 24, for: full)
        let size = ExportSizing.size(longEdge: edge, full: full)
        #expect(abs(size.width * size.height / 1_000_000 - 24) < 0.1)
        #expect(abs(size.width / size.height - 1.5) < 0.01)
        #expect(ExportSizing.size(longEdge: 20_000, full: full) == full, "never upscales")
        #expect(ExportSizing.size(longEdge: nil, full: full) == full)
    }

    @Test func estimatesScaleWithPixels() {
        let small = ExportSizing.estimatedBytes(sampleBytes: 300_000, samplePixels: 1_000_000, targetPixels: 2_000_000)
        let large = ExportSizing.estimatedBytes(sampleBytes: 300_000, samplePixels: 1_000_000, targetPixels: 24_000_000)
        #expect(small == 480_000)
        #expect(large == small * 12)
    }

    @Test func samplesEncode() throws {
        let image = solid(0.4, 0.5, 0.6, size: 256)
        let jpeg = try #require(ExportSizing.sampleBytes(image, format: .jpeg, quality: 0.9))
        let heic = try #require(ExportSizing.sampleBytes(image, format: .heic, quality: 0.9))
        #expect(jpeg > 0 && heic > 0)
    }
}

@Suite struct PresenceGuideTests {
    /// Soft blobs over a ramp: broad and mid-scale detail like a photo's.
    private func scene(width: CGFloat, height: CGFloat) -> CIImage {
        let blobs = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 40, y: 40))
            .applyingGaussianBlur(sigma: 30)
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: width, y: height),
            "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.05), "inputColor1": CIColor(red: 0.6, green: 0.6, blue: 0.6),
        ])!.outputImage!
        return blobs.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: ramp])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test func guidedClarityAndDehazeMatchFullResolution() {
        let full = scene(width: 3000, height: 2000)
        let guide = full.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.25, kCIInputAspectRatioKey: 1])
        var recipe = Recipe()
        let stamp = HLCStamp(millis: 1, node: "test")
        recipe.setScalar(.clarity, 70, at: stamp)
        recipe.setScalar(.dehaze, 40, at: stamp)
        recipe.setScalar(.texture, 30, at: stamp)
        var inputs = GradeInputs(defaults: .generic)
        let reference = GradeGraph.apply(recipe, to: full, inputs: inputs)
        inputs.presenceGuide = guide
        let fast = GradeGraph.apply(recipe, to: full, inputs: inputs)
        // Compare a patch in the middle and one at an edge.
        for rect in [CGRect(x: 1400, y: 900, width: 64, height: 64), CGRect(x: 0, y: 0, width: 64, height: 64)] {
            let a = pixels(reference, rect: rect), b = pixels(fast, rect: rect)
            let error = zip(a, b).map { abs($0.x - $1.x) + abs($0.y - $1.y) + abs($0.z - $1.z) }.reduce(0, +) / Float(a.count * 3)
            #expect(error < 0.01, "mean error \(error) at \(rect)")
        }
        // And the edit did something, so the comparison means something.
        let plain = pixels(full, rect: CGRect(x: 1400, y: 900, width: 64, height: 64))
        let edited = pixels(reference, rect: CGRect(x: 1400, y: 900, width: 64, height: 64))
        #expect(zip(plain, edited).map { abs($0.x - $1.x) }.reduce(0, +) / Float(plain.count) > 0.01)
    }

    @Test func guideNotMuchSmallerIsIgnored() {
        let full = scene(width: 1000, height: 600)
        var recipe = Recipe()
        recipe.setScalar(.clarity, 70, at: HLCStamp(millis: 1, node: "test"))
        var inputs = GradeInputs(defaults: .generic)
        let reference = GradeGraph.apply(recipe, to: full, inputs: inputs)
        inputs.presenceGuide = full.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.9, kCIInputAspectRatioKey: 1])
        let same = GradeGraph.apply(recipe, to: full, inputs: inputs)
        let rect = CGRect(x: 500, y: 300, width: 8, height: 8)
        #expect(pixels(reference, rect: rect) == pixels(same, rect: rect))
    }
}
