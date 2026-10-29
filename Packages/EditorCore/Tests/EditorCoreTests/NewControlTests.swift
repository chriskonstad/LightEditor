import CoreImage
import Foundation
import Testing
@testable import EditorCore

/// A left/right step edge, dark to bright, in linear sRGB.
func edgeImage(width: Int = 200, height: Int = 20, dark: Double = 0.05, bright: Double = 0.4) -> CIImage {
    let left = solid(dark, dark, dark, size: CGFloat(width)).cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
    let right = solid(bright, bright, bright, size: CGFloat(width)).cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    return right.composited(over: left)
}

@Suite struct PresenceTests {
    @Test func clarityIncreasesEdgeContrast() {
        let base = edgeImage()
        let output = graded(base) { $0.setScalar(.clarity, 100, at: testClock.now()) }
        let darkBefore = pixel(base, x: 97, y: 10).x, brightBefore = pixel(base, x: 103, y: 10).x
        let darkAfter = pixel(output, x: 97, y: 10).x, brightAfter = pixel(output, x: 103, y: 10).x
        #expect(darkAfter < darkBefore)
        #expect(brightAfter > brightBefore)
    }

    @Test func clarityLeavesFlatAreasAlone() {
        let output = graded(solid(0.2, 0.2, 0.2, size: 64)) { $0.setScalar(.clarity, 100, at: testClock.now()) }
        #expect(abs(pixel(output, x: 32, y: 32).x - 0.2) < 2e-3)
    }

    @Test func textureWorksAtFineScale() {
        let output = graded(edgeImage()) { $0.setScalar(.texture, 100, at: testClock.now()) }
        #expect(pixel(output, x: 99, y: 10).x < 0.05)
        #expect(abs(pixel(output, x: 20, y: 10).x - 0.05) < 2e-3, "far from the edge nothing changes")
    }

    @Test func dehazeDeepensHazyAreas() {
        let haze = solid(0.6, 0.62, 0.65, size: 64)
        let cleared = pixel(graded(haze) { $0.setScalar(.dehaze, 80, at: testClock.now()) }, x: 32, y: 32)
        let added = pixel(graded(solid(0.1, 0.1, 0.1, size: 64)) { $0.setScalar(.dehaze, -80, at: testClock.now()) }, x: 32, y: 32)
        #expect(cleared.x < 0.6)
        #expect(added.x > 0.1, "negative dehaze lifts toward the airlight")
    }
}

@Suite struct GrainTests {
    func variance(_ image: CIImage) -> Float {
        let values = pixels(image, rect: CGRect(x: 0, y: 0, width: 64, height: 64)).map(\.y)
        let mean = values.reduce(0, +) / Float(values.count)
        return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
    }

    @Test func grainAddsNoiseInMidtones() {
        let base = solid(0.2, 0.2, 0.2, size: 256)
        let grainy = graded(base) { $0.setScalar(.grainAmount, 80, at: testClock.now()) }
        #expect(variance(base) < 1e-8)
        #expect(variance(grainy) > 1e-6)
        #expect(grainy.extent == base.extent)
    }

    @Test func grainIsDeterministic() {
        let base = solid(0.2, 0.2, 0.2, size: 128)
        let a = pixels(graded(base) { $0.setScalar(.grainAmount, 50, at: testClock.now()) }, rect: CGRect(x: 0, y: 0, width: 32, height: 1))
        let b = pixels(graded(base) { $0.setScalar(.grainAmount, 50, at: testClock.now()) }, rect: CGRect(x: 0, y: 0, width: 32, height: 1))
        #expect(a == b)
    }
}

@Suite struct GeometryTests {
    @Test(arguments: [(50.0, 0.0), (-50.0, 0.0), (0.0, 60.0), (0.0, -60.0), (40.0, -40.0)])
    func perspectiveKeepsFrameCovered(vertical: Double, horizontal: Double) {
        let base = solid(0.5, 0.5, 0.5, size: 300).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        let output = graded(base) {
            $0.setScalar(.perspectiveVertical, vertical, at: testClock.now())
            $0.setScalar(.perspectiveHorizontal, horizontal, at: testClock.now())
        }
        #expect(output.extent == base.extent)
        for (x, y) in [(0.0, 0.0), (299.0, 0.0), (0.0, 199.0), (299.0, 199.0)] {
            #expect(pixel(output, x: x, y: y).w > 0.99, "corner \(x),\(y) is empty")
        }
    }

    @Test func perspectiveWithCrop() {
        let base = solid(0.5, 0.5, 0.5, size: 400).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        let output = graded(base) {
            $0.setScalar(.perspectiveVertical, 30, at: testClock.now())
            $0.set(.crop, .crop(CropGeometry(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1), angle: 3)), at: testClock.now())
        }
        #expect(output.extent == CGRect(x: 0, y: 0, width: 200, height: 200))
    }
}

@Suite struct GlobalWheelTests {
    @Test func globalWheelTintsEverything() {
        let edit: (inout Recipe) -> Void = { $0.set(.gradeWheel(.global), .point(x: cos(.pi * 0.2), y: sin(.pi * 0.2)), at: testClock.now()) }
        for value in [0.02, 0.2, 0.8] {
            let p = pixel(graded(solid(value, value, value), edit))
            #expect(p.x > p.z, "value \(value) should warm")
        }
    }
}

@Suite struct AutoToneTests {
    @Test func brightensDarkPhotos() {
        let values = AutoTone.values(for: edgeImage(width: 256, height: 64, dark: 0.003, bright: 0.02))
        #expect((values[.exposure] ?? 0) > 0.5)
    }

    @Test func darkensBrightPhotos() {
        let values = AutoTone.values(for: edgeImage(width: 256, height: 64, dark: 0.6, bright: 1.2))
        #expect((values[.exposure] ?? 0) < 0)
        #expect((values[.highlights] ?? 0) < 0, "clipped highlights are recovered")
    }

    @Test func leavesWellExposedPhotosMostlyAlone() {
        // An even ramp across the gamma-encoded range is already well exposed.
        let width = 256
        var ramp = [SIMD4<Float>]()
        for i in 0..<width {
            let v = 0.03 + 0.94 * Double(i) / Double(width - 1)
            let linear = Float(pow(v, 2.2))
            ramp.append(SIMD4(linear, linear, linear, 1))
        }
        let data = ramp.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: 1), format: .RGBAf, colorSpace: linearSRGB)
        let values = AutoTone.values(for: image)
        #expect(abs(values[.exposure] ?? 0) < 0.4, "\(values)")
        #expect(values[.highlights] == nil)
    }
}

@Suite struct FilmSimulationTests {
    @Test func codesMapToPresetNames() {
        #expect(FilmSimulations.name(forCode: 0xA00) == "Nostalgic Neg.")
        #expect(FilmSimulations.name(forCode: 0x600) == "Classic Chrome")
        #expect(FilmSimulations.name(forCode: 0x800) == "Classic Neg.")
        #expect(FilmSimulations.name(forCode: 0x1234) == nil)
        for code in [0x000, 0x200, 0x500, 0x501, 0x600, 0x700, 0x800, 0x900, 0xA00, 0xB00] {
            let name = FilmSimulations.name(forCode: code)!
            #expect(FilmSimulations.preset(named: name) != nil, "\(name) has a preset")
        }
    }

    @Test func detectsFromMetadata() {
        let properties: [CFString: Any] = ["{PictureStyle}" as CFString: ["FilmSimulation": ["2560", 2560, 2560], "Monochrome": ["0", 0, 0]]]
        #expect(FilmSimulations.detect(in: properties) == "Nostalgic Neg.")
        let mono: [CFString: Any] = ["{PictureStyle}" as CFString: ["FilmSimulation": ["0", 0, 0], "Monochrome": ["1", 1, 1]]]
        #expect(FilmSimulations.detect(in: mono) == "Monochrome")
        #expect(FilmSimulations.detect(in: [:]) == nil)
    }

    @Test func presetsUseKnownKeysAndRender() {
        for preset in FilmSimulations.presets {
            #expect(preset.collection == "Fujifilm")
            for key in preset.params.keys {
                #expect(ParamCatalog.spec(for: key) != nil, "\(preset.name) uses unknown \(key)")
            }
            let recipe = Recipe().applying(preset, amount: 1, defaults: .generic, stamp: testClock.now())
            let p = pixel(GradeGraph.apply(recipe, to: solid(0.2, 0.3, 0.4, size: 64), inputs: GradeInputs(defaults: .generic)), x: 32, y: 32)
            #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite)
        }
    }

    @Test(.enabled(if: !DecodeTests.fixtureFiles.isEmpty)) func detectsInRealFiles() async throws {
        for url in DecodeTests.fixtureFiles where url.lastPathComponent.uppercased().hasPrefix("DSCF") {
            let info = try await RawDecoder(cache: DecodeCache(directory: nil)).info(for: PhotoSource(url: url))
            print("\(url.lastPathComponent): film simulation \(info.filmSimulation ?? "none")")
            #expect(info.filmSimulation != nil)
        }
    }
}

@Suite struct FineAdjustTests {
    @Test func coarseDragFollowsTheFinger() {
        var tracker = FineAdjust.SliderTracker(startValue: 0.5, startX: 100)
        #expect(tracker.update(x: 150, distance: 0, width: 200) == 0.75)
        #expect(tracker.update(x: 400, distance: 10, width: 200) == 1, "clamped")
    }

    @Test func pullingAwayIsFinerWithoutJumping() {
        var tracker = FineAdjust.SliderTracker(startValue: 0.5, startX: 100)
        let coarse = tracker.update(x: 120, distance: 0, width: 200)
        #expect(abs(coarse - 0.6) < 1e-9)
        // Finger pulls 60 pt above the track: precision switches, value holds.
        let switched = tracker.update(x: 120, distance: 60, width: 200)
        #expect(tracker.precision == .fine)
        #expect(abs(switched - 0.6) < 1e-9)
        // A full track width now moves one tenth as far.
        let fine = tracker.update(x: 320, distance: 60, width: 200)
        #expect(abs(fine - 0.7) < 1e-9)
        // Even further away is finer still.
        _ = tracker.update(x: 320, distance: 200, width: 200)
        #expect(tracker.precision == .finer)
        let finer = tracker.update(x: 520, distance: 200, width: 200)
        #expect(abs(finer - 0.725) < 1e-9)
        // Coming back to the track resumes coarse movement from where it is.
        _ = tracker.update(x: 520, distance: 0, width: 200)
        #expect(tracker.precision == .coarse)
        #expect(abs(tracker.update(x: 540, distance: 0, width: 200) - 0.825) < 1e-9)
    }

    @Test func modifierForcesFine() {
        var tracker = FineAdjust.SliderTracker(startValue: 0.5, startX: 0)
        _ = tracker.update(x: 0, distance: 0, width: 100, forcedPrecision: .fine)
        #expect(abs(tracker.update(x: 100, distance: 0, width: 100, forcedPrecision: .fine) - 0.6) < 1e-9)
    }

    @Test func wheelMovesRelativelyAndClampsToDisc() {
        var tracker = FineAdjust.WheelTracker(start: (0, 0), touch: (50, 50))
        let p = tracker.update(touch: (75, 50), center: (50, 50), radius: 50)
        #expect(abs(p.x - 0.5) < 1e-9 && abs(p.y) < 1e-9)
        let up = tracker.update(touch: (75, 25), center: (50, 50), radius: 50)
        #expect(up.y > 0, "screen up is positive y")
        let far = tracker.update(touch: (400, 25), center: (50, 50), radius: 50)
        #expect(hypot(far.x, far.y) <= 1 + 1e-9)
    }

    @Test func wheelGoesFineOutsideTheWheel() {
        // A drag that starts near the bottom edge of a 100 pt-radius wheel.
        var tracker = FineAdjust.WheelTracker(start: (0, 0), touch: (100, 190))
        _ = tracker.update(touch: (100, 225), center: (100, 100), radius: 100)  // 25 pt outside: still coarse
        #expect(tracker.precision == .coarse)
        let before = tracker.update(touch: (100, 235), center: (100, 100), radius: 100)  // 35 pt outside
        #expect(tracker.precision == .fine)
        let after = tracker.update(touch: (200, 235), center: (100, 100), radius: 100)
        #expect(abs((after.x - before.x) - 0.1) < 1e-9)
        #expect(abs(after.y - before.y) < 1e-9)
    }
}
