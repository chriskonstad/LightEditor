import CoreImage
import Foundation
import Synchronization
import Testing
@testable import EditorCore

/// A round spot at a normalized point.
func dot(_ x: Double, _ y: Double, radius: Double = 0.05, kind: RetouchSpot.Kind, offset: NormalizedPoint? = nil, order: Double = 1) -> RetouchSpot {
    RetouchSpot(order: order, kind: kind, strokes: [BrushStroke(points: [NormalizedPoint(x: x, y: y)], radius: radius, feather: 0.2)], sourceOffset: offset)
}

func render(_ spots: [RetouchSpot], on image: CIImage, inpaints: (any InpaintProvider)? = nil) -> CIImage {
    var recipe = Recipe()
    for spot in spots { recipe.setRetouch(spot, at: testClock.now()) }
    var inputs = GradeInputs(defaults: .generic)
    inputs.inpaints = inpaints
    return GradeGraph.apply(recipe, to: image, inputs: inputs)
}

/// Left half `left`, right half `right`, 200×100.
func halves(_ left: (Double, Double, Double), _ right: (Double, Double, Double)) -> CIImage {
    let l = solid(left.0, left.1, left.2, size: 200).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
    let r = solid(right.0, right.1, right.2, size: 200).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
    return r.composited(over: l)
}

@Suite struct RetouchModelTests {
    @Test func roundTripsAndOrders() throws {
        var recipe = Recipe()
        let heal = dot(0.2, 0.3, kind: .heal, offset: NormalizedPoint(x: 0.1, y: 0), order: 2)
        let remove = dot(0.5, 0.5, kind: .remove, order: 1)
        recipe.setRetouch(heal, at: testClock.now())
        recipe.setRetouch(remove, at: testClock.now())
        #expect(recipe.retouches.map(\.id) == [remove.id, heal.id])
        #expect(try RecipeCodec.decode(try RecipeCodec.encode(recipe)) == recipe)
        #expect(recipe.nextRetouchOrder == 3)
    }

    @Test func chainKeysAreStable() {
        let spots = [dot(0.5, 0.5, kind: .remove), dot(0.2, 0.2, kind: .heal, offset: NormalizedPoint(x: 0.1, y: 0.1))]
        let keys = Set((0..<20).map { _ in RetouchRenderer.chainKey(spots[...1]) })
        #expect(keys.count == 1)
        #expect(RetouchRenderer.chainKey(spots[...0]) != RetouchRenderer.chainKey(spots[...1]))
    }

    @Test func retouchIsPerPhotoWhenPasting() {
        var source = Recipe()
        source.setRetouch(dot(0.5, 0.5, kind: .remove), at: testClock.now())
        let clip = RecipeClip(recipe: source, sourceName: "A", sourceDefaults: .generic)
        #expect(!PasteGroup.defaultSelection.contains(.retouch))
        #expect(Recipe().pasting(clip, groups: PasteGroup.defaultSelection, mode: .set, targetDefaults: .generic, stamp: testClock.now()).retouches.isEmpty)
        #expect(Recipe().pasting(clip, groups: [.retouch], mode: .set, targetDefaults: .generic, stamp: testClock.now()).retouches.count == 1)
    }

    @Test func boundsCoverTheBrush() {
        let spot = RetouchSpot(order: 1, kind: .remove, strokes: [BrushStroke(points: [NormalizedPoint(x: 0.2, y: 0.3), NormalizedPoint(x: 0.4, y: 0.35)], radius: 0.05)])
        let b = spot.bounds
        #expect(abs(b.x - 0.15) < 1e-9 && abs(b.y - 0.25) < 1e-9)
        #expect(abs(b.width - 0.3) < 1e-9 && abs(b.height - 0.15) < 1e-9)
        let region = RetouchRenderer.inpaintRegion(for: spot, imageSize: CGSize(width: 2000, height: 1000))
        #expect(region.x <= b.x && region.y <= b.y && region.x + region.width >= b.x + b.width)
        #expect(region.x >= 0 && region.y >= 0 && region.x + region.width <= 1 && region.y + region.height <= 1)
        #expect(abs(region.width * 2000 - region.height * 1000) < 1, "square in pixels")
    }
}

@Suite struct RetouchRenderTests {
    @Test func cloneCopiesTheSource() {
        let image = halves((0.8, 0.1, 0.1), (0.1, 0.1, 0.8))
        let output = render([dot(0.25, 0.5, radius: 0.08, kind: .clone, offset: NormalizedPoint(x: 0.5, y: 0))], on: image)
        let center = pixel(output, x: 50, y: 50)
        #expect(center.z > 0.7 && center.x < 0.2, "the red spot now shows the blue source")
        #expect(pixel(output, x: 10, y: 10).x > 0.7, "outside the spot is untouched")
    }

    @Test func healMatchesTheTargetsTone() {
        // A dark speck on mid gray; the source area is brighter but equally smooth.
        let gray = solid(0.3, 0.3, 0.3, size: 200).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bright = solid(0.6, 0.6, 0.6, size: 200).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let speck = solid(0.01, 0.01, 0.01, size: 200).cropped(to: CGRect(x: 47, y: 47, width: 6, height: 6))
        let image = speck.composited(over: bright.composited(over: gray))
        let offset = NormalizedPoint(x: 0.5, y: 0)
        let healed = pixel(render([dot(0.25, 0.5, radius: 0.04, kind: .heal, offset: offset)], on: image), x: 50, y: 50)
        let cloned = pixel(render([dot(0.25, 0.5, radius: 0.04, kind: .clone, offset: offset)], on: image), x: 50, y: 50)
        #expect(abs(healed.x - 0.3) < 0.06, "heal keeps the surrounding tone, got \(healed.x)")
        #expect(abs(cloned.x - 0.6) < 0.02, "clone copies the source as-is")
    }

    @Test func spotsChainInOrder() {
        let image = halves((0.8, 0.1, 0.1), (0.1, 0.1, 0.8))
        // First clone blue into the left, then clone that (now blue) area further left.
        let first = dot(0.3, 0.5, radius: 0.06, kind: .clone, offset: NormalizedPoint(x: 0.4, y: 0), order: 1)
        let second = dot(0.1, 0.5, radius: 0.06, kind: .clone, offset: NormalizedPoint(x: 0.2, y: 0), order: 2)
        let output = render([first, second], on: image)
        #expect(pixel(output, x: 20, y: 50).z > 0.7)
    }

    @Test func autoSourceStaysOnMatchingSurroundings() {
        // Bright sky on top, dark ground below; a spot in the sky should heal from sky.
        let sky = solid(0.7, 0.75, 0.9, size: 400).cropped(to: CGRect(x: 0, y: 150, width: 400, height: 150))
        let ground = solid(0.05, 0.06, 0.04, size: 400).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 150))
        let image = sky.composited(over: ground)
        let cg = RenderContext.shared.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: RenderContext.sRGB)!
        let spot = dot(0.5, 0.2, radius: 0.04, kind: .heal)
        let offset = RetouchRenderer.autoSource(for: spot, in: cg)
        let sourceY = 0.2 + offset.y
        #expect(sourceY < 0.45, "source stays in the sky, got y \(sourceY)")
    }

    @Test func removeWithoutAFillChangesNothing() {
        let image = halves((0.8, 0.1, 0.1), (0.1, 0.1, 0.8))
        let output = render([dot(0.25, 0.5, kind: .remove)], on: image)
        #expect(abs(pixel(output, x: 50, y: 50).x - 0.8) < 0.01)
    }
}

/// Runs the real LaMa model. Needs Models/LaMa.mlpackage (scripts/fetch-models.sh).
@Suite(.serialized) struct InpaintTests {
    static let modelURL: URL? = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Models/LaMa.mlpackage")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    @Test(.enabled(if: modelURL != nil)) func removesAnObject() throws {
        Inpainter.shared.configure(modelURL: Self.modelURL)
        // Mid-gray scene with a red "object" in the middle.
        let gray = solid(0.25, 0.25, 0.25, size: 800).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
        let object = solid(0.9, 0.05, 0.05, size: 800).cropped(to: CGRect(x: 370, y: 270, width: 60, height: 60))
        let image = object.composited(over: gray)
        let spot = dot(0.5, 0.5, radius: 0.06, kind: .remove)
        let store = InpaintStore(photoKey: UUID().uuidString, directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var recipe = Recipe()
        recipe.setRetouch(spot, at: testClock.now())
        let start = ContinuousClock.now
        try store.compute(spots: recipe.retouches, index: 0, base: image)
        print("inpaint took \(ContinuousClock.now - start)")
        #expect(store.hasPatch(for: RetouchRenderer.chainKey(recipe.retouches[...0])))
        let output = render(recipe.retouches, on: image, inpaints: store)
        let center = pixel(output, x: 400, y: 300)
        print("center after removal \(center)")
        #expect(center.x < 0.45 && abs(center.x - center.z) < 0.15, "the red object is gone")
        #expect(abs(pixel(output, x: 50, y: 50).x - 0.25) < 0.01, "far away is untouched")
    }

    /// The 1024 fill must be clean: on the Neural Engine it comes back as noise.
    @Test(.enabled(if: modelURL != nil)) func fullSizeFillIsClean() throws {
        Inpainter.shared.configure(modelURL: Self.modelURL)
        #expect(Inpainter.shared.fullSize == 1024)
        #expect(Inpainter.shared.size(for: .fast) == 512)
        let square = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let image = try #require(RenderContext.shared.createCGImage(solid(0.3, 0.3, 0.3, size: 1024), from: square, format: .RGBA8, colorSpace: RenderContext.sRGB))
        let disc = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 512, y: 512), "inputRadius0": 200, "inputRadius1": 202,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: square)
        let mask = try #require(RenderContext.shared.createCGImage(disc, from: square, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)))
        let start = ContinuousClock.now
        let output = try Inpainter.shared.inpaint(image: image, mask: mask, size: 1024)
        print("INPAINT 1024 took \(ContinuousClock.now - start)")
        #expect(output.width == 1024)
        let center = pixels(CIImage(cgImage: output), rect: CGRect(x: 412, y: 412, width: 200, height: 200))
        let mean = center.map { Double($0.y) }.reduce(0, +) / Double(center.count)
        let spread = (center.map { pow(Double($0.y) - mean, 2) }.reduce(0, +) / Double(center.count)).squareRoot()
        #expect(spread < 0.05, "a flat gray scene fills flat, not as noise: std \(spread)")
    }

    /// Standard fills come from the full-resolution image, not the preview.
    @Test(.enabled(if: modelURL != nil)) func fillsFromTheFullResolutionOriginal() async throws {
        Inpainter.shared.configure(modelURL: Self.modelURL)
        func scene(_ scale: CGFloat) -> CIImage {
            let gray = solid(0.25, 0.25, 0.25, size: 2400 * scale).cropped(to: CGRect(x: 0, y: 0, width: 2400 * scale, height: 1600 * scale))
            let object = solid(0.9, 0.05, 0.05, size: 2400 * scale).cropped(to: CGRect(x: 1160 * scale, y: 760 * scale, width: 80 * scale, height: 80 * scale))
            return object.composited(over: gray)
        }
        let full = scene(1), preview = scene(0.25)
        let store = InpaintStore(photoKey: UUID().uuidString, directory: nil)
        var recipe = Recipe()
        recipe.setRetouch(dot(0.5, 0.5, radius: 0.03, kind: .remove), at: testClock.now())
        let fullBox = UncheckedBox(full)
        try await store.prepare(recipe, preview: preview, fullResolution: { fullBox.value })
        let output = render(recipe.retouches, on: full, inpaints: store)
        let center = pixel(output, x: 1200, y: 800)
        #expect(center.x < 0.45 && abs(center.x - center.z) < 0.15, "removed at full resolution: \(center)")
    }

    /// Removes several objects one after another, the way the editor adds spots.
    @Test(.enabled(if: modelURL != nil)) func removesSeveralObjectsInTurn() async throws {
        Inpainter.shared.configure(modelURL: Self.modelURL)
        let gray = solid(0.25, 0.25, 0.25, size: 1200).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let centers = [(200.0, 400.0), (600.0, 400.0), (1000.0, 400.0)]
        var image = gray
        for (x, y) in centers {
            image = solid(0.9, 0.05, 0.05, size: 1200).cropped(to: CGRect(x: x - 30, y: y - 30, width: 60, height: 60)).composited(over: image)
        }
        let store = InpaintStore(photoKey: UUID().uuidString, directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var recipe = Recipe()
        for (order, (x, y)) in centers.enumerated() {
            recipe.setRetouch(dot(x / 1200, 1 - y / 800, radius: 0.04, kind: .remove, order: Double(order + 1)), at: testClock.now())
            try await store.prepare(recipe, base: image)
        }
        let output = render(recipe.retouches, on: image, inpaints: store)
        for (x, y) in centers {
            let center = pixel(output, x: x, y: y)
            #expect(center.x < 0.45 && abs(center.x - center.z) < 0.15, "the object at \(x) is gone: \(center)")
        }
    }
}

@Suite struct AutoSourceColorTests {
    /// A narrow green wall between red doors: a spot on the wall must heal from the wall.
    @Test func prefersMatchingColorOverMatchingBrightness() {
        let red = solid(0.45, 0.05, 0.04, size: 400).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let green = solid(0.03, 0.12, 0.08, size: 400).cropped(to: CGRect(x: 180, y: 0, width: 60, height: 400))
        let image = green.composited(over: red)
        let cg = RenderContext.shared.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: RenderContext.sRGB)!
        let spot = RetouchSpot(order: 1, kind: .heal, strokes: [BrushStroke(points: [NormalizedPoint(x: 0.525, y: 0.4)], radius: 0.03)])
        let offset = RetouchRenderer.autoSource(for: spot, in: cg)
        let sourceCenterX = 0.525 + offset.x
        #expect(sourceCenterX > 0.46 && sourceCenterX < 0.59, "source x \(sourceCenterX) should stay on the green wall")
    }
}

@Suite struct AutoSourceStructureTests {
    /// A spot on a vertical stripe: the matching source continues along the stripe.
    @Test func followsStructure() {
        let background = solid(0.45, 0.05, 0.04, size: 400).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let stripe = solid(0.03, 0.12, 0.08, size: 400).cropped(to: CGRect(x: 190, y: 0, width: 30, height: 400))
        let image = stripe.composited(over: background)
        let cg = RenderContext.shared.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: RenderContext.sRGB)!
        let spot = RetouchSpot(order: 1, kind: .heal, strokes: [BrushStroke(points: [NormalizedPoint(x: 0.5125, y: 0.5)], radius: 0.02)])
        let offset = RetouchRenderer.autoSource(for: spot, in: cg)
        #expect(abs(offset.x) < 0.01, "stays on the stripe, got x offset \(offset.x)")
        #expect(abs(offset.y) > 0.03, "moves along it, got y offset \(offset.y)")
    }
}

@Suite struct InpaintRegionTests {
    @Test func regionNeverUpscalesAndStaysInFrame() {
        let spot = dot(0.5, 0.5, radius: 0.005, kind: .remove)
        let size = CGSize(width: 9504, height: 6336)
        let region = RetouchRenderer.inpaintRegion(for: spot, imageSize: size, minimumSide: 1024)
        #expect(abs(region.width * size.width - 1024) < 1, "small spots get a native-resolution 1024 px crop")
        let big = dot(0.9, 0.9, radius: 0.3, kind: .remove)
        let bigRegion = RetouchRenderer.inpaintRegion(for: big, imageSize: size, minimumSide: 1024)
        #expect(bigRegion.x + bigRegion.width <= 1.0001 && bigRegion.y + bigRegion.height <= 1.0001)
        #expect(bigRegion.height * size.height <= size.height + 0.5)
    }
}

@Suite struct EnclosedFillTests {
    /// Circling an object with Remove selects its inside too.
    @Test func removeFillsInsideALoop() {
        var points: [NormalizedPoint] = []
        for step in 0...24 {
            let angle = Double(step) / 24 * 2 * .pi
            points.append(NormalizedPoint(x: 0.5 + cos(angle) * 0.2, y: 0.5 + sin(angle) * 0.2))
        }
        let stroke = BrushStroke(points: points, radius: 0.02, feather: 0.2)
        let extent = CGRect(x: 0, y: 0, width: 400, height: 400)
        let remove = RetouchRenderer.spotMask(RetouchSpot(order: 1, kind: .remove, strokes: [stroke]), extent: extent)
        let heal = RetouchRenderer.spotMask(RetouchSpot(order: 1, kind: .heal, strokes: [stroke]), extent: extent)
        #expect(pixel(remove, x: 200, y: 200).x > 0.9, "inside the loop is removed")
        #expect(pixel(heal, x: 200, y: 200).x < 0.1, "heal stays on the stroke")
        #expect(pixel(remove, x: 20, y: 20).x < 0.1, "outside stays untouched")
    }
}

@Suite struct InpaintGuardTests {
    @Test func theLargeModelStaysOffTheNeuralEngine() {
        #expect(Inpainter.units(for: 1024) == .cpuAndGPU)
        #expect(Inpainter.units(for: 512) == .all)
    }

    @Test func spotsNoiseInTheFilledArea() {
        let size = 64
        var mask = [UInt8](repeating: 0, count: size * size)
        for y in 16..<48 { for x in 16..<48 { mask[y * size + x] = 255 } }
        var smooth = [UInt8](repeating: 120, count: size * size * 4)
        for i in Swift.stride(from: 0, to: smooth.count, by: 4) { smooth[i + 1] = UInt8(100 + (i / 4) % size / 8) }
        #expect(!Inpainter.looksLikeNoise(smooth, mask: mask, size: size))
        var noisy = smooth
        var seed: UInt64 = 7
        for y in 16..<48 {
            for x in 16..<48 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                noisy[(y * size + x) * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        #expect(Inpainter.looksLikeNoise(noisy, mask: mask, size: size))
    }
}

@Suite struct DiffusionSamplerTests {
    /// With a perfect noise predictor, the sampler lands exactly on the clean latent.
    @Test func anOracleModelRecoversTheCleanLatent() async throws {
        var rng = SeededNoise(seed: 1)
        let clean = rng.gaussian(count: 64).map { $0 * 0.5 }
        let noise = rng.gaussian(count: 64)
        for (steps, strength) in [(30, 1.0), (30, 0.6), (8, 1.0)] {
            let sampler = DiffusionSampler(steps: steps, strength: strength)
            let start = sampler.noised(clean, noise: noise)
            let result = try await sampler.sample(from: start) { x, t, _ in
                let a = Float(DiffusionSampler.alpha(t)), s = Float(DiffusionSampler.sigma(t))
                return zip(x, clean).map { ($0 - a * $1) / s }
            }
            let error = zip(result, clean).map { abs($0 - $1) }.max() ?? 0
            #expect(error < 1e-3, "steps \(steps) strength \(strength): \(error)")
        }
    }

    @Test func strengthStartsPartway() {
        #expect(DiffusionSampler(steps: 30).timesteps.first == 999)
        #expect(DiffusionSampler(steps: 30).timesteps.count == 30)
        let partial = DiffusionSampler(steps: 30, strength: 0.6)
        #expect(partial.timesteps.count == 18)
        #expect(partial.timesteps.first! < 700 && partial.timesteps.first! > 550)
        #expect(partial.timesteps.last! < 50)
    }

    @Test func noiseIsSeededAndNormal() {
        var a = SeededNoise(seed: 42), b = SeededNoise(seed: 42), c = SeededNoise(seed: 43)
        let x = a.gaussian(count: 20000)
        #expect(x.prefix(10).elementsEqual(b.gaussian(count: 10)))
        #expect(!x.prefix(10).elementsEqual(c.gaussian(count: 10)))
        let mean = x.reduce(0, +) / Float(x.count)
        let variance = x.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(x.count)
        #expect(abs(mean) < 0.03 && abs(variance - 1) < 0.05)
    }
}

/// Runs LaMa + Stable Diffusion inpainting for real. Needs the models from
/// scripts/fetch-models.sh in Models/.
@Suite(.serialized) struct DiffusionInpaintTests {
    static let modelsDirectory = InpaintTests.modelURL?.deletingLastPathComponent()

    static let models: DiffusionInpainter.Models? = {
        guard let directory = modelsDirectory else { return nil }
        let models = DiffusionInpainter.Models(
            unet: directory.appending(path: "SDInpaintUNet.mlpackage"),
            encoder: directory.appending(path: "SDInpaintVAEEncoder.mlpackage"),
            decoder: directory.appending(path: "SDInpaintVAEDecoder.mlpackage"),
            embeddings: directory.appending(path: "SDInpaintEmbeddings.bin"))
        let all = [models.unet, models.encoder, models.decoder, models.embeddings]
        return all.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? models : nil
    }()

    @Test(.enabled(if: models != nil)) func removesAnObjectWithDiffusion() async throws {
        Inpainter.shared.configure(modelURL: InpaintTests.modelURL)
        DiffusionInpainter.shared.configure(Self.models)
        var settings = DiffusionInpainter.shared.settings
        settings.steps = 12  // Fewer steps keep the test quick.
        DiffusionInpainter.shared.settings = settings
        defer { DiffusionInpainter.shared.release() }
        // A textured gray scene with a red object in the middle.
        let base = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
            .applyingFilter("CIRandomGenerator").cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 0.15, kCIInputBrightnessKey: -0.2])
        let object = solid(0.9, 0.05, 0.05, size: 1200).cropped(to: CGRect(x: 560, y: 360, width: 80, height: 80))
        let image = object.composited(over: base)
        let store = InpaintStore(photoKey: UUID().uuidString, directory: nil)
        var recipe = Recipe()
        recipe.setRetouch(RetouchSpot(order: 1, kind: .remove, strokes: [BrushStroke(points: [NormalizedPoint(x: 0.5, y: 0.5)], radius: 0.06, feather: 0.2)], engine: .diffusion), at: testClock.now())
        let steps = Mutex(0)
        let start = ContinuousClock.now
        try await store.prepare(recipe, preview: image, stepProgress: { _ in steps.withLock { $0 += 1 } })
        print("DIFFUSION took \(ContinuousClock.now - start), \(steps.withLock { $0 }) progress updates")
        #expect(steps.withLock { $0 } >= 7, "reports each step")
        let output = render(recipe.retouches, on: image, inpaints: store)
        let center = pixel(output, x: 600, y: 400)
        print("DIFFUSION center \(center)")
        #expect(center.x < 0.5 && abs(center.x - center.y) < 0.2, "the red object is gone")
    }
}
